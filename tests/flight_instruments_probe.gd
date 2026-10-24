extends Node
## 飞行仪表系统数值契约探针（D-034）：纯逻辑无头断言，验证 gameplay-designer
## Phase A 报告的全部数值约定，作为唯一事实来源的反向守护。覆盖：
##   ① 襟翼三档失速速度（13.1 / 11.7 / 10.7 m/s）
##   ② 燃油容量 55 L + 油耗 0.10 L/s（聚合 + 常量双重锁）
##   ③ 低油滞环（≤20% 触发 / >25% 清除）+ 燃油耗尽判零
##   ④ RPM 映射 600–2700 + 百分比 + 节点 _rpm()
##   ⑤ VFE 30 m/s 软门限（超速放襟翼被拒，收襟翼不限）
##   ⑥ 滚轮油门 ±5% 钳 0..1 + 熄火无效
##   ⑦ 自动改平 2.0 s
##   ⑧ 六类告警阈值 + 两级 + 优先级排序
##   ⑨ 语音/蜂鸣提示边沿触发 + 重播 cadence 去重
##   ⑩ 姿态（pitch/roll 符号）+ 航向（+Z 北 / +X 东）实证
##   ⑪ HSI/CDI 直飞导航（bearing / dev / dots / distance）
##   ⑫ HUD 默认简单模式 + 蜂鸣默认开 + 标准难度辅助半开
##   ⑬ U-5 详细清单纯函数：7 行增量 + 去重闸 + CDI 空态（契约 = panel_row_texts）
##   ⑭ U-6 横幅排除：失速类走 banner_alerts() 让位，alerts()/蜂鸣零变化
##
## 纯逻辑（不建场景、不渲染），可直接 headless 跑：
## Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/flight_instruments_probe.tscn

var _failed := 0
## 机体基：多数断言不依赖姿态，用单位阵占位。
const _ID := Basis.IDENTITY


func _ready() -> void:
	await _run()


func _run() -> void:
	FlightSettings.set_current(FlightSettings.for_difficulty(FlightSettings.Difficulty.NORMAL))
	_run_flap_stall_checks()
	_run_fuel_checks()
	_run_rpm_checks()
	_run_flap_vfe_checks()
	_run_scroll_throttle_checks()
	_run_auto_level_checks()
	_run_alert_checks()
	_run_voice_cue_checks()
	_run_attitude_checks()
	_run_nav_checks()
	_run_hud_default_checks()
	_run_panel_row_checks()
	_run_banner_exclusion_checks()
	_finish()


## ① 襟翼三档失速速度：失速速度 = √(2mg / ρS·CLmax·flap_cl_factor)，
## 倍率 1.0 / 1.25 / 1.5 直接开方生效 → 13.1 / 11.7 / 10.7 m/s。
func _run_flap_stall_checks() -> void:
	var af := AircraftFlight.default_airframe()
	var vs0 := AircraftFlight.stall_speed(AircraftFlight.SEA_LEVEL_DENSITY, af, 0)
	var vs1 := AircraftFlight.stall_speed(AircraftFlight.SEA_LEVEL_DENSITY, af, 1)
	var vs2 := AircraftFlight.stall_speed(AircraftFlight.SEA_LEVEL_DENSITY, af, 2)
	_check(absf(vs0 - 13.1) < 0.3, "① 0 档失速速度钉死 13.1 m/s（实际 %.2f）" % vs0)
	_check(absf(vs1 - 11.7) < 0.2, "① 1 档（起飞）失速 ≈11.7 m/s（实际 %.2f）" % vs1)
	_check(absf(vs2 - 10.7) < 0.2, "① 2 档（着陆）失速 ≈10.7 m/s（实际 %.2f）" % vs2)
	_check(vs1 < vs0 and vs2 < vs1, "① 放襟翼失速速度严格递减")


## ②+③ 燃油：容量与油耗取自聚合气动框（默认套件 1 油箱 = 55 L / 0.10 L/s），
## 常量与聚合结果双重锁定（Phase A §1.3）；低油滞环（≤20% 触发 / >25% 清除）
## + 燃油耗尽判零（容量 >0 且油量 ≤0.05 L）。
func _run_fuel_checks() -> void:
	var parts := PartRegistry.default_loadout()
	var agg := AircraftFlight.Airframe.aggregate(parts)
	_check(absf(agg.fuel_capacity - 55.0) < 0.01,
		"② 默认套件燃油容量 = 55 L（聚合 %.1f）" % agg.fuel_capacity)
	_check(absf(agg.fuel_burn - 0.10) < 0.001,
		"② 默认套件满油门油耗 = 0.10 L/s（聚合 %.3f）" % agg.fuel_burn)
	_check(AircraftFlight.FUEL_CAPACITY_DEFAULT == 55.0, "② 常量 FUEL_CAPACITY_DEFAULT = 55")
	_check(AircraftFlight.FUEL_BURN_DEFAULT == 0.10, "② 常量 FUEL_BURN_DEFAULT = 0.10")
	var fi := FlightInstruments.new()
	# 触发：15% ≤ 20%。
	fi.update({"fuel_liters": 8.25, "fuel_capacity": 55.0, "fuel_ratio": 0.15}, _ID, 0.1)
	_check(fi.fuel_low, "③ 低油 15% 触发")
	# 滞环：22% 仍 ≤25%，不清。
	fi.update({"fuel_liters": 12.1, "fuel_capacity": 55.0, "fuel_ratio": 0.22}, _ID, 0.1)
	_check(fi.fuel_low, "③ 低油 22% 仍保持（滞环未清除）")
	# 清除：30% > 25%。
	fi.update({"fuel_liters": 16.5, "fuel_capacity": 55.0, "fuel_ratio": 0.30}, _ID, 0.1)
	_check(not fi.fuel_low, "③ 低油 30% 清除")
	# 耗尽：0.03 L ≤ 0.05 L 判零，低油灯同步亮。
	var fe := FlightInstruments.new()
	fe.update({"fuel_liters": 0.03, "fuel_capacity": 55.0, "fuel_ratio": 0.0005}, _ID, 0.1)
	_check(fe.fuel_empty, "③ 燃油 ≤0.05 L 判耗尽")
	_check(fe.fuel_low, "③ 耗尽同时点亮低油灯")


## ④ RPM 映射：怠速 600 / 满油门 2700，百分比 = rpm / 2700；
## 节点 _rpm() = 600 + 2100·平滑油门（运转且非耗尽）。
func _run_rpm_checks() -> void:
	_check(FlightInstruments.RPM_DISPLAY_MAX == 2700.0, "④ RPM 量程上限 2700")
	_check(Aircraft.RPM_IDLE == 600.0 and Aircraft.RPM_RANGE == 2100.0
		and Aircraft.RPM_MAX == 2700.0, "④ 节点 RPM 常量 600/2100/2700")
	var fi := FlightInstruments.new()
	fi.update({"rpm": 600.0}, _ID, 0.1)
	_check(absf(fi.rpm_pct - 600.0 / 2700.0) < 1e-6, "④ rpm 600 → pct 0.222")
	fi.update({"rpm": 2700.0}, _ID, 0.1)
	_check(absf(fi.rpm_pct - 1.0) < 1e-6, "④ rpm 2700 → pct 1.0")
	# 节点层：满油门平滑值 1 → 2700；怠速 0 → 600。
	var craft := Aircraft.new()
	craft.set_piloted(true)
	craft.set_engine(true)
	craft._rpm_value = 1.0
	_check(absf(craft._rpm() - 2700.0) < 1e-6, "④ 节点满油门 RPM = 2700")
	craft._rpm_value = 0.0
	_check(absf(craft._rpm() - 600.0) < 1e-6, "④ 节点怠速 RPM = 600")


## ⑤ VFE 软门限：空速 > 30 m/s 时收不到更高档襟翼（仅提示不硬拦）；
## 收襟翼不限速度（Phase A §1.4）。
func _run_flap_vfe_checks() -> void:
	_check(AircraftFlight.FLAP_VFE == 30.0, "⑤ VFE 软门限 = 30 m/s")
	var flc := Aircraft.new()
	flc._state.airspeed = 35.0  # > VFE
	flc.set_flaps(1)
	_check(flc.flaps_detent() == 0, "⑤ 超速（>30）放襟翼被拒（档位仍 0）")
	flc._state.airspeed = 10.0
	flc.set_flaps(1)
	_check(flc.flaps_detent() == 1, "⑤ 低速（10）放襟翼成功（1 档）")
	flc._state.airspeed = 35.0
	flc.set_flaps(0)  # 收襟翼不受速度限制
	_check(flc.flaps_detent() == 0, "⑤ 收襟翼不限速度")


## ⑥ 滚轮油门微调：步长 ±5%（±0.05），钳 0..1；熄火或无人驾驶忽略。
func _run_scroll_throttle_checks() -> void:
	var sc := Aircraft.new()
	sc.set_piloted(true)
	sc.set_engine(true)
	sc.controls.throttle = 0.5
	sc.adjust_throttle(0.05)
	_check(absf(sc.controls.throttle - 0.55) < 1e-6, "⑥ 滚轮 +5% 油门 0.50→0.55")
	sc.adjust_throttle(-0.05)
	_check(absf(sc.controls.throttle - 0.50) < 1e-6, "⑥ 滚轮 -5% 油门 0.55→0.50")
	sc.controls.throttle = 0.98
	sc.adjust_throttle(0.05)
	_check(absf(sc.controls.throttle - 1.0) < 1e-6, "⑥ 滚轮油门钳到 1.0")
	sc.controls.throttle = 0.02
	sc.adjust_throttle(-0.05)
	_check(absf(sc.controls.throttle - 0.0) < 1e-6, "⑥ 滚轮油门钳到 0.0")
	sc.set_engine(false)
	sc.controls.throttle = 0.5
	sc.adjust_throttle(0.05)
	_check(absf(sc.controls.throttle - 0.5) < 1e-6, "⑥ 熄火时滚轮油门无效")


## ⑦ 自动改平：双击左键后 LEVEL_ASSIST_TIME 秒增强增益摆平。
func _run_auto_level_checks() -> void:
	_check(Aircraft.LEVEL_ASSIST_TIME == 2.0, "⑦ LEVEL_ASSIST_TIME 常量 = 2.0 s")
	var al := Aircraft.new()
	al.set_piloted(true)
	al.request_level()
	_check(absf(al._level_timer - Aircraft.LEVEL_ASSIST_TIME) < 1e-6,
		"⑦ 双击改平设定计时器 = 2.0 s")


## ⑧ 六类告警：失速/超速/耗尽（优先级 0）> 过低（1）> 低油（2）；
## 过低两级（注意 AGL<15&VS<-2.5 / 警告 AGL<6&VS<-4）+ 清除条件。
## 注意 VSI 平滑（τ=0.3 s），需用 _feed 多帧收敛到目标下沉率。
func _feed(fi: FlightInstruments, reading: Dictionary, frames: int) -> void:
	for i in range(frames):
		fi.update(reading, _ID, 0.1)


func _run_alert_checks() -> void:
	# 失速（最高优先级）压过低油与过低。
	var a := FlightInstruments.new()
	_feed(a, {"stalled": true, "fuel_ratio": 0.1,
		"altitude_agl": 5.0, "vertical_speed": -5.0}, 25)
	var la := a.alerts()
	_check(la.size() >= 3, "⑧ 失速+过低+低油同时生效（%d 条）" % la.size())
	_check(la[0]["id"] == "stall_full", "⑧ 最高优先级为失速（压过低油/过低）")
	_check(a.alt_warn == 2, "⑧ AGL5/VS-5 过低 = 警告级")
	# 仅低油：单条 low_fuel（优先级 2，最低）。
	var b := FlightInstruments.new()
	_feed(b, {"fuel_ratio": 0.1}, 25)
	var lb := b.alerts()
	_check(lb.size() == 1 and lb[0]["id"] == "low_fuel", "⑧ 仅低油时单条 low_fuel")
	# 超速：top = overspeed（优先级 0）。
	var c := FlightInstruments.new()
	_feed(c, {"overspeed": true}, 25)
	_check(c.alerts()[0]["id"] == "overspeed", "⑧ 超速告警 top")
	# 无失速/超速时，过低（优先级 1）压过低油（优先级 2）。
	var d := FlightInstruments.new()
	_feed(d, {"fuel_ratio": 0.1, "altitude_agl": 5.0, "vertical_speed": -5.0}, 25)
	var ld := d.alerts()
	_check(ld[0]["id"] == "altitude_critical", "⑧ 无失速时过低警告优先于低油")
	# 过低注意级：AGL<15 & VS<-2.5 但不满足警告级（AGL 在 6~15）。
	var e := FlightInstruments.new()
	_feed(e, {"altitude_agl": 12.0, "vertical_speed": -3.0}, 25)
	_check(e.alt_warn == 1, "⑧ AGL12/VS-3 过低 = 注意级")
	# 离地清除：AGL 在 6 内但已着地（AGL≤2）不报。
	var f := FlightInstruments.new()
	_feed(f, {"altitude_agl": 1.0, "vertical_speed": -8.0}, 25)
	_check(f.alt_warn == 0, "⑧ 已离地净空不足（AGL1）不报过低")
	# 燃油耗尽（优先级 0）与失速同优先级，失速在前（插入序）。
	var g := FlightInstruments.new()
	_feed(g, {"fuel_liters": 0.0, "fuel_capacity": 55.0, "fuel_ratio": 0.0,
		"stalled": true}, 25)
	_check(g.fuel_empty, "⑧ 燃油耗尽置位")
	_check(g.alerts()[0]["id"] == "stall_full", "⑧ 失速与耗尽同优先级 0，失速在前")


## ⑨ 语音/蜂鸣提示：边沿触发播一次；持续按 replay cadence（1.2 s）重播；
## 无告警不播。模拟真实逐帧累计时间，验证早不重播、到点才重播。
func _run_voice_cue_checks() -> void:
	var v := FlightInstruments.new()
	v.update({"stalled": true}, _ID, 0.1)
	var first := v.take_voice_cues(0.1)  # 首帧：since=0 必播
	_check(first.size() == 1 and first[0]["id"] == "stall_full", "⑨ 首帧播失速提示（1 条）")
	var immediate := v.take_voice_cues(0.1)  # 间隔仅 0.1 s（< 1.2 s）
	_check(immediate.size() == 0, "⑨ 重播间隔内（0.1 s）不重复（0 条）")
	# 逐帧累计到 >1.2 s：replay cadence 到点应再次播报。
	var replayed := false
	for i in range(40):
		var c := v.take_voice_cues(0.05)  # 40 × 0.05 = 2.0 s 累计
		if c.size() == 1:
			replayed = true
			break
	_check(replayed, "⑨ 越过重播间隔（累计≈1.2 s）后再次播报")
	# 无告警：不播。
	var w := FlightInstruments.new()
	_check(w.take_voice_cues(0.1).size() == 0, "⑨ 无告警时不播")


## ⑩ 姿态与航向实证（与 D-033 战术地图 / 座舱布局同约定，勿凭直觉改）：
## +Z = 北、+X = 东；pitch 抬头为正；roll 右翼下沉为正。
func _run_attitude_checks() -> void:
	# 机头朝北（绕 Y 转 π）：航向 0°。
	var north := FlightInstruments.new()
	north.update({}, Basis.from_euler(Vector3(0.0, PI, 0.0)), 0.1)
	_check(absf(north.heading_deg) < 0.5, "⑩ 机头朝北航向 0°")
	# 机头朝东（绕 Y 转 -π/2）：航向 90°。
	var east := FlightInstruments.new()
	east.update({}, Basis.from_euler(Vector3(0.0, -PI / 2.0, 0.0)), 0.1)
	_check(absf(east.heading_deg - 90.0) < 1.0, "⑩ 机头朝东航向 90°")
	# 抬头（绕 X 正转）：pitch 正。
	var up := FlightInstruments.new()
	up.update({}, Basis.from_euler(Vector3(0.3, 0.0, 0.0)), 0.1)
	_check(up.pitch_deg > 10.0 and up.pitch_deg < 20.0,
		"⑩ 抬头 pitch 为正（约 %.1f°）" % up.pitch_deg)
	# 右滚（绕 Z 负转，右翼下沉）：roll 正。
	var right := FlightInstruments.new()
	right.update({}, Basis.from_euler(Vector3(0.0, 0.0, -0.4)), 0.1)
	_check(right.roll_deg > 15.0 and right.roll_deg < 30.0,
		"⑩ 右滚 roll 为正（约 %.1f°）" % right.roll_deg)


## ⑪ HSI/CDI 直飞导航：机在原点、目标正北 100 m；
## 航向正北时偏差 0；航向东时偏差 -90°（目标在左，dots 打满 -1）。
func _run_nav_checks() -> void:
	var n := FlightInstruments.new()
	n.set_navigation(Vector3(0.0, 0.0, 100.0), "机场")
	n.update({"position": Vector3.ZERO}, Basis.from_euler(Vector3(0.0, PI, 0.0)), 0.1)
	_check(n.nav_active, "⑪ 导航激活")
	_check(absf(n.nav_bearing_deg) < 1.0, "⑪ 目标正北 bearing 0°")
	_check(absf(n.nav_dev_deg) < 1.0, "⑪ 航向正北时偏差 0°")
	_check(absf(n.nav_distance_m - 100.0) < 0.5, "⑪ 直线距离 100 m")
	n.update({"position": Vector3.ZERO}, Basis.from_euler(Vector3(0.0, -PI / 2.0, 0.0)), 0.1)
	var dev := n.nav_dev_deg
	_check(absf(dev - (-90.0)) < 1.0 or absf(dev - 270.0) < 1.0,
		"⑪ 航向东时偏差 -90°（目标在左）")
	_check(absf(n.nav_dots - (-1.0)) < 0.01, "⑪ CDI 偏差打满 -1（左）")


## ⑫ HUD 默认简单模式 + 蜂鸣默认开 + 标准难度辅助半开（儿童优先，不晕）。
func _run_hud_default_checks() -> void:
	_check(FlightSettings.new().hud_detail == false,
		"⑫ HUD 默认简单模式（hud_detail=false）")
	_check(FlightSettings.from_dict({}).hud_detail == false,
		"⑫ 设置读档缺省 hud_detail=false")
	_check(FlightSettings.default_settings().beeper_enabled == true,
		"⑫ 警告蜂鸣码默认开")
	_check(FlightSettings.for_difficulty(FlightSettings.Difficulty.NORMAL).assist_level
		== FlightSettings.Assist.PARTIAL, "⑫ 标准难度辅助 = 半开")


## ⑬ U-5 详细清单纯函数（D-069）：契约本体 = FlightInstrumentHUD.panel_row_texts()
## （静态纯函数）。「按索引取行」的断言一律走它；节点层 _panel_rows 只上屏、
## 不构成契约。7 行 = 四角没有的增量读数；四角已有的（空速/航向/MSL/升降率/
## 燃油）不得复现——那正是 U-5 的去重闸。
func _run_panel_row_checks() -> void:
	var fi := FlightInstruments.new()
	fi.update({"kmh": 120.0, "stall_speed": 13.1, "altitude_agl": 300.0,
		"rpm": 2400.0, "flaps": 1, "gear_down": true}, _ID, 0.1)
	var rows: Array = FlightInstrumentHUD.panel_row_texts(fi)
	_check(rows.size() == 7, "⑬ 清单 7 行（实际 %d）" % rows.size())
	if rows.size() != 7:
		return  # 行数不对时后续索引断言必越界——SCRIPT ERROR 即污染，直接收尾
	_check(String(rows[0]).begins_with("失速余量："), "⑬ 行0 = 失速余量")
	_check(String(rows[1]).begins_with("姿态：俯仰"), "⑬ 行1 = 姿态")
	_check(String(rows[2]).begins_with("离地："), "⑬ 行2 = 离地")
	_check(String(rows[3]).begins_with("转弯率："), "⑬ 行3 = 转弯率")
	_check(String(rows[4]).begins_with("CDI："), "⑬ 行4 = 导航 CDI")
	_check(String(rows[5]).begins_with("转速："), "⑬ 行5 = 转速")
	_check(String(rows[6]).begins_with("襟翼："), "⑬ 行6 = 襟翼/起落架")
	# 去重闸：四角已有的读数不得在清单复现（合并全文检索）。
	var merged := ""
	for r in rows:
		merged += String(r)
	for banned in ["航向", "升降率", "燃油", "MSL", "空速"]:
		_check(not merged.contains(banned),
			"⑬ 去重闸：清单不含「%s」（四角已有）" % banned)
	# 无导航目标 → CDI 行显示占位符。
	_check(String(rows[4]) == "CDI：—", "⑬ 无导航目标时 CDI = —")
	# 失速余量数值：120 km/h − 13.1 m/s × 3.6 ≈ +72.8 km/h。
	_check(String(rows[0]).contains("+72") or String(rows[0]).contains("+73"),
		"⑬ 失速余量数值正确（%s）" % String(rows[0]))
	# U-5 后续项（D-069 目检）：地面滑速必低于失速速度，负余量是物理事实而非
	# 预警——常显「-37 km/h」会让儿童以为马上要掉下来，离地前分流为「—（地面）」。
	var gnd := FlightInstruments.new()
	gnd.update({"kmh": 10.0, "stall_speed": 13.1, "altitude_agl": 0.0},
		_ID, 0.1)
	var grows: Array = FlightInstrumentHUD.panel_row_texts(gnd)
	_check(String(grows[0]) == "失速余量：—（地面）",
		"⑬ 地面（AGL=0）失速余量 = 「—（地面）」而非负值（%s）" % String(grows[0]))
	_check(gnd.is_airborne() == false,
		"⑬ 地面口径 is_airborne() = false（与分流判据同源）")
	# 有导航目标 → CDI 行带 TO/FROM 旗。
	var nav := FlightInstruments.new()
	nav.set_navigation(Vector3(0.0, 0.0, 100.0), "机场")
	nav.update({"kmh": 120.0, "stall_speed": 13.1, "position": Vector3.ZERO},
		Basis.from_euler(Vector3(0.0, PI, 0.0)), 0.1)
	var nrows: Array = FlightInstrumentHUD.panel_row_texts(nav)
	_check(String(nrows[4]).contains("TO") or String(nrows[4]).contains("FROM"),
		"⑬ 有导航目标时 CDI 带 TO/FROM（%s）" % String(nrows[4]))


## ⑭ U-6 横幅排除（D-069）：失速类的权威文字通道是 hud.gd 卡片失速行
##（带【↓】/ U-8 状态机文案），全宽闪烁横幅对它们让位；蜂鸣路径
## （take_voice_cues / alerts()）零变化——⑧⑨ 段语义不变。
func _run_banner_exclusion_checks() -> void:
	_check(FlightInstruments.BANNER_EXCLUDED.has("stall_full")
		and FlightInstruments.BANNER_EXCLUDED.has("stall"),
		"⑭ 排除集含 stall / stall_full")
	# 纯失速 → 横幅空（卡片失速行 + 蜂鸣照常报）。
	var a := FlightInstruments.new()
	_feed(a, {"stalled": true}, 25)
	_check(a.banner_alerts().is_empty(), "⑭ 纯失速 → 横幅列表空")
	_check(a.alerts()[0]["id"] == "stall_full", "⑭ 纯失速时 alerts() 仍以失速居首（蜂鸣不受影响）")
	# 失速 + 低油 → 横幅改显低油（让位前会被失速霸占，次级警告不可见）。
	var b := FlightInstruments.new()
	_feed(b, {"stalled": true, "fuel_ratio": 0.1}, 25)
	var lb := b.banner_alerts()
	_check(lb.size() == 1 and lb[0]["id"] == "low_fuel",
		"⑭ 失速+低油 → 横幅显低油（次级警告不再被霸占）")
	# 仅超速 → 横幅原样显超速。
	var c := FlightInstruments.new()
	_feed(c, {"overspeed": true}, 25)
	var lc := c.banner_alerts()
	_check(lc.size() == 1 and lc[0]["id"] == "overspeed", "⑭ 仅超速 → 横幅显超速")
	# 接近失速（非完全失速）同样让位。
	var d := FlightInstruments.new()
	_feed(d, {"stall_warning": true}, 25)
	_check(d.banner_alerts().is_empty(), "⑭ 接近失速 → 横幅列表空")


func _finish() -> void:
	if _failed == 0:
		print("FLIGHT_INSTRUMENTS_PROBE_OK")
		get_tree().quit(0)
	else:
		print("FLIGHT_INSTRUMENTS_PROBE_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
