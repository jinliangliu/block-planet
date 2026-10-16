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
	scene.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


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
		main_scene.queue_free()
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

	main_scene.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
