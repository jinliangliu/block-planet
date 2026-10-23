class_name StallCoach
extends RefCounted
## 失速改出教学（U-8 / D-069）：纯逻辑状态机，与 TakeoffCoach 同范式——
## 不绘制任何界面，输入 Aircraft.snapshot() 同款字典，输出当前教案步
## {text, sub, color, flash, bar}；空字典 = 此刻不需要教案（hud.gd 见空字典
## 即隐藏教练区）。界面渲染全部在 hud.gd 飞行卡片教练区。
##
## 状态机：IDLE → ① 松杆低头 → ② 油门推满 → ③ 等速度恢复 → 成功 → IDLE。
## 触发 = stalled 或 stall_warning 上升沿（一扇门两把钥匙：接近失速就提前
## 教，儿童版；不设第三种入口、不加会话计数器）；每次失速完整教一遍
## （重复失速重置回①）；②③单步 15 s 无推进 / 着陆（AGL≤2 m）→ 回 IDLE
## 静默（危险已过，停止跟读；①是指令性步骤不设超时，着地才收）。
##
## 通道分工（D-069，与 U-6 合并终版）：蜂鸣 + SPD 盘红闪 + 空速行变红 =
## 告警层（非文字，全部既有零新增）；本教案（教练区四节点）= 失速唯一
## 权威文字通道，承接 D-046「永远可见」职责——hud.gd 卡片失速行随本类
## 上线删除；仪表 HUD 全宽横幅对失速类让位（banner_alerts()），只报其余
## 警告。熄火交圈：TakeoffCoach 的「按 F 点火」分支在失速时仍让位本教案
## （stall_coach_probe 锁回归），点火重启后的失速由本教案持续带。

const COL_WARN := Color(1.0, 0.42, 0.36)
const COL_KEY := Color(1.0, 0.88, 0.35)
const COL_GOOD := Color(0.45, 0.95, 0.55)

enum State { IDLE, STEP1_NOSE_DOWN, STEP2_POWER, STEP3_SPEED, SUCCESS }

## ②③单步无进展超时（秒）：超时回 IDLE 静默——危险解除后继续跟读没有意义。
## ①不设超时：指令性步骤，着地才收（防儿童慌乱期提示中途消失）。
const STEP_TIMEOUT_S := 15.0
## 成功停留（秒）：改出判据成立后保持成功文案这么久（正反馈）。
const SUCCESS_HOLD_S := 2.5
## ①→② 推进判据：机身俯角（pitch_deg，抬头为正，snapshot 直接读度）。
const NOSE_DOWN_PITCH := -3.0
## ①→② 俯角维持时长（秒）：防止穿越 −3° 时抖动静翻步。
const STEP2_HOLD_S := 0.3
## ③→成功判据：失速余量（km/h）——≈2.8 m/s 余量，温和不易二次失速。
const SPEED_RECOVERED_KMH := 10.0
## 着陆判据 AGL（m）：低于此值教案整体退出（地面失速物理上不可能，
## GROUND_PITCH_MAX 12° < 警告迎角 15.5°；本闸是兜底）。
const LOW_AGL := 2.0

var _state: int = State.IDLE
## 单步计时（推进即清零）与①步俯角维持计时、②步 margin 维持计时。
var _step_time := 0.0
var _nose_hold := 0.0
var _margin_hold := 0.0
## 成功保持计时。
var _success_hold := 0.0
## 边沿触发用：上帧的失速告警态 / 完全失速态。
var _was_warning := false
var _was_stalled := false
## 呼吸闪烁计时（HUD 渲染用，与 TakeoffCoach.elapsed() 同语义）。
var _elapsed := 0.0
## 可选绑定（登机时由 HUD 设置；step_for 不依赖它，探针可直接喂字典）。
var _craft: Aircraft = null


## 登机时调用：绑定飞机并整体重置（每次登机从干净态开始；教案只在一段
## 飞行内推进，不跨登机——再次失速仍从①完整教）。
func bind(craft: Aircraft) -> void:
	_craft = craft
	reset()


## 下机时调用：解绑并整体重置（下次登机从干净态开始）。
func unbind() -> void:
	_craft = null
	reset()


## 整体重置（探针 / 下机复用）。
func reset() -> void:
	_state = State.IDLE
	_step_time = 0.0
	_nose_hold = 0.0
	_margin_hold = 0.0
	_success_hold = 0.0
	_was_warning = false
	_was_stalled = false
	_elapsed = 0.0


## 内部计时（s）：HUD 用它算「要按键」步骤的呼吸闪烁透明度。
func elapsed() -> float:
	return _elapsed


## 每帧由 HUD 的 _refresh_flight_panel 调用：推进内部状态机并返回当前步。
## 返回 {text, sub, color, flash, bar}；空字典 = 此刻不需要教案。
func step_for(snap: Dictionary, delta: float) -> Dictionary:
	_elapsed += delta
	_step_time += delta
	var sv := _snap_vals(snap)
	var warning: bool = sv["stalled"] or sv["stall_warning"]
	var stalled_edge: bool = sv["stalled"] and not _was_stalled
	var warning_edge: bool = warning and not _was_warning
	_was_stalled = sv["stalled"]
	_was_warning = warning
	var margin := _margin_kmh(sv)
	var airborne: bool = sv["altitude_agl"] > LOW_AGL

	match _state:
		State.IDLE:
			# R1：失速告警上升沿 + 确已离地 → 从①开始教。
			if warning_edge and airborne:
				_enter(State.STEP1_NOSE_DOWN)
		State.STEP1_NOSE_DOWN:
			# R9：完全失速上升沿 → 回①重头教（含成功保持中被再次吓到）。
			if stalled_edge:
				_enter(State.STEP1_NOSE_DOWN)
			elif not airborne:
				_enter(State.IDLE)  # R7：着陆 → 静默（①不设超时）
			elif sv["pitch"] <= NOSE_DOWN_PITCH:
				# R2：俯角达标并维持 → ②。
				_nose_hold += delta
				if _nose_hold >= STEP2_HOLD_S:
					_enter(State.STEP2_POWER)
			else:
				_nose_hold = 0.0
		State.STEP2_POWER:
			if stalled_edge:
				_enter(State.STEP1_NOSE_DOWN)
			elif not airborne:
				_enter(State.IDLE)
			elif margin >= 0.0:
				# R3：margin≥0 持续 0.3 s 才推进（同 R2 去抖——速度贴线抖动时
				# ②③文案不互换）。教学提示与完成判据分离：②只「教」加油门，
				# 不「考」它——俯冲改出但没推油门的儿童不卡步（D-069 裁定）。
				_margin_hold += delta
				if _margin_hold >= STEP2_HOLD_S:
					_enter(State.STEP3_SPEED)
			else:
				_margin_hold = 0.0
				if _step_time >= STEP_TIMEOUT_S:
					_enter(State.IDLE)  # R6（仅②③）
		State.STEP3_SPEED:
			if stalled_edge:
				_enter(State.STEP1_NOSE_DOWN)
			elif not airborne:
				_enter(State.IDLE)
			elif margin >= SPEED_RECOVERED_KMH:
				_enter(State.SUCCESS)  # R4
			elif _step_time >= STEP_TIMEOUT_S:
				_enter(State.IDLE)
		State.SUCCESS:
			if stalled_edge:
				_enter(State.STEP1_NOSE_DOWN)
			elif not airborne:
				_enter(State.IDLE)  # R8：着陆即收
			else:
				_success_hold += delta
				if _success_hold >= SUCCESS_HOLD_S:
					_enter(State.IDLE)  # R5
	return _step_of(sv)


## 当前教案步的文案。IDLE 返回空字典（HUD 隐藏教练区）。
## ①按严重度自适应：完全失速 = 红闪「失速了！」；仅接近失速 = 黄闪
## 「要失速了！」——同一动作（低头）两种语气，不把警告夸大成事故。
func _step_of(sv: Dictionary) -> Dictionary:
	match _state:
		State.STEP1_NOSE_DOWN:
			if sv["stalled"]:
				return {
					"text": "失速了！按【↓】低头",
					"sub": "机头缓缓压低，别猛推",
					"color": COL_WARN, "flash": true, "bar": "",
				}
			return {
				"text": "要失速了！轻点【↓】低头",
				"sub": "轻轻压一点就好",
				"color": COL_KEY, "flash": true, "bar": "",
			}
		State.STEP2_POWER:
			# 熄火交圈（D-069）：熄火导致的失速也走本教案——②先教点火再教油门，
			# 与起飞教练的「按 F」分支同文案形状；点火后②自动回到推油门措辞。
			if not sv["engine"]:
				return {
					"text": "② 先按【F】点火，再推油门",
					"sub": "不点火，油门推不动",
					"color": COL_KEY, "flash": false, "bar": "",
				}
			return {
				"text": "② 油门推满！按【W】",
				"sub": "等速度回来，保持低头",
				"color": COL_KEY, "flash": false,
				"bar": _throttle_bar(sv["throttle"]),
			}
		State.STEP3_SPEED:
			return {
				"text": "③ 保持低头，等速度恢复",
				"sub": "别急着拉杆",
				"color": COL_KEY, "flash": false,
				"bar": _speed_bar(_margin_kmh(sv)),
			}
		State.SUCCESS:
			return {
				"text": "改出成功！",
				"sub": "继续保持平稳飞行",
				"color": COL_GOOD, "flash": false, "bar": "",
			}
	return {}


func _enter(next: int) -> void:
	_state = next
	_step_time = 0.0
	_nose_hold = 0.0
	_margin_hold = 0.0
	_success_hold = 0.0


## snapshot 读取（键名与 Aircraft.snapshot() / AircraftFlight.snapshot() 对齐：
## 姿态角字段是 pitch_deg（度，抬头为正），不是 pitch）。
func _snap_vals(snap: Dictionary) -> Dictionary:
	return {
		"stalled": bool(snap.get("stalled", false)),
		"stall_warning": bool(snap.get("stall_warning", false)),
		"airspeed": float(snap.get("airspeed", 0.0)),
		"stall_speed": float(snap.get("stall_speed", 0.0)),
		"pitch": float(snap.get("pitch_deg", 0.0)),
		"throttle": float(snap.get("throttle", 0.0)),
		"altitude_agl": float(snap.get("altitude_agl", 0.0)),
		"engine": bool(snap.get("engine", false)),
	}


## 失速余量（km/h）：与 FlightInstruments.airspeed_margin_kmh 同源同式。
func _margin_kmh(sv: Dictionary) -> float:
	return (float(sv["airspeed"]) - float(sv["stall_speed"])) * AircraftFlight.MPS_TO_KMH


## 油门进度条：10 格，与飞行面板油门条同一套字形（█/░）。
func _throttle_bar(throttle: float) -> String:
	var filled := clampi(int(round(clampf(throttle, 0.0, 1.0) * 10.0)), 0, 10)
	return "█".repeat(filled) + "░".repeat(10 - filled)


## 速度进度条：20 格，margin 0→10 km/h 映射满格（负余量恒空）。
func _speed_bar(margin: float) -> String:
	var filled := clampi(int(margin / 0.5), 0, 20)
	return "█".repeat(filled) + "░".repeat(20 - filled)
