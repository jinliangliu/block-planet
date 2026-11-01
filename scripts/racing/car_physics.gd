class_name CarPhysics
extends RefCounted
## 地面赛车动力学（纯逻辑，不碰节点，可无头测试）。
##
## 与飞机一样走「纯逻辑层 + 节点壳」两段式：本类只管数值积分，RaceCar 负责
## 视觉与读输入。竞技场是平的，所以位置只在 XZ 平面上演进（y 恒为路面高度），
## 不需要物理引擎参与——跑得快、完全确定性、探针可逐帧断言。
##
## 坐标系约定（必须与 RaceCar / TrackLayout 一致，改动前先读这段）：
##   pos.x → 世界 X，pos.y → 世界 Z
##   forward = Vector2(sin h, cos h)     ⇒ h=0 时车头朝 +Z，节点 rotation.y = h
##   h 增大 = 向左转（+Z 转向 +X）；steer 输入 +1 = 向右打方向 ⇒ heading 减小
##
## 手感四要素：
##   极速  = spec.max_speed_mps × 地形 speed_factor（阻力系数按此反解，全油门自然收敛）
##   抓地  = terrain.grip × spec.grip_base，决定侧滑角回正速率（低抓地 = 推头/甩尾）
##   刹车  = spec.brake_mps2 × 地形 brake_factor（湿地刹车距离明显变长）
##   漂移  = 手刹 × (DECEL 少掉速 + YAW 甩得出去 + GRIP 滑得久)，见下方三常量

const GRIP_K := 20.0      # 侧滑回正速率系数（1/s）：slip 以 GRIP_K×grip 的速率衰减
const TURN_REF := 5.0     # 转向生效参考速度（m/s）：低于它转向权限按比例减弱
const ROLL_K := 6.0       # 滚动阻力换算系数
const SPEED_CAP_SLACK := 1.02

## ── 手刹（漂移）三件套（D-084）────────────────────────────────────────
## 改前的实测问题：手刹只做两件事——减 0.6×brake_mps2 的纵向速度、把侧滑回正
## 降到 0.2。**转向率完全不变**，于是 2 s 满舵的转角和不拉手刹一模一样（230°），
## 而速度掉了 20~32%。也就是说手刹＝「同样的弯，更慢的车」——玩家没有任何理由
## 用它，漂移在系统上是个纯惩罚。
## 三个常量分工：DECEL 决定「漂移掉多少速」，YAW 决定「车头愿意转多快」
## （甩得出来才叫漂移），GRIP 决定「滑多久」。
const HANDBRAKE_DECEL := 0.18   # 纵向减速占 brake_mps2 的比例（原 0.60 → 急刹感）
const HANDBRAKE_YAW := 1.35     # 手刹时转向权限倍率（原 1.0 → 手刹换不来转角）
const HANDBRAKE_GRIP := 0.20    # 手刹时侧滑回正速率倍率（原硬编码 0.2，提为常量）

var pos := Vector2.ZERO          # 世界 XZ
var heading := 0.0               # 朝向（弧度）
var vel := Vector2.ZERO          # 世界速度（m/s，XZ）
var fuel := 0.0
var spec: Dictionary = {}

var throttle := 0.0
var brake := 0.0
var steer := 0.0
var handbrake := false


func setup(vehicle_spec: Dictionary, at: Vector2, facing: float) -> void:
	spec = vehicle_spec
	pos = at
	heading = facing
	vel = Vector2.ZERO
	fuel = float(spec.get("fuel_l", 8.0))
	throttle = 0.0
	brake = 0.0
	steer = 0.0
	handbrake = false


func forward() -> Vector2:
	return Vector2(sin(heading), cos(heading))


## 车速（m/s，标量，取速度矢量模长）。
func speed() -> float:
	return vel.length()


func kmh() -> float:
	return speed() * 3.6


## 侧滑角（度）：速度方向与车头方向的夹角，越大越「漂」。
func slip_deg() -> float:
	if vel.length() < 0.05:
		return 0.0
	var diff := wrapf(atan2(vel.x, vel.y) - heading, -PI, PI)
	return rad_to_deg(absf(diff))


func max_speed() -> float:
	return float(spec.get("max_speed_mps", 20.0))


func fuel_ratio() -> float:
	var cap := float(spec.get("fuel_l", 8.0))
	return clampf(fuel / maxf(cap, 0.001), 0.0, 1.0)


## 推进一帧。input 已由调用方写入本对象的 throttle/brake/steer/handbrake。
func step(dt: float, terrain: Dictionary) -> void:
	if dt <= 0.0:
		return
	var grip := float(terrain.get("grip", 1.0)) * float(spec.get("grip_base", 1.0))
	var vmax := max_speed() * float(terrain.get("speed_factor", 1.0))
	var accel := float(spec.get("accel_mps2", 6.0))
	var has_fuel := fuel > 0.0

	# ── 1. 动力：沿车头方向加力。阻力系数由「全油门刚好收敛到 vmax」反解，
	#        于是地形 speed_factor 天然改变极速，不必额外夹紧。
	if throttle > 0.0 and has_fuel:
		vel += forward() * (accel * throttle * dt)

	# ── 2. 减速：刹车 / 手刹沿速度方向，滚动阻力 + 空气阻力。
	var spd := vel.length()
	var decel := 0.0
	if brake > 0.0:
		decel += float(spec.get("brake_mps2", 9.0)) * float(terrain.get("brake_factor", 1.0)) * brake
	if handbrake:
		decel += float(spec.get("brake_mps2", 9.0)) * HANDBRAKE_DECEL
	var vmax2 := maxf(vmax * vmax, 1.0)
	var drag_k := accel / vmax2
	decel += float(terrain.get("rolling_resistance", 0.02)) * ROLL_K + drag_k * spd * spd
	if spd > 0.0001:
		var target := maxf(spd - decel * dt, 0.0)
		if target > vmax * SPEED_CAP_SLACK:
			target = vmax * SPEED_CAP_SLACK
		vel = vel.normalized() * target

	# ── 3. 转向：速度越低转向权限越小（静止打不动方向），抓地越低越吃不住弯。
	#        手刹时额外 ×HANDBRAKE_YAW ——「拉手刹甩尾」的另一半就这一条：
	#        回正变慢只让velocity方向落后，转向变快才让车头真的甩出去。
	var spd2 := vel.length()
	var f_speed := vel.dot(forward())
	var authority := clampf(spd2 / TURN_REF, 0.0, 1.0)
	var yaw_boost := HANDBRAKE_YAW if handbrake else 1.0
	var rate := deg_to_rad(float(spec.get("turn_rate_deg", 100.0))) \
		* steer * authority * (0.4 + 0.6 * grip) * yaw_boost
	heading -= rate * dt * signf(f_speed)

	# ── 4. 侧滑：把速度矢量朝车头方向回正。回正速率 = GRIP_K×grip，
	#        手刹时降到 20% ——「拉手刹甩尾」就是这条。
	var spd3 := vel.length()
	if spd3 > 0.001:
		var vel_ang := atan2(vel.x, vel.y)
		var diff := wrapf(vel_ang - heading, -PI, PI)
		var grip_mul := HANDBRAKE_GRIP if handbrake else 1.0
		var align := clampf(GRIP_K * grip * grip_mul * dt, 0.0, 1.0)
		vel_ang = heading + diff * (1.0 - align)
		vel = Vector2(sin(vel_ang), cos(vel_ang)) * spd3

	# ── 5. 积分位置 + 油耗。
	pos += vel * dt
	if fuel > 0.0:
		fuel = maxf(0.0, fuel - float(spec.get("fuel_burn_lps", 0.05))
			* (0.25 + 0.75 * throttle) * dt)


## 供 HUD / 探针读取的一帧快照。
func snapshot() -> Dictionary:
	return {
		"pos": Vector3(pos.x, 0.0, pos.y),
		"heading": heading,
		"speed": speed(),
		"kmh": kmh(),
		"slip_deg": slip_deg(),
		"fuel": fuel,
		"fuel_ratio": fuel_ratio(),
		"throttle": throttle,
		"brake": brake,
		"steer": steer,
		"handbrake": handbrake,
	}
