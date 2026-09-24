extends Node
## 一次性取证探针：打开生物图鉴并截取视口画面存盘（UI 布局目检用）。
## 运行：Godot_console.exe --path . res://tests/bestiary_shot.tscn （需窗口，勿加 --headless）

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

	hud.open_bestiary()
	var panel: BestiaryUI = hud._bestiary
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("bestiary_shot_all.png"))

	# 第二张：筛到「动物 / 哺乳动物」并点开一张卡片，弹出居中预览卡（3D 模型）。
	panel._set_kingdom("animalia")
	panel._set_category("mammal")
	panel._region = "asia"
	panel._rebuild_chips()
	panel._refresh_grid()
	panel._on_card_pressed("giant_panda")
	for i in range(12):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("bestiary_shot_preview.png"))
	panel._close_preview()
	for i in range(6):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("bestiary_shot_filtered.png"))

	# 第三张：知识问答页（出题 + 答一题看讲解）。
	panel._set_tab(BestiaryUI.Tab.QUIZ)
	for i in range(10):
		await get_tree().process_frame
	panel._on_option_pressed(panel._quiz_answer)
	for i in range(10):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("bestiary_shot_quiz.png"))

	print("BESTIARY_SHOT_DONE ", _shot_path("bestiary_shot_all.png"))
	get_tree().quit(0)
