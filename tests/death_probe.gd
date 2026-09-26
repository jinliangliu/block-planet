extends Node
## 死亡墓碑探针：验证「死亡 → 原地立 R.I.P 墓碑 → 停顿冻结 → 复活回出生点」全链路。
## 运行：Godot_console.exe --headless --path . res://tests/death_probe.tscn

const DEATH_PAUSE := 2.2

var _failed := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame

	var player: Player = main_scene.get_node("Player")

	# 把玩家搬到远离出生点的位置再弄死，验证墓碑立在西、人回东。
	player.global_position = Vector3(40.5, 40.0, 40.5)
	player.velocity = Vector3.ZERO
	for i in range(5):
		await get_tree().physics_frame
	var death_pos := player.global_position

	# ── 致命一击 ──────────────────────────────────────────
	player.take_damage(99, "探针")
	_check(player._dead, "致命一击后进入死亡停顿（_dead）")
	_check(player.health == 0, "死亡时生命归零")

	# 墓碑已立在死亡地点（玩家 siblings 中能找到 Tombstone）。
	var tomb_found := false
	for child in main_scene.get_children():
		if child is Tombstone:
			tomb_found = true
			var tomb_pos: Vector3 = (child as Node3D).global_position
			# 墓碑立在身前 1.6 m（0.5m 体素化后身位 ×2），留 0.4 m 余量。
			_check(tomb_pos.distance_to(death_pos) < 2.0,
				"墓碑立在死亡地点（距离 %.2f m）" % tomb_pos.distance_to(death_pos))
			break
	_check(tomb_found, "死亡后场景中出现墓碑")

	# 停顿期间：悬空不坠落（物理被冻结，重力不生效）。
	player.global_position = death_pos
	player.velocity = Vector3.ZERO
	for i in range(10):
		await get_tree().physics_frame
	_check(player.global_position.distance_to(death_pos) < 0.05,
		"死亡停顿期间物理冻结（悬空不坠落）")

	# 停顿期间再次受击：无效。
	var hp_before := player.health
	player.take_damage(5, "探针补刀")
	_check(player.health == hp_before, "死亡停顿期间不受击")

	# ── 等待停顿结束（time_scale=1，留裕量）────────────────
	var waited := 0.0
	while player._dead and waited < DEATH_PAUSE + 2.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	_check(not player._dead, "停顿结束后解除死亡状态")
	_check(player.health == Player.MAX_HEALTH, "复活后生命回满")
	var spawn_dist := player.global_position.distance_to(player.spawn_position)
	_check(spawn_dist < 3.0, "复活回到出生点（距离出生点 %.2f m）" % spawn_dist)

	# 连死两次：每次都等复活结束再死下一次，三座墓碑并存（45 秒生命周期）。
	var tombs_total := 1
	for k in range(2):
		player.global_position = Vector3(40.5 + float(k), 40.0, 40.5)
		player.velocity = Vector3.ZERO
		for i in range(3):
			await get_tree().physics_frame
		player.take_damage(99, "探针连死 %d" % k)
		tombs_total += 1
		var w := 0.0
		while player._dead and w < DEATH_PAUSE + 2.0:
			await get_tree().process_frame
			w += get_process_delta_time()
	var tomb_count := 0
	for child in main_scene.get_children():
		if child is Tombstone:
			tomb_count += 1
	_check(tomb_count >= tombs_total,
		"三次死亡产生 %d 座墓碑并存（实际 %d 座）" % [tombs_total, tomb_count])

	if _failed == 0:
		print("DEATH_PROBE_OK")
		get_tree().quit(0)
	else:
		print("DEATH_PROBE_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
