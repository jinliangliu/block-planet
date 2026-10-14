extends Node
## 非机场区域（太平洋）简易降落场 + 任务锚定 无头探针。
## 覆盖：
##   1) 大洋区域出生点旁生成了降落场（圆石跑道，出生点落在跑道面上）；
##   2) 降落场支持 block 为实体（建在岛上，不是海里）；
##   3) 任务航路 / 降落区锚定降落场中心，且要求停在跑道面（端到端经 HUD 注入面板）。
## 运行：Godot_v4.6.3-stable_win64_console.exe --headless --path . res://tests/field_probe.tscn

var _failed := 0


## 看门狗：主场景加载 + 全量断言若中途异常（协程中断则不会 quit），
## 120 s 强制失败退出，避免无头进程无限空转。
func _watchdog() -> void:
	await get_tree().create_timer(120.0).timeout
	print("FIELD_TEST_FAILED count=%d (watchdog timeout)" % _failed)
	get_tree().quit(1)


func _ready() -> void:
	_watchdog()
	await _run()


func _run() -> void:
	# 切到太平洋（has_landing_field 区域）再加载主场景。
	GameState.set_region(RegionAtlas.PACIFIC)
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame

	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")

	# 1) 降落场已生成：出生列脚下存在跑道方块（COBBLESTONE/SAND）。
	var spawn_cell := Vector3i(player.global_position.floor())
	var feet_y := spawn_cell.y - 1
	var on_field := false
	for dx in range(-3, 4):
		for dz in range(-3, 4):
			var b := world.get_block(Vector3i(spawn_cell.x + dx, feet_y, spawn_cell.z + dz))
			if b == BlockTypes.Block.COBBLESTONE or b == BlockTypes.Block.SAND:
				on_field = true
				break
		if on_field:
			break
	_check(on_field, "太平洋出生点落在降落场跑道面上（%s）" % spawn_cell)

	# 2) 支持 block 为实体：降落场必须建在岛/冰面上，不是海里。
	var support := world.get_block(Vector3i(spawn_cell.x, feet_y, spawn_cell.z))
	_check(support != BlockTypes.Block.AIR and support != BlockTypes.Block.WATER,
		"降落场支持 block 为实体（%d，非水非空）" % support)

	# 3) 任务锚定降落场：面板降落区中心在出生点旁（场址即锚点），且带跑道面要求。
	var hud_node: HUD = main_scene.get_node("UI")
	var panel: MissionPanel = hud_node._mission_panel if hud_node != null else null
	var live_ok := false
	if panel != null and panel._missions.size() == 3:
		var live_landing: MissionData = panel._missions[2]
		var center := Vector2(live_landing.zone_center.x, live_landing.zone_center.z)
		live_ok = center.distance_to(Vector2(spawn_cell.x, spawn_cell.z)) < 24.0 \
			and live_landing.zone_block() == BlockTypes.Block.COBBLESTONE
	_check(live_ok, "任务降落区锚定降落场且要求跑道面（端到端注入生效）")

	if _failed == 0:
		print("FIELD_TEST_OK")
		get_tree().quit(0)
	else:
		print("FIELD_TEST_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
