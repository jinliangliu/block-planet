extends Node
## 无头竞速探针（feature_car_racing）：
##   A. 数据层：赛道 / 地形 / 机器人 / 赛车 / 教学 / 格式化 / 解锁；
##   B. 纯逻辑层：TrackLayout 几何、CarPhysics 收敛与地形差异、AiRacer 输出、
##      RaceSession 门平面判定与圈数、RaceRecords 记录合并、RaceReplayLog 落盘；
##   C. 整场自动驾驶 e2e：race_scene 手动定步长跑完一场 → 完赛、排名、记录落盘、
##      Events.race_finished 广播、Progress 计数器累计；
##   D. UI 接线：HUD 里的赛道选择器 + 地图页 🏁 入口 + 模态互斥。
##
## 运行：Godot_console.exe --headless --path . res://tests/racing_probe.tscn

const DT := 1.0 / 60.0
## 定步长手动推进的上限：一场 4 圈约 6~10k tick，给足余量防死循环。
const MAX_RACE_TICKS := 40000
const RECORDS_TMP := "user://race_records_probe.json"

var _failed := 0
var _race_events: Array = []
var _lap_events := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	# 存档隔离（D-010 铁律 3）：本探针真实完赛 → 写 user://race_records.json /
	# race_replay.jsonl，并触发 Progress 计数器；快照必须最先做。
	SaveGuard.snapshot()

	_test_data_layer()
	_test_track_layout()
	_test_car_physics()
	_test_ai_racer()
	_test_session_progress()
	_test_pace_and_offroad()
	_test_handbrake_drift()
	_test_waypoint_tracks()
	_test_records_and_replay()
	await _test_scene_end_to_end()
	await _test_hud_wiring()

	_finish()


func _finish() -> void:
	SaveGuard.restore()
	if _failed == 0:
		print("RACING_TEST_OK")
		get_tree().quit(0)
	else:
		print("RACING_TEST_FAILED count=%d" % _failed)
		get_tree().quit(1)


# ────────────────────────────── A. 数据层 ──────────────────────────────
func _test_data_layer() -> void:
	_check(RaceSystem.tracks().size() >= 3, "赛道数据加载（%d 条）" % RaceSystem.tracks().size())
	_check(RaceSystem.terrains().size() >= 5, "地形数据加载（%d 种）" % RaceSystem.terrains().size())
	var asphalt := RaceSystem.terrain("asphalt")
	var wetland := RaceSystem.terrain("wetland")
	_check(float(asphalt["grip"]) > float(wetland["grip"]), "柏油抓地 > 湿地抓地")
	_check(float(asphalt["speed_factor"]) > float(wetland["speed_factor"]), "柏油更快 > 湿地")
	_check(float(wetland["brake_factor"]) < float(asphalt["brake_factor"]), "湿地刹车系数更差")

	var any_ai_only := false
	for v: Variant in RaceSystem.player_vehicles():
		if bool((v as Dictionary).get("ai_only", false)):
			any_ai_only = true
	_check(not any_ai_only, "玩家可选车不含 ai_only 专用车")
	_check(RaceSystem.player_vehicles().size() >= 3, "玩家可选车 ≥ 3")
	_check(RaceSystem.difficulties().size() >= 3, "AI 难度 ≥ 3 档")
	_check(RaceSystem.ai_names().size() >= 3, "AI 名字池 ≥ 3")
	_check(RaceSystem.teachings_for("first_race_start").size() >= 1, "有 first_race_start 教学")

	_check(RaceSystem.format_time(95.5) == "01:35.50", "时间格式化 95.5 → 01:35.50")
	_check(RaceSystem.format_time(-1.0) == "--:--.--", "负数时间显示 --:--.--")
	_check(RaceSystem.format_lap(0.0) == "--:--.--", "零圈速显示 --:--.--")

	# 解锁判定：临时把内存记录换成空存档，逐条验证后原样还原（不碰用户真实记录）。
	var saved_records: Dictionary = RaceSystem._records
	RaceSystem._records = RaceRecords.blank_store()
	_check(RaceSystem.is_unlocked("default"), "default 赛道恒解锁")
	_check(RaceSystem.is_unlocked(""), "空解锁串视为已解锁")
	_check(not RaceSystem.is_unlocked("wins:1"), "无胜场时 wins:1 未解锁")
	_check(not RaceSystem.is_unlocked("record:1"), "无记录时 record:1 未解锁")
	_check(RaceSystem.unlock_hint("wins:1") != "已解锁", "解锁提示给出条件文案")
	RaceSystem._records = saved_records
	_check(RaceSystem.unlock_hint("default") == "已解锁", "default 提示已解锁")


# ────────────────────────── B1. 赛道几何 ──────────────────────────
func _test_track_layout() -> void:
	var def := RaceSystem.track("desert_ring")
	_check(not def.is_empty(), "沙丘环线定义存在")
	var layout := TrackLayout.build(def)
	_check(layout != null, "赛道几何构建成功")
	if layout == null:
		return
	_check(layout.size() > 100, "中心线采样点 > 100（%d）" % layout.size())
	var target := float(def["length_m"])
	var err: float = absf(layout.total - target) / target
	_check(err < 0.06, "周长贴近目标 %.0fm（实测 %.1f m）" % [target, layout.total])
	_check(layout.gate_count() >= 2, "检查点 ≥ 2（%d）" % layout.gate_count())
	var d := layout.direction(0)
	_check(absf(d.length() - 1.0) < 0.01, "方向向量单位化")
	var gp := layout.gate_position(0)
	_check(absf(gp.y) < 0.5, "起跑线门位于路平面")
	var terrain_ok := true
	for i in range(layout.size()):
		if layout.terrain_at_index(i).is_empty():
			terrain_ok = false
	_check(terrain_ok, "每个采样点都有合法地形 id")

	# 六条赛道全部可构建且周长自洽（数据驱动，防止某条 shape 写错）。
	var all_ok := true
	for t: Variant in RaceSystem.tracks():
		var l := TrackLayout.build(t as Dictionary)
		if l == null or l.size() < 10 or l.gate_count() < 1:
			all_ok = false
	_check(all_ok, "全部赛道均可构建几何")


# ────────────────────────── B2. 车辆物理 ──────────────────────────
func _test_car_physics() -> void:
	var spec := RaceSystem.vehicle("tricycle")
	var asphalt := RaceSystem.terrain("asphalt")
	var car := CarPhysics.new()
	car.setup(spec, Vector2.ZERO, 0.0)
	for i in range(int(20.0 / DT)):
		car.throttle = 1.0
		car.step(DT, asphalt)
	var want := float(spec["max_speed_mps"]) * float(asphalt["speed_factor"])
	_check(car.speed() > want * 0.75 and car.speed() <= want * 1.1,
		"全油门 20s 收敛到路面上限（%.1f / %.1f m/s）" % [car.speed(), want])
	_check(car.fuel_ratio() < 1.0, "耗油：燃油比下降（%.2f）" % car.fuel_ratio())
	_check(car.kmh() > 0.0, "kmh 换算为正")

	var a := CarPhysics.new()
	var w := CarPhysics.new()
	a.setup(spec, Vector2.ZERO, 0.0)
	w.setup(spec, Vector2.ZERO, 0.0)
	for i in range(600):
		a.throttle = 1.0
		a.step(DT, asphalt)
		w.throttle = 1.0
		w.step(DT, RaceSystem.terrain("wetland"))
	_check(a.speed() > w.speed() + 0.5,
		"同油门柏油比湿地快（%.1f vs %.1f）" % [a.speed(), w.speed()])


# ────────────────────────── B3. AI 驾驶 ──────────────────────────
func _test_ai_racer() -> void:
	var layout := RaceSystem.build_layout("city_circuit")
	var start := layout.start_pose()
	var sdir: Vector3 = start["dir"]
	var spos: Vector3 = start["pos"]
	var car := CarPhysics.new()
	car.setup(RaceSystem.vehicle("tricycle"), Vector2(spos.x, spos.z), atan2(sdir.x, sdir.z))
	var ai := AiRacer.new()
	ai.setup(layout, RaceSystem.difficulty("normal"), 12345)
	var inp := ai.think(car, RaceSystem.terrain("asphalt"), DT)
	var has_keys := inp.has("throttle") and inp.has("brake") and inp.has("steer")
	_check(has_keys, "AI 输出油门/刹车/转向")
	var t := float(inp.get("throttle", -1.0))
	var s := float(inp.get("steer", 9.0))
	_check(t >= 0.0 and t <= 1.0, "AI 油门在 [0,1]（%.2f）" % t)
	_check(s >= -1.0 and s <= 1.0, "AI 转向在 [-1,1]（%.2f）" % s)


# ─────────────────── B4. 会话：门平面判定与圈数 ───────────────────
func _test_session_progress() -> void:
	var layout := RaceSystem.build_layout("city_circuit")
	var start := layout.start_pose()
	var sdir: Vector3 = start["dir"]
	var spos: Vector3 = start["pos"]
	var car := CarPhysics.new()
	car.setup(RaceSystem.vehicle("racer"), Vector2(spos.x, spos.z), atan2(sdir.x, sdir.z))
	var r := RaceSession.Racer.new()
	r.is_player = true
	r.id = "player"
	r.vehicle_id = "racer"
	r.car = car
	var session := RaceSession.new()
	session.setup(layout, 2, [r])
	_lap_events = 0
	session.lap_completed.connect(_on_probe_lap)
	var ai := AiRacer.new()
	ai.setup(layout, RaceSystem.difficulty("hard"), 7)
	session.begin_countdown(0.05)
	var idx := 0
	var ticks := 0
	while not r.finished() and ticks < MAX_RACE_TICKS:
		session.tick(DT)
		var at := Vector3(car.pos.x, 0.0, car.pos.y)
		idx = layout.nearest_index_forward(idx, at, 30)
		var off := absf(layout.lateral_offset(at, idx)) > layout.half_width
		var terr := RaceSystem.terrain("grass") if off else RaceSystem.terrain(layout.terrain_at_index(idx))
		var inp := ai.think(car, terr, DT)
		car.throttle = float(inp["throttle"])
		car.brake = float(inp["brake"])
		car.steer = float(inp["steer"])
		car.handbrake = false
		car.step(DT, terr)
		session.update_progress(r, off)
		ticks += 1
	_check(r.finished(), "纯逻辑层跑完 2 圈（tick=%d）" % ticks)
	_check(_lap_events == 2, "触发 2 次 lap_completed（%d）" % _lap_events)
	_check(r.best_lap > 0.0, "记录最快圈速（%.2f s）" % r.best_lap)
	_check(r.finish_time > 0.0, "记录完赛时间（%.2f s）" % r.finish_time)
	_check(r.gates_passed >= 2 * layout.gate_count(), "过门次数 ≥ 圈数×门数")


func _on_probe_lap(_id: String, _lap: int, _t: float) -> void:
	_lap_events += 1


# ────────────────── B5. 记录合并与回放日志 ──────────────────
func _test_records_and_replay() -> void:
	var store := RaceRecords.blank_store()
	var o1 := RaceRecords.apply(store, "desert_ring", "tricycle", 2, 45.0, 150.0, "t1")
	_check(bool(o1["first_race"]) and bool(o1["broke_lap"]) and bool(o1["broke_race"]),
		"首场即刷新圈速与完赛记录")
	var o2 := RaceRecords.apply(store, "desert_ring", "racer", 1, 43.0, 140.0, "t2")
	_check(bool(o2["broke_lap"]) and bool(o2["broke_race"]), "更快成绩刷新记录")
	var o3 := RaceRecords.apply(store, "desert_ring", "racer", 3, 50.0, 160.0, "t3")
	_check(not bool(o3["broke_lap"]) and not bool(o3["broke_race"]), "更慢成绩不刷新记录")
	var e := RaceRecords.entry_of(store, "desert_ring")
	_check(int(e["total_races"]) == 3, "场次累计 3（%d）" % int(e["total_races"]))
	_check(int(e["wins"]) == 1, "胜场累计 1（%d）" % int(e["wins"]))
	_check(int(e["best_rank"]) == 1, "最好名次 1（%d）" % int(e["best_rank"]))
	_check(absf(float(e["best_lap_time"]) - 43.0) < 0.001, "最佳圈速取最小值")
	_check(RaceRecords.total_wins(store) == 1, "总胜场统计")
	_check(RaceRecords.record_count(store) == 1, "有记录的赛道数统计")

	_check(RaceRecords.save_to(RECORDS_TMP, store), "记录落盘成功")
	var loaded := RaceRecords.load_from(RECORDS_TMP)
	_check(int(RaceRecords.entry_of(loaded, "desert_ring")["total_races"]) == 3, "记录读回一致")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(RECORDS_TMP))

	RaceReplayLog.clear()
	RaceReplayLog.append(10, "race_start", "city_circuit", "tricycle", Vector3(1.0, 0.0, 2.0), "玩家")
	RaceReplayLog.append(20, "checkpoint", "city_circuit", "tricycle", Vector3(3.0, 0.0, 4.0), "玩家")
	var ev := RaceReplayLog.read_events()
	_check(ev.size() == 2, "回放日志写入/读回（%d 条）" % ev.size())
	if ev.size() == 2:
		_check(String(ev[1]["action"]) == "checkpoint", "回放日志末条 action 正确")
		_check(int(ev[0]["tick"]) == 10, "回放日志 tick 正确")
	RaceReplayLog.clear()
	_check(RaceReplayLog.read_lines().is_empty(), "回放日志可清空")


# ─────────────────── C. 整场自动驾驶 e2e ───────────────────
func _test_scene_end_to_end() -> void:
	var before_any := int(Progress.counters.get("race_finished_any", 0))
	_race_events.clear()
	Events.race_finished.connect(_on_probe_race_finished)

	RaceSystem.select_race("city_circuit", "tricycle", 3, "easy")
	var scene: Node3D = load("res://scenes/racing/race_scene.tscn").instantiate()
	scene.autopilot = true
	add_child(scene)
	# 关掉引擎驱动的物理步进，改由探针手动定步长推进（不受实时节流，快且确定）。
	scene.set_physics_process(false)

	_check(scene._session != null and scene._session.racer_count() == 4,
		"场景生成 4 名参赛者（玩家 + 3 机器人）")
	_check(scene._loader != null and scene._loader.arena_radius > 0.0, "赛道地台已构建")
	_check(scene._cars.size() == 4, "赛车节点数 4")
	if scene._cars.size() == 4:
		_check(scene._cars[0]._wheels.size() >= 3, "赛车模型已拼装（含轮子）")

	var ticks := 0
	while not scene._finalized and ticks < MAX_RACE_TICKS:
		scene._physics_process(DT)
		ticks += 1
	_check(scene._finalized, "自动驾驶跑完整场（tick=%d）" % ticks)

	var p: RaceSession.Racer = scene._session.player()
	_check(p != null and p.finished(), "玩家完赛")
	var want_laps := int(scene._track_def.get("laps", 3))
	_check(p.lap >= want_laps, "完成全部 %d 圈（%d）" % [want_laps, p.lap])
	_check(p.best_lap > 0.0 and p.finish_time > 0.0, "记录圈速与完赛时间")
	_check(p.rank >= 1 and p.rank <= 4, "名次在 1..4（%d）" % p.rank)
	_check(_race_events.size() == 1, "Events.race_finished 广播一次（%d）" % _race_events.size())
	if _race_events.size() == 1:
		_check(String(_race_events[0]["track"]) == "city_circuit", "广播带正确赛道 id")
		_check(int(_race_events[0]["laps"]) == p.lap, "广播圈数与实况一致")
	_check(int(Progress.counters.get("race_finished_any", 0)) == before_any + 1,
		"Progress 累计完赛次数")

	var entry := RaceSystem.entry_of("city_circuit")
	_check(int(entry["total_races"]) >= 1, "记录已写入（total_races=%d）" % int(entry["total_races"]))
	_check(float(entry["best_lap_time"]) > 0.0, "记录含最佳圈速")
	_check(RaceReplayLog.read_events().size() > 0, "回放日志已落盘")

	Events.race_finished.disconnect(_on_probe_race_finished)
	# 同 _test_hud_wiring 收尾：不手动释放，等帧区即崩溃区（rc=139）。


func _on_probe_race_finished(track_id: String, vehicle_id: String, rank: int, laps: int,
		best_lap: float, _total_time: float, clean: bool) -> void:
	_race_events.append({
		"track": track_id, "vehicle": vehicle_id, "rank": rank,
		"laps": laps, "best": best_lap, "clean": clean,
	})


# ─────────────────── D. HUD / 地图选择器接线 ───────────────────
func _test_hud_wiring() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(30):
		await get_tree().process_frame

	var hud: HUD = main_scene.get_node("UI")
	_check(hud._track_selector != null, "HUD 已建赛道选择器")
	_check(hud._map_selector != null, "HUD 已建地图选择器")
	if hud._track_selector == null or hud._map_selector == null:
		return
	_check(hud._map_selector.race_requested.get_connections().size() > 0, "地图页「🏁 竞速」已接线")
	_check(hud._track_selector.race_requested.get_connections().size() > 0, "赛道选择器「开始比赛」已接线")

	hud.open_track_selector()
	_check(hud._track_selector.is_open(), "open_track_selector 打开选择器")
	_check(hud._any_overlay_open(), "选择器计入覆盖层（模态互斥）")
	_check(hud.is_any_panel_open(), "选择器计入模态互斥查询")
	hud.close_track_selector()
	_check(not hud._track_selector.is_open(), "close_track_selector 关闭选择器")

	# 地图页入口 → 打开赛道选择器（模拟点「🏁 赛道竞速」）。
	hud._map_selector.race_requested.emit()
	_check(hud._track_selector.is_open(), "地图页 🏁 入口打开选择器")
	hud.close_track_selector()

	# 选择器内容：至少一条赛道卡片 + 「开始比赛」按钮可用。
	hud.open_track_selector()
	_check(hud._track_selector._card_grid.get_child_count() >= 1, "选择器列出赛道卡片")
	_check(not hud._track_selector._start_button.disabled, "默认赛道可选、开始按钮可用")
	hud.close_track_selector()

	# 不手动 queue_free main_scene：退出期手动释放 + 等帧会踩 Vulkan 清理段
	# 崩溃（rc=139，进程死在 SaveGuard.restore 之前，race_replay.jsonl 残留，
	# 随后又被 racing_shot 快照固化）——flight_reset_probe 同款教训。场景树
	# 随 quit 整体销毁即可，restore 在 _finish 里先于 quit 执行。


# ──── E. 配速归一 / 只减速侧橡皮筋 / off-road 计时 ────
## 钉住三件事：
##   ① pace_bias_for 三段阈值（落后恒 1.0，领先越多减得越多，封顶 0.82）；
##   ② 目标速度的基数被「场地极速」夹住，AI 不再拿自己车的极速算目标；
##   ③ RaceSession 的 off-road 计时吃真实 dt，不再硬编码 0.0166。
func _test_pace_and_offroad() -> void:
	# ① 橡皮筋曲线（纯静态函数，可逐点断言）。
	_check(AiRacer.pace_bias_for(0.0) == 1.0, "并排（gap=0）不加不减，pace_bias=1.0")
	_check(AiRacer.pace_bias_for(30.0) == 1.0, "领先 30 m 以内不干预，pace_bias=1.0")
	_check(AiRacer.pace_bias_for(-500.0) == 1.0, "AI 落后 500 m 也不加速（pace_bias=1.0）")
	var at_max := AiRacer.pace_bias_for(150.0)
	_check(absf(at_max - 0.82) < 0.001, "领先 150 m 减到 0.82（%.3f）" % at_max)
	var cap := AiRacer.pace_bias_for(1000.0)
	_check(absf(cap - 0.82) < 0.001, "领先 1000 m 仍封顶 0.82（%.3f）" % cap)
	var mid := AiRacer.pace_bias_for(90.0)
	_check(mid > 0.82 and mid < 1.0, "30~150 m 之间线性过渡（90 m → %.3f）" % mid)
	_check(AiRacer.pace_bias_for(40.0) >= AiRacer.pace_bias_for(80.0)
		and AiRacer.pace_bias_for(80.0) >= AiRacer.pace_bias_for(140.0),
		"领先越多减得越多（pace_bias 单调不增）")
	var gap_ai := AiRacer.new()
	gap_ai.set_gap(200.0)
	_check(absf(gap_ai.pace_bias - 0.82) < 0.001,
		"set_gap(200) 写入 pace_bias=0.82（%.3f）" % gap_ai.pace_bias)

	# ② 配速归一：racer 极速 40 m/s，场地极速取玩家小三轮的 24 m/s。
	#    34 m/s 时归一后的目标 ≤ 24×1.0(expert)×1.1(柏油) = 26.4，必然点刹。
	var layout := RaceSystem.build_layout("city_circuit")
	var start := layout.start_pose()
	var sdir: Vector3 = start["dir"]
	var spos: Vector3 = start["pos"]
	# 关掉随机犯错，让同一速度下的两条断言可确定复现。
	var diff := RaceSystem.difficulty("expert").duplicate()
	diff["mistake_chance"] = 0.0
	var fast := CarPhysics.new()
	fast.setup(RaceSystem.vehicle("racer"), Vector2(spos.x, spos.z), atan2(sdir.x, sdir.z))
	fast.vel = fast.forward() * 34.0
	var asphalt := RaceSystem.terrain("asphalt")

	var norm_ai := AiRacer.new()
	norm_ai.setup(layout, diff, 1, 24.0)
	var n_inp := norm_ai.think(fast, asphalt, DT)
	var n_brake := float(n_inp["brake"])
	_check(n_brake > 0.0,
		"归一后 racer 车 34 m/s 已超场地极速 → 刹车（brake=%.2f）" % n_brake)

	var free_ai := AiRacer.new()
	free_ai.setup(layout, diff, 1, 0.0)
	var f_inp := free_ai.think(fast, asphalt, DT)
	var f_brake := float(f_inp["brake"])
	var f_throttle := float(f_inp["throttle"])
	_check(f_brake == 0.0 and f_throttle == 1.0,
		"不归一（field_top=0）时同一速度仍全油门（旧行为 brake=%.2f throttle=%.2f）"
		% [f_brake, f_throttle])

	# ③ off-road 计时用真实 dt：只断言「增量」，不假设初值。
	var r := RaceSession.Racer.new()
	r.id = "probe_offroad"
	r.vehicle_id = "tricycle"
	r.car = CarPhysics.new()
	r.car.setup(RaceSystem.vehicle("tricycle"), Vector2(spos.x, spos.z), atan2(sdir.x, sdir.z))
	var session := RaceSession.new()
	session.setup(layout, 1, [r])
	var before := r.off_road_time
	session.update_progress(r, true, 0.05)
	_check(absf((r.off_road_time - before) - 0.05) < 0.0001,
		"off-road 计时吃真实 dt（+%.3f s）" % (r.off_road_time - before))
	var before_road := r.off_road_time
	session.update_progress(r, false, 0.05)
	_check(absf(r.off_road_time - before_road) < 0.0001, "在路面内 off-road 计时不增长")


# ──── F. 手刹漂移（D-084）────
## 改前的实测病：手刹只减纵向速度、把侧滑回正降到 0.2，**转向率一点不变**——
## 于是同样 2 s 满舵，转角与不拉手刹完全一致（230°），速度却掉了三成。
## 「同样的弯、更慢的车」= 玩家没有任何理由用它，漂移是纯惩罚。
## 本节钉住三条：① 手刹能换来转角（甩得出去）；② 换来的速度代价可接受（不是急刹）；
## ③ 手刹真的在漂（侧滑角显著 > 普通转弯）。
## CarPhysics 是纯逻辑层，整段是「构造式喂帧」，逐帧确定，不是机会性断言。
func _test_handbrake_drift() -> void:
	_check(absf(CarPhysics.HANDBRAKE_DECEL - 0.18) < 0.0001
		and absf(CarPhysics.HANDBRAKE_YAW - 1.35) < 0.0001
		and absf(CarPhysics.HANDBRAKE_GRIP - 0.20) < 0.0001,
		"手刹三常量在位（DECEL=%.2f YAW=%.2f GRIP=%.2f）"
		% [CarPhysics.HANDBRAKE_DECEL, CarPhysics.HANDBRAKE_YAW, CarPhysics.HANDBRAKE_GRIP])
	_check(CarPhysics.HANDBRAKE_YAW > 1.0,
		"手刹必须有转向增益——否则它只会减速、换不来任何转弯能力")

	for vid: String in ["tricycle", "racer"]:
		var plain := _cornering(vid, "asphalt", false)
		var drift := _cornering(vid, "asphalt", true)
		var turn_ratio := float(drift["turn_deg"]) / maxf(float(plain["turn_deg"]), 0.001)
		_check(turn_ratio > 1.20,
			"%s：拉手刹 2 s 转角 %.0f° ≫ 普通转弯 %.0f°（×%.2f）"
			% [vid, float(drift["turn_deg"]), float(plain["turn_deg"]), turn_ratio])
		_check(float(drift["retain"]) > 0.85,
			"%s：漂移后仍保有 %.0f%% 车速（不是急刹，%.1f→%.1f m/s）"
			% [vid, float(drift["retain"]) * 100.0,
				float(drift["v_before"]), float(drift["v_after"])])
		_check(float(drift["max_slip"]) > 20.0,
			"%s：漂移最大侧滑 %.1f°（> 20° 才看得出在漂）" % [vid, float(drift["max_slip"])])
		_check(float(plain["max_slip"]) < 10.0,
			"%s：不拉手刹侧滑仅 %.1f°（反向对照：普通转弯不漂）"
			% [vid, float(plain["max_slip"])])
		# 「漂移有收益」的不变式：单位速度的转角（= 1/有效转弯半径）手刹更大。
		# 这条是本节的存在理由——只要它不成立，手刹就该被删掉而不是被调参。
		var plain_efficiency := float(plain["turn_deg"]) / maxf(float(plain["v_after"]), 0.001)
		var drift_efficiency := float(drift["turn_deg"]) / maxf(float(drift["v_after"]), 0.001)
		_check(drift_efficiency > plain_efficiency,
			"%s：漂移的有效转弯更紧（单位速度转角 %.2f > %.2f °/(m/s)）"
			% [vid, drift_efficiency, plain_efficiency])

	# 低抓地放大漂移：湿地上同样的手刹侧滑更大（grip 0.4 < 柏油 1.0）。
	var wet := _cornering("buggy", "wetland", true)
	var dry := _cornering("buggy", "asphalt", true)
	_check(float(wet["max_slip"]) >= float(dry["max_slip"]),
		"湿地漂移侧滑 %.1f° ≥ 柏油 %.1f°（低抓地放大甩尾）"
		% [float(wet["max_slip"]), float(dry["max_slip"])])

	# 不打方向就拉手刹 → 只是滑行，不该凭空产生侧滑角（转向增益只作用于转向）。
	var straight := CarPhysics.new()
	straight.setup(RaceSystem.vehicle("buggy"), Vector2.ZERO, 0.0)
	straight.vel = straight.forward() * 25.0
	var straight_slip := 0.0
	for i in range(int(1.0 / DT)):
		straight.throttle = 0.0
		straight.steer = 0.0
		straight.handbrake = true
		straight.step(DT, RaceSystem.terrain("asphalt"))
		straight_slip = maxf(straight_slip, straight.slip_deg())
	_check(straight_slip < 1.0,
		"直线上拉手刹不产生侧滑（%.2f°）——增益只经转向生效" % straight_slip)


## 让车在给定地形上跑到接近极速，供 _cornering 用。
func _car_at_top_speed(vehicle_id: String, terrain_id: String) -> CarPhysics:
	var spec := RaceSystem.vehicle(vehicle_id)
	var terr := RaceSystem.terrain(terrain_id)
	var car := CarPhysics.new()
	car.setup(spec, Vector2.ZERO, 0.0)
	var goal := float(spec["max_speed_mps"]) * float(terr["speed_factor"]) * 0.995
	for i in range(int(40.0 / DT)):
		car.throttle = 1.0
		car.step(DT, terr)
		if car.speed() > goal:
			break
	return car


## 满舵 2 s：返回 {turn_deg, v_before, v_after, retain, max_slip, arc, radius}。
func _cornering(vehicle_id: String, terrain_id: String, handbrake: bool) -> Dictionary:
	var terr := RaceSystem.terrain(terrain_id)
	var car := _car_at_top_speed(vehicle_id, terrain_id)
	var v0 := car.speed()
	var h0 := car.heading
	var max_slip := 0.0
	var arc := 0.0
	for i in range(int(2.0 / DT)):
		car.throttle = 1.0
		car.steer = 1.0
		car.handbrake = handbrake
		car.step(DT, terr)
		arc += car.speed() * DT
		max_slip = maxf(max_slip, car.slip_deg())
	# 注意：heading 是无界累积量（不是 wrap 到 ±π），漂移 2 s 能转过 300°+。
	# 这里绝不能 wrapf——wrap 会把 310° 折成 −50°，断言会读到「手刹转得更少」的假象。
	var turn := absf(car.heading - h0)
	return {
		"turn_deg": rad_to_deg(turn),
		"v_before": v0,
		"v_after": car.speed(),
		"retain": car.speed() / maxf(v0, 0.001),
		"max_slip": max_slip,
		"arc": arc,
		"radius": arc / maxf(turn, 0.0001),
	}


# ──── G. waypoints 形状模式与三条新赛道（D-085）────
## 为什么需要第二种形状定义：极坐标正弦环 r(θ) 是**星形曲线**——任何方向只有
## 唯一的半径，因此永远不可能出现发卡弯（180° 回头）或减速弯（S 形快速反打）。
## 原来 6 条赛道在弯的性格上必然同质，只是正弦起伏的疏密不同。本节钉住三件事：
##   ① 新赛道几何合法（等距、闭合、不自交、曲率半径不会让路面带翻面）；
##   ② 它们确实是「新弯型」而不是又一条正弦环（最小曲率半径显著更小）；
##   ③ 坏 waypoints 数据会安全回落到极坐标，不会炸掉整个赛道。
func _test_waypoint_tracks() -> void:
	var new_ids: Array[String] = ["canyon_hairpin", "harbor_chicane", "dune_slalom"]
	var all := RaceSystem.tracks()
	_check(all.size() == 9, "赛道总数 9 条（实际 %d）" % all.size())
	for tid: String in new_ids:
		var def := RaceSystem.track(tid)
		_check(not def.is_empty(), "新赛道定义存在：%s" % tid)
		_check(def.has("waypoints"), "%s 走 waypoints 形状模式" % tid)
		var lay := RaceSystem.build_layout(tid)
		_check(lay != null and lay.size() > 100,
			"%s 几何构建成功（%d 采样点）" % [tid, 0 if lay == null else lay.size()])
		if lay == null:
			continue
		var target := float(def.get("length_m", 0.0))
		var err := absf(lay.total - target) / maxf(target, 1.0)
		_check(err < 0.06, "%s 周长贴近目标 %.0f m（实测 %.1f m）" % [tid, target, lay.total])
		# 「等距」是**弧长**意义，不是弦长：曲线上相隔 4 m 弧长的两点，直线距离略短
		# （半径 16 m 处弦差约 0.009 m）；再叠加 PackedVector2Array 是 float32、
		# 在 ±430 m 量级上累积的坐标量化（实测 0.018~0.051 m）。两者之和决定了
		# 容差至少要 0.07。取 0.1 仍然能一眼抓出真正的回归——少算一档就是 4 m 级。
		var worst_gap := 0.0
		for i in lay.size():
			worst_gap = maxf(worst_gap, absf(lay.point(i).distance_to(lay.point(i + 1)) - TrackLayout.SPACING))
		_check(worst_gap < 0.1, "%s 采样等距（最大弦长偏差 %.4f m < 0.1）" % [tid, worst_gap])
		# 报告出来的周长必须是 count × SPACING 的精确值——这个等式是几何与圈速记账
		# 的共同基础，不能有残差。
		var exact_total := float(lay.size()) * TrackLayout.SPACING
		_check(absf(lay.total - exact_total) < 0.000001,
			"%s total 精确等于 采样点数×%.0f（%.4f）" % [tid, TrackLayout.SPACING, lay.total])
		# length_m 必须是 SPACING 的整数倍：否则 count 向下取整后最后一段会明显偏长
		# （例如 1505 m → 最后一段 5 m），赛道圈长记账会悄悄偏 1 m。
		_check(absf(target - roundf(target / TrackLayout.SPACING) * TrackLayout.SPACING) < 0.0001,
			"%s length_m %.0f 是 %.0f 的整数倍（否则闭合边会明显偏长）"
			% [tid, target, TrackLayout.SPACING])
		# 路面带自交翻面的物理条件：中心线曲率半径 < half_width 时内侧边线会翻过去。
		# 这里用 1.2× 做回归闸（留一点离散化余量），另外新赛道还要过 2.5× 的设计线。
		var min_r := lay.min_curve_radius()
		_check(min_r > lay.half_width * 1.2,
			"%s 最小曲率半径 %.1f m > 路面半宽 %.1f m（不会翻面）" % [tid, min_r, lay.half_width])
		_check(min_r >= lay.half_width * 2.5,
			"%s 满足新赛道设计线：minR %.1f ≥ %.1f（半宽 ×2.5）"
			% [tid, min_r, lay.half_width * 2.5])
		# 简单多边形：waypoints 随手摆很容易让赛道自己穿过去（画面上看不出、
		# 却能让孩子冲到对向车道上）。这条是 waypoints 模式独有的风险闸。
		_check(not _self_intersects(lay), "%s 中心线不自交（简单闭合多边形）" % tid)
		var gate_ok := lay.gate_count() >= 3 and lay.gate_count() <= 8
		_check(gate_ok, "%s 检查点 %d 个在 3..8" % [tid, lay.gate_count()])
		_check(lay.gate_index(0) == 0, "%s 起跑线在 0 号采样点" % tid)
		var unlock := String(def.get("unlock", "default"))
		_check(RaceSystem.unlock_hint(unlock) != "", "%s 解锁条件可读：%s → %s"
			% [tid, unlock, RaceSystem.unlock_hint(unlock)])

	# 「真的是新弯型」：新赛道的最小曲率半径必须明显小于全部极坐标赛道。
	# 若哪天有人把新赛道的 waypoints 换成近似圆形，这条会立刻报出来。
	var polar_min := 1.0e9
	for def: Dictionary in RaceSystem.tracks():
		if def.has("waypoints"):
			continue
		var lay := TrackLayout.build(def)
		if lay == null:
			continue
		polar_min = minf(polar_min, lay.min_curve_radius())
	_check(polar_min > 0.0 and polar_min < 1.0e8,
		"极坐标赛道最小曲率半径 %.1f m（作为对照基准）" % polar_min)
	for tid: String in new_ids:
		var lay := RaceSystem.build_layout(tid)
		if lay == null:
			continue
		_check(lay.min_curve_radius() < polar_min,
			"%s minR %.1f < 极坐标基准 %.1f（确实是极坐标做不出的弯）"
			% [tid, lay.min_curve_radius(), polar_min])

	# 坏数据安全阀：waypoints 少于 3 点时 _raw_waypoints 返回空，build 回落极坐标。
	var broken := RaceSystem.track("desert_ring").duplicate(true)
	broken["waypoints"] = [[0.0, 0.0], [10.0, 0.0]]
	var lay_broken := TrackLayout.build(broken)
	_check(lay_broken != null and lay_broken.size() > 100,
		"坏 waypoints（2 个点）安全回落到极坐标（%d 采样点）"
		% (0 if lay_broken == null else lay_broken.size()))


## 闭合折线是否自交（跳过相邻边与首尾相邻边）。O(n²)，9 条赛道累计几十万次，
## 但这是 waypoints 模式唯一能「画面上看不出、逻辑上致命」的错误来源，值得跑。
func _self_intersects(lay: TrackLayout) -> bool:
	var n := lay.size()
	for i in n:
		var a1 := lay.point(i)
		var a2 := lay.point(i + 1)
		for j in range(i + 2, n):
			if i == 0 and j == n - 1:
				continue     # 首尾相邻，共享顶点
			if _segments_cross(a1, a2, lay.point(j), lay.point(j + 1)):
				return true
	return false


func _segments_cross(a1: Vector3, a2: Vector3, b1: Vector3, b2: Vector3) -> bool:
	var p := Vector2(a1.x, a1.z)
	var r := Vector2(a2.x - a1.x, a2.z - a1.z)
	var q := Vector2(b1.x, b1.z)
	var s := Vector2(b2.x - b1.x, b2.z - b1.z)
	var denom := r.cross(s)
	if absf(denom) < 0.000001:
		return false      # 平行或共线：等距采样下不构成穿越
	var t := (q - p).cross(s) / denom
	var u := (q - p).cross(r) / denom
	return t > 0.0001 and t < 0.9999 and u > 0.0001 and u < 0.9999


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
