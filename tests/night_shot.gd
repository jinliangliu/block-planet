extends Node
## 一次性取证探针：夜景目检——卡通月亮、闪烁星星、村庄玻璃窗透明。
## 运行：Godot_console.exe --path . res://tests/night_shot.tscn （需窗口，勿加 --headless）

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
	var player: Player = main_scene.get_node("Player")
	var day_night: DayNightCycle = main_scene.get_node("DayNightCycle")

	# 拨到午夜 + 玩家站到村庄广场上看向民居玻璃窗。
	day_night._time = DayNightCycle.DAY_LENGTH + DayNightCycle.NIGHT_LENGTH * 0.5
	var base_y := day_night_get_base(player)
	player.global_position = Vector3(23.5, float(base_y) + 1.2, 26.5)
	player.velocity = Vector3.ZERO
	for i in range(30):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var night_path := _shot_path("night_village_shot.png")
	get_viewport().get_texture().get_image().save_png(night_path)
	print("NIGHT_SHOT_DONE ", night_path)

	# 抬头偏西看月亮与星空（月亮挂在西北 ~43° 方位、30° 仰角）。
	player.rotation_degrees.y = 40.0
	player._camera.rotation_degrees.x = 26.0
	for i in range(30):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var moon_path := _shot_path("night_moon_shot.png")
	get_viewport().get_texture().get_image().save_png(moon_path)
	print("MOON_SHOT_DONE ", moon_path)
	player.rotation_degrees.y = 0.0
	player._camera.rotation_degrees.x = 0.0

	# 白天同机位：玻璃窗透明中心在白天也应可见（对照图）。
	day_night._time = DayNightCycle.DAY_LENGTH * 0.4
	for i in range(30):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var day_path := _shot_path("day_village_shot.png")
	get_viewport().get_texture().get_image().save_png(day_path)
	print("DAY_SHOT_DONE ", day_path)
	get_tree().quit(0)


## 村庄基准高度：与 VillageBuilder._probe_base_y 同款（探针侧独立复算）。
func day_night_get_base(_player: Player) -> int:
	var world: World = get_child(0).get_node("World")
	var top := 0
	for x in range(VillageBuilder.REGION_MIN.x, VillageBuilder.REGION_MAX.x + 1):
		for z in range(VillageBuilder.REGION_MIN.z, VillageBuilder.REGION_MAX.z + 1):
			top = maxi(top, world.get_surface_height(x, z) - 1)
	return top
