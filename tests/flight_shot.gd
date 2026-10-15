extends Node
## 飞行器外观/驾驶舱取证：在一条平整跑道上放一架飞机，出四张截图——
## ① 第三人称全景 ② 近景 ③ 坐进驾驶舱后的第一人称（座舱视角）④ 追尾视角。
## 用于核对机模比例、座椅位与相机高度是否自洽。需窗口运行，勿加 --headless。
## 运行：Godot_v4.6.3-stable_win64_console.exe --path . res://tests/flight_shot.tscn

const SHOT_DIR := "res://tmp"
const STRIP_CANDIDATES := [
	Vector2i(300, 300),
	Vector2i(300, 600),
	Vector2i(600, 300),
	Vector2i(600, 600),
]
const STRIP_WIDTH := 10
const STRIP_LENGTH := 64

var _craft: Aircraft


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


func _ready() -> void:
	await _run()


func _run() -> void:
	# 存档隔离（D-010 铁律 3）：登机时玩家碰撞盒与机身重叠会被 depenetration
	# 顶起一帧，on_floor 边沿跳变触发 aircraft_took_off → flew +1（实测泄漏），
	# 快照须在实例化 main.tscn 之前。
	SaveGuard.snapshot()
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(90):
		await get_tree().process_frame
	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")
	var hud: HUD = main_scene.get_node("UI")
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
	GameState.needs_region_pick = false
	for i in range(30):
		await get_tree().process_frame

	var origin := _pick_strip_origin(world)
	var strip_y := _build_strip(world, origin)
	var surface := float(strip_y + 1)
	# 跑道中央放一架飞机，机头朝 +Z（与跑道同向）。
	var craft_pos := Vector3(
		float(origin.x) + 5.0, surface, float(origin.y) + 32.0)
	_craft = Aircraft.spawn(main_scene, craft_pos, PI)

	# 全景：站在跑道铺面上、机头前方（净空只清了跑道本宽，站旁边会被树挡住），
	# 第一人称避免玩家入镜，拍完整机。
	player.set_physics_process(false)
	player.global_position = Vector3(
		float(origin.x) + 5.0, surface, float(origin.y) + 8.0)
	var dir := craft_pos - player.global_position
	player.rotation.y = atan2(-dir.x, -dir.z)
	player.camera_distance = 0.0
	player._apply_camera_mode()
	for i in range(30):
		await get_tree().physics_frame
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("flight_shot_wide.png"))

	# 近景：站在机尾后方铺面上，第三人称中距——玩家与飞机同框作比例参照。
	player.global_position = Vector3(
		float(origin.x) + 7.5, surface, float(origin.y) + 47.0)
	dir = craft_pos - player.global_position
	player.rotation.y = atan2(-dir.x, -dir.z)
	player.camera_distance = 5.0
	player._apply_camera_mode()
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("flight_shot_close.png"))

	# ── 登机：核对座椅位与相机高度 ──────────────────────────
	# 必须恢复物理：玩家每帧在 _physics_process 里被贴到座舱位，物理停着就不会动。
	player.set_physics_process(true)
	player.ride_aircraft(_craft)
	for i in range(10):
		await get_tree().physics_frame
	var cam: Camera3D = player.get_node("Camera3D")
	print("craft_origin=", _craft.global_position)
	print("seat(玩家原点=脚底)=", player.global_position,
		"  相对机体=", player.global_position - _craft.global_position)
	print("第一人称相机世界位=", cam.global_position,
		"  相对机体=", cam.global_position - _craft.global_position)
	print("机模最高点(垂尾顶)=", _craft.global_position.y + 1.425 * AircraftModel.MODEL_SCALE)

	# ③ 座舱视角：第一人称、视线水平（看机头前方）。
	var spring: SpringArm3D = player.get_node("SpringArm3D")
	player.camera_distance = 0.0
	player._apply_camera_mode()
	spring.rotation.x = 0.0
	player.get_node("Camera3D").rotation = Vector3.ZERO
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("flight_shot_cockpit.png"))

	# ④ 追尾视角：驾驶时的默认相机（距离与俯仰都是驾驶专用默认值）。
	player.camera_distance = Player.CAM_DISTANCE_MAX_RIDING
	player._apply_camera_mode()
	spring.rotation.x = Player.CHASE_PITCH_RIDING
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("flight_shot_chase.png"))

	SaveGuard.restore()
	print("FLIGHT_SHOT_DONE strip_y=%d" % strip_y)
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
			# 净空 9 格：垂尾顶在跑道面上 6.8 格，须整体清出。
			for h in range(1, 10):
				world.set_block_deferred(Vector3i(x, y + h, z), BlockTypes.Block.AIR)
	world.rebuild_chunks_in_region(Vector3i(origin.x, 0, origin.y), max_cell)
	return y
