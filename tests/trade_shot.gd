extends Node
## 一次性取证探针：打开 T 键交易面板截图（储物箱化改版目检用）。
## 运行：Godot_console.exe --path . res://tests/trade_shot.tscn （需窗口，勿加 --headless）

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
	# 给玩家 10 颗绿宝石 + 一些前期物资：可见「可交换/置灰」与「可出售」两种状态。
	var player: Player = main_scene.get_node("Player")
	player.inventory.add_item(ItemTypes.EMERALD, 10)
	player.inventory.add_item(BlockTypes.Block.WOOD, 14)
	player.inventory.add_item(BlockTypes.Block.COBBLESTONE, 20)
	hud.set_trade_open(true)
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var shot_path := _shot_path("trade_panel_shot.png")
	get_viewport().get_texture().get_image().save_png(shot_path)
	print("TRADE_SHOT_DONE ", shot_path)

	# 卖出页签：物资换绿宝石的打包收购行。
	hud._on_trade_tab(1)
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var sell_path := _shot_path("trade_sell_shot.png")
	get_viewport().get_texture().get_image().save_png(sell_path)
	print("TRADE_SELL_SHOT_DONE ", sell_path)
	get_tree().quit(0)
