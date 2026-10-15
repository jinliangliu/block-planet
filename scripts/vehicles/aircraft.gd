class_name Aircraft
extends CharacterBody3D
## 可放置 / 可乘坐的轻型飞行器。
##
## 分工：气动与姿态积分在 AircraftFlight（纯逻辑），本节点只做「把状态搬进场景」——
## 机身碰撞与地面支撑、轮胎抓地、撞击解体、乘员座位、信号广播。
## 机型表现见 AircraftModel（纯代码生成的机模）。
##
## 世界尺度：1 格 = 0.5 m（D-030）。机身长约 10.2 m（约 20 格）、翼展 24 m
## （48 格）的轻型单发机，比村庄民居（12×12 格 = 6×6 m）大一圈，起飞需要
## 一段平地或跑道。
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
## 碰撞盒：横向只包住机身（6.6 × 4.8 × 15.6 m，即 13.2 × 9.6 × 31.2 格），
## 翼展（24 m）不参与碰撞，否则机身会一路刮蹭树冠与屋檐。
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

# ── 飞行里程统计（探索模式成就的数据源） ─────────────────────
## 离地高度测量：向下射线长度（m）。世界高度上限 64 格 ≈ 32 m，400 m 足够。
const AGL_RAY_LENGTH := 400.0
## 测高刷新间隔（秒）：射线不必每帧打，5 Hz 够仪表与里程碑用。
const AGL_INTERVAL := 0.2
## 离地高度里程碑步长（m）：每越过一档广播一次。
const ALT_MILESTONE_STEP := 20.0
## 累计飞行距离里程碑步长（m）。
const DIST_MILESTONE_STEP := 100.0

@export var use_player_input := true

var controls := AircraftFlight.Controls.new()
## 触屏驾驶输入：由 HUD 飞行触控层写入，替代键盘/鼠标（仅触屏设备、有人驾驶时启用）。
## 桌面端 _touch_active 恒为 false，走键盘/鼠标分支，互不影响。
var _touch_active := false
var _touch_pitch := 0.0
var _touch_roll := 0.0
var _touch_yaw := 0.0
var _touch_throttle := 0.0
var _touch_brake := false
## 是否有人驾驶（决定输入来源与座位跟随）。
var piloted := false
## 当前骑乘者（Player），未骑乘为 null。
var rider: Player = null

var _state := AircraftFlight.State.new()
var _model: AircraftModel
## 已套用的涂装索引（每帧与设置比对，变了才改色，避免无谓的材质刷新）。
var _applied_livery := -1
## 蓝图装配来源：非 null 时 _ready 据其零件生成体素块外观（替代整机机模）。
var _blueprint: Blueprint = null
## 蓝图机外观登记表（P2-6/P2-17）：螺旋桨中继节点 / 升降舵网格 / 零件材质
## 与类别（涂装改色用）。整机机模路径（_model）下三者皆空。
var _bp_props: Array[Node3D] = []
var _bp_elevators: Array[MeshInstance3D] = []
var _bp_mats: Array[MeshInstance3D] = []
var _bp_cats: Array[int] = []
## 试飞机标记（from_loadout 生成）：由蓝图拼装、未消耗库存物品，双击 F
## 收回时不退回 AIRCRAFT 道具——否则「工坊台试飞 → 收回」可无限刷物品（P2-3）。
var blueprint_built := false
var _wrecked := false
var _stick := Vector2.ZERO
var _readings_timer := 0.0
var _stall_state := false
var _collider: CollisionShape3D
## 离地高度（m，AGL）：机身原点距下方地形面的高度，测高射线刷新。
## HUD「离地」读数与高度里程碑共用；无命中（飞出世界边缘）时退回 position.y。
var _altitude_agl := 0.0
var _agl_timer := 0.0
## 上一帧是否着地（起飞边沿检测）。
var _was_on_floor := true
## 本次飞行已达成的离地高度里程碑与里程里程碑（m）。
var _alt_milestone := 0.0
var _dist_milestone := 0.0
## 累计空中飞行距离（m）。
var _flight_distance := 0.0


## 在世界里落下一架飞行器：机轮贴地、机头朝 heading。
static func spawn(parent: Node, at: Vector3, heading: float = 0.0) -> Aircraft:
	var craft := Aircraft.new()
	parent.add_child(craft)
	craft.place(at, heading)
	return craft


## 用蓝图拼装一架飞机（Phase 1 装配入口；Phase 2 建造编辑器经此生成可见机体）。
## 与 spawn() 同一落位路径，只把默认气动框换成蓝图零件的聚合结果，并以零件
## 体素块外观替代整机机模。默认 spawn() 仍走 ×3 代码机模，保持已验证手感。
## （先 place() 再覆盖 airframe：place() 内部 make_state 会重建 State 并复位
## 气动框，故聚合结果必须在 place() 之后写入。）
static func from_loadout(
	parent: Node, at: Vector3, heading: float, blueprint: Blueprint) -> Aircraft:
	var craft := Aircraft.new()
	craft._blueprint = blueprint
	craft.blueprint_built = true   # 试飞机：收回不退回物品（P2-3）
	parent.add_child(craft)              # _ready 读到 _blueprint → 建零件体素外观
	craft.place(at, heading)             # 落位并建默认气动框
	craft._state.airframe = blueprint.aggregate()  # 覆盖为零件聚合结果
	return craft


## 落位：把机轮放到地面上（at 为地面点）。
func place(at: Vector3, heading: float = 0.0) -> void:
	_state = AircraftFlight.make_state(
		at + Vector3(0.0, GROUND_CLEARANCE + 0.05, 0.0), heading)
	global_transform = Transform3D(_state.basis, _state.position)
	velocity = Vector3.ZERO


## 按蓝图零件生成体素块外观。纯视觉、无碰撞，不改变飞行。
## 三处对齐整机机模（P2-6/P2-17 合并修，同函数一次改动）：
##   1. 零件组底面锚到机轮触地高度（−GROUND_CLEARANCE，即碰撞盒底）——
##      原按重心居中，而重心≠机身原点（碰撞盒以原点为准），整组悬空约 0.85 m；
##   2. 螺旋桨/升降舵登记进 _bp_props/_bp_elevators，每帧跟油门与杆量动起来
##      （原蓝图机的桨不转、舵不摆，与整机机模落差明显）；
##   3. 材质登记进 _bp_mats/_bp_cats，出厂即套当前涂装——_sync_livery 原对
##      _model==null 直接早退，蓝图机换涂装无效果。
func _build_part_visuals(bp: Blueprint) -> void:
	var container := Node3D.new()
	container.name = "PartMeshes"
	add_child(container)
	var com := bp.center_of_gravity()
	# 零件组最低点（相对重心）：绕 Y 旋转只对调宽/深，半高即 size.y 的一半。
	var min_y := INF
	for p in bp.parts:
		var c: Vector3 = p.local_pos() - com
		min_y = minf(min_y, c.y - float(p.data.size.y) * 0.5 * PartData.GRID_METERS)
	container.position = Vector3(0.0, -GROUND_CLEARANCE - min_y, 0.0)
	_bp_props.clear()
	_bp_elevators.clear()
	_bp_mats.clear()
	_bp_cats.clear()
	for p in bp.parts:
		var center: Vector3 = p.local_pos() - com
		var is_prop := p.data.category == PartData.Category.PROPELLER
		var parent: Node3D = container
		if is_prop:
			# 桨叶挂中继节点：中继保持单位旋转，绕其局部 Z（机头轴）旋转即
			# 盘面旋转——零件网格自身的 Y 向 rot 不会污染转轴。
			var pivot := Node3D.new()
			pivot.position = center
			container.add_child(pivot)
			parent = pivot
			_bp_props.append(pivot)
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(p.data.size) * PartData.GRID_METERS
		mi.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = _category_color(p.data.category)
		mat.metallic = 0.1
		mat.roughness = 0.7
		mi.material_override = mat
		mi.position = Vector3.ZERO if is_prop else center
		mi.rotation_degrees = Vector3(0.0, float(p.rot) * 90.0, 0.0)
		parent.add_child(mi)
		_bp_mats.append(mi)
		_bp_cats.append(p.data.category)
		if p.data.category == PartData.Category.TAIL:
			_bp_elevators.append(mi)
	# 出厂即套当前涂装（与整机机模一致）。
	_applied_livery = -1
	_sync_livery()


## 零件类别 → 体素块配色（蓝本为儿童向、辨识度优先）。
static func _category_color(cat: int) -> Color:
	match cat:
		PartData.Category.FUSELAGE:  return Color(0.75, 0.78, 0.82)
		PartData.Category.WING:      return Color(0.30, 0.55, 0.85)
		PartData.Category.TAIL:      return Color(0.45, 0.65, 0.90)
		PartData.Category.ENGINE:    return Color(0.35, 0.35, 0.40)
		PartData.Category.PROPELLER: return Color(0.20, 0.20, 0.22)
		PartData.Category.GEAR:      return Color(0.55, 0.50, 0.30)
		PartData.Category.FUEL_TANK: return Color(0.80, 0.55, 0.25)
		_:                           return Color(0.70, 0.70, 0.70)


func _ready() -> void:
	add_to_group("aircraft")
	if _blueprint != null:
		_build_part_visuals(_blueprint)
	else:
		_model = AircraftModel.new()
		# 出厂即套用当前涂装（默认经典红白）。
		_model.set_livery_index(FlightSettings.current().livery_index)
		_applied_livery = _model.livery_index()
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
	var data := AircraftFlight.snapshot(_state)
	# 节点级补充字段：离地高度（纯逻辑层不持有世界引用，测高在节点做）。
	data["altitude_agl"] = _altitude_agl
	# 油门读数取「飞行员指令」(controls) 而非滞后一帧的集成状态 (state)，
	# 让油门条实时跟手；其余气动读数（空速/失速）仍取自物理状态。
	data["throttle"] = controls.throttle
	return data


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
## 交给 HUD 飞行触控层写入本帧操纵量（触屏专用）。桌面端不调用，故不影响键鼠通路。
func set_touch_flight_input(pitch: float, roll: float, yaw: float, throttle: float, brake: bool) -> void:
	_touch_active = true
	_touch_pitch = pitch
	_touch_roll = roll
	_touch_yaw = yaw
	_touch_throttle = throttle
	_touch_brake = brake


func set_piloted(value: bool, who: Player = null) -> void:
	piloted = value
	rider = who if value else null
	if not value:
		controls.throttle = 0.0
		controls.pitch = 0.0
		controls.roll = 0.0
		controls.yaw = 0.0
		_stick = Vector2.ZERO
		_touch_active = false
		_touch_pitch = 0.0
		_touch_roll = 0.0
		_touch_yaw = 0.0
		_touch_throttle = 0.0
		_touch_brake = false


func _physics_process(delta: float) -> void:
	if _wrecked:
		return

	_prepare_input(delta)
	var on_ground := is_on_floor()
	# 辅助稳定增益（FlightSettings 单例）；无设置/关闭档即纯气动模型。
	var assist := FlightSettings.current().gains()
	AircraftFlight.integrate(_state, controls, delta, on_ground, assist)
	_sync_livery()
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
	else:
		_animate_bp_surfaces(controls.throttle, controls.pitch, delta)

	_update_flight_tracking(delta, on_ground)
	_check_failure(impact)
	_emit_readings(delta)


## 涂装同步：设置里换了涂装就在下一帧改色（整数比对，命中才刷材质）。
## 两条外观路径都覆盖：整机机模（_model）与蓝图零件（_bp_mats）——
## 原实现对 _model==null 直接早退，蓝图机换涂装无效果（P2-6）。
func _sync_livery() -> void:
	var want := FlightSettings.current().livery_index
	if want == _applied_livery:
		return
	if _model != null:
		_model.set_livery_index(want)
	elif not _bp_mats.is_empty():
		_apply_bp_livery(want)
	_applied_livery = want


## 蓝图零件涂装：机身/机翼取涂装 body 色，尾翼/发动机/起落架/油箱取 accent 色，
## 螺旋桨固定深色（桨叶与涂装无关，保持深色辨识）。类别→角色映射集中在此，
## 与 _category_color 的默认配色互补——玩家显式选了涂装就以涂装为准。
func _apply_bp_livery(index: int) -> void:
	var body := AircraftLivery.body_of(index)
	var accent := AircraftLivery.accent_of(index)
	var dark := Color(0.20, 0.20, 0.22)
	for i in _bp_mats.size():
		var mat := _bp_mats[i].material_override as StandardMaterial3D
		if mat == null:
			continue
		match _bp_cats[i]:
			PartData.Category.FUSELAGE, PartData.Category.WING:
				mat.albedo_color = body
			PartData.Category.PROPELLER:
				mat.albedo_color = dark
			_:
				mat.albedo_color = accent


## 蓝图机动画：螺旋桨绕机头轴按油门旋转、升降舵随拉杆/推杆偏转
##（参数与量级同 AircraftModel.spin_propeller / deflect_controls）。
func _animate_bp_surfaces(throttle: float, pitch: float, delta: float) -> void:
	for pivot in _bp_props:
		pivot.rotate_z(-AircraftModel.PROP_MAX_SPIN * clampf(throttle, 0.0, 1.0) * delta)
	for mi in _bp_elevators:
		mi.rotation.x = -pitch * 0.5


## 飞行里程统计：起飞边沿、离地高度里程碑、累计里程，广播给进度核心
## （探索模式「展翅高飞 / 冲上云霄 / 空中漫游」三枚成就的数据源）。
func _update_flight_tracking(delta: float, on_ground: bool) -> void:
	if not on_ground and _was_on_floor:
		# 起飞：本次飞行的里程碑从零起算（落地下次再飞可重新达成）。
		Events.aircraft_took_off.emit()
		_alt_milestone = 0.0
		_dist_milestone = 0.0
	_was_on_floor = on_ground

	if on_ground:
		_altitude_agl = 0.0
		return

	# 累计空中里程：每满 100 m 广播一段。
	_flight_distance += _state.velocity.length() * delta
	while _flight_distance >= _dist_milestone + DIST_MILESTONE_STEP:
		_dist_milestone += DIST_MILESTONE_STEP
		Events.aircraft_distance.emit(DIST_MILESTONE_STEP)

	# 测高节流：5 Hz 足够仪表与里程碑，省得每帧打射线。
	_agl_timer += delta
	if _agl_timer < AGL_INTERVAL:
		return
	_agl_timer = 0.0
	_altitude_agl = _raycast_altitude_agl()
	while _altitude_agl >= _alt_milestone + ALT_MILESTONE_STEP:
		_alt_milestone += ALT_MILESTONE_STEP
		Events.aircraft_altitude.emit(_alt_milestone)


## 离地高度：自机身原点向下打一道射线，命中地形面即距地高度
## （扣掉机轮离地净空，停放时读数为 0）。未命中退回世界坐标 y——
## 飞出世界边缘时没有地形可测，给个单调递增的值也好过没有。
func _raycast_altitude_agl() -> float:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		global_position, global_position + Vector3.DOWN * AGL_RAY_LENGTH)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return global_position.y
	var hit_pos: Vector3 = hit["position"]
	return maxf(hit_pos.distance_to(global_position) - GROUND_CLEARANCE, 0.0)


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
	# 模态界面打开中（任务/设置等面板冻结玩家，Player.input_locked）：不接受
	# 新输入，保持当前杆位与油门继续飞行——否则玩家在面板里按 W/S/A/D/空格
	# 仍在遥控飞机（P2-2）。
	if rider != null and rider.input_locked:
		return

	if _touch_active:
		# 触屏驾驶：HUD 飞行触控层已写好本帧操纵量，原样采用。
		controls.pitch = _touch_pitch
		controls.roll = _touch_roll
		controls.yaw = _touch_yaw
		controls.throttle = _touch_throttle
		controls.brake = _touch_brake
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
	# 先广播原因再弹射乘员（P2-5）：HUD 的 crashed 监听在下机时断开，
	# 顺序反了坠机原因播报就会丢失。
	crashed.emit(reason)
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
