extends Node
## 一次性取证探针：在「探索模式」下打开地图选择器，把地球转到若干角度，
## 截取带飞行旗帜的地球页存盘，供 UI 布局目检。
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/globe_flags_shot.tscn （需窗口，勿加 --headless）

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
	# 先切到探索模式，再开选择器，让模式列正确显示「✓ 探索」。
	GameState.set_mode(GameState.Mode.EXPLORE)
	hud.open_map_selector()
	for i in range(25):
		await get_tree().process_frame

	var globe = hud._map_selector._globe
	var angles := [
		{"yaw": 20.0, "pitch": -25.0},
		{"yaw": 140.0, "pitch": -20.0},
		{"yaw": 260.0, "pitch": -28.0},
	]
	var idx := 0
	for a in angles:
		globe.set_view_angles(a["yaw"], a["pitch"])
		for i in range(15):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var path := _shot_path("globe_flags_%d.png" % idx)
		get_viewport().get_texture().get_image().save_png(path)
		print("GLOBE_FLAGS_SHOT_DONE %d -> %s" % [idx, path])
		idx += 1

	get_tree().quit(0)
