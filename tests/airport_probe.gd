extends Node
## 机场生成 + 双击 F 回收 无头探针。
## 覆盖：
##   1) 带机场区域（默认亚洲）确实生成了跑道（COBBLESTONE 铺面 + 机库）；
##   2) 出生点落在跑道旁（脚下为跑道方块）；
##   3) 双击 F 回收停着的飞机：飞机从世界移除，生存模式退回背包 +1。
## 运行：Godot_v4.6.3-stable_win64_console.exe --headless --path . res://tests/airport_probe.tscn

var _failed := 0


func _ready() -> void:
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
	await get_tree().process_frame
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
