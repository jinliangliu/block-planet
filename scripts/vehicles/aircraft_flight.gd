class_name AircraftFlight
extends RefCounted
## 轻型飞机的简化真实气动模型（纯逻辑，不触碰场景树，可在无头探针里直接驱动）。
##
## 设计参考 Tater's Flight Sim（Three.js 飞行模拟器）的做法：定步长积分、
## 参数按机型标定。本作是儿童向体素世界，故只保留「看得懂、打得准」的核心：
## 升力随攻角线性上升、越过临界攻角失速掉升力、诱导阻力随升力平方增长、
## 空气密度随高度衰减、操纵权限随动压下降（低速时杆变软）。
##
## 世界尺度：1 格 = 0.5 m（D-030），模型内部一律用「米」= 游戏米制。
##
## 聚合化（D-032 探索模式重构）：整机不再是「一台烘焙好常数的飞机」，而是
## **由零件拼装、物理特性按零件求和**。随零件变化的量——总质量、翼面积、
## 推力、零升阻力、重心、升力中心——全部收进 Airframe（挂在 State 上），由
## Airframe.aggregate(零件) 计算；翼型曲线、大气、操控品质等跨零件共享的量
## 仍为静态常量。默认零件套件（PartRegistry.default_loadout）的聚合结果与
## D-031 旧标定逐项一致，故飞行动作不变，目标值由 flight_probe 断言守护：
##   失速速度 √(2mg / ρS·CLmax) ≈ 13 m/s（47 km/h）
##   巡航 35 m/s 平飞需推力 ≈ 815 N（半油门）；最大平飞约 50 m/s（低于 VNE 55）
##   起飞滑跑净加速约 6.3 m/s²，拉杆后约 2 秒 / 18 m 离地；升阻比 L/Dmax ≈ 8
## 注意：地面姿态被机轮限在 12° 以内——必须「到抬轮速度后拉杆」才会离地。
## 运行验证：tests/flight_probe.tscn

const GRAVITY := 9.80665
const SEA_LEVEL_DENSITY := 1.225
## 大气标高：密度随高度指数衰减（8500 m 处约为海平面 37%）。
const DENSITY_SCALE_HEIGHT := 8500.0
const MPS_TO_KMH := 3.6

# ── 翼型 / 大气（跨零件共享，保持静态）──────────────────
## 升力线斜率（1/rad）：3D 机翼实测值低于二维翼型 2π，取 5.0。
const CL_ALPHA := 5.0
const CL_MAX := 1.6
## 临界攻角 0.32 rad ≈ 18°（= CLmax / CLα，自洽）；超过即失速。
const STALL_ALPHA := 0.32
const STALL_WARN_ALPHA := 0.27

# ── 整机气动（旧为烘焙常量，现由 Airframe 从零件聚合）────
## 零升阻力基值：聚合 cd0 = CD0_BASE + Σ零件 parasite_drag（默认套件 = 0.075）。
const CD0_BASE := 0.06
## 诱导阻力因子（诱导阻力 = k·CL²）。
const INDUCED_K := 0.052
## 侧滑引起的附加阻力（每弧度侧滑角）。
const SIDESLIP_DRAG := 0.35
## 螺旋桨推力随密度衰减的指数（螺旋桨比喷气机更依赖空气密度）。
const THRUST_DENSITY_EXPONENT := 0.7
## 不可超越速度默认值（结构极限，超出即解体）。MVP 不随零件变化，
## Airframe.vne 取此值；Phase 3 按机身/机翼结构强度取各零件下限。
const VNE := 55.0
## 触地垂直速度上限（m/s），超出即解体。
const TOUCHDOWN_LIMIT := 6.0

# ── 操纵 ────────────────────────────────────────────────────
const ROLL_RATE_MAX := 2.2
const PITCH_RATE_MAX := 1.1
const YAW_RATE_MAX := 0.55
## 操纵面对杆量的响应时间常数倒数（1/s）：越大越跟手。
const RATE_RESPONSE := 4.5
## 动压基准（Pa）：操纵权限以此为 1，低于此值杆效按比例下降。
const CONTROL_Q_REF := 250.0
const CONTROL_AUTHORITY_MIN := 0.12
## 侧滑回中的风标稳定性（每弧度侧滑角的偏航角速度）。
const YAW_STABILITY := 1.1
## 转弯协调：坡度自然带出偏航角速度，不踩舵也能转出协调转弯。
const TURN_COORDINATION_RATE := 0.5
## 俯仰角限制（rad），约 ±83°：不限制就拉成后空翻。
const PITCH_LIMIT := 1.45
# ── 地面 ───────────────────────────────────────────────────
## 地面姿态机轮限位：滚转被摆平、俯仰最多抬到约 12°（可抬头离地，不能翻跟头）。
const GROUND_PITCH_MAX := 0.21
const GROUND_LEVEL_RATE := 6.0


## 操纵输入：杆量 −1..1，油门 0..1。
class Controls extends RefCounted:
	var throttle := 0.0
	## 俯仰杆：+1 拉杆（机头向上）。
	var pitch := 0.0
	## 副翼：+1 右滚。
	var roll := 0.0
	## 方向舵（地面即前轮转向）：+1 右偏航。
	var yaw := 0.0
	## 机轮刹车（仅地面生效）。
	var brake := false


## 整机聚合特性：由零件拼装求和得到，挂在 State 上随飞机走。
## mass / wing_area / thrust_max / cd0 随零件变化；com / lift_center 供
## 建造编辑器可视化与结构分析；vne / induced_k / sideslip_drag 为 MVP 默认值。
class Airframe extends RefCounted:
	var mass := 0.0
	var wing_area := 0.0
	var thrust_max := 0.0
	var vne := VNE
	var cd0 := CD0_BASE
	var induced_k := INDUCED_K
	var sideslip_drag := SIDESLIP_DRAG
	## 重心（机体局部坐标，米）：质量加权平均。
	var com := Vector3.ZERO
	## 升力中心（机体局部坐标，米）：升力面面积加权平均；无升力面时退回重心。
	var lift_center := Vector3.ZERO

	## 由零件清单聚合整机特性（Phase 1 核心：物理按零件求和）。
	static func aggregate(parts: Array[PlacedPart]) -> Airframe:
		var af := Airframe.new()
		var mass_sum := 0.0
		var area_sum := 0.0
		var thrust_sum := 0.0
		var cd0_sum := CD0_BASE
		var com_weighted := Vector3.ZERO
		var lift_weighted := Vector3.ZERO
		for placed in parts:
			var data: PartData = placed.data
			var pos := placed.local_pos()
			mass_sum += data.mass
			thrust_sum += data.thrust
			cd0_sum += data.parasite_drag
			com_weighted += pos * data.mass
			if data.is_lifting and data.lift_area > 0.0:
				area_sum += data.lift_area
				lift_weighted += pos * data.lift_area
		af.mass = mass_sum
		af.wing_area = area_sum
		af.thrust_max = thrust_sum
		af.cd0 = cd0_sum
		if mass_sum > 0.0:
			af.com = com_weighted / mass_sum
		af.lift_center = lift_weighted / area_sum if area_sum > 0.0 else af.com
		return af


## 默认气动框：由 PartRegistry.default_loadout 聚合而来（单一数据源，
## 保证「默认零件套件飞起来」与 D-031 标定一致）。
static func default_airframe() -> Airframe:
	return Airframe.aggregate(PartRegistry.default_loadout())


## 飞行状态：位置/速度/姿态 + 机体三轴角速度 + 聚合气动框。纯数据，不持有节点。
class State extends RefCounted:
	var position := Vector3.ZERO
	var velocity := Vector3.ZERO
	## 机体基：+X 右翼、+Y 机背、-Z 机头（Godot 约定）。
	var basis := Basis.IDENTITY
	var roll_rate := 0.0
	var pitch_rate := 0.0
	var yaw_rate := 0.0
	## 本机的聚合特性（零件拼装结果）；未指定时用默认套件。
	var airframe: Airframe
	## 结算读数（HUD 与探针共用同一份来源）。
	var airspeed := 0.0
	var alpha := 0.0
	var load_factor := 1.0
	var stalled := false
	var stall_warning := false
	var overspeed := false
	var throttle := 0.0

	func _init() -> void:
		airframe = AircraftFlight.default_airframe()


static func make_state(at: Vector3, heading: float = 0.0) -> State:
	var state := State.new()
	state.position = at
	state.basis = Basis.from_euler(Vector3(0.0, heading, 0.0))
	return state


## 空气密度（kg/m³）：等温指数大气，够用且单调。
static func air_density(altitude: float) -> float:
	return SEA_LEVEL_DENSITY * exp(-maxf(altitude, 0.0) / DENSITY_SCALE_HEIGHT)


## 失速速度（m/s）：升力恰好等于重力的速度，随整机质量/翼面积/空气密度变化。
static func stall_speed(density: float, airframe: Airframe) -> float:
	var denom := density * airframe.wing_area * CL_MAX
	if denom <= 0.0:
		return 0.0
	return sqrt(2.0 * airframe.mass * GRAVITY / denom)


## 升力系数曲线：线性段到临界攻角，之后升力平缓下滑（简化的失速平台）。
static func lift_coefficient(alpha: float) -> float:
	var magnitude := absf(alpha)
	if magnitude <= STALL_ALPHA:
		return clampf(CL_ALPHA * alpha, -CL_MAX, CL_MAX)
	# 失速后：从 CLmax 起按更陡的斜率下滑，保留 35% 残余升力。
	# 残余升力不为零是为了避免「一失速就直接坠地」——真机也是抖振后逐渐掉头，
	# 儿童向更要留出改出的余地。
	var over := magnitude - STALL_ALPHA
	return signf(alpha) * maxf(CL_MAX * 0.35, CL_MAX - over * 2.4)


## 动压 q = ½ρV²（Pa）。
static func dynamic_pressure(state: State) -> float:
	var speed := state.velocity.length()
	return 0.5 * air_density(state.position.y) * speed * speed


## 攻角（rad）：机体速度矢量与机头方向在对称面内的夹角，机头高于航迹为正。
static func angle_of_attack(state: State) -> float:
	var speed := state.velocity.length()
	if speed < 1.0:
		return 0.0
	var v_b := state.basis.inverse() * state.velocity
	var forward_speed := maxf(-v_b.z, 0.5)
	return clampf(atan2(-v_b.y, forward_speed), -0.6, 0.6)


## 侧滑角（rad）：机体横向速度分量，右滑为正。
static func sideslip(state: State) -> float:
	var speed := state.velocity.length()
	if speed < 1.0:
		return 0.0
	var v_b := state.basis.inverse() * state.velocity
	return asin(clampf(v_b.x / speed, -1.0, 1.0))


## 气动力 + 推力合成加速度（m/s²）。lift 与 drag 都按动压 × 整机翼面积结算，
## 各系数取自本机的 Airframe（零件聚合结果）。
static func acceleration(state: State, controls: Controls) -> Vector3:
	var af := state.airframe
	var speed := state.velocity.length()
	var q_dyn := dynamic_pressure(state)
	var alpha := angle_of_attack(state)
	var beta := sideslip(state)
	var cl := lift_coefficient(alpha)
	var cd := af.cd0 + af.induced_k * cl * cl + absf(beta) * af.sideslip_drag
	var q_area := q_dyn * af.wing_area

	# 升力垂直于速度、位于机体的对称面内（机背方向去掉速度分量）。
	# 该式同时给出两种效果：攻角产生的升力，以及滚转时机翼倾斜把升力掰向侧向
	# ——这正是「压坡度就会转弯」的来源，不需要额外转弯公式。
	var velocity_dir := state.velocity / speed if speed > 0.001 else -state.basis.z
	var lift_dir := state.basis.y - velocity_dir * state.basis.y.dot(velocity_dir)
	if lift_dir.length_squared() < 0.0001:
		lift_dir = state.basis.y
	lift_dir = lift_dir.normalized()

	var lift := lift_dir * (q_area * cl)
	var drag := -velocity_dir * (q_area * cd)
	var thrust_dir := -state.basis.z
	var thrust := thrust_dir * (
		controls.throttle * af.thrust_max
		* pow(air_density(state.position.y) / SEA_LEVEL_DENSITY, THRUST_DENSITY_EXPONENT)
	)
	var weight := Vector3.DOWN * (af.mass * GRAVITY)
	var inv_mass := 1.0 / af.mass if af.mass > 0.0 else 0.0
	return (lift + drag + thrust + weight) * inv_mass


## 推进一帧：先按杆量更新机体角速度与姿态，再积分速度与位置，最后刷新读数。
static func integrate(state: State, controls: Controls, delta: float, on_ground: bool) -> void:
	var q_dyn := dynamic_pressure(state)
	var authority := clampf(
		q_dyn / CONTROL_Q_REF, CONTROL_AUTHORITY_MIN, 1.0) if not on_ground else 1.0
	_update_rates(state, controls, delta, authority, on_ground)
	_integrate_attitude(state, delta, on_ground)
	state.throttle = controls.throttle

	# 地面：气动照常结算（这才有先加速攒升力、再抬前轮离地的过程），
	# 但垂直分量交给机轮支撑——由节点在 move_and_slide 之后抹平。
	state.velocity += acceleration(state, controls) * delta
	state.position += state.velocity * delta
	_refresh_readings(state)


static func _update_rates(
	state: State, controls: Controls, delta: float, authority: float, on_ground: bool
) -> void:
	var blend := clampf(RATE_RESPONSE * delta, 0.0, 1.0)
	var beta := sideslip(state)
	# 风标稳定性：机头自动朝向来流（侧滑越大气越强）。地面由机轮主导，抑制之。
	var weathervane := beta * YAW_STABILITY * authority if not on_ground else 0.0
	# 转弯协调：坡度带出偏航。机翼右翼抬高（左坡度）对应左转。
	var bank_sin := clampf(state.basis.x.y, -1.0, 1.0)
	var coordination := -bank_sin * TURN_COORDINATION_RATE * authority \
		if not on_ground else 0.0

	var target_roll := controls.roll * ROLL_RATE_MAX * authority
	var target_pitch := controls.pitch * PITCH_RATE_MAX * authority
	var target_yaw := controls.yaw * YAW_RATE_MAX * authority - weathervane + coordination

	# 接近俯仰限位时先收杆，避免积分越界后姿态解算出现奇异（机头朝上为正）。
	# 地面用机轮限位（12°）而非空中限位（83°）：不然拉杆会把机头抬到 19° 卡在
	# 机轮上，攻角越过临界角、滑跑全程被标成「失速」。
	var pitch_limit := GROUND_PITCH_MAX if on_ground else PITCH_LIMIT
	var pitch_sin := (-state.basis.z).y
	if (pitch_sin > sin(pitch_limit) and target_pitch > 0.0) \
			or (pitch_sin < -sin(pitch_limit) and target_pitch < 0.0):
		target_pitch = 0.0

	state.roll_rate += (target_roll - state.roll_rate) * blend
	state.pitch_rate += (target_pitch - state.pitch_rate) * blend
	state.yaw_rate += (target_yaw - state.yaw_rate) * blend


static func _integrate_attitude(state: State, delta: float, on_ground: bool) -> void:
	# 机体轴旋转（右手法则，结论已用绕轴矩阵逐个验过）：
	#   roll  绕机体 +Z（机尾方向）正转会把右翼抬起来 → 右滚取负号；
	#   pitch 绕机体 +X 正转把机头抬起来 → **直接取正号**（此处曾误加负号，
	#         于是「拉杆」变成压机头，飞机在跑道上永远抬不起前轮）；
	#   yaw   绕机体 +Y 正转把机头转向左 → 右偏航取负号。
	var spin := Basis(Vector3(0.0, 0.0, 1.0), -state.roll_rate * delta) \
		* Basis(Vector3(1.0, 0.0, 0.0), state.pitch_rate * delta) \
		* Basis(Vector3(0.0, 1.0, 0.0), -state.yaw_rate * delta)
	var basis := (state.basis * spin).orthonormalized()

	if on_ground:
		# 机轮限位：滚转被摆平、俯仰最多抬到 GROUND_PITCH_MAX。
		var forward := -basis.z
		var heading := atan2(-forward.x, -forward.z)
		var pitch := clampf(asin(clampf(forward.y, -1.0, 1.0)), 0.0, GROUND_PITCH_MAX)
		var leveled := Basis.from_euler(Vector3(pitch, heading, 0.0))
		basis = basis.slerp(leveled, clampf(GROUND_LEVEL_RATE * delta, 0.0, 1.0))
		state.roll_rate = 0.0
	state.basis = basis


static func _refresh_readings(state: State) -> void:
	var af := state.airframe
	var speed := state.velocity.length()
	var alpha := angle_of_attack(state)
	state.airspeed = speed
	state.alpha = alpha
	state.stalled = absf(alpha) > STALL_ALPHA and speed > 3.0
	state.stall_warning = absf(alpha) > STALL_WARN_ALPHA and speed > 3.0
	state.overspeed = speed > af.vne
	# 载荷系数：升力 / 重力。失速后升力掉下去，读数自然回落。
	var cl := lift_coefficient(alpha)
	var weight := af.mass * GRAVITY
	state.load_factor = (dynamic_pressure(state) * af.wing_area * absf(cl)) / weight \
		if weight > 0.0 else 0.0


## 一帧读数快照：HUD 仪表与探针断言共用同一套字段名。
static func snapshot(state: State) -> Dictionary:
	return {
		"airspeed": state.airspeed,
		"kmh": state.airspeed * MPS_TO_KMH,
		"stall_speed": stall_speed(air_density(state.position.y), state.airframe),
		"altitude": state.position.y,
		"alpha_deg": rad_to_deg(state.alpha),
		"load_factor": state.load_factor,
		"throttle": state.throttle,
		"stalled": state.stalled,
		"stall_warning": state.stall_warning,
		"overspeed": state.overspeed,
	}
