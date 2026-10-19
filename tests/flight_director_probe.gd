extends Node
## 飞行指引十字（Flight Director Cross，D-054）纯逻辑探针（无头）：
## 只锁「引导律的正确性」与「不会悄悄坏掉」的契约，不渲染、不断言像素。
##   ① 模式判定：无导航/停机→OFF；贴地→ROLL；爬升→TAKEOFF；远→CRUISE；
##      近→APPROACH。**起飞瞬间（距离≈0、正在爬升）必须判 TAKEOFF 而非
##      APPROACH**——判错就会在离地那一刻提示低头，是最危险的错引导。
##   ② 航向偏差 wrap：350°→10° = +20（右），10°→350° = −20（左），不跳变。
##   ③ 下滑道垂直指令：**高于 3° 下滑道→该低头（负）**；低于→该抬头（正）；
##      正在道上→0；贴脸有分母下限；极端角度钳制 ±12°。符号反了会让玩家
##      「越飞越高、永远落不下来」，是本控件最危险的失效模式，必须钉死。
##   ④ 偏移映射：正航向偏差→右移，正俯仰偏差→上移；限幅 ±MAX_OFF；随 s 线性。
##   ⑤ 饱和判定：超限幅才置位（用于外指示箭头）。
##   ⑥ 控件状态：set_guide/refresh 后 mode 与 deviation 与手算一致；
##      clear_guide → OFF（下机/无目标时不留残影）。
##   ⑦ 起飞航向锁定：滑跑段锁定起飞航向，转向后出现横向偏差指令。
##   ⑧ 指令文字：偏差大时给「左转/右转/掉头/抬头/低头」动作词，不是模式名；
##   ⑨ 不出屏 + 不压仪表板：十字及其标签在 1280×720 / 1280×590 下都不越过
##      底沿仪表板顶沿，也不出屏。
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/flight_director_probe.tscn

var _failed := 0
## 参与断言的视口（typed：无类型 Array 迭代出 Variant，会让 `vp * 0.5`
## 无法推断类型而编译失败）。
const VIEWPORTS: Array[Vector2] = [
	Vector2(1280.0, 720.0), Vector2(1280.0, 590.0), Vector2(960.0, 540.0)]


func _ready() -> void:
	await _run()


func _run() -> void:
	_check_mode()
	_check_heading_dev()
	_check_glide_dev()
	_check_offset()
	_check_saturation()
	_check_widget()
	_check_lock()
	_check_label()
	_check_bounds()
	_finish()


## ① 模式判定（含最关键的「起飞瞬间不被判成进近」）。
func _check_mode() -> void:
	var M := FlightDirector.Mode
	_check(FlightDirector.mode_for(false, 50.0, 0.0, 300.0, 80.0) == M.OFF,
		"① 无导航目标 → OFF（不显示）")
	_check(FlightDirector.mode_for(true, 0.0, 0.0, 300.0, 0.0) == M.OFF,
		"① 停机（空速 0）→ OFF")
	_check(FlightDirector.mode_for(true, 0.5, 0.0, 30.0, 60.0) == M.ROLL,
		"① 贴地滑跑（AGL 0.5m）→ ROLL")
	# 起飞瞬间：机场就在脚下（d≈0）、正在爬升（vs>1）。按距离会判 APPROACH
	# 并引导 3° 下降——离地那一刻被提示低头，是本控件最危险的失效模式。
	_check(FlightDirector.mode_for(true, 6.0, 3.0, 8.0, 70.0) == M.TAKEOFF,
		"① 起飞瞬间（d≈0、爬升中）→ TAKEOFF，不按距离误判进近")
	_check(FlightDirector.mode_for(true, 40.0, 3.0, 120.0, 90.0) == M.TAKEOFF,
		"① 爬升离场（AGL 40m、d 120m）→ TAKEOFF")
	_check(FlightDirector.mode_for(true, 40.0, -2.0, 300.0, 90.0) == M.APPROACH,
		"① 下降接近（d 300m）→ APPROACH")
	_check(FlightDirector.mode_for(true, 40.0, -2.0, 800.0, 90.0) == M.CRUISE,
		"① 远距离（d 800m）→ CRUISE")
	# 爬升但已远离机场（d>200）不该再锁起飞段，否则飞出去还一直提示 8° 爬升。
	_check(FlightDirector.mode_for(true, 30.0, 3.0, 500.0, 90.0) == M.CRUISE,
		"① 远离机场爬升（d 500m）→ CRUISE（不再锁起飞爬升角）")


## ② 航向偏差 wrap（正 = 目标在右）。
func _check_heading_dev() -> void:
	_check(absf(FlightDirector.heading_dev_deg(350.0, 10.0) - (-20.0)) < 1e-6,
		"② 目标 350°、机头 10° → −20°（左转，走 0° 近路不绕 340°）")
	_check(absf(FlightDirector.heading_dev_deg(10.0, 350.0) - 20.0) < 1e-6,
		"② 目标 10°、机头 350° → +20°（右转）")
	_check(absf(FlightDirector.heading_dev_deg(90.0, 90.0)) < 1e-6,
		"② 对正 → 0°")
	_check(absf(absf(FlightDirector.heading_dev_deg(0.0, 180.0)) - 180.0) < 1e-6,
		"② 正后方 → ±180°（不越界）")


## ③ 下滑道垂直指令（正 = 该抬头，负 = 该低头）。
func _check_glide_dev() -> void:
	# 1000m 外下滑道应有高度 52.4m；飞机在 100m（高于道 47.6m）→ 低头追回（负）。
	var high := FlightDirector.glide_dev_deg(0.0, 100.0, 1000.0)
	_check(high < -2.0 and high > -3.5,
		"③ 高于下滑道 47.6m → %.2f°（低头追回，符号反了会越飞越高）" % high)
	# 飞机在 10m（低于道 42.4m）→ 抬头爬回去（正）。
	var low := FlightDirector.glide_dev_deg(0.0, 10.0, 1000.0)
	_check(low > 2.0 and low < 3.0,
		"③ 低于下滑道 42.4m → +%.2f°（抬头爬回下滑道）" % low)
	# 正在 3° 下滑道上 → 指令≈0。
	var on_path := FlightDirector.glide_dev_deg(0.0, 1000.0 * tan(deg_to_rad(3.0)), 1000.0)
	_check(absf(on_path) < 0.01, "③ 正在 3° 下滑道上 → 指令 %.4f°（≈0）" % on_path)
	# 贴脸：d=2m 时若直接 atan2 会飙到 ±90°，分母下限 30m 兜住。
	var close := FlightDirector.glide_dev_deg(0.0, 300.0, 2.0)
	_check(absf(close) <= FlightDirector.DEV_CLAMP + 1e-6,
		"③ 贴脸（d=2m、高 300m）指令钳在 %.1f° 内（不发散）" % close)
	_check(absf(FlightDirector.glide_dev_deg(0.0, -9999.0, 40.0)) <= FlightDirector.DEV_CLAMP + 1e-6,
		"③ 极端角度钳制在 ±%.0f°" % FlightDirector.DEV_CLAMP)


## ④ 偏差 → 屏幕偏移。
func _check_offset() -> void:
	var o := FlightDirector.cross_offset(10.0, 0.0, 1.0)
	_check(absf(o.x - 110.0) < 1e-6 and absf(o.y) < 1e-6,
		"④ 航向偏差 +10° → 十字右移 %.0f px" % o.x)
	var v := FlightDirector.cross_offset(0.0, 5.0, 1.0)
	_check(absf(v.y + 55.0) < 1e-6,
		"④ 俯仰偏差 +5°（该抬头）→ 十字上移 %.0f px（y 为负）" % absf(v.y))
	var big := FlightDirector.cross_offset(90.0, 90.0, 1.0)
	_check(absf(big.x) <= FlightDirector.MAX_OFF + 1e-6
		and absf(big.y) <= FlightDirector.MAX_OFF + 1e-6,
		"④ 90° 偏差被限幅在 ±%.0f px（十字不飞出屏幕）" % FlightDirector.MAX_OFF)
	# 缩放线性：s=0.8 的偏移 = s=1 的 0.8 倍（比例跨分辨率恒定）。
	var a1 := FlightDirector.cross_offset(4.0, -2.0, 1.0)
	var a2 := FlightDirector.cross_offset(4.0, -2.0, 0.8)
	_check(absf(a2.x - a1.x * 0.8) < 1e-6 and absf(a2.y - a1.y * 0.8) < 1e-6,
		"④ 偏移随缩放线性（s=0.8 → 0.8 倍，比例跨分辨率恒定）")


## ⑤ 饱和判定（外指示箭头的开关）。
func _check_saturation() -> void:
	_check(not FlightDirector.is_saturated(5.0, 5.0, 1.0),
		"⑤ 5° 偏差未超量程（不画外指示箭头）")
	_check(FlightDirector.is_saturated(20.0, 0.0, 1.0),
		"⑤ 20° 航向偏差超量程 → 置位")
	_check(FlightDirector.is_saturated(0.0, -20.0, 1.0),
		"⑤ −20° 俯仰偏差超量程 → 置位")
	_check(not FlightDirector.is_saturated(FlightDirector.MAX_OFF / FlightDirector.GAIN_PX_PER_DEG - 0.1, 0.0, 1.0),
		"⑤ 恰好在限幅边界内不置位（无抖动）")


## ⑥ 控件状态：refresh 后的 mode / deviation 与手算一致。
func _check_widget() -> void:
	var fd := FlightDirector.new()
	var fi := FlightInstruments.new()
	var target := Vector3(0.0, 40.0, 0.0)
	fd.set_guide(target)
	# 进近：距目标 300m（水平）、高 100m、正在下降。
	var pos := Vector3(300.0, 140.0, 0.0)
	_settle(fi, _reading(pos, 90.0, 100.0, -2.0), _basis(0.0), target)
	fd.refresh(pos, fi)
	_check(fd.current_mode() == FlightDirector.Mode.APPROACH,
		"⑥ 进近态：控件 mode=APPROACH（实得 %d）" % fd.current_mode())
	var expect_v := FlightDirector.glide_dev_deg(target.y, pos.y, 300.0)
	_check(absf(fd.deviation_deg().y - expect_v) < 1e-6,
		"⑥ 进近垂直指令 %.2f° = 手算 %.2f°（高于下滑道 → 负 = 低头）"
			% [fd.deviation_deg().y, expect_v])
	_check(fd.deviation_deg().y < 0.0,
		"⑥ 高于下滑道时指令为负（低头），不是抬头")
	_check(absf(fd.deviation_deg().x - fi.nav_dev_deg) < 1e-6,
		"⑥ 进近水平偏差复用 CDI 的 nav_dev_deg（%.2f°）" % fi.nav_dev_deg)
	# 无目标 / 清除 → OFF（下机后不留残影）。
	fd.clear_guide()
	fd.refresh(pos, fi)
	_check(fd.current_mode() == FlightDirector.Mode.OFF,
		"⑥ clear_guide 后 mode=OFF（不留残影）")
	# 停机（空速 0）→ OFF。
	fd.set_guide(target)
	_settle(fi, _reading(pos, 0.0, 100.0, 0.0), _basis(0.0), target)
	fd.refresh(pos, fi)
	_check(fd.current_mode() == FlightDirector.Mode.OFF,
		"⑥ 停机（空速 0）→ OFF")
	fd.free()


## ⑦ 起飞航向锁定：滑跑段锁定起飞航向，之后转向给出回正指令。
func _check_lock() -> void:
	var fd := FlightDirector.new()
	var fi := FlightInstruments.new()
	var target := Vector3(0.0, 40.0, 0.0)
	fd.set_guide(target)
	var pos := Vector3(0.0, 40.2, 30.0)   # 机场旁，贴地
	# 起飞航向 = 朝 −Z（yaw=0 时 fwd=−Z，heading=180°）。
	_settle(fi, _reading(pos, 60.0, 0.2, 0.0), _basis(0.0), target)
	fd.refresh(pos, fi)
	_check(fd.current_mode() == FlightDirector.Mode.ROLL,
		"⑦ 贴地滑跑 → ROLL（实得 %d）" % fd.current_mode())
	_check(absf(fd.deviation_deg().x) < 0.5,
		"⑦ 沿起飞航向滑跑 → 横向偏差 %.2f°（≈0）" % fd.deviation_deg().x)
	# 偏航 25°（yaw=25°，heading 从 180° 变 205°）→ 给回正指令。
	_settle(fi, _reading(pos, 60.0, 0.2, 0.0), _basis(25.0), target)
	fd.refresh(pos, fi)
	_check(absf(absf(fd.deviation_deg().x) - 25.0) < 1.0,
		"⑦ 滑跑偏航 25° → 横向指令 %.1f°（提示回起飞航向）" % fd.deviation_deg().x)
	_check(fd.deviation_deg().y == 0.0,
		"⑦ 滑跑不干预俯仰（dev_v=0）")
	fd.free()


## ⑧ 指令文字：行动作词而不是模式名（儿童向可读性）。
func _check_label() -> void:
	var fd := FlightDirector.new()
	var target := Vector3.ZERO
	var d := 300.0
	var gs := d * tan(deg_to_rad(3.0))
	var fi := FlightInstruments.new()
	# 对准（在 3° 下滑道上、机头正对目标）→「对准」。
	var p := Vector3(0.0, gs, d)
	_settle(fi, _reading(p, 90.0, gs, -2.0), _basis(0.0), target)
	fd.set_guide(target)
	fd.refresh(p, fi)
	_check(fd.label_text() == "对准", "⑧ 对准 → 标签「对准」（实得 %s）" % fd.label_text())
	# 机头左偏 20° → 十字在右，指令「右转」。
	_settle(fi, _reading(p, 90.0, gs, -2.0), _basis(-20.0), target)
	fd.refresh(p, fi)
	_check(fd.label_text() == "右转",
		"⑧ 机头左偏 → 标签「右转」（实得 %s，dev_h=%.0f）"
			% [fd.label_text(), fd.deviation_deg().x])
	# 偏 170° → 「掉头」（左右转都说不上）。
	_settle(fi, _reading(p, 90.0, gs, -2.0), _basis(170.0), target)
	fd.refresh(p, fi)
	_check(fd.label_text() == "掉头",
		"⑧ 目标在正后方 → 标签「掉头」（实得 %s）" % fd.label_text())
	# 高于下滑道很多（垂直饱和）+ 对准 → 「低头」。
	var hi := Vector3(0.0, gs + 120.0, d)
	_settle(fi, _reading(hi, 90.0, gs + 100.0, -6.0), _basis(0.0), target)
	fd.refresh(hi, fi)
	_check(fd.label_text() == "低头",
		"⑧ 远高于下滑道 → 标签「低头」（实得 %s，dev_v=%.1f）"
			% [fd.label_text(), fd.deviation_deg().y])
	fd.free()


## ⑨ 不出屏 + 不压底部仪表板（含标签）。
func _check_bounds() -> void:
	for vp in VIEWPORTS:
		var s := CockpitInstruments.ui_scale(vp)
		var c: Vector2 = vp * 0.5
		var worst: Vector2 = FlightDirector.cross_offset(180.0, 180.0, s)  # 双向满偏
		var p: Vector2 = c + worst
		var top: float = p.y - (FlightDirector.ARM + 8.0) * s
		var bot: float = p.y + (FlightDirector.ARM + 8.0) * s
		var lbl: float = p.y + FlightDirector.LABEL_DY * s - 14.0 * s
		_check(top >= 0.0 and bot <= vp.y,
			"⑨ %s 满偏十字在屏内（y %.0f..%.0f）" % [_tag(vp), top, bot])
		_check(lbl >= 0.0, "⑨ %s 标签不出上沿（y %.0f）" % [_tag(vp), lbl])
		# 仪表板顶沿（D-053 后 dash 占屏高 25.2%，取 30% 留余量）。
		var dash_top: float = vp.y * 0.70
		_check(bot <= dash_top,
			"⑨ %s 十字底 %.0f 不压仪表板顶 %.0f" % [_tag(vp), bot, dash_top])
		var lbl_bot: float = p.y + FlightDirector.LABEL_DY * s + 4.0 * s
		_check(lbl_bot <= dash_top,
			"⑨ %s 标签底 %.0f 不压仪表板顶 %.0f" % [_tag(vp), lbl_bot, dash_top])


# ── 工具 ────────────────────────────────────────────────────────
func _tag(vp: Vector2) -> String:
	return "%dx%d" % [int(vp.x), int(vp.y)]


func _basis(yaw_deg: float) -> Basis:
	return Basis.IDENTITY.rotated(Vector3.UP, deg_to_rad(yaw_deg))


func _reading(pos: Vector3, kmh: float, agl: float, vs: float) -> Dictionary:
	return {
		"position": pos, "kmh": kmh, "altitude": pos.y, "altitude_agl": agl,
		"vertical_speed": vs, "stall_speed": 12.0, "engine": true,
		"throttle": 1.0, "fuel_pct": 1.0, "gear_down": true,
	}


## FlightInstruments 的垂直速度是平滑量（VSI_TAU），单帧 update 收敛不到位，
## 连跑多帧让它稳定到目标值——探针比的是稳态，不是瞬态。
func _settle(fi: FlightInstruments, reading: Dictionary, basis: Basis,
		target: Vector3) -> void:
	fi.set_navigation(target, "机场")
	for _i in range(40):
		fi.update(reading, basis, 0.1)


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("PASS  " + msg)
	else:
		_failed += 1
		print("FAIL  " + msg)


func _finish() -> void:
	print("RESULT flight_director_probe: FAIL=%d" % _failed)
	get_tree().quit(0 if _failed == 0 else 1)
