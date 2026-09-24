extends Node
## 无头集成冒烟测试。
## 运行：Godot_console.exe --headless --path . res://tests/smoke_test.tscn
## 覆盖：世界生成、方块修改跨区块卸载留存（F-02）、模式切换与飞行信号接线、合成预检。

const TELEPORT_FRAMES := 150
const WAIT_FRAMES_INIT := 40

var _failed := 0
var _flying_signal_seen := false


func _ready() -> void:
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	await _wait_frames(WAIT_FRAMES_INIT)

	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")
	Events.player_mode_changed.connect(_on_flying_signal)

	# 1) 地形已生成：地表方块为实心。
	var surface_y := world.get_surface_height(8, 8) - 1
	_check(
		world.get_block(Vector3i(8, surface_y, 8)) != BlockTypes.Block.AIR,
		"玩家出生区域存在地形"
	)

	# 2) 放置方块并立即读取。
	var target := Vector3i(20, 40, 20)
	world.set_block(target, BlockTypes.Block.STONE)
	_check(world.get_block(target) == BlockTypes.Block.STONE, "set_block 后可立即读取")

	# 3) 传送远离触发卸载，再返回验证修改留存（F-02 往返）。
	player.global_position = Vector3(200.5, 40.0, 200.5)
	await _wait_frames(TELEPORT_FRAMES)
	player.global_position = Vector3(8.5, 40.0, 8.5)
	await _wait_frames(TELEPORT_FRAMES)
	_check(world.get_block(target) == BlockTypes.Block.STONE, "区块卸载重载后修改仍在")

	# 4) 模式切换与飞行接线。
	GameState.set_mode(GameState.Mode.CREATIVE)
	player.set_flying(true)
	_check(player.flying, "创造模式下可进入飞行")
	_check(_flying_signal_seen, "player_mode_changed 信号已广播")
	GameState.set_mode(GameState.Mode.SURVIVAL)
	_check(not player.flying, "切回生存自动退出飞行")
	player.set_flying(true)
	_check(not player.flying, "生存模式禁止进入飞行")

	# 5) 背包与合成预检。
	var inv := Inventory.new()
	var recipe: Dictionary = ItemTypes.RECIPES[0]
	_check(not inv.can_craft(recipe), "空背包不可合成")
	inv.add_item(BlockTypes.Block.WOOD, 5)
	_check(inv.can_craft(recipe), "材料齐备且有空位时可合成")
	for i in range(Inventory.SLOT_COUNT):
		inv.slots[i]["item"] = BlockTypes.Block.WOOD
		inv.slots[i]["count"] = BlockTypes.STACK_SIZE
	_check(not inv.can_craft(recipe), "背包已满时合成被空位预检拦截")

	if _failed == 0:
		print("SMOKE_TEST_OK")
		get_tree().quit(0)
	else:
		print("SMOKE_TEST_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _on_flying_signal(flying: bool) -> void:
	_flying_signal_seen = flying


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)


func _wait_frames(count: int) -> void:
	for i in range(count):
		await get_tree().process_frame
