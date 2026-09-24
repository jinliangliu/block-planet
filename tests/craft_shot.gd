extends Node
## 一次性取证探针：打开合成台面板并截取视口画面存盘（UI 布局目检用）。
## 运行：Godot_console.exe --path . res://tests/craft_shot.tscn （需窗口，勿加 --headless）

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
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
		for i in range(10):
			await get_tree().process_frame
	hud.set_craft_open(true)
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var shot_path := _shot_path("craft_panel_shot.png")
	image.save_png(shot_path)
	print("CRAFT_SHOT_DONE ", shot_path)
	get_tree().quit(0)
