extends Node
## 飞行重置探针（D-039）：坠机 / 卡住时按 Y 一键归位回本地图初始跑道。
## 场景：实例化 main.tscn（默认区域 ASIA，带机场），SaveGuard 隔离存档。
##   A 段 坠机重置：wreck() 弹出乘员 → **D-056 起生还即自动重置**（无需按 Y）
##        → 玩家回初始出生点、残骸清除、停机位出现一架满油完好的飞机、玩家
##        朝北正对飞机、已下机。
##   B 段 卡住重置（完好飞机归位）：把在场飞机 place() 到远处模拟「卡住」，
##        reset → 同一实例（instance_id 不变，蓝图装配不丢）被搬回停机位。
##        （玩家在远方时初始跑道区块已流式卸载——真实坠机场景，teleport_to
##        必须回退原值不上天。）
##   C 段 无机补给：场上无完好飞机 → reset 在停机位补一架默认满油机。
##   D 段 输入入口：构造 Y 键事件走 main._unhandled_input → 触发重置。
## 运行：Godot_v4.6.3-stable_win64_console.exe --headless --path . res://tests/flight_reset_probe.tscn

var _failed := 0


func _ready() -> void:
	await _run()


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("PASS: %s" % msg)
	else:
		_failed += 1
		print("FAIL: %s" % msg)


func _crafts_under(main_scene: Node) -> Array[Aircraft]:
	var out: Array[Aircraft] = []
	for child in main_scene.get_children():
		var craft := child as Aircraft
		if craft != null and is_instance_valid(craft):
			out.append(craft)
	return out


## 飞机停稳判定：机身原点应在停机位地面点之上约一个 GROUND_CLEARANCE
## （place() 的落位约定：at 为地面点，原点 = at + GROUND_CLEARANCE + 0.05）。
func _parked_ok(craft: Aircraft, park: Vector3) -> bool:
	var d := craft.global_position - park
	return absf(d.x) < 1.5 and absf(d.z) < 1.5 \
		and absf(d.y - Aircraft.GROUND_CLEARANCE) < 1.0


func _player_home_ok(player: Player, flight_spawn: Vector3) -> bool:
	var d := player.global_position - flight_spawn
	return absf(d.x) < 1.5 and absf(d.z) < 1.5 and absf(d.y) < 3.0


func _run() -> void:
	# 存档隔离（D-010 铁律 3）：必须在实例化 main.tscn 之前。
	SaveGuard.snapshot()
	var prev_pick := GameState.needs_region_pick
	GameState.needs_region_pick = false

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame

	var player: Player = main_scene.get_node("Player")
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()

	var flight_spawn: Vector3 = main_scene._flight_spawn
	var craft_park: Vector3 = main_scene._craft_park
	_check(flight_spawn != Vector3.ZERO and craft_park != Vector3.ZERO,
		"main 记录了初始出生点与停机位（spawn=%s park=%s）"
			% [str(flight_spawn), str(craft_park)])

	# ── A 段：坠机重置 ────────────────────────────────
	var craft := Aircraft.spawn(main_scene, craft_park, PI)
	# 先给玩家一个非零 yaw：进近引导的 looking_at 在「玩家-目标」共线时告警
	# （真实开局玩家 yaw=π 已避开，探针默认 yaw=0 会踩）。
	player.rotation.y = 0.8
	player.ride_aircraft(craft)
	for i in range(30):
		await get_tree().physics_frame
	_check(player.is_riding(), "A0 玩家已登机")
	craft.wreck("探针触发坠机")
	# wreck 同步置解体：必须在残骸被自动清除前读（清除后对象已释放）。
	_check(craft.is_wrecked(), "A2 飞机已解体")
	# D-056：坠机弹射生还后 Main 自动走一遍重置（Events.aircraft_crash_survived
	# → reset_flight_experience），这里等它跑完即可，不再手动调用。
	for i in range(30):
		await get_tree().process_frame
	_check(not player.is_riding(), "A1 坠机弹出乘员")
	_check(not is_instance_valid(craft), "A1b 残骸已被自动清除（未等 4 秒消散）")
	var after_a := _crafts_under(main_scene)
	_check(after_a.size() == 1, "A3 残骸已清除且场上恰好一架飞机（实际 %d）" % after_a.size())
	var new_craft: Aircraft = after_a[0] if after_a.size() == 1 else null
	if new_craft != null:
		_check(not new_craft.is_wrecked(), "A5 新飞机完好")
		_check(new_craft.fuel_ratio() > 0.999, "A6 新飞机满油（%.2f）" % new_craft.fuel_ratio())
		_check(_parked_ok(new_craft, craft_park),
			"A4 新飞机停在初始停机位（机轮贴地，偏移 %s）"
				% str(new_craft.global_position - craft_park))
	_check(_player_home_ok(player, flight_spawn),
		"A7 玩家回到初始出生点（偏移 %s）" % str(player.global_position - flight_spawn))
	_check(absf(absf(player.rotation.y) - PI) < 0.01,
		"A8 玩家朝北正对飞机（yaw=%.3f）" % player.rotation.y)
	_check(not player.is_riding(), "A9 玩家处于下机状态")

	# ── B 段：卡住重置（完好飞机同实例归位）────────────
	var far := craft_park + Vector3(120.0, 6.0, 90.0)
	new_craft.place(far, 0.7)
	player.global_position = far + Vector3(6.0, 2.0, 0.0)
	for i in range(20):
		await get_tree().physics_frame
	var far_id := new_craft.get_instance_id()
	var d_far := new_craft.global_position - far
	var d_park := new_craft.global_position - craft_park
	_check(absf(d_far.x) < 8.0 and absf(d_far.z) < 8.0,
		"B0 飞机已被放到远处（模拟卡住/迫降外地，水平偏移 %s，坡地滑行距离不稳定故放宽）"
			% str(Vector2(d_far.x, d_far.z)))
	_check(d_park.x * d_park.x + d_park.z * d_park.z > 2500.0,
		"B0b 飞机确实远离初始停机位（水平距离 %.1f 格）"
			% sqrt(d_park.x * d_park.x + d_park.z * d_park.z))
	main_scene.reset_flight_experience()
	for i in range(60):
		await get_tree().process_frame
	var after_b := _crafts_under(main_scene)
	_check(after_b.size() == 1 and after_b[0].get_instance_id() == far_id,
		"B1 同一架飞机被搬回（instance_id 不变，蓝图装配不丢）")
	if after_b.size() == 1:
		_check(_parked_ok(after_b[0], craft_park),
			"B2 飞机归位停机位（机轮贴地，偏移 %s）"
				% str(after_b[0].global_position - craft_park))
	_check(_player_home_ok(player, flight_spawn),
		"B3 玩家回到初始出生点（偏移 %s，远方坠机时跑道区块按回退原值落位后重载）"
			% str(player.global_position - flight_spawn))

	# ── C 段：无完好飞机 → 补默认机 ───────────────────
	after_b[0].queue_free()
	for i in range(10):
		await get_tree().process_frame
	_check(_crafts_under(main_scene).is_empty(), "C0 场上已无飞机")
	main_scene.reset_flight_experience()
	for i in range(30):
		await get_tree().process_frame
	var after_c := _crafts_under(main_scene)
	_check(after_c.size() == 1, "C1 重置后补出一架飞机（实际 %d）" % after_c.size())
	if after_c.size() == 1:
		_check(_parked_ok(after_c[0], craft_park),
			"C2 补给机在停机位（偏移 %s）" % str(after_c[0].global_position - craft_park))
		_check(after_c[0].fuel_ratio() > 0.999, "C3 补给机满油")

	# ── D 段：Y 键输入入口 ────────────────────────────
	player.global_position = craft_park + Vector3(40.0, 3.0, 40.0)
	for i in range(20):
		await get_tree().physics_frame
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_Y
	ev.pressed = true
	main_scene._unhandled_input(ev)
	for i in range(60):
		await get_tree().process_frame
	_check(_player_home_ok(player, flight_spawn),
		"D1 Y 键事件触发重置、玩家回出生点（偏移 %s）"
			% str(player.global_position - flight_spawn))

	# ── 收尾：还原并退出 ──────────────────────────────
	# 不手动 queue_free main_scene：退出期手动释放会踩 Vulkan 清理段崩溃
	# （rc=139，进程死在 SaveGuard.restore() 之前——racing_probe 同款教训），
	# 场景树随 quit 整体销毁即可。restore 必须先于 quit。
	GameState.needs_region_pick = prev_pick
	SaveGuard.restore()
	print("FLIGHT_RESET_TEST_%s" % ("OK" if _failed == 0 else "FAILED"))
	get_tree().quit(0 if _failed == 0 else 1)
