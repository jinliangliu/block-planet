extends Node
## 无头集成冒烟测试。
## 运行：Godot_console.exe --headless --path . res://tests/smoke_test.tscn
## 覆盖：世界生成、方块修改跨区块卸载留存（F-02）、模式切换与飞行信号接线、合成预检。
##
## D-010：本探针会实例化真实 main.tscn（ProgressManager autoload 随之启动），
## 且F-02 往返会传送玩家。此前既无 SaveGuard 又写死传送高度 y=40——地形一改
## 玩家就从高处坠落摔死，`died` 计数被写进真实存档（实测 1896→1897），
## 断言全过却违反「探针不污染真实存档」。现已加 SaveGuard + 传送贴实际地表。

const TELEPORT_FRAMES := 150
const WAIT_FRAMES_INIT := 40

var _failed := 0
var _flying_signal_seen := false


func _ready() -> void:
	SaveGuard.snapshot()   # 必须在实例化 main.tscn 之前（暖机帧也可能触发 Events）
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	await _wait_frames(WAIT_FRAMES_INIT)

	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")
	Events.player_mode_changed.connect(_on_flying_signal)

	# 1) 地形已生成：玩家脚下的方块为实心。
	# 出生点已不是固定的 (8,8)——亚洲出生锚定村庄整平区（见 main.gd
	# _find_spawn_position），而世界按玩家位置流式加载。故以玩家实际所在列为准，
	# 并轮询等待区块生成（固定帧等待在机器繁忙时会不足）。
	var on_ground := false
	for i in range(600):
		var feet := Vector3i(player.global_position.floor())
		if world.get_block(Vector3i(feet.x, feet.y - 1, feet.z)) != BlockTypes.Block.AIR:
			on_ground = true
			break
		await get_tree().process_frame
	_check(on_ground, "玩家出生区域存在地形（出生列 %s）"
		% Vector3i(player.global_position.floor()))

	# 2) 放置方块并立即读取。目标取出生列附近（确保所在区块已加载——
	#    机场/村庄会改变出生点，故不再硬编码 (20,40,20) 这类远离出生点的坐标）。
	var _spawn_cell := Vector3i(player.global_position.floor())
	var target := Vector3i(_spawn_cell.x + 4, _spawn_cell.y + 8, _spawn_cell.z + 4)
	world.set_block(target, BlockTypes.Block.STONE)
	_check(world.get_block(target) == BlockTypes.Block.STONE, "set_block 后可立即读取")

	# 3) 传送远离触发卸载，再返回验证修改留存（F-02 往返）。返回点对齐目标列，
	#    保证该区块在玩家回到出生区域时被重新加载、且修改仍在。
	# D-055：两处传送的 y 必须贴**该列实际地表**，不能写死 40。世界高度
	# 64→256 且分层地形起伏后，写死的 40 会让玩家悬空或埋土——从高处坠落
	# 会摔死（Player.died → ProgressManager.notify("died")），探针断言全过
	# 却污染真实存档（D-010：user:// 的 died 1896→1897）。用「地表 +2 格」
	# 的安全传送高度，两处都不触发坠落伤害。
	var far_x := 200
	var far_z := 200
	world.ensure_chunks_in_region(
		Vector3i(far_x - 8, 0, far_z - 8), Vector3i(far_x + 8, World.CHUNK_SIZE.y - 1, far_z + 8))
	var far_y := world.get_surface_height(far_x, far_z) + 2
	player.global_position = Vector3(float(far_x) + 0.5, float(far_y), float(far_z) + 0.5)
	await _wait_frames(TELEPORT_FRAMES)
	var back_y := world.get_surface_height(target.x, target.z) + 2
	player.global_position = Vector3(float(target.x) + 0.5, float(back_y), float(target.z) + 0.5)
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

	# D-010：两条退出路径都要还原，且必须在 quit 之前——否则 ProgressManager
	# 的 _exit_tree 会 _save() 把内存态写盘，覆盖还原（flight_probe 实测教训）。
	SaveGuard.restore()
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
