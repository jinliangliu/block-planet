extends Node
## 机场生成 + 双击 F 回收 无头探针。
## 覆盖：
##   1) 带机场区域（默认亚洲）确实生成了跑道（COBBLESTONE 铺面 + 机库）；
##   2) 出生点落在跑道旁（脚下为跑道方块）；
##   3) 双击 F 回收停着的飞机：飞机从世界移除，生存模式退回背包 +1。
## 运行：Godot_v4.6.3-stable_win64_console.exe --headless --path . res://tests/airport_probe.tscn

var _failed := 0


## 看门狗：主场景加载 + 全量断言若中途异常（协程中断则不会 quit），
## 120 s 强制失败退出，避免无头进程无限空转。
func _watchdog() -> void:
	await get_tree().create_timer(120.0).timeout
	print("AIRPORT_TEST_FAILED count=%d (watchdog timeout)" % _failed)
	get_tree().quit(1)


func _ready() -> void:
	_watchdog()
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame

	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")

	# 回收测试走生存模式背包分支，结果可量化（背包 +1）。
	GameState.set_mode(GameState.Mode.SURVIVAL)

	# 1) 机场跑道已生成：统计机场区域内 COBBLESTONE 跑道方块数量。
	#    机场中心 (96,96)，跑道宽 12 / 长 57，机库另铺圆石，数量应远大于阈值。
	var cobble := 0
	for x in range(90, 103):
		for z in range(68, 126):
			for y in range(30, 46):
				if world.get_block(Vector3i(x, y, z)) == BlockTypes.Block.COBBLESTONE:
					cobble += 1
	_check(cobble > 200, "机场跑道已生成（COBBLESTONE 方块 %d）" % cobble)

	# 2) 出生点落在跑道旁：出生列脚下（±3 格）存在跑道方块 COBBLESTONE/SAND。
	var spawn_x := int(player.global_position.x)
	var spawn_z := int(player.global_position.z)
	var feet_y := int(player.global_position.y) - 1
	var on_runway := false
	for dx in range(-3, 4):
		for dz in range(-3, 4):
			var b := world.get_block(Vector3i(spawn_x + dx, feet_y, spawn_z + dz))
			if b == BlockTypes.Block.COBBLESTONE or b == BlockTypes.Block.SAND:
				on_runway = true
				break
		if on_runway:
			break
	_check(on_runway, "出生点落在跑道旁（出生列 %s）" % Vector3i(player.global_position.floor()))

	# 3) 双击 F 回收停着的飞机：在玩家侧旁放一架。place() 会把机身抬高
	#    GROUND_CLEARANCE，故先预扣该高度，使落位后机身与玩家同高、水平距约 6 m——
	#    距机身碰撞盒 > 登机余量（不误登机），且在回收半径（7 m）内。
	var craft := Aircraft.spawn(
		main_scene,
		player.global_position + Vector3(6.0, -Aircraft.GROUND_CLEARANCE, 0.0),
		0.0,
	)
	# 不在此处等帧：add_child 已同步触发 _ready 完成入组；等帧会让物理把机体挤出地面
	# 而上移，拉到与玩家的 3D 距离在 7m 回收半径附近抖动（偶发越界）。此处位置确定。
	_check(not craft.piloted and not craft.is_wrecked(), "测试飞机初始可用（未驾驶 / 未解体）")
	_check(craft.is_in_group("aircraft"), "测试飞机已登记到 aircraft 组")

	var before := player.inventory.count_item(ItemTypes.AIRCRAFT)
	# 第一次按 F：单按 → 走登机分支，因距机身碰撞盒 > BOARD_MARGIN 不登机；
	# 紧接第二次按 F：双击 → 走 _pickup_target 回收分支。
	player._handle_aircraft_key()
	player._handle_aircraft_key()
	await get_tree().process_frame  # 让 queue_free 生效
	_check(not is_instance_valid(craft), "双击 F 后飞机从世界移除")
	var after := player.inventory.count_item(ItemTypes.AIRCRAFT)
	_check(after == before + 1, "生存模式回收飞机退回背包（+1，%d → %d）" % [before, after])

	# 4) 飞行任务航路 / 降落区锚定机场（runway ↔ mission 联动）。
	var mm := MissionData.missions_for_airport(Vector3(96.0, 0.0, 96.0))
	_check(mm.size() == 3, "missions_for_airport 返回三任务")
	var landing: MissionData = mm[2]
	_check(landing.type == MissionData.Type.LANDING, "第三个任务为降落")
	_check(landing.zone_center.distance_to(Vector3(96.0, 0.0, 96.0)) < 0.01,
		"降落区锚定机场中心 (96,96)")
	var circuit: MissionData = mm[1]
	var anchored := circuit.waypoints.size() == 4
	for wp: Vector3 in circuit.waypoints:
		if Vector2(wp.x - 96.0, wp.z - 96.0).length() > 200.0:
			anchored = false
	_check(anchored, "绕点航路绕机场中心（4 点，均在 200 m 内）")

	# 4b) 降落任务要求停在跑道面（zone_block = COBBLESTONE）。
	_check(landing.zone_block() == BlockTypes.Block.COBBLESTONE,
		"降落任务要求停在跑道面（zone_block=COBBLESTONE）")

	# 4c) 绕点航路为单向进场矩形：末航点落在跑道中线上（最后一程直线进场），
	#     首航点越过跑道北端（+28），第三航点在南端外侧。
	var wps := circuit.waypoints
	var sized := wps.size() == 4
	var final_on_centerline := sized and is_equal_approx(wps[3].x, 96.0) and is_equal_approx(wps[0].x, 96.0)
	var spans_runway := sized and wps[0].z > 96.0 + 28.0 and wps[2].z < 96.0 - 28.0
	_check(final_on_centerline and spans_runway, "绕点航路末程对准跑道中线（单向进场，x=96）")

	# 端到端：main 经 HUD 注入后，面板实际持有的是锚定机场的任务集。
	var hud_node: HUD = main_scene.get_node("UI")
	var panel: MissionPanel = hud_node._mission_panel if hud_node != null else null
	var live_ok := false
	if panel != null and panel._missions.size() == 3:
		var live_landing: MissionData = panel._missions[2]
		live_ok = live_landing.zone_center.distance_to(Vector3(96.0, 0.0, 96.0)) < 0.01
	_check(live_ok, "面板降落区已锚定机场（端到端注入生效）")

	# 5) 简易降落场（build_field）：大洋/极地区域的无机库短跑道。
	#    在亚洲场景里手动建一座验证生成器本身（场址用 main 的选址逻辑）。
	var site: Vector3i = main_scene._find_field_site()
	var field_spawn: Vector3 = AirportBuilder.new().build_field(world, site)
	_check(field_spawn != Vector3.ZERO, "build_field 返回出生点（%s）" % field_spawn)
	# 出生列脚下为跑道铺面（COBBLESTONE/SAND）。
	var fx := int(field_spawn.x)
	var fz := int(field_spawn.z)
	var fy := int(field_spawn.y) - 1
	var feet_on_field := false
	for dx in range(-3, 4):
		for dz in range(-3, 4):
			var fb := world.get_block(Vector3i(fx + dx, fy, fz + dz))
			if fb == BlockTypes.Block.COBBLESTONE or fb == BlockTypes.Block.SAND:
				feet_on_field = true
				break
		if feet_on_field:
			break
	_check(feet_on_field, "降落场出生点落在跑道面上")
	# 铺面完整：宽 10 × 长 32 = 320 个 COBBLESTONE（无机库）。
	var field_cobble := 0
	for x in range(site.x - 7, site.x + 8):
		for z in range(site.z - 18, site.z + 19):
			for y in range(20, 50):
				if world.get_block(Vector3i(x, y, z)) == BlockTypes.Block.COBBLESTONE:
					field_cobble += 1
	_check(field_cobble >= 320, "降落场跑道铺面完整（COBBLESTONE %d ≥ 320）" % field_cobble)

	if _failed == 0:
		print("AIRPORT_TEST_OK")
		get_tree().quit(0)
	else:
		print("AIRPORT_TEST_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
