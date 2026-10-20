extends Node
## 接地质量评分探针（U-7）+ 进近高度呼号探针（U-10）。
##   A 段 LandingQuality 纯逻辑：三项连续打分的边界与分级文案
##   B 段 MissionManager 降落任务：二值判定 → 连续评分的改造（软着陆比
##        硬着陆边缘分高、越轻分越高、失败仍 0 分、防刷仍计分）
##   C 段 FlightInstruments 高度呼号：下沉穿越 30/20/10/5 各呼一次、
##        爬升不呼、同层不重复、着地重置、take 即消费
##   D 段端到端（真实飞机节点）：低空落跑道 → 触地边沿记 vs → 滑跑停稳
##        → Events.aircraft_landed 广播（SaveGuard 隔离存档）
## A/B/C 纯逻辑不建场景；D 实例化 main.tscn。
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/landing_quality_probe.tscn

const DT := 0.1

var _failed := 0


func _ready() -> void:
	GameState.needs_region_pick = false
	_run_quality_checks()
	_run_mission_score_checks()
	_run_callout_checks()
	await _run_e2e_checks()
	print("LANDING_QUALITY_TEST_%s" % ("OK" if _failed == 0 else "FAILED"))
	get_tree().quit(0 if _failed == 0 else 1)


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("PASS: %s" % msg)
	else:
		_failed += 1
		print("FAIL: %s" % msg)


# ---------------------------------------------------------- A 段 纯逻辑
func _run_quality_checks() -> void:
	# 满分：零下沉、零偏差、零滑跑速度。
	var perfect := LandingQuality.score(0.0, 0.0, 0.0)
	_check(int(perfect["total"]) == 100, "A1 三项全零 = 100 分（实际 %d）" % perfect["total"])
	_check(int(perfect["vs_points"]) == 40 and int(perfect["zone_points"]) == 30
		and int(perfect["roll_points"]) == 30, "A2 满分构成 40/30/30（实际 %d/%d/%d）"
		% [perfect["vs_points"], perfect["zone_points"], perfect["roll_points"]])
	_check(String(perfect["grade"]) == "完美降落！", "A3 100 分等级「完美降落！」")

	# vs 项线性：1.5 m/s（任务软着陆典型值）→ 40×(1−1.5/3)=20。
	var soft := LandingQuality.score(-1.5, 5.0, 10.0)
	_check(int(soft["vs_points"]) == 20, "A4 触地 1.5 m/s → vs 项 20 分（实际 %d）" % soft["vs_points"])
	_check(int(soft["zone_points"]) == 27, "A5 偏差 5 m → zone 项 27 分（实际 %d）" % soft["zone_points"])
	_check(int(soft["roll_points"]) == 18, "A6 停稳 10 km/h → roll 项 18 分（实际 %d）" % soft["roll_points"])
	_check(int(soft["total"]) == 65, "A7 合计 65 分（实际 %d）" % soft["total"])
	_check(String(soft["grade"]) == "降落不错", "A8 65 分等级「降落不错」")

	# vs 边界：3.0（硬着陆阈值）→ 0；超过阈值钳 0 不出现负分。
	var hard_edge := LandingQuality.score(-3.0, 0.0, 0.0)
	_check(int(hard_edge["vs_points"]) == 0, "A9 触地 3.0 m/s → vs 项 0 分（阈值即硬着陆）")
	var over := LandingQuality.score(-9.9, 999.0, 999.0)
	_check(int(over["total"]) == 0, "A10 超阈值输入钳到 0 分不出现负分（实际 %d）" % over["total"])
	_check(String(over["grade"]) == "摔得有点疼", "A11 0 分等级「摔得有点疼」")

	# 连续性：同样偏差/滑跑下，触地越轻分越高（评分而非判定）。
	var lighter := LandingQuality.score(-0.5, 5.0, 10.0)
	_check(int(lighter["total"]) > int(soft["total"]),
		"A12 触地 0.5 m/s 比 1.5 m/s 分高（%d > %d，连续性）"
		% [lighter["total"], soft["total"]])

	# zone 项：无参照传负 → 中性 18，不奖不罚。
	var no_zone := LandingQuality.score(-1.0, -1.0, 0.0)
	_check(int(no_zone["zone_points"]) == 18,
		"A13 无参照落点 → zone 中性 18 分（实际 %d）" % no_zone["zone_points"])
	# zone 边界：50 m（降落区半径）→ 0。
	var far := LandingQuality.score(0.0, 50.0, 0.0)
	_check(int(far["zone_points"]) == 0, "A14 偏差 50 m → zone 项 0 分（半径即满分边界）")

	# 分级边界：roll 项 20 分（stop 8.333 km/h）→ 总分 90 踩「完美」线；
	# roll 项 5 分（stop 20.833 km/h）→ 75 踩「漂亮」线。
	_check(LandingQuality.score(0.0, 0.0, 8.333)["total"] == 90,
		"A15 roll 8.33 km/h → 90 分踩「完美」线（实际 %d）" % LandingQuality.score(0.0, 0.0, 8.333)["total"])
	_check(LandingQuality.score(0.0, 0.0, 20.833)["total"] == 75,
		"A16 roll 20.83 km/h → 75 分踩「漂亮」线（实际 %d）" % LandingQuality.score(0.0, 0.0, 20.833)["total"])
	_check(String(LandingQuality.score(0.0, 0.0, 12.5)["grade"]) == "飞得很漂亮"
		and LandingQuality.score(0.0, 0.0, 12.5)["total"] == 85,
		"A17 roll 12.5 km/h → 85 分「飞得很漂亮」")
	_check(String(LandingQuality.score(-3.0, 50.0, 25.0)["grade"]) == "摔得有点疼",
		"A18 三项全触底 → 0 分「摔得有点疼」")

	# 汇总文案。
	_check(LandingQuality.summary(soft) == "🛬 落地 65 分：👍降落不错",
		"A19 汇总文案格式（实际「%s」）" % LandingQuality.summary(soft))


# ------------------------------------------------- B 段 任务连续评分
func _frames_landing(touchdown_vs: float, final_pos: Vector3, stop_speed: float,
		block_under: int = -1) -> Array[Dictionary]:
	var f: Array[Dictionary] = []
	for i in 4:  # 进近：空中
		f.append({"altitude_agl": 50.0 - i * 10.0, "speed": 100.0,
			"position": Vector3(0, 0, 0), "on_ground": false,
			"vertical_speed": -2.0, "wrecked": false})
	f.append({"altitude_agl": 0.0, "speed": stop_speed, "position": final_pos,
		"on_ground": true, "vertical_speed": touchdown_vs, "wrecked": false,
		"block_under": block_under})
	return f


func _run_mission(m: MissionData, frames: Array[Dictionary]) -> Dictionary:
	var mm := MissionManager.new()
	var holder := {"result": {}}
	mm.mission_result.connect(func(_success: bool, r: Dictionary):
		holder["result"] = r)
	mm.start(m)
	for f in frames:
		if not holder["result"].is_empty():
			break
		mm.step(DT, f)
	if holder["result"].is_empty():
		mm.timeout()
	return holder["result"]


func _mk_landing() -> MissionData:
	var m := MissionData.new()
	m.type = MissionData.Type.LANDING
	m.params = {"zone_radius": 50.0, "max_touchdown_vs": 3.0, "max_roll_speed": 25.0}
	m.zone_center = Vector3(0, 0, 0)
	return m


func _run_mission_score_checks() -> void:
	var m := _mk_landing()
	# 软着陆 + 区内 + 停稳：与 A 段同参数（vs 1.5 / 偏差 5 m / 10 km/h）。
	var soft := _run_mission(m, _frames_landing(-1.5, Vector3(5, 0, 0), 10.0))
	_check(bool(soft.get("success", false)), "B1 软着陆判成功")
	_check(int(soft.get("score", 0)) == 65,
		"B2 任务评分 = LandingQuality 口径 65（实际 %d，原公式为 0~200）" % soft["score"])
	var q: Dictionary = soft.get("landing_quality", {})
	_check(int(q.get("total", -1)) == int(soft.get("score", -2)),
		"B3 result.landing_quality.total 与 score 一致（%d vs %d）"
		% [q.get("total", -1), soft.get("score", -2)])
	_check(String(q.get("grade", "")) == "降落不错",
		"B4 result 带等级文案（「%s」）" % q.get("grade", ""))

	# 连续性：同样条件下触地更轻分更高。
	var lighter := _run_mission(m, _frames_landing(-0.5, Vector3(5, 0, 0), 10.0))
	_check(int(lighter.get("score", 0)) > int(soft.get("score", 0)),
		"B5 触地 0.5 比 1.5 分高（%d > %d）"
		% [lighter["score"], soft["score"]])

	# 失败路径：硬着陆 score 仍为 0。
	var hard := _run_mission(m, _frames_landing(-10.0, Vector3(5, 0, 0), 10.0))
	_check(not bool(hard.get("success", true)), "B6 硬着陆判失败")
	_check(int(hard.get("score", 0)) == 0, "B7 硬着陆评分 0（实际 %d）" % hard["score"])

	# 防刷：同一实例重复完成——首次正常发奖，第二次 repeat 标记 + 奖励归零，
	# 但评分照算（0~100 新口径下 score>0 仍成立，mission_probe 同款断言）。
	var mm := MissionManager.new()
	var holder := {"result": {}}
	mm.mission_result.connect(func(_success: bool, r: Dictionary):
		holder["result"] = r)
	mm.start(m)
	for f in _frames_landing(-1.5, Vector3(5, 0, 0), 10.0):
		if not holder["result"].is_empty():
			break
		mm.step(DT, f)
	_check(bool(holder["result"].get("success", false)), "B8 首次完成判成功")
	_check(int(holder["result"].get("score", 0)) > 0,
		"B9 首次完成计分（score=%d）" % holder["result"]["score"])
	_check(not bool(holder["result"].get("repeat", true)), "B10 首次无 repeat 标记")
	holder["result"] = {}
	mm.start(m)
	for f in _frames_landing(-1.5, Vector3(5, 0, 0), 10.0):
		if not holder["result"].is_empty():
			break
		mm.step(DT, f)
	_check(bool(holder["result"].get("repeat", false)), "B11 重复完成带 repeat 标记")
	_check(int(holder["result"].get("reward", -1)) == 0, "B12 重复完成奖励归零")
	_check(int(holder["result"].get("score", 0)) > 0,
		"B13 重复完成仍计分（score=%d）" % holder["result"]["score"])


# ------------------------------------------------- C 段 高度呼号
func _fi() -> FlightInstruments:
	return FlightInstruments.new()


const _ID := Basis.IDENTITY


func _run_callout_checks() -> void:
	var fi := _fi()
	# 进近下降：50 → 0，步长 1.25 m 模拟连续下沉（真实 dt 下 AGL 连续变化）。
	# 步长必须穿过 5 m 层的「airborne 窗口」——一帧从 5+ 跨到 <2（着地判据）
	# 会漏呼，那是大步长的假象，不是漏报。
	var agl := 50.0
	var spoken: Array[float] = []
	for i in range(40):
		fi.update({"altitude_agl": agl, "vertical_speed": -2.0}, _ID, DT)
		spoken.append_array(fi.take_altitude_callouts())
		agl -= 1.25
	_check(spoken == [30.0, 20.0, 10.0, 5.0],
		"C1 下沉穿越 30/20/10/5 各呼一次（实际 %s）" % str(spoken))
	# 消费后清空：同一帧再取为空。
	_check(fi.take_altitude_callouts().is_empty(), "C2 take 即消费，重复取为空")

	# 爬升穿越同层不呼。
	var fi2 := _fi()
	var spoken2: Array[float] = []
	agl = 5.0
	for i in range(8):
		fi2.update({"altitude_agl": agl, "vertical_speed": 2.0}, _ID, DT)
		spoken2.append_array(fi2.take_altitude_callouts())
		agl += 5.0
	_check(spoken2.is_empty(), "C3 爬升穿越同层不呼号（实际 %s）" % str(spoken2))

	# 平飞不呼（|vs| 小于阈值）。
	var fi3 := _fi()
	var spoken3: Array[float] = []
	agl = 40.0
	for i in range(8):
		fi3.update({"altitude_agl": agl, "vertical_speed": -0.2}, _ID, DT)
		spoken3.append_array(fi3.take_altitude_callouts())
		agl -= 1.0
	_check(spoken3.is_empty(), "C4 缓降（−0.2 m/s）不呼号（实际 %s）" % str(spoken3))

	# 同层二次穿越不重复呼：下降到 20 以下后拉升回 25，再降穿 20 不呼。
	var fi4 := _fi()
	fi4.update({"altitude_agl": 25.0, "vertical_speed": -2.0}, _ID, DT)
	fi4.take_altitude_callouts()
	fi4.update({"altitude_agl": 19.0, "vertical_speed": -2.0}, _ID, DT)
	_check(fi4.take_altitude_callouts() == [20.0], "C5 首次穿 20 呼一次")
	fi4.update({"altitude_agl": 26.0, "vertical_speed": 2.0}, _ID, DT)
	fi4.update({"altitude_agl": 19.0, "vertical_speed": -2.0}, _ID, DT)
	_check(fi4.take_altitude_callouts().is_empty(), "C6 同层二次穿越不重复呼")

	# 着地重置：降到地面后重新起飞，可再次呼号。
	var fi5 := _fi()
	fi5.update({"altitude_agl": 25.0, "vertical_speed": -2.0}, _ID, DT)
	fi5.take_altitude_callouts()
	fi5.update({"altitude_agl": 1.0, "vertical_speed": -2.0}, _ID, DT)  # 着地
	fi5.take_altitude_callouts()
	fi5.update({"altitude_agl": 25.0, "vertical_speed": 2.0}, _ID, DT)  # 重新起飞
	fi5.update({"altitude_agl": 19.0, "vertical_speed": -2.0}, _ID, DT)
	_check(fi5.take_altitude_callouts() == [20.0],
		"C7 着地后重新起飞可再次呼号（重置 done 集合）")


# ------------------------------------------- D 段 端到端（真实飞机落地）
func _run_e2e_checks() -> void:
	SaveGuard.snapshot()
	var prev_pick := GameState.needs_region_pick
	GameState.needs_region_pick = false
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame

	var park: Vector3 = main_scene._craft_park
	_check(park != Vector3.ZERO, "D0 main 记录了停机位（%s）" % str(park))

	# 低空落在跑道上：机轮离地 1.5 m（落速 ≈5.4 m/s，低于解体阈值 7，
	# 不至于一碰就碎；又足够触发 airborne→ground 边沿）。
	var craft := Aircraft.spawn(main_scene, park + Vector3(0.0, 1.5, 0.0), PI)
	var landed := {"fired": false, "result": {}}
	Events.aircraft_landed.connect(func(r: Dictionary):
		landed["fired"] = true
		landed["result"] = r)
	# 等停稳结算（滑跑 + 摩擦减速，超时 15 s 兜底）。
	for i in range(300):
		await get_tree().physics_frame
		if bool(landed["fired"]):
			break
	_check(bool(landed["fired"]), "D1 落地停稳后广播 aircraft_landed")
	if not bool(landed["fired"]):
		GameState.needs_region_pick = prev_pick
		SaveGuard.restore()
		return
	var r: Dictionary = landed["result"]
	var total := int(r.get("total", -1))
	_check(total >= 0 and total <= 100,
		"D2 评分在 0~100（实际 %d，grade=%s）" % [total, str(r.get("grade", ""))])
	_check(float(r.get("roll_distance", -1.0)) >= 0.0,
		"D3 带滑跑距离（%.1f m）" % float(r.get("roll_distance", -1.0)))
	var grades := ["完美降落！", "飞得很漂亮", "降落不错", "勉强站稳", "摔得有点疼"]
	_check(grades.has(String(r.get("grade", ""))),
		"D4 等级文案取自分级表（「%s」）" % str(r.get("grade", "")))
	_check(String(r.get("emoji", "")) != "", "D5 带表情符号（%s）" % str(r.get("emoji", "")))

	GameState.needs_region_pick = prev_pick
	SaveGuard.restore()
