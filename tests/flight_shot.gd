extends Node
## 飞行器外观取证：在一条平整跑道上放一架飞机，第三人称 + 近景两张截图，
## 用于核对机模与玩家/方块的尺寸比例。需窗口运行，勿加 --headless。
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


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


func _ready() -> void:
	await _run()


func _run() -> void:
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
	Aircraft.spawn(main_scene, craft_pos, PI)

	# 玩家站到飞机侧前方，第三人称看全机（相机距离拉到上限 9）。
	player.set_physics_process(false)
	player.global_position = Vector3(
		float(origin.x) + 11.0, surface, float(origin.y) + 26.0)
	var dir := craft_pos - player.global_position
	player.rotation.y = atan2(-dir.x, -dir.z)
	player.camera_distance = Player.CAM_DISTANCE_MAX
	player._apply_camera_mode()
	for i in range(30):
		await get_tree().physics_frame
	var spring: SpringArm3D = player.get_node("SpringArm3D")
	spring.rotation.x = -0.16
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("flight_shot_wide.png"))

	# 近景：走到机身旁，第一人称看清座舱/机翼/起落架。
	player.global_position = Vector3(
		float(origin.x) + 7.5, surface, float(origin.y) + 28.5)
	player.camera_distance = 0.0
	player._apply_camera_mode()
	spring.rotation.x = -0.1
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("flight_shot_close.png"))

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
			for h in range(1, 7):
				world.set_block_deferred(Vector3i(x, y + h, z), BlockTypes.Block.AIR)
	world.rebuild_chunks_in_region(Vector3i(origin.x, 0, origin.y), max_cell)
	return y
