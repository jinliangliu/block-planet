extends Node
## 一次性取证探针：打开任务与成就面板并截取视口画面（关闭按钮样式目检用）。
## 运行：Godot_console.exe --path . res://tests/quest_shot.tscn （需窗口，勿加 --headless）

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
	hud.open_quest_panel()
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var shot_path := _shot_path("quest_panel_shot.png")
	get_viewport().get_texture().get_image().save_png(shot_path)
	# 再切到成就页截第二张：两页共用同一个 ✕，都要确认融进窗体底色。
	hud._quest_panel.set_tab(QuestPanel.Tab.ACHIEVEMENTS)
	for i in range(10):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		_shot_path("quest_panel_shot_ach.png"))
	print("QUEST_SHOT_DONE ", shot_path)
	get_tree().quit(0)
