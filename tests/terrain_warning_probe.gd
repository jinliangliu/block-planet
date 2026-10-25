extends Node
## 地形前视预警（D-072 P2b）探针：纯逻辑构造式断言 + FlightInstruments 集成
## + 真实世界接线端到端。
##
##   A 段 TerrainWarning 纯逻辑：合成高度场（Callable 采样器）+ 手搓读数，
##       把两级门限（警告 <25 m 绝对 / 注意 <40 m 且 rise>20）、+20 m 滞环、
##       三道门控（未离地 / 失速让位 / 着陆下降段）、采样密度声明逐条钉死，
##       每条关键判据配反向对照（防空闸）。
##   B 段 FlightInstruments 集成：告警列表（id/级别/置顶优先级）、横幅通道、
##       蜂鸣边沿 + 重播 cadence、失速门下让位、无采样器恒 0（既有探针零影响）。
##   C 段 真实世界（main.tscn）：hud.gd 登机时注入的采样器端到端生效——
##       贴谷地平飞触发警告 → 爬升后滞环清除。
##
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/terrain_warning_probe.tscn

const PROBE_PAD := preload("res://tests/probe_pad.gd")

var _failed := 0
const _ID := Basis.IDENTITY


func _ready() -> void:
	await _run()


func _run() -> void:
	# C 段真实起飞会推进 progress 的 flew 计数（Events.aircraft_took_off →
	# notify("flew")），必须原样还原（D-010 铁律 3）。
	SaveGuard.snapshot()
	_a_terrain_warning_logic()
	_b_instruments_integration()
	await _c_real_world_wiring()
	SaveGuard.restore()
	_finish()


# ── A 段：TerrainWarning 纯逻辑 ───────────────────────────
## 手搓读数：只放 TerrainWarning 用到的 6 个键（缺键按安全默认处理）。
func _reading(pos: Vector3, vel: Vector3, agl: float, vs: float = 0.0,
		stalled: bool = false, warn: bool = false) -> Dictionary:
	return {
		"position": pos, "velocity": vel, "altitude_agl": agl,
		"vertical_speed": vs, "stalled": stalled, "stall_warning": warn,
	}


## 平地高度场（全 0）。
func _flat() -> Callable:
	return func(_wx: int, _wz: int) -> int:
		return 0


## 墙高度场：z < wall_z 为 flat_h，z >= wall_z 起 wall_h。
func _wall(wall_z: int, wall_h: int, flat_h: int) -> Callable:
	return func(_wx: int, wz: int) -> int:
		return wall_h if wz >= wall_z else flat_h


## 台地高度场：z < step_z 为 low_h，之外 high_h（rise 判别对用）。
func _step(step_z: int, low_h: int, high_h: int) -> Callable:
	return func(_wx: int, wz: int) -> int:
		return high_h if wz >= step_z else low_h


## 窄脊高度场：z ∈ [a, b] 为 ridge_h，其余 flat_h（采样密度声明用）。
func _ridge(a: int, b: int, ridge_h: int, flat_h: int) -> Callable:
	return func(_wx: int, wz: int) -> int:
		return ridge_h if wz >= a and wz <= b else flat_h


func _a_terrain_warning_logic() -> void:
	var VEL := Vector3(0.0, 0.0, 50.0)   # +Z 50 m/s → 外推 500 m，采样 50..450
	var O := Vector3(0.0, 0.0, 0.0)

	# A1 平飞净空（假阳性守卫）：绝对阈值 + rise 条件都不能把「低空平飞」
	# 误判成「前方有山」——40 m 巡航（FD 封顶 100 − 谷地粗模 45 = 55 余量）
	# 全程黄牌就是警报疲劳（decisions.md 同款教训）。
	var w1 := TerrainWarning.new()
	w1.set_sampler(_flat())
	w1.update(_reading(O + Vector3(0, 70, 0), VEL, 70.0))
	_check(w1.level == 0, "A1 平飞净空 70 m → 不报（假阳性守卫）")

	# A2 平飞低空（警告绝对档）：min_ahead 20 < 25 → 红。绝对档刻意不加
	# rise 条件——18 m 贴地平飞没有「山」也该被拦，安全优先于安静。
	var w2 := TerrainWarning.new()
	w2.set_sampler(_flat())
	w2.update(_reading(O + Vector3(0, 20, 0), VEL, 20.0))
	_check(w2.level == 2, "A2 平飞低空 20 m → 警告（min_ahead<25 绝对档）")

	# A3 墙在 300 m 外（60 m 高）：采样点在 z=300 命中，余量 10 < 25 → 警告。
	var w3 := TerrainWarning.new()
	w3.set_sampler(_wall(300, 60, 0))
	w3.update(_reading(O + Vector3(0, 70, 0), VEL, 70.0))
	_check(w3.level == 2, "A3 300 m 外 60 m 墙、高度 70 → 警告（余量 10<25）")

	# A4 注意档：墙 40 m、余量 30 < 40 且 rise 40 > 20 → 黄。
	var w4 := TerrainWarning.new()
	w4.set_sampler(_wall(300, 40, 0))
	w4.update(_reading(O + Vector3(0, 70, 0), VEL, 70.0))
	_check(w4.level == 1, "A4 300 m 外 40 m 墙、高度 70 → 注意（余量 30<40 且 rise 40>20）")

	# A5 rise 判别对（同余量 30、异 rise）：rise 15 → 静默；rise 35 → 注意。
	# 这是「ALT 过低警告刻意要求下沉率」的同款教训在地形上的对偶——没有
	# rise 条件，任何 <40 m 的飞行都黄牌。两侧余量严格相等，唯一变量是 rise。
	var w5a := TerrainWarning.new()
	w5a.set_sampler(_step(150, 30, 45))
	w5a.update(_reading(O + Vector3(0, 75, 0), VEL, 45.0))
	_check(w5a.level == 0, "A5 余量 30 但 rise 15（≤20）→ 不报（rise 门控生效）")
	var w5b := TerrainWarning.new()
	w5b.set_sampler(_step(150, 30, 65))
	w5b.update(_reading(O + Vector3(0, 95, 0), VEL, 65.0))
	_check(w5b.level == 1, "A5b 余量 30 且 rise 35（>20）→ 注意（反向对照，非空闸）")

	# A6 滞环：警告后余量 30 / 44 都保持 2（清除带 45），到 45 才清零。
	# 单次 update 不重算方向——每次喂新读数模拟飞机爬升。
	var w6 := TerrainWarning.new()
	w6.set_sampler(_wall(300, 60, 0))
	w6.update(_reading(O + Vector3(0, 84, 0), VEL, 84.0))
	_check(w6.level == 2, "A6 前置：余量 24<25 → 警告")
	w6.update(_reading(O + Vector3(0, 90, 0), VEL, 90.0))
	_check(w6.level == 2, "A6b 余量升到 30（<45 清除带）→ 保持警告（滞环）")
	w6.update(_reading(O + Vector3(0, 104, 0), VEL, 104.0))
	_check(w6.level == 2, "A6c 余量 44（清除带下沿 45 以下）→ 仍保持")
	w6.update(_reading(O + Vector3(0, 105, 0), VEL, 105.0))
	_check(w6.level == 0, "A6d 余量 45（== 25+20 清除带）→ 清除（等值点）")

	# A7 门控一：未离地不报。等值点 AGL 2.0（<= AIRBORNE_AGL 判据）屏蔽，
	# 2.5 即报——滑跑正前方永远有「山」（跑道尽头的坡），报了孩子只会学会
	# 忽略警报。同一高度场、同一速度，唯一变量是 AGL。
	var w7a := TerrainWarning.new()
	w7a.set_sampler(_wall(300, 60, 0))
	w7a.update(_reading(O + Vector3(0, 2.0, 0), VEL, 2.0))
	_check(w7a.level == 0, "A7 未离地（AGL == 2.0 等值点）→ 不报（滑跑门控）")
	var w7b := TerrainWarning.new()
	w7b.set_sampler(_wall(300, 60, 0))
	w7b.update(_reading(O + Vector3(0, 2.5, 0), VEL, 2.5))
	_check(w7b.level == 2, "A7b 离地（AGL 2.5）→ 照常报（反向对照）")

	# A8 门控二：失速中让位 StallCoach（含接近失速——教案①在 warning 就亮）。
	# 「推杆低头」与「快拉升」实时冲突，同 D-071 范式。
	var w8a := TerrainWarning.new()
	w8a.set_sampler(_wall(300, 60, 0))
	w8a.update(_reading(O + Vector3(0, 70, 0), VEL, 70.0, 0.0, true, false))
	_check(w8a.level == 0, "A8 完全失速中 → 不报（让位 StallCoach）")
	var w8b := TerrainWarning.new()
	w8b.set_sampler(_wall(300, 60, 0))
	w8b.update(_reading(O + Vector3(0, 70, 0), VEL, 70.0, 0.0, false, true))
	_check(w8b.level == 0, "A8b 接近失速（stall_warning）→ 也不报（教案①已亮）")
	# 反向对照：同一读数去掉失速标志 → 确实该报（证明 A8 非空闸）。
	var w8c := TerrainWarning.new()
	w8c.set_sampler(_wall(300, 60, 0))
	w8c.update(_reading(O + Vector3(0, 70, 0), VEL, 70.0))
	_check(w8c.level == 2, "A8c 去掉失速标志 → 照常报（反向对照）")

	# A9 门控三：着陆下降段屏蔽（AGL<60 且 VS<−1.5）。等值点两侧：
	# VS −2.0 屏蔽 / VS −1.0 不屏蔽——否则每次正常进近全程误报。
	var w9a := TerrainWarning.new()
	w9a.set_sampler(_wall(300, 30, 0))
	w9a.update(_reading(O + Vector3(0, 50, 0), VEL, 50.0, -2.0))
	_check(w9a.level == 0, "A9 着陆下降段（AGL 50 + VS −2.0）→ 不报")
	var w9b := TerrainWarning.new()
	w9b.set_sampler(_wall(300, 30, 0))
	w9b.update(_reading(O + Vector3(0, 50, 0), VEL, 50.0, -1.0))
	_check(w9b.level == 2, "A9b 沉降不够（VS −1.0）→ 照常报（反向对照）")

	# A10 采样密度声明：窄脊（z 280..320，60 m 高）落在 50 m 采样网格的
	# 300 档上——单取地平线（500 m 处平坦）会漏，多档采样命中。
	var w10 := TerrainWarning.new()
	w10.set_sampler(_ridge(280, 320, 60, 0))
	w10.update(_reading(O + Vector3(0, 70, 0), VEL, 70.0))
	_check(w10.level == 2, "A10 窄脊落在采样档上 → 命中（多档采样防漏脊）")

	# A11 航迹不可信 / 无采样器：速度 <1 或采样器无效 → 不报。
	var w11a := TerrainWarning.new()
	w11a.set_sampler(_wall(300, 60, 0))
	w11a.update(_reading(O + Vector3(0, 70, 0), Vector3(0.0, 0.0, 0.5), 70.0))
	_check(w11a.level == 0, "A11 航迹速度 <1 m/s → 不报（方向不可信）")
	var w11b := TerrainWarning.new()
	w11b.set_sampler(Callable())
	w11b.update(_reading(O + Vector3(0, 70, 0), VEL, 70.0))
	_check(w11b.level == 0, "A11b 无采样器 → 不报（未注入时静默）")
	var w11c := TerrainWarning.new()
	w11c.set_sampler(_wall(300, 60, 0))
	var no_vel: Dictionary = {"position": O + Vector3(0, 70, 0), "altitude_agl": 70.0}
	w11c.update(no_vel)
	_check(w11c.level == 0, "A11c 读数缺 velocity 键 → 不报（缺键安全默认）")

	# A12 reset：登机/下机同步调，陈旧级别不带进下次飞行。
	var w12 := TerrainWarning.new()
	w12.set_sampler(_wall(300, 60, 0))
	w12.update(_reading(O + Vector3(0, 70, 0), VEL, 70.0))
	_check(w12.level == 2, "A12 前置：已告警")
	w12.reset()
	_check(w12.level == 0, "A12b reset 后清零")


# ── B 段：FlightInstruments 集成 ─────────────────────────
func _b_instruments_integration() -> void:
	var VEL := Vector3(0.0, 0.0, 50.0)
	var O := Vector3(0.0, 0.0, 0.0)

	# B1 警告进 alerts 且置顶（-1 压过超速 0）：装山是秒级致命威胁。
	var fi := FlightInstruments.new()
	fi.set_terrain_sampler(_wall(300, 60, 0))
	for i in range(3):
		fi.update({"position": O + Vector3(0, 70, 0), "velocity": VEL,
			"altitude_agl": 70.0, "overspeed": true}, _ID, 0.1)
	_check(fi.terrain_warn == 2, "B1 地形警告级别置 2")
	var la := fi.alerts()
	_check(la.size() >= 2 and la[0]["id"] == "terrain",
		"B1b 地形警告置顶（压过超速，alerts()[0] = terrain）")
	_check(la[0]["level"] == FlightInstruments.AlertLevel.WARNING,
		"B1c 地形警告为 WARNING 级")
	_check(String(la[0]["text"]).contains("快拉升"), "B1d 警告文案「%s」" % la[0]["text"])

	# B2 注意档 + 横幅通道（banner_alerts 不排除地形类）。
	var fb := FlightInstruments.new()
	fb.set_terrain_sampler(_wall(300, 40, 0))
	for i in range(3):
		fb.update({"position": O + Vector3(0, 70, 0), "velocity": VEL,
			"altitude_agl": 70.0}, _ID, 0.1)
	var lb := fb.alerts()
	var found := false
	for a in lb:
		if String(a["id"]) == "terrain_caution":
			found = true
	_check(found, "B2 注意档告警 id = terrain_caution")
	_check(not fb.banner_alerts().is_empty()
		and String(fb.banner_alerts()[0]["id"]) == "terrain_caution",
		"B2b 注意档进横幅通道（banner_alerts 首位）")

	# B3 失速门下：地形告警整体消失，alerts()[0] 归失速（StallCoach 通道）。
	var fc := FlightInstruments.new()
	fc.set_terrain_sampler(_wall(300, 60, 0))
	for i in range(3):
		fc.update({"position": O + Vector3(0, 70, 0), "velocity": VEL,
			"altitude_agl": 70.0, "stalled": true}, _ID, 0.1)
	var lc := fc.alerts()
	var has_terrain := false
	for a in lc:
		if String(a["id"]).begins_with("terrain"):
			has_terrain = true
	_check(fc.terrain_warn == 0 and not has_terrain,
		"B3 失速中地形告警让位（alerts 无 terrain 项）")
	_check(lc[0]["id"] == "stall_full", "B3b 失速居首（教案通道不受地形挤压）")

	# B4 无采样器：terrain_warn 恒 0——既有探针（读数无 velocity）零影响。
	var fd := FlightInstruments.new()
	for i in range(3):
		fd.update({"position": O + Vector3(0, 70, 0), "velocity": VEL,
			"altitude_agl": 70.0}, _ID, 0.1)
	_check(fd.terrain_warn == 0 and fd.alerts().is_empty(),
		"B4 未注入采样器 → 地形预警恒 0（既有断言零影响）")

	# B5 蜂鸣：边沿触发播一次，按 replay 0.8 s 重播。
	var fe := FlightInstruments.new()
	fe.set_terrain_sampler(_wall(300, 60, 0))
	fe.update({"position": O + Vector3(0, 70, 0), "velocity": VEL,
		"altitude_agl": 70.0}, _ID, 0.1)
	var first := fe.take_voice_cues(0.1)
	_check(first.size() == 1 and first[0]["id"] == "terrain",
		"B5 地形警告首帧播蜂鸣（terrain）")
	var soon := fe.take_voice_cues(0.1)
	_check(soon.is_empty(), "B5b 0.1 s 内不重播（replay 0.8 s cadence）")
	var replayed := false
	for i in range(16):   # 16 × 0.05 = 0.8 s 累计
		if not fe.take_voice_cues(0.05).is_empty():
			replayed = true
	_check(replayed, "B5c 累计 0.8 s 到点重播")

	# B6 reset_terrain_warning：与 reset_voice_cues 同批调用点（登机/下机）。
	fe.reset_terrain_warning()
	_check(fe.terrain_warn == 0, "B6 reset_terrain_warning 后级别清零")


# ── C 段：真实世界接线（hud.gd 采样器注入端到端） ────────
func _c_real_world_wiring() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame
	var player: Player = main_scene.get_node("Player")
	var hud: HUD = main_scene.get_node("UI") as HUD
	var world: World = main_scene.get_node("World")
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	GameState.needs_region_pick = false
	for i in range(30):
		await get_tree().process_frame

	var pad := PROBE_PAD.prepare(world, player)
	var craft: Aircraft = Aircraft.spawn(main_scene, pad["spawn"], PI)
	var crashed := false
	craft.crashed.connect(func(_reason: String) -> void:
		crashed = true)
	player.ride_aircraft(craft)
	craft.drive_remotely()
	for i in range(300):
		await get_tree().physics_frame
		if not is_instance_valid(craft):
			break
		if craft.is_on_floor() and craft.velocity.length() < 0.5:
			break
	if not is_instance_valid(craft) or craft.is_wrecked():
		_check(false, "C0 就位阶段机体解体")
		return
	_check(not craft.is_wrecked(), "C1 就位后机体完好")
	# 等 hud.gd 的登机装配跑完（setup + 采样器注入在 _process 的骑乘刷新里）。
	for i in range(10):
		await get_tree().process_frame
	var instr: FlightInstruments = hud.instrument_hud().instruments_ref()
	_check(instr != null, "C2 仪表实例可引用（instruments_ref）")

	# ── 贴谷地平飞：真实采样器 + 真实读数链路 → 警告 ──
	# y=55：脚下地表 27~37（谷地盘），航迹 500 m 内最低点 37 → 预测余量
	# 18 < 25 → 警告。刻意不找墙——绝对警告档贴地平飞就触发，不依赖特定地形。
	craft.global_position = Vector3(122.0, 55.0, 53.0)
	craft.controls.throttle = 1.0
	craft.controls.pitch = 0.0
	craft.controls.roll = 0.0
	craft.launch(50.0)
	# AGL 射线 5 Hz（0.2 s）节流 + HUD tick 在进程帧：等 20 物理帧（0.33 s，
	# 跨过一个节流周期）再放过 2 个进程帧，保证读到传送后的新 AGL 与刷新后的
	# 仪表（process_frame 在节点 _process 之前发，等 1 次读到的是旧值）。
	for i in range(20):
		await get_tree().physics_frame
	await get_tree().process_frame
	await get_tree().process_frame
	_check(instr.terrain_warn == 2,
		"C3 贴谷地平飞 → 地形警告（hud.gd 注入的采样器端到端生效，level=%d）"
			% instr.terrain_warn)
	var lc := instr.alerts()
	_check(not lc.is_empty() and lc[0]["id"] == "terrain",
		"C3b 告警列表置顶为 terrain（横幅+蜂鸣通道）")

	# ── 爬升到净空：滞环清除（余量 ≥ 45） ──
	craft.global_position = Vector3(122.0, 95.0, 53.0)
	craft.launch(50.0)
	for i in range(20):
		await get_tree().physics_frame
	await get_tree().process_frame
	await get_tree().process_frame
	_check(instr.terrain_warn == 0,
		"C4 爬升到 95 m（余量 ≥45 清除带）→ 警告清除（level=%d）" % instr.terrain_warn)

	_check(not crashed, "C5 全过程未坠机")
	# 收尾：下机让 HUD 解绑（与 stall_coach_probe 同范式），再还原存档。
	if is_instance_valid(craft) and not craft.is_wrecked():
		player.exit_aircraft()
		for i in range(10):
			await get_tree().physics_frame


func _finish() -> void:
	if _failed == 0:
		print("TERRAIN_WARNING_PROBE_OK")
		get_tree().quit(0)
	else:
		print("TERRAIN_WARNING_PROBE_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
