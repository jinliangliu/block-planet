extends Node
## 一次性取证探针：打开游戏说明书并截取视口画面存盘（UI 布局目检用）。
## 运行：Godot_console.exe --path . res://tests/manual_shot.tscn （需窗口，勿加 --headless）

const SAVE_PATH := "C:/Users/pc/Documents/github_repo/block-planet/manual_panel_shot.png"


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
	var manual: ManualPanel = hud._manual
	hud.open_manual()
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(SAVE_PATH)
	# 再切到第 6 页（狩猎与生态）截第二张，验证状态栏随页刷新。
	manual.select_page(6)
	for i in range(10):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(
		"C:/Users/pc/Documents/github_repo/block-planet/manual_panel_shot_p6.png")
	print("MANUAL_SHOT_DONE ", SAVE_PATH)
	get_tree().quit(0)
