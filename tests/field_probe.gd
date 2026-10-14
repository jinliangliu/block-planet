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

	# 2b) 进近导航灯：南端绿门槛（进场）/ 北端红端行（远端），视觉对齐 +Z 进近。
	#     降落场 FIELD_LEN=32：出生点落在 center.z-_len/2+3，故南绿在 spawn_z-3、
	#     北红在 spawn_z+29（均在已整平足迹内、base_y 高度）。
	#     先同步强制加载降落场整区（流式 LOAD_RADIUS=2 可能未载到北端所在 chunk）。
	world.ensure_chunks_in_region(
		Vector3i(spawn_cell.x - 16, 0, spawn_cell.z - 16),
		Vector3i(spawn_cell.x + 16, 0, spawn_cell.z + 40))
	var nav_ok := false
	for dx in range(-5, 6):
		var south := world.get_block(Vector3i(spawn_cell.x + dx, feet_y, spawn_cell.z - 3))
		var north := world.get_block(Vector3i(spawn_cell.x + dx, feet_y, spawn_cell.z + 29))
		if south == BlockTypes.Block.NAV_GREEN and north == BlockTypes.Block.NAV_RED:
			nav_ok = true
			break
	_check(nav_ok, "降落场进近导航灯：南绿（进场端）/ 北红（远端）")

	# 2c) 渲染接线：灯块面汇入独立 emissive MeshInstance，且该网格带 ARRAY_COLOR
	#     顶点色；emissive 材质为 unshaded + vertex_color_use_as_albedo（夜恒亮、
	#     零动态光、不打断主世界合批）。仅验接线，不验像素。
	var emissive_ok := false
	for coord in world._chunks.keys():
		var ch: Chunk = world._chunks[coord]
		var emi: MeshInstance3D = ch._emissive_mesh_instance
		if emi == null or emi.mesh == null:
			continue
		var arrs: Array = emi.mesh.surface_get_arrays(0)
		var cols: Variant = arrs[Mesh.ARRAY_COLOR]
		if cols != null and (cols as PackedColorArray).size() > 0:
			emissive_ok = true
			break
	_check(emissive_ok, "导航灯汇入独立 emissive 网格（含 ARRAY_COLOR 顶点色）")
	var emat: StandardMaterial3D = world._emissive_material
	_check(emat != null and emat.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED
		and emat.vertex_color_use_as_albedo,
		"emissive 材质为 unshaded + 顶点色作反照率（夜恒亮、零动态光）")

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
