extends Node
## 坠机恢复探针（D-056）：坠机弹射生还后必须自动退出驾驶舱界面、回到初始停机坪。
## 场景：实例化 main.tscn（默认区域 ASIA，带机场），SaveGuard 隔离存档。
##   A 段 座舱 UI 复原 + 自动归位：登机（默认第一人称座舱，D-049）→ 座舱仪表簇
##       可见 → wreck() 弹射 → 屏幕仪表六层全隐藏、飞行相机让位、战术地图代关、
##       HUD 徒步件恢复 → 玩家自动回初始出生点、残骸清除、停机位出现满油完好的
##       新飞机、玩家朝北。伤害照常扣（防「为达复位目的吞掉弹射伤害」的敛邪修法）。
##       （根因：屏幕仪表 HUD 的 tick 只在驾驶中驱动，下机后 _apply_visibility
##       不再运行，UI 滞留屏上——用户实测「界面停留在驾驶舱画面」。）
##   B 段 死亡不归位：致死弹射（血量 1 + 弹射伤害 6）走死亡/复活流程，
##       坠机救援不接管——不清残骸、不传送（死亡停顿后由 _respawn 送回家）。
##   C 段 正常下机也复原：无伤害 exit_aircraft() → 座舱 UI 同样隐藏，
##       且不触发自动归位（玩家留在机体旁、场上飞机原样保留）。
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/crash_recover_probe.tscn

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


## 屏幕飞行仪表 HUD 的六个覆盖层是否全部隐藏（FlightInstrumentHUD._hide_all 的全集）。
func _instrument_layers_hidden(hud: HUD) -> bool:
	var ih: FlightInstrumentHUD = hud._instrument_hud
	if ih == null:
		return true
	return not ih._glass.visible and not ih._cockpit.visible \
		and not ih._panel.visible and not ih._minimap.visible \
		and not ih._warn.visible and not ih._fd.visible


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
	var hud: HUD = main_scene.get_node("UI") as HUD
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()

	var flight_spawn: Vector3 = main_scene._flight_spawn
	var craft_park: Vector3 = main_scene._craft_park
	_check(flight_spawn != Vector3.ZERO and craft_park != Vector3.ZERO,
		"main 记录了初始出生点与停机位（spawn=%s park=%s）"
			% [str(flight_spawn), str(craft_park)])

	# ── A 段：座舱 UI 复原 + 自动归位 ──────────────────
	var craft := Aircraft.spawn(main_scene, craft_park, PI)
	# 先给玩家一个非零 yaw：进近引导的 looking_at 在「玩家-目标」共线时告警
	# （真实开局玩家 yaw=π 已避开，探针默认 yaw=0 会踩）。
	player.rotation.y = 0.8
	player.ride_aircraft(craft)
	for i in range(30):
		await get_tree().process_frame
	_check(player.is_riding(), "A0 玩家已登机")
	var ih: FlightInstrumentHUD = hud._instrument_hud
	_check(ih != null and ih._cockpit.visible,
		"A1 驾驶中座舱仪表簇可见（探针前提：确实进过座舱界面）")
	# 飞行中打开战术地图（M）：它会把鼠标改成 VISIBLE 且不锁输入——弹射后
	# 若没人代关，玩家面对一张关不掉的地图和外露的鼠标（D-056 一并修）。
	# 记下打开前的鼠标模式：close_map 的契约就是还原成它（无头环境没有窗口
	# 可捕获，CAPTURED 不一定落得住，故只验「还原」语义，不硬编码 CAPTURED）。
	var mouse_before_map: Input.MouseMode = Input.mouse_mode
	hud._toggle_tactical_map()
	_check(hud._tactical_map != null and hud._tactical_map.is_open(),
		"A1b 飞行中战术地图可打开（探针前提）")
	_check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE,
		"A1c 战术地图打开中鼠标为 VISIBLE（泄漏源，待会儿要还原）")
	craft.wreck("探针触发坠机")
	_check(craft.is_wrecked(), "A2 wreck() 同步置解体（弹射前读）")
	# D-056：坠机弹射生还后自动执行飞行重置（无需按 Y）——等它跑完。
	for i in range(30):
		await get_tree().process_frame
	_check(not player.is_riding(), "A3 坠机弹出乘员")
	_check(_instrument_layers_hidden(hud),
		"A4 弹射后座舱屏幕仪表全隐藏（仪表簇/玻璃/清单/小地图/警告/指引十字）")
	_check(not main_scene._flight_camera.current,
		"A4b 飞行相机已让位（current=false，不再把镜头钉在座舱）")
	_check(player._camera.current,
		"A4c 玩家自己的相机恢复为当前相机")
	_check(not (hud._tactical_map != null and hud._tactical_map.is_open()),
		"A4d 战术地图已代关（不再留一张关不掉的地图）")
	_check(Input.mouse_mode == mouse_before_map,
		"A4e 鼠标模式还原为打开地图前的值（%d → %d，不外露指针）"
			% [int(Input.MOUSE_MODE_VISIBLE), int(mouse_before_map)])
	_check(not is_instance_valid(craft),
		"A5 残骸已被自动清除（节点释放，未等 4 秒消散）")
	var after_a := _crafts_under(main_scene)
	_check(after_a.size() == 1, "A6 场上恰好一架飞机（实际 %d）" % after_a.size())
	var fresh: Aircraft = after_a[0] if after_a.size() == 1 else null
	if fresh != null:
		_check(not fresh.is_wrecked(), "A7 新飞机完好")
		_check(fresh.fuel_ratio() > 0.999, "A8 新飞机满油（%.2f）" % fresh.fuel_ratio())
		_check(_parked_ok(fresh, craft_park),
			"A9 新飞机停在初始停机位（偏移 %s）"
				% str(fresh.global_position - craft_park))
	_check(_player_home_ok(player, flight_spawn),
		"A10 弹射生还后玩家自动回初始出生点（偏移 %s）"
			% str(player.global_position - flight_spawn))
	_check(absf(absf(player.rotation.y) - PI) < 0.01,
		"A11 玩家朝北正对飞机（yaw=%.3f）" % player.rotation.y)
	_check(not player.is_riding(), "A12 玩家处于下机状态")
	# 弹射伤害照常扣（防「为复位而吞伤害」的敛邪修法把坠机变成免费重置）。
	_check(player.health == Player.MAX_HEALTH - Aircraft.CRASH_DAMAGE,
		"A13 弹射伤害照常扣（health=%d，期望 %d）"
			% [player.health, Player.MAX_HEALTH - Aircraft.CRASH_DAMAGE])
	_check(hud._last_crash_reason == "探针触发坠机",
		"A14 HUD 记下坠机原因（_last_crash_reason=%s）" % hud._last_crash_reason)
	# 下机后徒步 HUD 件恢复（与飞行件消失是一体两面）。
	_check(hud._stats_box.visible and hud._hotbar_bar.visible,
		"A15 左上状态块与底部物品栏恢复显示")
	_check(not hud._flight_panel.visible, "A16 飞行面板卡片已收起")

	# ── B 段：致死弹射不走自动归位 ──────────────────────
	# 第二架停到别处：与 A 段补给机保持距离，避免两台碰撞盒互相穿透被
	# 物理弹飞（同位置双机是已知坑）。
	var craft2 := Aircraft.spawn(main_scene, craft_park + Vector3(40.0, 0.0, 0.0), PI)
	player.rotation.y = 0.8
	player.ride_aircraft(craft2)
	for i in range(30):
		await get_tree().process_frame
	_check(player.is_riding(), "B0 玩家已登第二架")
	# 先确认没有不死图腾：_damage 致命时会自动消耗图腾免死，会把「致死」
	# 悄悄变成「生还」，B1 就失去前提。
	_check(player.inventory.count_item(ItemTypes.TOTEM) == 0,
		"B0b 背包无不死图腾（致死前提）")
	player.health = 1  # 弹射伤害 6 > 1 → 致死
	craft2.wreck("探针致命坠机")
	for i in range(20):
		await get_tree().process_frame
	_check(player.is_dead(), "B1 玩家死亡（致死弹射）")
	_check(not player.is_riding(), "B2 死亡也交还飞机")
	_check(_instrument_layers_hidden(hud), "B3 死亡退机后座舱 UI 同样隐藏")
	var wrecked_alive := false
	for c: Aircraft in _crafts_under(main_scene):
		if c.is_wrecked():
			wrecked_alive = true
	_check(wrecked_alive, "B4 死亡不清残骸（坠机救援不接管，残骸留场自消散）")
	var d_home: Vector3 = player.global_position - flight_spawn
	_check(Vector2(d_home.x, d_home.z).length() > 5.0,
		"B5 死亡不传送回出生点（由死亡停顿后的复活流程送回家，水平距 %.1f）"
			% Vector2(d_home.x, d_home.z).length())
	# 等死亡停顿（2.2 s）结束：帧率不稳，用「不死就退出的轮询」而非固定拍数。
	for i in range(300):
		await get_tree().process_frame
		if not player.is_dead():
			break
	_check(not player.is_dead(), "B6 死亡停顿后玩家复活")
	_check(_player_home_ok(player, flight_spawn),
		"B7 复活回到出生点（偏移 %s）" % str(player.global_position - flight_spawn))

	# ── C 段：正常下机也复原座舱 UI，且不触发自动归位 ────
	# fresh 是 A 段自动归位补出的机（4 秒消散计时不适用于它，不会中途被释放）；
	# 若前段失败导致它已不存在，整段跳过并记 FAIL，绝不对已释放对象发消息。
	if fresh == null or not is_instance_valid(fresh):
		_check(false, "C0 前置失败：A 段补给机不存在，C 段跳过")
	else:
		player.rotation.y = 0.8
		player.ride_aircraft(fresh)
		for i in range(30):
			await get_tree().process_frame
		_check(player.is_riding(), "C0 玩家重新登机")
		_check(ih != null and ih._cockpit.visible, "C1 座舱仪表簇再次可见")
		# 只数「完好机」：B 段残骸有自己的 4 秒消散计时，到点自然消失是既有
		# 行为，不能算成「正常下机清场」——要钉的是完好机数量不变、不补机。
		var good_before := 0
		for c: Aircraft in _crafts_under(main_scene):
			if not c.is_wrecked():
				good_before += 1
		player.exit_aircraft()
		for i in range(10):
			await get_tree().process_frame
		_check(not player.is_riding(), "C2 正常下机")
		_check(_instrument_layers_hidden(hud), "C3 正常下机后座舱 UI 同样隐藏")
		var near: float = (player.global_position - fresh.global_position).length()
		_check(near < 8.0, "C4 正常下机落到机体旁边（距机 %.1f m）" % near)
		var d_home2: Vector3 = player.global_position - flight_spawn
		_check(Vector2(d_home2.x, d_home2.z).length() > 5.0,
			"C5 正常下机不传送回出生点（水平距 %.1f）"
				% Vector2(d_home2.x, d_home2.z).length())
		var good_after := 0
		for c: Aircraft in _crafts_under(main_scene):
			if not c.is_wrecked():
				good_after += 1
		_check(good_after == good_before and good_after >= 1,
			"C6 正常下机不清场、不补机（完好机 %d → %d）" % [good_before, good_after])

	# ── 收尾：还原并退出 ──────────────────────────────
	# 不手动 queue_free main_scene：退出期手动释放会踩 Vulkan 清理段崩溃
	# （rc=139，进程死在 SaveGuard.restore() 之前——racing_probe 同款教训），
	# 场景树随 quit 整体销毁即可。restore 必须先于 quit。
	GameState.needs_region_pick = prev_pick
	SaveGuard.restore()
	print("CRASH_RECOVER_TEST_%s" % ("OK" if _failed == 0 else "FAILED"))
	get_tree().quit(0 if _failed == 0 else 1)
