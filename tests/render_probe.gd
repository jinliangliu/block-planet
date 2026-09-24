extends Node
## 实机渲染探针：加载主场景运行片刻后截取视口画面存盘，用于桌面端视觉取证。
## 运行：Godot_console.exe --path . res://tests/render_probe.tscn （需窗口，勿加 --headless）

## 截图输出目录：tmp/ 属本地临时产物，已由 .gitignore 忽略。
const SHOT_DIR := "res://tmp"
const WAIT_FRAMES := 120


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


func _ready() -> void:
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(WAIT_FRAMES):
		await get_tree().process_frame

	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")
	var camera: Camera3D = player.get_node("Camera3D")
	camera.rotation.x = -0.35
	await RenderingServer.frame_post_draw

	var image := get_viewport().get_texture().get_image()
	image.save_png(_shot_path("render_probe.png"))
	print("surface_height(8,8)=", world.get_surface_height(8, 8))
	print("player_pos=", player.global_position, " on_floor=", player.is_on_floor())
	print("camera_pos=", camera.global_position)
	print("light_energy=", main_scene.get_node("DirectionalLight3D").light_energy)

	# 第三人称取证：拉远相机并在角色前方触发一次破坏碎屑，验证角色形体与特效。
	player.camera_distance = 3.0
	player._apply_camera_mode()
	var spring: SpringArm3D = player.get_node("SpringArm3D")
	spring.rotation.x = camera.rotation.x
	var fx_origin: Vector3 = player.global_position + Vector3(0.0, 1.0, -2.5)
	BreakFx.burst(world, fx_origin, BreakFx.color_for_block(BlockTypes.Block.WOOD), 26, 0.7)
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var third_image := get_viewport().get_texture().get_image()
	third_image.save_png(_shot_path("render_probe_third.png"))
	print("third_person_cam=", spring.get_node("Camera3D").global_position)
	print("model_visible=", player.get_node("PlayerModel").visible)

	print("RENDER_PROBE_DONE")
	get_tree().quit(0)
