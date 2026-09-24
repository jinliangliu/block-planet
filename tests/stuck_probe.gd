extends Node
## 无头防卡死探针：验证玩家嵌入实心方块时瞬间死亡重生脱困，
## 以及半身嵌入/单帧掠过不误触发、创造模式同样生效。
## 运行：Godot_console.exe --headless --path . res://tests/stuck_probe.tscn

const TIMEOUT_FRAMES := 600

var _failed := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame

	var player: Player = main_scene.get_node("Player")
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	# 冻结自动生成，保证确定性。
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()

	# 深石层探针位：y=5 必为 STONE（地形最矮约 18），玩家嵌在实心岩石中央
	# 无 depenetration 出口，是确定性的真实卡死构造。
	var buried := Vector3(8.5, 5.0, 8.5)
	var sky := Vector3(40.5, 50.0, 8.5)

	# ── A：正常站立不误触发 ──────────────────────────────
	for i in range(30):
		await get_tree().physics_frame
	_check(player.stuck_rescues == 0, "正常站立 30 帧不触发防卡死")
	_check(player.health == Player.MAX_HEALTH, "正常站立生命无损")

	# ── B：半身嵌入（仅脚格实心）不触发 ────────────────────
	player.global_position = sky
	player.velocity = Vector3.ZERO
	var world: World = main_scene.get_node("World")
	world.set_block(Vector3i(40, 50, 8), BlockTypes.Block.STONE)
	for i in range(30):
		await get_tree().physics_frame
	_check(player.stuck_rescues == 0, "仅脚格嵌入实心不触发防卡死（头部格空气）")
	world.set_block(Vector3i(40, 50, 8), BlockTypes.Block.AIR)
	await get_tree().physics_frame
	await get_tree().physics_frame

	# ── C：单帧掠过嵌入不触发（宽限期过滤） ──────────────────
	var rescues_c := player.stuck_rescues
	player.global_position = buried
	player.velocity = Vector3.ZERO
	await get_tree().physics_frame
	player.global_position = sky
	player.velocity = Vector3.ZERO
	for i in range(30):
		await get_tree().physics_frame
	_check(player.stuck_rescues == rescues_c, "嵌入 1 帧即离开不触发防卡死（宽限 3 帧）")

	# ── D：完全嵌入 → 瞬间死亡重生脱困 ──────────────────────
	player.global_position = buried
	player.velocity = Vector3.ZERO
	for i in range(20):
		await get_tree().physics_frame
	_check(player.stuck_rescues == rescues_c + 1, "完全嵌入实心触发防卡死脱困")
	_check(player.health == Player.MAX_HEALTH, "脱困后生命重置为满")
	var dist := player.global_position.distance_to(buried)
	_check(dist > 10.0, "脱困后已离开嵌入点（距离 %.1f m）" % dist)

	# ── E：创造模式同样脱困 ──────────────────────────────
	GameState.set_mode(GameState.Mode.CREATIVE)
	var rescues_e := player.stuck_rescues
	player.global_position = buried
	player.velocity = Vector3.ZERO
	for i in range(20):
		await get_tree().physics_frame
	_check(player.stuck_rescues == rescues_e + 1, "创造模式嵌入同样触发防卡死（不受无敌影响）")
	GameState.set_mode(GameState.Mode.SURVIVAL)
	_check(player.health == Player.MAX_HEALTH, "创造模式脱困后生命为满")

	if _failed == 0:
		print("STUCK_TEST_OK")
		get_tree().quit(0)
	else:
		print("STUCK_TEST_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
