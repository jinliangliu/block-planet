extends Node
## 一次性取证探针：打开合成台面板并截取视口画面存盘（UI 布局目检用）。
## 运行：Godot_console.exe --path . res://tests/craft_shot.tscn （需窗口，勿加 --headless）

const SAVE_PATH := "C:/Users/pc/Documents/github_repo/block-planet/craft_panel_shot.png"


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
	image.save_png(SAVE_PATH)
	print("CRAFT_SHOT_DONE ", SAVE_PATH)
	get_tree().quit(0)
