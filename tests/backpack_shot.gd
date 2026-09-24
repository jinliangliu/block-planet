extends Node
## 一次性取证探针：填几件物品后打开背包窗口（B 键面板）截图，用于布局目检。
## 运行：Godot_console.exe --path . res://tests/backpack_shot.tscn （需窗口，勿加 --headless）

const SAVE_PATH := "C:/Users/pc/Documents/github_repo/block-planet/backpack_panel_shot.png"


func _ready() -> void:
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame
	var hud: HUD = main_scene.get_node("UI")
	var player: Player = main_scene.get_node("Player")
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
		for i in range(10):
			await get_tree().process_frame
	# 填一些物品：常用区若干 + 待售区两格，便于目检分区与 9 列排布。
	var inv: Inventory = player.inventory
	inv.slots[0] = {"item": ItemTypes.WOOD_AXE, "count": 1, "durability": 40}
	inv.slots[1] = {"item": ItemTypes.IRON_PICKAXE, "count": 1, "durability": 60}
	inv.slots[2] = {"item": BlockTypes.Block.WOOD, "count": 32, "durability": -1}
	inv.slots[11] = {"item": ItemTypes.RAW_BEEF, "count": 3, "durability": -1}
	inv.slots[26] = {"item": ItemTypes.ARROW, "count": 12, "durability": -1}
	inv.slots[27] = {"item": BlockTypes.Block.SAND, "count": 20, "durability": -1}
	inv.slots[35] = {"item": ItemTypes.BONE, "count": 4, "durability": -1}
	inv.changed.emit()
	hud.open_inventory()
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(SAVE_PATH)
	print("BACKPACK_SHOT_DONE ", SAVE_PATH)
	get_tree().quit(0)
