extends Node
## 一次性取证探针：截游戏内 HUD 右上角，看模式徽章贴在小地图外框下的效果。
## 三种模式各截一张，验证换字与换色。
## 运行：Godot_console.exe --path . res://tests/hud_mode_shot.tscn （需窗口，勿加 --headless）

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
	for i in range(90):
		await get_tree().process_frame
	var hud: HUD = main_scene.get_node("UI")
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
		for i in range(10):
			await get_tree().process_frame
	GameState.set_mode(GameState.Mode.SURVIVAL)
	await _shoot("hud_mode_survival.png", 20)
	GameState.set_mode(GameState.Mode.CREATIVE)
	await _shoot("hud_mode_creative.png", 10)
	GameState.set_mode(GameState.Mode.EXPLORE)
	await _shoot("hud_mode_explore.png", 10)
	print("HUD_MODE_SHOT_DONE")
	get_tree().quit(0)


func _shoot(file_name: String, frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path(file_name))
