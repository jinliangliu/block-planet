extends Node
## 一次性取证探针：截取地图选择器地球页（含模式三选一）存盘，UI 布局目检用。
## 运行：Godot_console.exe --path . res://tests/map_mode_shot.tscn （需窗口，勿加 --headless）

## 截图输出目录：tmp/ 属本地临时产物，已由 .gitignore 忽略。
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
	hud.open_map_selector()
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var first := _shot_path("map_mode_shot.png")
	get_viewport().get_texture().get_image().save_png(first)
	# 改选探索模式再截一张：验证选中态与说明文案随选切换，
	# 并确认飞行旗帜与 🏁 赛道竞速入口只在探索模式出现（D-041）。
	hud._map_selector._select_mode(GameState.Mode.EXPLORE)
	for i in range(10):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("map_mode_shot_explore.png"))
	print("MAP_MODE_SHOT_DONE ", first)
	get_tree().quit(0)
