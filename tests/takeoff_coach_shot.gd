extends Node
## 起飞教练取证（D-043）：登机后按「点火 → 推油门 → 滑跑 → 抬轮 → 离地」
## 五个阶段各出一张截图，验证教练条文案、配色与进度条是否随状态推进。
##
## 不依赖长跑道：速度由 Aircraft.launch() 直接给（抬轮段给到抬轮速度以上即可
## 触发「按 ↑ 抬轮」，无需真的滑跑 18 m）。操纵量走 drive_remotely 外部写入，
## 与飞行手感无关，只验证教练条的状态机与绘制。
## 需窗口运行，勿加 --headless。
## 运行：Godot_v4.6.3-stable_win64_console.exe --path . res://tests/takeoff_coach_shot.tscn

const SHOT_DIR := "res://tmp"

## 自建平整跑道（对齐 flight_hud_shot）：出生点附近不一定平，斜坡会让飞机一落
## 地就撞地形解体，取证失真。
const STRIP_CANDIDATES := [
	Vector2i(300, 300),
	Vector2i(300, 600),
	Vector2i(600, 300),
	Vector2i(600, 600),
]
const STRIP_WIDTH := 10
const STRIP_LENGTH := 64

var _craft: Aircraft = null
var _player: Player = null


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


func _wait(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


func _wait_physics(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


func _snap(file_name: String) -> void:
	await _wait(2)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path(file_name))
	var s := _craft.snapshot()
	print("DBG ", file_name, " engine=", s["engine"], " throttle=%.2f" % float(s["throttle"]),
		" kmh=%.1f" % float(s["kmh"]), " vs=%.1f m/s" % float(s["stall_speed"]),
		" on_ground=", s["on_ground"], " agl=%.1f" % float(s["altitude_agl"]))


func _ready() -> void:
	await _run()


func _run() -> void:
	SaveGuard.snapshot()
	GameState.needs_region_pick = false
	GameState.current_region = RegionAtlas.ASIA

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	await _wait(120)

	var hud: HUD = main_scene.get_node("UI")
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
	# 停刷怪：生物撞机会扰动滑跑段（对齐 flight_hud_shot）。
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	await _wait(20)

	_player = main_scene.get_node("Player")
	var world: World = main_scene.get_node("World")
	# 以玩家出生点为中心清出一块净空并抹平脚下地面：出生点本身就是平地，
	# 只需清掉头顶的树/杂物，飞机落下才不会当场解体（比自建跑道更稳——
	# 候选跑道坐标会随区域尺寸落到地图外、飞机掉进虚空）。
	var base := _player.global_position
	var ox := int(base.x)
	var oz := int(base.z)
	var ground_y := int(base.y) - 1
	var min_cell := Vector3i(ox - 16, 0, oz - 16)
	var max_cell := Vector3i(ox + 16, 0, oz + 16)
	world.ensure_chunks_in_region(min_cell, max_cell)
	for x in range(ox - 16, ox + 17):
		for z in range(oz - 16, oz + 17):
			if world.get_block(Vector3i(x, ground_y, z)) == BlockTypes.Block.AIR:
				world.set_block_deferred(Vector3i(x, ground_y, z),
					BlockTypes.Block.COBBLESTONE)
			for h in range(1, 13):
				world.set_block_deferred(Vector3i(x, ground_y + h, z),
					BlockTypes.Block.AIR)
	world.rebuild_chunks_in_region(min_cell, max_cell)
	await _wait_physics(12)

	var spawn_pos := Vector3(float(ox) + 0.5, float(ground_y) + 0.3, float(oz) + 0.5)
	_craft = Aircraft.spawn(main_scene, spawn_pos, PI)
	await _wait_physics(2)

	# 先登机 + 远程驾驶：飞机在**未驾驶**时物理积分不跑，先等落地会永远悬空。
	# 登机后物理激活，再等它自然落稳（on_ground 且几乎不动）。
	_player.ride_aircraft(_craft)
	_craft.drive_remotely()
	for i in range(300):
		await get_tree().physics_frame
		if _craft.is_on_floor() and _craft.velocity.length() < 0.5:
			break
	await _wait_physics(6)

	# ① 刚登机：发动机默认熄火（这正是新手「推油门没反应」的卡点）。
	await _snap("coach_1_engine_off.png")

	# ② 已点火、油门 0。
	_craft.set_engine(true)
	_craft.controls.throttle = 0.0
	await _wait_physics(4)
	await _snap("coach_2_throttle.png")

	# ③ 油门推满、速度还不够。
	_craft.controls.throttle = 1.0
	await _wait_physics(40)
	await _snap("coach_3_roll.png")

	# ④ 给到抬轮速度以上：教练该喊「按 ↑ 抬轮」。
	var vr_mps := float(_craft.snapshot()["stall_speed"]) * 1.2
	_craft.launch(vr_mps + 2.0)
	await _wait_physics(4)
	await _snap("coach_4_rotate.png")

	# ⑤ 拉杆离地：爬升中 / 起飞成功。
	_craft.controls.pitch = 0.7
	for i in range(180):
		await get_tree().physics_frame
		if float(_craft.snapshot()["altitude_agl"]) > 4.0:
			break
	await _snap("coach_5_climb.png")

	for i in range(240):
		await get_tree().physics_frame
		if float(_craft.snapshot()["altitude_agl"]) > 16.0:
			break
	await _snap("coach_6_success.png")

	SaveGuard.restore()
	get_tree().quit(0)


func _pick_strip_origin(world: World) -> Vector2i:
	var best := STRIP_CANDIDATES[0]
	var best_top := 1 << 30
	for candidate: Vector2i in STRIP_CANDIDATES:
		world.ensure_chunks_in_region(
			Vector3i(candidate.x, 0, candidate.y),
			Vector3i(candidate.x + STRIP_WIDTH, 0, candidate.y + STRIP_LENGTH))
		var top := 0
		for x in range(candidate.x, candidate.x + STRIP_WIDTH + 1, 2):
			for z in range(candidate.y, candidate.y + STRIP_LENGTH + 1, 2):
				top = maxi(top, world.get_surface_height(x, z))
		if top < best_top:
			best_top = top
			best = candidate
	return best


func _build_strip(world: World, origin: Vector2i) -> int:
	var max_cell := Vector3i(origin.x + STRIP_WIDTH, 0, origin.y + STRIP_LENGTH)
	world.ensure_chunks_in_region(Vector3i(origin.x, 0, origin.y), max_cell)
	var top := 0
	for x in range(origin.x, origin.x + STRIP_WIDTH + 1):
		for z in range(origin.y, origin.y + STRIP_LENGTH + 1):
			top = maxi(top, world.get_surface_height(x, z))
	var y := top + 1
	if y > 58:
		y = 58
	for x in range(origin.x, origin.x + STRIP_WIDTH + 1):
		for z in range(origin.y, origin.y + STRIP_LENGTH + 1):
			world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.COBBLESTONE)
			for h in range(1, 10):
				world.set_block_deferred(Vector3i(x, y + h, z), BlockTypes.Block.AIR)
	world.rebuild_chunks_in_region(Vector3i(origin.x, 0, origin.y), max_cell)
	return y
