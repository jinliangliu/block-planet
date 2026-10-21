class_name BoatPhysics
extends RefCounted
## 航海动力学（纯逻辑，不碰节点，可无头测试）——D-042 航海玩法。
##
## 与赛车（CarPhysics）/ 飞机（AircraftFlight）同构的两段式：本类只管数值
## 积分，Boat 节点负责视觉、浮水与地形碰撞。探针把输入写进 throttle/steer
## 即可逐帧断言，不需要场景。
##
## 坐标系约定（必须与 Boat / HarborBuilder 一致，改动前先读这段）：
##   pos.x → 世界 X，pos.y → 世界 Z（与 CarPhysics 相同）
##   forward = Vector2(sin h, cos h)     ⇒ h=0 时船头朝 +Z（北），节点 rotation.y = h
##   steer 输入 +1 = 向右打舵 ⇒ heading 减小（h 增大 = 左转）
##
## 单位（D-062 P1：1 格 = 1 m）：位置/速度内部一律用「格」，而 1 格就是 1 m，
## 故 MPS_TO_BLOCKS = 1.0（原 D-030 的 0.5 m/格 换算 ×2 已废止）。
## 数据表里的 m/s 设计值在 setup 时 × MPS_TO_BLOCKS 换算；HUD 显示 km/h 时
## 再 × 3.6。海况 wave_m / wind_mps 是「米」设计值，同样换算。
##
## 手感模型（街机向，儿童要的是「推油就走、打舵就转」）：
##   速度趋近 = forward × throttle × 极速 × 海况减速（波高越大越推不动）
##   转向权限 ∝ 车速/极速（原地打舵不转，高速舵效足）
##   风沿航向分量给一小段附加加速度（顺风推、逆风阻）
##   无动力船（木筏 fuel_l=0）不耗油也不会熄火；有油料时耗尽自动熄火，
##   发动机熄火后只随波漂流（速度趋近 0，但风仍能推着走）。

## 米 → 格（D-062 P1：1 格 = 1 m，故为 1.0；原 D-030 的 0.5 m/格 时为 2.0）。
const MPS_TO_BLOCKS := 1.0
## 速度趋近时间常数的倒数（1/s）：越大越跟手。
const ACCEL_RESPONSE := 0.9
## 横向阻尼（1/s）：船不侧滑，速度矢量被拽回船头方向。
const LATERAL_DAMP := 3.0
## 转向参考比例：低于该车速比转向权限按比例衰减。
const TURN_REF_RATIO := 0.25
## 风影响系数：顺风 1 m/s 的附加加速度（格/s²）。
const WIND_PUSH := 0.12
## 波高减速：每米波高削减的极速比例。
const WAVE_SLOWDOWN := 0.06
## 波高减速下限（再大的浪也能挪动，不会完全锁死）。
const WAVE_SLOWDOWN_MIN := 0.55
## 熄火漂流的残余阻力（1/s）。
const DRIFT_DAMP := 0.5

var pos := Vector2.ZERO          # 世界 XZ（格）
var heading := 0.0               # 朝向（弧度），0 = +Z 北
var vel := Vector2.ZERO          # 世界速度（格/s，XZ）
var fuel := 0.0                  # 当前油料（升）
var spec: Dictionary = {}

var throttle := 0.0              # 0~1
var steer := 0.0                 # -1~1（+1 右转）
var engine_on := true            # 熄火时油门锁 0（木筏恒 true）

var _max_speed := 0.0            # 格/s（数据极速，不含海况）
var _turn_rate := 0.0            # rad/s


func setup(boat_spec: Dictionary, at: Vector2, facing: float) -> void:
	spec = boat_spec
	pos = at
	heading = facing
	vel = Vector2.ZERO
	var cap := float(boat_spec.get("fuel_l", 0.0))
	fuel = cap  # 新摆出的船满油；持久化油量由 BoatSystem 单独覆写
	throttle = 0.0
	steer = 0.0
	engine_on = true
	_max_speed = float(boat_spec.get("max_speed_mps", 8.0)) * MPS_TO_BLOCKS
	_turn_rate = float(boat_spec.get("turn_rate", 1.0))


func forward() -> Vector2:
	return Vector2(sin(heading), cos(heading))


func speed() -> float:
	return vel.length()


## 对玩家显示的速度（km/h）：格/s 即 m/s，× 3.6。
func kmh() -> float:
	return speed() * 3.6


func max_speed() -> float:
	return _max_speed


## 罗经朝向（度，0 = 北，顺时针）。
func heading_deg() -> float:
	return rad_to_deg(wrapf(heading, 0.0, TAU))


func fuel_ratio() -> float:
	var cap := float(spec.get("fuel_l", 0.0))
	if cap <= 0.0:
		return 1.0  # 无动力船没有油量概念
	return clampf(fuel / cap, 0.0, 1.0)


## 是否有燃油动力（木筏 false：不耗油、不会熄火）。
func has_engine() -> bool:
	return float(spec.get("fuel_l", 0.0)) > 0.0


## 油门是否被锁（熄火或没油）：UI 显示「发动机熄火」用。
func throttle_locked() -> bool:
	return has_engine() and (not engine_on or fuel <= 0.0)


## 海况 → 极速折扣。sea = {"wave_m": float, ...}（米）。
func sea_speed_factor(sea: Dictionary) -> float:
	var wave := float(sea.get("wave_m", 0.0))
	return clampf(1.0 - wave * WAVE_SLOWDOWN, WAVE_SLOWDOWN_MIN, 1.0)


## 推进一帧。sea 为 BoatSystem.sea_state() 的输出（wave_m / wind_mps /
## wind_along_mps：风沿航向的分量，正 = 顺风）。dt 秒。
func step(dt: float, sea: Dictionary) -> void:
	if dt <= 0.0:
		return
	# 熄火/无油 → 油门锁 0；木筏无发动机，永远可「划」。
	var eff_throttle := throttle
	if throttle_locked():
		eff_throttle = 0.0
	var factor := sea_speed_factor(sea)
	var vmax := _max_speed * factor
	var target := forward() * eff_throttle * vmax
	# 风推：顺/逆风沿船首方向给附加加速度（顺风推、逆风阻）。侧吹分量
	# 由 LATERAL_DAMP 在速度趋近后掐掉，这里只管前后分量，避免船乱滑。
	var wind_along := float(sea.get("wind_along_mps", 0.0)) * MPS_TO_BLOCKS
	target += forward() * wind_along * WIND_PUSH
	# 速度趋近（一阶惯性，推油/收油都有手感）。
	var response := ACCEL_RESPONSE * (0.4 + 0.6 * factor)
	vel = vel.lerp(target, clampf(response * dt, 0.0, 1.0))
	# 横向阻尼：把速度里垂直于船头的分量掐掉，船不侧滑。
	var fwd := forward()
	var along := vel.dot(fwd)
	var side := vel - fwd * along
	vel -= side * clampf(LATERAL_DAMP * dt, 0.0, 1.0)
	if eff_throttle <= 0.0 and along > 0.0:
		# 收油后水阻减速（保留一点滑行，不要立刻站住）。
		vel -= fwd * along * clampf(DRIFT_DAMP * dt, 0.0, 1.0)
	pos += vel * dt
	# 转向：权限随车速比例增长（原地打舵不转）。
	var ratio := clampf(speed() / maxf(_max_speed, 0.001), 0.0, 1.0)
	var authority := clampf(ratio / TURN_REF_RATIO, 0.0, 1.0)
	heading -= steer * _turn_rate * authority * dt
	# 油耗：只在真正输出动力时烧。
	if has_engine() and eff_throttle > 0.0:
		fuel = maxf(0.0, fuel - float(spec.get("burn_lps", 0.0)) * eff_throttle * dt)


## 当前读数快照（HUD 与探针共用一份，勿各算一套）。
func snapshot() -> Dictionary:
	return {
		"pos": pos,
		"heading_deg": heading_deg(),
		"speed_blocks": speed(),
		"kmh": kmh(),
		"throttle": throttle,
		"steer": steer,
		"engine_on": engine_on and not throttle_locked(),
		"fuel": fuel,
		"fuel_ratio": fuel_ratio(),
		"has_engine": has_engine(),
	}
