extends Node
## 一次性取证探针：机场 / 降落场进近导航灯目检——自发光方块在昼/夜的实际颜色。
## 关注点：南端绿门槛 / 北端红端行 / 黄虚线中线 / 白边缘线是否按顶点色渲染
##（曾因误用 Godot 3 的 vertex_colors_enabled 导致整片渲染成白色）。
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/nav_shot.tscn （需窗口，勿加 --headless）

const SHOT_DIR := "res://tmp"


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


func _ready() -> void:
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame
	var hud: HUD = main_scene.get_node("UI")
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
		for i in range(10):
			await get_tree().process_frame
	var player: Player = main_scene.get_node("Player")
	var day_night: DayNightCycle = main_scene.get_node("DayNightCycle")

	# 玩家移到跑道中段 (96, base_y+1, 96)：让流式加载半径（±2 区块）覆盖整条跑道，
	# 含北端红行所在 chunk（z 112-127），否则 get_block/渲染都看不到北端。
	player.global_position = Vector3(96.5, 38.0, 96.5)
	player.velocity = Vector3.ZERO
	for i in range(90):
		await get_tree().process_frame

	# 自由相机悬在跑道中线上方垂直俯瞰，每帧重设 current 以防玩家相机抢回。
	var cam := Camera3D.new()
	cam.position = Vector3(96.5, 44.0, 96.5)
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	cam.fov = 80.0
	main_scene.add_child(cam)

	# 夜间：自发光导航灯应恒亮（不受方向光夜降影响）。
	day_night._time = DayNightCycle.DAY_LENGTH + DayNightCycle.NIGHT_LENGTH * 0.5
	for i in range(40):
		cam.make_current()
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var night_path := _shot_path("nav_night_shot.png")
	get_viewport().get_texture().get_image().save_png(night_path)
	print("NAV_SHOT_DONE ", night_path)

	# 夜间南端特写：应见一条绿色门槛行（进场端）。
	cam.position = Vector3(96.5, 42.0, 66.5)
	for i in range(30):
		cam.make_current()
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var south_path := _shot_path("nav_night_south_shot.png")
	get_viewport().get_texture().get_image().save_png(south_path)
	print("NAV_SHOT_DONE ", south_path)

	# 夜间北端特写：应见一条红色端行（远端）。
	cam.position = Vector3(96.5, 42.0, 125.5)
	for i in range(30):
		cam.make_current()
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var north_path := _shot_path("nav_night_north_shot.png")
	get_viewport().get_texture().get_image().save_png(north_path)
	print("NAV_SHOT_DONE ", north_path)

	cam.position = Vector3(96.5, 44.0, 96.5)

	# 白天对照：灯块应与深色跑道面形成清晰色差。
	day_night._time = DayNightCycle.DAY_LENGTH * 0.4
	for i in range(40):
		cam.make_current()
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var day_path := _shot_path("nav_day_shot.png")
	get_viewport().get_texture().get_image().save_png(day_path)
	print("NAV_SHOT_DONE ", day_path)
	get_tree().quit(0)
