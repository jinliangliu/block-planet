extends Node
## 航海玩法取证（D-042）：在太平洋（带港口的大洋区）启动，登船后出两张截图——
## ① 第三人称：船模 + 航海 HUD（罗经/坐标/海况/航向/油量）同框；
## ② 码头视角：沙滩平台 + 木栈桥 + 灯塔 + 港湾里异型景观船。
## 需窗口运行，勿加 --headless。
## 运行：Godot_v4.6.3-stable_win64_console.exe --path . res://tests/boat_shot.tscn

const SHOT_DIR := "res://tmp"


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


func _player_boat(main_scene: Node) -> Boat:
	for child in main_scene.get_children():
		var b := child as Boat
		if b != null and is_instance_valid(b) and b.use_player_input and b.harbor_pos != Vector3.ZERO:
			return b
	return null


func _ready() -> void:
	await _run()


func _run() -> void:
	SaveGuard.snapshot()
	GameState.needs_region_pick = false
	GameState.current_region = RegionAtlas.PACIFIC

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(120):
		await get_tree().process_frame

	var player: Player = main_scene.get_node("Player")
	var hud: HUD = main_scene.get_node("UI")
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
	for i in range(20):
		await get_tree().process_frame

	var pb: Boat = _player_boat(main_scene)
	if pb == null:
		push_error("boat_shot: 未找到默认船")
		SaveGuard.restore()
		get_tree().quit(1)
		return

	# 码头视角：站在泊位后方看港口（不登船，HUD 不显）。
	player.set_physics_process(false)
	var hp: Vector3 = pb.harbor_pos
	player.global_position = hp + Vector3(11.0, 4.0, 13.0)
	var look := hp + Vector3(0.0, 1.0, 0.0) - player.global_position
	player.rotation.y = atan2(-look.x, -look.z)
	player.camera_distance = 9.0
	player._apply_camera_mode()
	for i in range(25):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("boat_shot_harbor.png"))

	# 登船：第三人称看船模 + 航海 HUD。
	player.set_physics_process(true)
	player.ride_boat(pb)
	for i in range(30):
		await get_tree().physics_frame
	# 等登船提示条（Events.notice，居中顶部停留 2.2 s 再淡出 0.6 s）走完再截图，
	# 否则它超长的文字会溢出 640 px 文本框、压到右上角海况面板上。
	for i in range(180):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("boat_shot_riding.png"))

	SaveGuard.restore()
	get_tree().quit(0)
