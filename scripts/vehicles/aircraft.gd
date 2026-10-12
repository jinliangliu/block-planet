class_name Aircraft
extends CharacterBody3D
## 可放置 / 可乘坐的轻型飞行器。
##
## 分工：气动与姿态积分在 AircraftFlight（纯逻辑），本节点只做「把状态搬进场景」——
## 机身碰撞与地面支撑、轮胎抓地、撞击解体、乘员座位、信号广播。
## 机型表现见 AircraftModel（纯代码生成的机模）。
##
## 世界尺度：1 格 = 0.5 m（D-030）。机身约 17 格长、翼展 24 格（≈ 8.5 m × 12 m
## 的轻型单发机），比村庄民居（12×12 格）大一圈，起飞需要一段平地或跑道。
##
## 驾驶输入（use_player_input = true 且 piloted 时）：
##   鼠标 → 操纵杆（俯仰 / 滚转，松手缓慢回中）
##   W / S → 油门增减    A / D → 方向舵（地面即前轮转向）
##   空格 → 机轮刹车     F → 下机
## 探针把 use_player_input 置否、直接写 controls，走同一条物理路径。

## 每帧读数变化时广播（节流到 READINGS_INTERVAL），HUD 仪表监听。
signal readings_changed(snapshot: Dictionary)
## 失速状态翻转时广播（进入 / 退出失速），HUD 亮灯与告警音用。
signal stall_changed(stalled: bool)
## 解体时广播，reason 为中文原因（供提示文案）。
signal crashed(reason: String)

## 机身原点（重心）距地面的高度：与 AircraftModel.GROUND_CLEARANCE 一致。
const GROUND_CLEARANCE := AircraftModel.GROUND_CLEARANCE
## 碰撞盒：横向只包住机身（6.6 × 4.8 × 15.6 格 ≈ 3.3 × 2.4 × 7.8 m），
## 翼展（24 格）不参与碰撞，否则机身会一路刮蹭树冠与屋檐。
## 底面必须恰在 −GROUND_CLEARANCE：中心 y = −0.15 × 3，半高 2.4。
const COLLIDER_SIZE := Vector3(2.2, 1.6, 5.2) * AircraftModel.MODEL_SCALE
const COLLIDER_CENTER := Vector3(0.0, -0.05, 0.0) * AircraftModel.MODEL_SCALE
## 飞行员原点（脚底）在机体坐标里的位置：脚踩机舱地板、眼位（+1.4）落进
## 座舱罩内（罩顶 2.99，眼位 2.75）——第一人称才是「坐在舱里」而非骑在机背。
const SEAT_OFFSET := Vector3(0.0, 1.35, -2.8)

## 撞击判定：单帧速度损失超过此值视为撞毁（含硬着陆与撞墙）。
const CRASH_IMPACT_DV := 7.0
## 残骸停留时长。
const WRECK_LIFETIME := 4.0
## 读数广播节流间隔（秒）。
const READINGS_INTERVAL := 0.1

# ── 地面操纵 ────────────────────────────────────────────────
## 轮胎抓地：水平速度被拽向机头方向的速率（1/s）。
const GROUND_GRIP := 3.0
## 滚动阻力（m/s²）。满油门净加速度 ≈ 2.57 − 0.6 = 1.97 m/s²。
const ROLLING_RESISTANCE := 0.6
const BRAKE_DECEL := 6.0
## 前轮转向速率（rad/s），随速度衰减（高速靠气动舵面）。
const STEER_RATE := 0.8
# ── 鼠标操纵杆 ──────────────────────────────────────────────
const MOUSE_STICK_SENSITIVITY := 0.006
## 松手回中速率（1/s）：慢回中，允许玩家保持一个稳定的转弯坡度。
const STICK_CENTER_RATE := 0.55
## 油门变化速率（每秒）。
const THROTTLE_RATE := 0.55
## 骑乘者受伤（解体时抛出）。
const CRASH_DAMAGE := 6

@export var use_player_input := true

var controls := AircraftFlight.Controls.new()
## 是否有人驾驶（决定输入来源与座位跟随）。
var piloted := false
## 当前骑乘者（Player），未骑乘为 null。
var rider: Player = null

var _state := AircraftFlight.State.new()
var _model: AircraftModel
var _wrecked := false
var _stick := Vector2.ZERO
var _readings_timer := 0.0
var _stall_state := false
var _collider: CollisionShape3D


## 在世界里落下一架飞行器：机轮贴地、机头朝 heading。
static func spawn(parent: Node, at: Vector3, heading: float = 0.0) -> Aircraft:
	var craft := Aircraft.new()
	parent.add_child(craft)
	craft.place(at, heading)
	return craft


## 落位：把机轮放到地面上（at 为地面点）。
func place(at: Vector3, heading: float = 0.0) -> void:
	_state = AircraftFlight.make_state(
		at + Vector3(0.0, GROUND_CLEARANCE + 0.05, 0.0), heading)
	global_transform = Transform3D(_state.basis, _state.position)
	velocity = Vector3.ZERO


func _ready() -> void:
	add_to_group("aircraft")
	_model = AircraftModel.new()
	add_child(_model)
	_collider = CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = COLLIDER_SIZE
	_collider.shape = shape
	_collider.position = COLLIDER_CENTER
	add_child(_collider)
	# 机身与地形接触即着陆：地面法线朝上的方块都算可停放面。
	floor_max_angle = deg_to_rad(55.0)
	up_direction = Vector3.UP


## 空中投放/起飞：给机体一个沿机头方向的初速（可选带爬升分量）。
## 探针在 D 段用它把飞机直接投进巡航状态，避免从零速自由落体。
func launch(forward_speed: float, climb_speed: float = 0.0) -> void:
	_state.velocity = -_state.basis.z * forward_speed + Vector3.UP * climb_speed
	velocity = _state.velocity


## 每帧读数快照（HUD 仪表与探针共用）。
func snapshot() -> Dictionary:
	return AircraftFlight.snapshot(_state)


func is_wrecked() -> bool:
	return _wrecked


## 油门归一化值（机模螺旋桨转速用）。
func throttle() -> float:
	return controls.throttle


## 座位变换：驾驶时玩家节点被贴到此处，相机随之跟随机体姿态。
func seat_transform() -> Transform3D:
	return global_transform * Transform3D(Basis.IDENTITY, SEAT_OFFSET)


## 鼠标操纵杆：累积杆量后限幅在单位圆内。
func add_mouse_motion(relative: Vector2) -> void:
	_stick.x = clampf(_stick.x + relative.x * MOUSE_STICK_SENSITIVITY, -1.0, 1.0)
	_stick.y = clampf(_stick.y + relative.y * MOUSE_STICK_SENSITIVITY, -1.0, 1.0)


## 交给脚本/探针驾驶：纳入控制通路，但控制量完全由外部写 controls。
## （只设 use_player_input=false 而不设 piloted，会被当成无人停放机——杆与油门
## 每帧回零，飞机纹丝不动。这个组合是探针最容易踩的坑，故封一个入口。）
func drive_remotely() -> void:
	use_player_input = false
	set_piloted(true)


## 上机 / 下机。
func set_piloted(value: bool, who: Player = null) -> void:
	piloted = value
	rider = who if value else null
	if not value:
		controls.throttle = 0.0
		controls.pitch = 0.0
		controls.roll = 0.0
		controls.yaw = 0.0
		_stick = Vector2.ZERO


func _physics_process(delta: float) -> void:
	if _wrecked:
		return

	_prepare_input(delta)
	var on_ground := is_on_floor()
	AircraftFlight.integrate(_state, controls, delta, on_ground)
	if on_ground:
		_apply_ground_forces(delta)

	# 撞击检测：比对 move_and_slide 前后的速度损失（硬着陆与撞墙同源）。
	var before := _state.velocity
	velocity = before
	move_and_slide()
	var impact := (velocity - before).length()
	_state.velocity = velocity
	_state.position = global_position
	if is_on_floor():
		# 机轮支撑：抹掉向下的速度分量（气动照常结算，故先攒升力再离地）。
		if _state.velocity.y < 0.0:
			_state.velocity.y = 0.0
			velocity.y = 0.0

	if _model != null:
		_model.spin_propeller(controls.throttle, delta)
		_model.deflect_controls(controls.roll, controls.pitch)

	_check_failure(impact)
	_emit_readings(delta)


## 读数与失速边沿广播（读数节流到 10 Hz，避免每帧刷 HUD）。
func _emit_readings(delta: float) -> void:
	if _state.stalled != _stall_state:
		_stall_state = _state.stalled
		stall_changed.emit(_stall_state)
	_readings_timer += delta
	if _readings_timer < READINGS_INTERVAL:
		return
	_readings_timer = 0.0
	readings_changed.emit(snapshot())


## 结构失效判定：超速解体优先于撞击（超速时通常已经失控）。
func _check_failure(impact: float) -> void:
	if _wrecked:
		return
	if _state.overspeed:
		wreck("超过极限速度，机翼折断")
	elif impact >= CRASH_IMPACT_DV:
		wreck("摔得太狠，机身解体")


## 地面：轮胎抓地（水平速度拽向机头）+ 滚动阻力 + 刹车 + 前轮转向。
func _apply_ground_forces(delta: float) -> void:
	var horizontal := Vector3(_state.velocity.x, 0.0, _state.velocity.z)
	var speed_h := horizontal.length()

	var forward := -_state.basis.z
	forward.y = 0.0
	if speed_h > 0.05 and forward.length_squared() > 0.01:
		horizontal = horizontal.lerp(
			forward.normalized() * speed_h, clampf(GROUND_GRIP * delta, 0.0, 1.0))

	var decel := ROLLING_RESISTANCE + (BRAKE_DECEL if controls.brake else 0.0)
	var target_speed := maxf(0.0, speed_h - decel * delta)
	if speed_h > 0.001:
		horizontal *= target_speed / speed_h
	_state.velocity.x = horizontal.x
	_state.velocity.z = horizontal.z

	# 前轮转向：低速灵敏、高速靠气动舵面，故按速度衰减。
	if absf(controls.yaw) > 0.01 and speed_h > 0.3:
		var authority := clampf(1.0 - speed_h / 25.0, 0.15, 1.0)
		_state.basis = _state.basis.rotated(
			Vector3.UP, -controls.yaw * STEER_RATE * authority * delta)


## 组装本帧操纵量：无人驾驶回中收油；脚本驱动原样交给外部；有人则取输入。
func _prepare_input(delta: float) -> void:
	if not piloted:
		controls.pitch = 0.0
		controls.roll = 0.0
		controls.yaw = 0.0
		controls.brake = false
		controls.throttle = maxf(0.0, controls.throttle - THROTTLE_RATE * delta)
		return
	if not use_player_input:
		# 脚本/探针驱动：一个字段都不碰，全部由外部写入。
		return

	_stick = _stick.lerp(Vector2.ZERO, clampf(STICK_CENTER_RATE * delta, 0.0, 1.0))
	var kbd_pitch := Input.get_axis("aircraft_pitch_down", "aircraft_pitch_up")
	var kbd_roll := Input.get_axis("aircraft_roll_left", "aircraft_roll_right")
	controls.pitch = clampf(-_stick.y + kbd_pitch, -1.0, 1.0)
	controls.roll = clampf(_stick.x + kbd_roll, -1.0, 1.0)
	controls.yaw = Input.get_axis("move_left", "move_right")
	controls.brake = Input.is_action_pressed("jump")
	var throttle_axis := Input.get_axis("move_back", "move_forward")
	controls.throttle = clampf(
		controls.throttle + throttle_axis * THROTTLE_RATE * delta, 0.0, 1.0)


## 解体：抛出乘员、喷出碎屑、残骸翻倒后消散。
func wreck(reason: String) -> void:
	if _wrecked:
		return
	_wrecked = true
	velocity = Vector3.ZERO
	_state.velocity = Vector3.ZERO
	_spawn_debris()
	if rider != null:
		var ejected := rider
		ejected.exit_aircraft(CRASH_DAMAGE)
	# 残骸：向一侧翻倒并沉入地面一点，避免看起来还完整。
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "rotation:z", 0.9, 0.6).set_trans(Tween.TRANS_BOUNCE)
	tween.tween_property(self, "position:y", global_position.y - 0.35, 0.6)
	crashed.emit(reason)
	var timer := get_tree().create_timer(WRECK_LIFETIME)
	timer.timeout.connect(queue_free)


func _spawn_debris() -> void:
	var debris := CPUParticles3D.new()
	debris.amount = 48
	debris.lifetime = 1.4
	debris.one_shot = true
	debris.emitting = true
	debris.direction = Vector3.UP
	debris.spread = 88.0
	debris.initial_velocity_min = 4.0
	debris.initial_velocity_max = 11.0
	debris.gravity = Vector3(0.0, -18.0, 0.0)
	debris.scale_amount_min = 0.12
	debris.scale_amount_max = 0.34
	debris.color = Color(0.35, 0.33, 0.31, 1.0)
	add_child(debris)
