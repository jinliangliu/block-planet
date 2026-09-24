extends Node
## 一次性取证探针：放置储物箱并打开箱面板截图（背包扩容后布局目检用）。
## 运行：Godot_console.exe --path . res://tests/chest_shot.tscn （需窗口，勿加 --headless）

const SAVE_PATH := "C:/Users/pc/Documents/github_repo/block-planet/chest_panel_shot.png"


func _ready() -> void:
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame
	var hud: HUD = main_scene.get_node("UI")
	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
		for i in range(10):
			await get_tree().process_frame
	var cell := Vector3i(int(player.global_position.x) + 2,
		int(player.global_position.y), int(player.global_position.z))
	world.set_block(cell, BlockTypes.Block.CHEST)
	var box: Inventory = world.get_box(cell)
	box.add_item(BlockTypes.Block.WOOD, 12)
	player.inventory.add_item(BlockTypes.Block.STONE, 7)
	hud._on_request_box_open(cell)
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(SAVE_PATH)
	print("CHEST_SHOT_DONE ", SAVE_PATH)
	get_tree().quit(0)
