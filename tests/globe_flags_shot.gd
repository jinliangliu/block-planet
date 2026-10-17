extends Node
## 一次性取证探针：在「探索」模式打开地图选择器，把地球依次转到四大洋与
## 一个机场大洲的正对角度，截取球面 3D 标记（小飞机 ✈️ / 小鱼 🐟）存盘目检。
## 取景角度由区域锚点自动求解（扫 yaw/pitch 找该区域最正对相机的一组），
## 不写死角度——改锚点或加区域都不会拍空。
##
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/globe_flags_shot.tscn （需窗口，勿加 --headless）

const SHOT_DIR := "res://tmp"

## 取景目标：四大洋看小鱼 + 降落场小飞机，亚洲看机场小飞机（红涂装）。
const TARGETS := [
	{"region": RegionAtlas.PACIFIC, "name": "pacific"},
	{"region": RegionAtlas.ATLANTIC, "name": "atlantic"},
	{"region": RegionAtlas.INDIAN, "name": "indian"},
	{"region": RegionAtlas.ARCTIC, "name": "arctic"},
	{"region": RegionAtlas.ASIA, "name": "asia_airport"},
]


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


## 区域锚点最正对相机时的 (yaw, pitch)。球节点 rotation_degrees=(pitch,yaw,0)
## 对应 Basis.from_euler 的 YXZ 序，这里用同一套变换扫描，保证与渲染一致。
func _best_view(region_id: int) -> Vector2:
	var anchor: Vector2 = RegionAtlas.REGION_ANCHORS[region_id]
	var dir: Vector3 = RegionAtlas.lat_lon_to_dir(anchor.x, anchor.y)
	var best := Vector2.ZERO
	var best_z := -2.0
	for yaw in range(-180, 180, 5):
		for pitch in range(-70, 71, 5):
			var b := Basis.from_euler(Vector3(
				deg_to_rad(float(pitch)), deg_to_rad(float(yaw)), 0.0))
			var facing := (b * dir).z
			if facing > best_z:
				best_z = facing
				best = Vector2(float(yaw), float(pitch))
	return best


func _ready() -> void:
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame

	var hud: HUD = main_scene.get_node("UI")
	# 先切到探索模式，再开选择器：小飞机只在探索模式显示（D-041）。
	GameState.set_mode(GameState.Mode.EXPLORE)
	hud.open_map_selector()
	for i in range(25):
		await get_tree().process_frame

	var globe = hud._map_selector._globe
	print("DBG planes=%d fields=%d fish=%d flight_visible=%s fish_visible=%s" % [
		globe.airport_marker_count(), globe.field_marker_count(), globe.fish_marker_count(),
		globe.flight_flags_visible(), globe.fish_markers_visible(),
	])

	for target in TARGETS:
		var region_id: int = int(target["region"])
		var view: Vector2 = _best_view(region_id)
		globe.set_view_angles(view.x, view.y)
		for i in range(20):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var path := _shot_path("globe_markers_%s.png" % String(target["name"]))
		get_viewport().get_texture().get_image().save_png(path)
		print("GLOBE_MARKERS_SHOT %s view=(%.0f,%.0f) -> %s" % [
			String(target["name"]), view.x, view.y, path])
		await get_tree().process_frame

	get_tree().quit(0)
