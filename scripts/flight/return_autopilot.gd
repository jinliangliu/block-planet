extends RefCounted
## 返航自动驾驶杆量生成器（D-098）：纯闭环逻辑，不触碰场景树、不改气动。
##
## 输入为 HSI 口径的航向偏差 nav_dev_deg（正 = 目标在右）、当前坡度 bank_rad
## （右转为正）、机体偏航角速度 yaw_rate（rad/s）、当前/目标高度、空速与到
## 目标的水平距离；输出 −1..1 杆量与 0..1 油门，直接覆写 AircraftFlight.Controls。
##
## 关键前提（aircraft_flight.gd:370）：controls.roll 是**滚转角速度指令的杆量**
## （经 ROLL_RATE_MAX 积分成角速度），不是坡度角、也不是航向角速度。故横向
## 用「目标坡度 ↔ 当前坡度」的 P 闭环 + 偏航率阻尼生成杆量，不能把 nav_dev
## 直接当坡度写回。
##
## 设计取舍：
##   · 目标坡度按 nav_dev 比例给出并限幅 MAX_BANK_RAD：大偏差（含 180° 掉头）
##     也只给温和的满坡度，避免杆量随偏差线性飙满后左右来回摆。
##   · ROLL_DAMP 借 yaw_rate 阻尼：已在朝目标方向转就别继续压杆，抑制绕圈
##     震荡与掉头过冲。
##   · yaw 只给极小同向协调量，转弯主要交给气动自带 TURN_COORDINATION_RATE
##     （坡度带出偏航），不与它打架。
##   · 纵向：高度误差经 PITCH_GAIN 配平并限幅；油门以巡航为基准，逼近 VNE
##     线性收油、逼近失速速度线性加油。
##   · arrived 只看水平距离：飞到机场附近即交还玩家做进近/落地，不做自动着陆。
##
## 本脚本刻意不声明全局类名（全工程红线），由 aircraft.gd / 探针以
## `preload(...).new()` 取无类型实例调用（坑 #33：该实例是 Variant，禁用 :=）。

# ── 硬边界与增益（全部可被引程断言）────────────────────────────
## 结构极限速度（m/s）：与 AircraftFlight.VNE 一致，越逼近越收油。
const VNE := 55.0
## 默认套件失速速度（m/s）：D-031 标定 ≈13.1，低于即加油改出。
const STALL_SPEED := 13.1
## 到机场的水平到达距离（m）：进此圈即解除、交还玩家。
const ARRIVE_DIST_M := 150.0
## 目标坡度上限（rad）：25°（= 25×π/180 ≈ 0.4363），温和，掉头也不压满杆。
const MAX_BANK_RAD := 0.436332313
## 航向偏差（度）→ 目标坡度（rad）比例：约 45° 偏差到满坡度。
const DEV_TO_BANK_GAIN := MAX_BANK_RAD / 45.0
## 坡度误差（rad）→ 滚转杆量的比例增益。
const ROLL_GAIN := 2.5
## 偏航角速度（rad/s）阻尼增益：抑制绕圈与掉头过冲。
const ROLL_DAMP := 0.35
## 高度误差（m）→ 俯仰杆量的比例增益。
const PITCH_GAIN := 0.012
## 俯仰杆量硬限幅：避免大高度差拉成陡爬升/俯冲。
const PITCH_CMD_MAX := 0.35
## 巡航油门：D-031 默认套件 35 m/s 平飞约半油门。
const THROTTLE_CRUISE := 0.6
## 进入收油/加油软区的速度比例（相对 VNE / STALL_SPEED）。
const VNE_SOFT_RATIO := 0.9
const STALL_SOFT_RATIO := 1.2
## 方向舵协调量相对滚转杆量的比例：极小，不与 TURN_COORDINATION_RATE 打架。
const YAW_COORD_GAIN := 0.06
## 巡航目标高度（m，机场锚点之上）：飞回途中保持的安全巡航层。
const CRUISE_ALT_M := 40.0
## 手动接管杆量阈值：任一 |杆量| 超过即让位（探针断言边界）。
const TAKEOVER_STICK := 0.12
## 掉头方向锁定（D-098 引擎实测后补）：|nav_dev| 超过该值即锁定初始转向方向，
## 之后只用 abs(dev) 配锁定方向算目标坡度。wrapf 在 ±180° 处会把 +170 翻成
## −173，若不做锁定，目标坡度会在 ±25° 间瞬间反转，飞机左右摇摆、净航向几乎
## 不变（2026-11-16 引擎实测：自动驾驶组仅比对照组多转 1.13°）。
const TURN_LATCH_DEG := 150.0
## 偏差收敛到该角度以下才解锁，交回常规比例控制（必须 < TURN_LATCH_DEG）。
const TURN_RELEASE_DEG := 110.0


## 一帧闭环杆量。_delta 为物理帧步长（秒）：本控制器是无状态比例闭环，输出为
## 瞬时杆量（非增量），与帧长无关；保留该参数只为与 AircraftFlight.integrate
## 同口径，便于将来需要速率限幅时无痛接入，不参与本次输出计算。前缀 _ 抑制
## GDScript 的 UNUSED_PARAMETER 警告（本工程既有同款先例），8 参签名不变。

## 掉头锁定方向：+1 右转 / -1 左转 / 0 未锁定。跨 ±180° 反屈点保持不变，
## 是本控制器唯一的跨帧状态（其余增益均为无状态比例闭环）。
var _turn_dir := 0.0


## 每次激活返航 / 取消后由 aircraft.gd 调用，避免上一次掉头方向污染下一次。
func reset() -> void:
	_turn_dir = 0.0


func step(nav_dev_deg: float, bank_rad: float, yaw_rate: float,
		altitude_m: float, target_altitude_m: float, speed_mps: float,
		dist_m: float, _delta: float) -> Dictionary:
	# 掉头方向锁定：只在「未锁定且偏差极大」时选一次方向；锁定期间即便
	# wrapf 把 dev 从 +170 翻成 -173，也用 abs(dev) 配原方向，坡度不反转。
	var abs_dev := absf(nav_dev_deg)
	if _turn_dir == 0.0 and abs_dev > TURN_LATCH_DEG:
		_turn_dir = 1.0 if nav_dev_deg >= 0.0 else -1.0
	elif abs_dev < TURN_RELEASE_DEG:
		_turn_dir = 0.0
	var eff_dev := nav_dev_deg
	if _turn_dir != 0.0:
		eff_dev = _turn_dir * abs_dev
	# 横向：偏差 → 目标坡度（限幅）→ 坡度误差 P 控制 + 偏航率阻尼 → 滚转杆量。
	var target_bank := clampf(
		eff_dev * DEV_TO_BANK_GAIN, -MAX_BANK_RAD, MAX_BANK_RAD)
	var bank_err := target_bank - bank_rad
	var roll := clampf(
		ROLL_GAIN * bank_err - ROLL_DAMP * yaw_rate, -1.0, 1.0)
	# 方向舵只给极小同向协调量，转弯主要靠坡度经气动自带协调带出。
	var yaw := clampf(roll * YAW_COORD_GAIN, -1.0, 1.0)
	# 纵向：高度误差 → 俯仰配平（限幅）。
	var pitch := clampf(
		clampf((target_altitude_m - altitude_m) * PITCH_GAIN,
			-PITCH_CMD_MAX, PITCH_CMD_MAX), -1.0, 1.0)
	# 油门：巡航基准，逼近 VNE 收油到 0、逼近失速加油到满，中间线性过渡。
	var fast_edge := VNE * VNE_SOFT_RATIO
	var slow_edge := STALL_SPEED * STALL_SOFT_RATIO
	var throttle := THROTTLE_CRUISE
	if speed_mps > fast_edge:
		throttle = THROTTLE_CRUISE * clampf(
			(VNE - speed_mps) / (VNE - fast_edge), 0.0, 1.0)
	elif speed_mps < slow_edge:
		throttle = THROTTLE_CRUISE + (1.0 - THROTTLE_CRUISE) * clampf(
			(slow_edge - speed_mps) / (slow_edge - STALL_SPEED), 0.0, 1.0)
	throttle = clampf(throttle, 0.0, 1.0)
	return {
		"roll": roll,
		"pitch": pitch,
		"yaw": yaw,
		"throttle": throttle,
		"arrived": dist_m <= ARRIVE_DIST_M,
	}


## 玩家是否正在接管：任一 |杆量| 超过 TAKEOVER_STICK 即为真。sticks 只应传
## 姿态杆（roll/pitch/yaw），**不要传油门**——巡航油门远大于该阈值，误传会
## 让自动驾驶每帧自我解除。
static func takeover(sticks: Array) -> bool:
	for s in sticks:
		if absf(float(s)) > TAKEOVER_STICK:
			return true
	return false
