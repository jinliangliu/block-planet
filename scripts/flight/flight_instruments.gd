class_name FlightInstruments
extends RefCounted
## 飞行仪表数据层（D-034）：把 Aircraft.snapshot() 的原始读数加工成 12 项
## 飞行仪表的显示值与警告。纯逻辑、不持有节点，座舱 3D 面板、屏幕 HUD 与
## 无头探针共用同一份数字——避免三处各算一套、互相对不上。
##
## 覆盖的 12 项仪表：
##   空速表 / 姿态仪 / 高度表 / 转弯协调仪 / 航向指示器 / 垂直速度表 /
##   HSI / CDI / 雷达高度表 / 发动机参数（RPM）/ 燃油表 / 襟翼起落架指示灯
##
## 用法：每帧 update(reading, craft_basis, delta)，之后直接读公开字段；
## alerts() 取当前生效警告（灯光用，按优先级排序）；take_voice_cues(delta)
## 取「本次该响」的语音/蜂鸣提示（边沿触发 + 重播 cadence，只播最高级那条，
## 取一次即从内部队列清除）。reset_voice_cues() 在登机/下机时清空。
##
## 数值全部来自 gameplay-designer Phase A 报告（D-034），阈值/滞环/优先级
## 以此文件为唯一事实来源；节点层只喂原始读数（snapshot）。
##
## 角度约定（与 flight_view_probe / D-033 战术地图实证一致，勿再凭直觉改）：
##   +Z = 北（项目世界约定）；航向 = atan2(机头.x, 机头.z) 归一化到 0-360
##   （指北 0°、指东 +90°）；pitch 抬头为正；roll_deg 右转为正（全量程，
##   含倒飞——姿态仪球要能翻过来；坡度尺用同一值钳 ±90 显示）。
##
## 探针直接构造 Dictionary 读数即可驱动（不依赖真实飞机节点）。

## 警告严重级别：注意（黄）/ 警告（红）。视觉与蜂鸣码按级别分档。
enum AlertLevel { CAUTION, WARNING }

## 蜂鸣码表（Phase A §5）：程序生成音（无语音资产的儿童友好替代）。
## 字段：freq 基频 Hz / alt_freq 交替音高（可选，双音循环）/ dur 单声响时长 s /
## gap 声间隔 s / count 连响次数 / replay 重播间隔 s（0 = 触发时只响一次）。
## 全部落在 330–880 Hz、单条 ≤1.2 s，避免刺耳。
const BEEP_CODES := {
	# 失速注意：高频急鸣三声，每 1.2 s 重播。
	"stall": {"freq": 880.0, "dur": 0.12, "gap": 0.12, "count": 3, "replay": 1.2},
	# 失速：880/620 高低交替连续音，直到改出（1.2 s 片段按 1.2 s 重播 = 连续）。
	"stall_full": {"freq": 880.0, "alt_freq": 620.0, "dur": 0.15, "gap": 0.0, "count": 8, "replay": 1.2},
	# 超速：660/520 双音循环（2 s 片段按 2 s 重播 = 连续），直到解除。
	"overspeed": {"freq": 660.0, "alt_freq": 520.0, "dur": 0.125, "gap": 0.125, "count": 8, "replay": 2.0},
	# 低油：慢滴三连，每 2 s 一组。
	"low_fuel": {"freq": 440.0, "dur": 0.15, "gap": 0.12, "count": 3, "replay": 2.0},
	# 燃油耗尽：长低音一声，之后每 5 s 一短声提醒。
	"fuel_empty": {"freq": 330.0, "dur": 0.8, "gap": 0.0, "count": 1, "replay": 5.0},
	# 高度过低（注意）：中频两声，每 1 s 一组。
	"altitude_low": {"freq": 700.0, "dur": 0.1, "gap": 0.15, "count": 2, "replay": 1.0},
	# 高度过低（警告）：同音型，每 0.5 s 一组（更急）。
	"altitude_critical": {"freq": 700.0, "dur": 0.1, "gap": 0.15, "count": 2, "replay": 0.5},
	# 进近高度呼号（U-10）：中频两声，各层共用同一音色（层级信息由 Toast
	# 文字给，不靠音高编码——儿童不解析音高序列）。
	"alt_call": {"freq": 780.0, "dur": 0.09, "gap": 0.12, "count": 2, "replay": 0.0},
}

## 警告优先级（Phase A §5）：失速 = 超速 = 耗尽 > 过低 > 低油。
## 同刻多警只播最高级那条的声音，其余留灯光——防声音叠加成噪音。
const ALERT_PRIORITY := {
	"stall": 0, "stall_full": 0, "overspeed": 0, "fuel_empty": 0,
	"altitude_critical": 1, "altitude_low": 1, "low_fuel": 2,
}

## 低油警告阈值（燃油比例）：≤20% 触发、>25% 才清除（滞环防边界抖闪）。
const LOW_FUEL_RATIO := 0.2
const LOW_FUEL_CLEAR_RATIO := 0.25
## 燃油耗尽判定（升）：低于此值即判零（节点层油耗钳到 0，留一点裕量）。
const FUEL_EMPTY_L := 0.05
## 「高度过低」两级门限（Phase A §5）：注意 = AGL<15 且下沉率>2.5；
## 警告 = AGL<6 且下沉率>4；着地或 AGL>20 清除。刻意要求下沉率条件——
## 否则降落进近全程报警，儿童会学会忽略警报（警报疲劳比没警报更糟）。
const ALT_LOW_AGL := 15.0
const ALT_LOW_VS := -2.5
const ALT_CRIT_AGL := 6.0
const ALT_CRIT_VS := -4.0
const ALT_CLEAR_AGL := 20.0
## 判定「已离地」的离地高度下限（m）：机轮贴地时 AGL≈重心离地高，
## 留一倍余量避免地面误报。
const AIRBORNE_AGL := 2.0
## CDI 每「点」偏差对应的角度（度）：儿童向取 10°/点（真机 5°）。
const CDI_DEG_PER_DOT := 10.0
## 标准转弯率（度/秒）：转弯协调仪的「标准率」标记区间。
const STANDARD_RATE := 3.0
const STANDARD_RATE_TOL := 0.6
## 垂直速度表平滑时间常数（秒）：压住单帧噪声，指针不抖。
const VSI_TAU := 0.3
## 转速表量程上限（转/分）：与 Aircraft.RPM_MAX 一致（600 怠速 + 2100 量程）。
const RPM_DISPLAY_MAX := 2700.0
## 侧滑球满偏对应的侧滑角（度）：±10° 打满。
const SLIP_BALL_FULL_DEG := 10.0

## ── 进近高度呼号（U-10） ─────────────────────────────────────
## 下沉穿越这些 AGL 层（米）时呼号。借鉴 Infinite Flight 的 50/40/30/20 英尺
## 档，按本世界尺度折算：跑道 56 m、进近段通常几百米内，英尺档太疏——取
## 30/20/10/5 米四档，落地前最后一呼距地 5 m。
const ALTO_CALLOUTS := [30.0, 20.0, 10.0, 5.0]
## 呼号只在明确下沉时触发（m/s）：爬升/平飞穿越同层不呼，防「每过一层
## 响一次」的骚扰；阈值比 VSI 噪声大一个量级。
const CALL_DESCENT_VS := -0.5

# ── 仪表读数（update 后有效）────────────────────────────────
var airspeed_kmh := 0.0
var stall_speed_kmh := 0.0
## 指示空速与失速速度的余量（km/h）：负值即已进入失速边缘内。
var airspeed_margin_kmh := 0.0
var altitude_msl := 0.0
var altitude_agl := 0.0
## 垂直速度（m/s，正 = 爬升；平滑值，垂直速度表与过低警告共用）。
var vertical_speed := 0.0
## 航向（度，0-360，+Z = 北）。
var heading_deg := 0.0
var pitch_deg := 0.0
## 滚转（度，右转为正，全量程含倒飞——姿态仪球用）。
var roll_deg := 0.0
## 转弯率（度/秒，正 = 右转）与标准率标记。
var turn_rate_deg_s := 0.0
var standard_rate := false
## 侧滑球位置（-1..1，右滑为正）：snapshot 带 sideslip_deg 时用实测值，
## 否则按载荷因子与坡度反推的近似值（仅供儿童向显示）。
var slip_ball := 0.0
var g_load := 1.0
## 襟翼档位（0/1/2）与起落架（固定式：恒放下锁定，绿色）。
var flaps := 0
var gear_down := true
## 发动机与燃油。
var engine_on := false
## 油门（0..1，飞行员指令值——四角 HUD 油门条用；snapshot 的 "throttle"）。
var throttle := 0.0
## 转速（转/分，绝对量 0–2700）与百分比（0..1，大数字读数用）。
var rpm := 0.0
var rpm_pct := 0.0
var fuel_liters := 0.0
var fuel_capacity := 0.0
var fuel_ratio := 0.0
var fuel_low := false
var fuel_empty := false
## 失速/超速原始状态（来自 snapshot，与 HUD 旧读数同源）。
var stalled := false
var stall_warning := false
var overspeed := false
## 高度过低级别（0=无 / 1=注意 / 2=警告）：_refresh_alerts 维护。
var alt_warn := 0

# ── 导航（HSI/CDI）────────────────────────────────────────
## set_navigation(target) 后生效：HSI 显示目标方位角，CDI 显示直飞偏差。
var nav_active := false
var nav_name := ""
var nav_bearing_deg := 0.0
## CDI 偏差角（度，wrap 到 ±180）：正 = 目标在右侧。
var nav_dev_deg := 0.0
## CDI 点数化偏差（-1..1，每点 CDI_DEG_PER_DOT 度）。
var nav_dots := 0.0
var nav_distance_m := 0.0
var nav_to_flag := true

var _vsi_raw := 0.0
var _heading_prev := 0.0
var _has_heading_prev := false
var _fuel_low_latched := false
var _cue_ids := {}
var _cue_timers := {}
var _nav_target := Vector3.ZERO
## 进近高度呼号（U-10）：上帧 AGL（穿越边沿检测）、本次飞行已呼过的层
## （一次性，防同层重复）、待取走的层（take_altitude_callouts 消费）。
var _prev_agl := 0.0
var _callouts_done := {}
var _callouts_pending: Array[float] = []


## 设置直飞导航目标（任务航点 / 机场）。传空即清除。
func set_navigation(target: Vector3, name: String = "") -> void:
	nav_active = true
	nav_name = name
	_nav_target = target


func clear_navigation() -> void:
	nav_active = false
	nav_name = ""


## 每帧更新。reading 为 Aircraft.snapshot() 的输出（探针可手搓同名字典）；
## craft_basis 为机体全局基；delta 为帧步长（秒）。
func update(reading: Dictionary, craft_basis: Basis, delta: float) -> void:
	# ── 空速 / 高度 ──
	airspeed_kmh = float(reading.get("kmh", 0.0))
	stall_speed_kmh = float(reading.get("stall_speed", 0.0)) * AircraftFlight.MPS_TO_KMH
	airspeed_margin_kmh = airspeed_kmh - stall_speed_kmh
	altitude_msl = float(reading.get("altitude", 0.0))
	altitude_agl = float(reading.get("altitude_agl", 0.0))
	g_load = float(reading.get("load_factor", 1.0))
	stalled = bool(reading.get("stalled", false))
	stall_warning = bool(reading.get("stall_warning", false))
	overspeed = bool(reading.get("overspeed", false))
	# ── 姿态（全量程滚转：atan2 版能显示倒飞，供姿态仪球） ──
	var fwd: Vector3 = -craft_basis.z
	var right: Vector3 = craft_basis.x
	var up: Vector3 = craft_basis.y
	pitch_deg = rad_to_deg(asin(clampf(fwd.y, -1.0, 1.0)))
	roll_deg = rad_to_deg(atan2(-right.y, up.y))
	heading_deg = _normalize_deg(rad_to_deg(atan2(fwd.x, fwd.z)))
	# ── 垂直速度（平滑）：优先 snapshot 的 velocity.y（权威），
	# 探针手搓读数不带时退回海拔差分。 ──
	var vs_raw: float = float(reading.get("vertical_speed", NAN))
	if is_nan(vs_raw):
		vs_raw = (altitude_msl - _vsi_raw) / delta if delta > 0.0 else 0.0
	_vsi_raw = altitude_msl
	var k := 1.0 - exp(-delta / VSI_TAU) if delta > 0.0 else 1.0
	vertical_speed = lerpf(vertical_speed, vs_raw, clampf(k, 0.0, 1.0))
	# ── 转弯率（航向变化率，平滑）与标准率 ──
	if _has_heading_prev and delta > 0.0:
		var d_head := wrapf(heading_deg - _heading_prev, -180.0, 180.0)
		var rate := d_head / delta
		turn_rate_deg_s = lerpf(turn_rate_deg_s, rate, clampf(k * 2.0, 0.0, 1.0))
	_heading_prev = heading_deg
	_has_heading_prev = true
	standard_rate = absf(turn_rate_deg_s - STANDARD_RATE) <= STANDARD_RATE_TOL
	# ── 侧滑球：实测 sideslip_deg（snapshot）优先，±10° 满偏；
	# 无该键时按「协调转弯载荷因子 = 1/cos(坡度)」反推近似值。 ──
	var slip_deg: float = float(reading.get("sideslip_deg", NAN))
	if is_nan(slip_deg):
		var cos_roll := maxf(cos(deg_to_rad(roll_deg)), 0.05)
		slip_ball = clampf((g_load * cos_roll - 1.0) * 4.0, -1.0, 1.0)
	else:
		slip_ball = clampf(slip_deg / SLIP_BALL_FULL_DEG, -1.0, 1.0)
	# ── 襟翼 / 起落架 / 发动机 / 燃油 / 转速 ──
	flaps = clampi(int(reading.get("flaps", 0)), 0, 2)
	gear_down = bool(reading.get("gear_down", true))
	engine_on = bool(reading.get("engine", false))
	throttle = clampf(float(reading.get("throttle", 0.0)), 0.0, 1.0)
	# rpm 为绝对转速（转/分，0–2700）；rpm_pct 为 0..1 大数字百分比。
	# 兼容只给 ration 的旧读数：缺失时按量程折算。
	rpm = float(reading.get("rpm", 0.0))
	rpm_pct = clampf(float(reading.get("rpm_pct", rpm / RPM_DISPLAY_MAX)), 0.0, 1.0)
	fuel_liters = float(reading.get("fuel_liters", 0.0))
	fuel_capacity = float(reading.get("fuel_capacity", 0.0))
	fuel_ratio = clampf(float(reading.get("fuel_pct", reading.get("fuel_ratio", 1.0))), 0.0, 1.0)
	# ── 导航（HSI/CDI）──
	if nav_active:
		var to_target: Vector3 = _nav_target - _craft_position(reading)
		to_target.y = 0.0
		nav_distance_m = to_target.length()
		nav_bearing_deg = _normalize_deg(rad_to_deg(atan2(to_target.x, to_target.z)))
		nav_dev_deg = wrapf(nav_bearing_deg - heading_deg, -180.0, 180.0)
		nav_dots = clampf(nav_dev_deg / CDI_DEG_PER_DOT, -1.0, 1.0)
		nav_to_flag = true  # MVP 直飞导航恒为 TO
	_update_altitude_callouts()
	_refresh_alerts()


## 进近高度呼号边沿检测（U-10）：已离地且明确下沉时，AGL 从上往下穿过
## ALTO_CALLOUTS 某一层即登记一次（同层本次飞行只呼一次）。着地即清空
## 「已呼」集合——下次起飞重新可呼。爬升/平飞穿越不检测。
func _update_altitude_callouts() -> void:
	if is_airborne():
		if vertical_speed < CALL_DESCENT_VS:
			for h in ALTO_CALLOUTS:
				if _prev_agl >= h and altitude_agl < h and not _callouts_done.has(h):
					_callouts_done[h] = true
					_callouts_pending.append(h)
	else:
		_callouts_done.clear()
	_prev_agl = altitude_agl


## 机体世界坐标：snapshot 不带位置（姿态在 basis 里），由调用方经 reading
## 传入（探针与真实飞机都带 "position" 键）。
func _craft_position(reading: Dictionary) -> Vector3:
	var p: Variant = reading.get("position", Vector3.ZERO)
	return p if p is Vector3 else Vector3.ZERO


func _normalize_deg(deg: float) -> float:
	return fposmod(deg, 360.0)


## 是否已离地（高度警告的地面屏蔽用）。
func is_airborne() -> bool:
	return altitude_agl > AIRBORNE_AGL


## 警告状态机（Phase A §5）：低油滞环、燃油耗尽判零、过低两级 + 清除条件。
## 纯读数推导，无时间依赖——update 每帧调，探针可直接构造读数断言。
func _refresh_alerts() -> void:
	# 低油：≤20% 触发、>25% 才清除（滞环防边界抖闪）。
	if not _fuel_low_latched:
		if fuel_ratio <= LOW_FUEL_RATIO:
			_fuel_low_latched = true
	elif fuel_ratio > LOW_FUEL_CLEAR_RATIO:
		_fuel_low_latched = false
	fuel_low = _fuel_low_latched
	fuel_empty = fuel_capacity > 0.0 and fuel_liters <= FUEL_EMPTY_L
	# 过低：着地 / AGL>20 清除；否则按 AGL+下沉率两级判定。
	if not is_airborne() or altitude_agl > ALT_CLEAR_AGL:
		alt_warn = 0
	elif altitude_agl < ALT_CRIT_AGL and vertical_speed < ALT_CRIT_VS:
		alt_warn = 2
	elif altitude_agl < ALT_LOW_AGL and vertical_speed < ALT_LOW_VS:
		alt_warn = 1


## 当前生效的警告列表：按优先级排序（Phase A §5：失速=超速=耗尽 > 过低 >
## 低油，同级内警告在注意前），每项 {id, level, text, beep, replay}。
## level 取 AlertLevel 枚举值；beep 为 BEEP_CODES 条目（蜂鸣器直接播）。
func alerts() -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	if stalled:
		list.append(_alert("stall_full", AlertLevel.WARNING, "失速了！推杆低头"))
	elif stall_warning:
		list.append(_alert("stall", AlertLevel.CAUTION, "要失速了，推杆低头"))
	if overspeed:
		list.append(_alert("overspeed", AlertLevel.WARNING, "飞太快！收油减速"))
	if fuel_empty:
		list.append(_alert("fuel_empty", AlertLevel.WARNING, "没油了！滑翔降落"))
	elif fuel_low:
		list.append(_alert("low_fuel", AlertLevel.CAUTION, "油不多了，准备降落"))
	match alt_warn:
		2:
			list.append(_alert("altitude_critical", AlertLevel.WARNING, "快拉升！"))
		1:
			list.append(_alert("altitude_low", AlertLevel.CAUTION, "离地面太近！"))
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa: int = int(ALERT_PRIORITY.get(a["id"], 9))
		var pb: int = int(ALERT_PRIORITY.get(b["id"], 9))
		if pa != pb:
			return pa < pb
		return int(a["level"]) > int(b["level"]))
	return list


## 取「本次该响」的语音/蜂鸣提示：与 alerts() 同构的列表，取一次即消费。
## 规则（Phase A §5 优先级 + 重播 cadence）：
##   1. 只播最高优先级那条（list[0]）——其余警告留灯光，防声音叠加；
##   2. 新触发立即响；持续生效按 beep 的 replay 间隔重播（0 = 不重播）；
##   3. 高级清除后，次级警告补位响起（边沿触发不吞后续提示）。
func take_voice_cues(delta: float) -> Array[Dictionary]:
	var cues: Array[Dictionary] = []
	var list := alerts()
	var active := {}
	for a in list:
		active[a["id"]] = true
	if not list.is_empty():
		var top: Dictionary = list[0]
		var id := String(top["id"])
		var since := float(_cue_timers.get(id, 0.0))
		var replay := float(top.get("replay", 0.0))
		if not _cue_ids.has(id) or (replay > 0.0 and since >= replay):
			cues.append(top)
			_cue_timers[id] = 0.0
	for key in _cue_timers.keys():
		if active.has(key):
			_cue_timers[key] = float(_cue_timers[key]) + delta
		else:
			_cue_timers.erase(key)
	_cue_ids = active
	return cues


## 立刻清空语音去重状态（下机/重进座舱时调用，避免陈旧 id 吞掉下次提示）。
func reset_voice_cues() -> void:
	_cue_ids = {}
	_cue_timers = {}


## 取「本次该呼」的高度层（米）：与 take_voice_cues 平行的独立通道，取一次
## 即消费。刻意不并进 alerts() 的「同刻只播最高级」合并——降落末段若被
## 失速/超速警告挤掉，呼号就失去存在意义（警告防的是事故，呼号教的是节奏）。
func take_altitude_callouts() -> Array[float]:
	var out := _callouts_pending.duplicate()
	_callouts_pending.clear()
	return out


## 清空呼号状态（下机/重进座舱时与 reset_voice_cues 同步调用）。
func reset_altitude_callouts() -> void:
	_callouts_done.clear()
	_callouts_pending.clear()
	_prev_agl = 0.0


static func _alert(id: String, level: int, text: String) -> Dictionary:
	var beep: Dictionary = BEEP_CODES.get(
		id, {"freq": 600.0, "dur": 0.1, "gap": 0.1, "count": 1, "replay": 0.0})
	return {
		"id": id, "level": level, "text": text,
		"beep": beep, "replay": float(beep.get("replay", 0.0)),
	}
