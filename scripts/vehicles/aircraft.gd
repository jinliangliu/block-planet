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
##   F → 发动机启停（熄火后油门锁 0，滑翔仍可操纵）
##   空格 → 地面机轮刹车 / 空中拉升（上升）
##   Shift → 空中加速    Ctrl → 空中下降
##   X → 下机（徒步时就近按 F 登机，X 收回停着的飞机）
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
## 空中加速（Shift）油门变化速率（每秒）：比 W 推油快一倍以上，「按一下就走」。
const BOOST_RATE := 1.4
## 骑乘者受伤（解体时抛出）。
const CRASH_DAMAGE := 6

# ── 飞行里程统计（探索模式成就的数据源） ─────────────────────
## 离地高度测量：向下射线长度（m）。世界高度上限 256 格 = 128 m（D-055），
## 400 m 仍足够覆盖整个世界高度。
const AGL_RAY_LENGTH := 400.0
## 测高刷新间隔（秒）：射线不必每帧打，5 Hz 够仪表与里程碑用。
const AGL_INTERVAL := 0.2
## 离地高度里程碑步长（m）：每越过一档广播一次。
const ALT_MILESTONE_STEP := 20.0
## 累计飞行距离里程碑步长（m）。
const DIST_MILESTONE_STEP := 100.0

# ── 燃油与发动机参数（D-034，gameplay-designer Phase A 数值）────
## 燃油：容量与油耗取自聚合气动框（Airframe.fuel_capacity / fuel_burn，单位
## 升 / 升每秒满油门）；burn = fuel_burn × 油门，熄火不耗。默认套件 55 L +
## 0.10 L/s → 满油满油门续航 9.2 min、半油门巡航 18.3 min（单局任务足够）。
## 耗尽自动熄火（油门锁 0、无推力），舵面仍可滑翔降落——不坠毁不爆炸。
const FUEL_CAPACITY := 55.0
## 低油警告阈值（比例）：与 FlightInstruments 低油滞环一致（≤20% 触发）。
const FUEL_LOW_RATIO := 0.2
## RPM 模型：转速 = RPM_IDLE + RPM_RANGE × 油门（熄火 = 0），
## 仪表显示 600–2700 转/分（大数字百分比 + 小字转速）。
const RPM_IDLE := 600.0
const RPM_RANGE := 2100.0
## 转速表量程上限（转/分）：百分比读数与刻度盘共用。
const RPM_MAX := RPM_IDLE + RPM_RANGE
## RPM 表滞后时间常数（秒）：转速不瞬变，指针才像真的。
const RPM_TAU := 0.4
## 自动改平持续时间（秒）：双击左键后以增强辅助增益摆平（D-034 鼠标操控）。
const LEVEL_ASSIST_TIME := 2.0

# ── 接地质量评分（U-7） ──────────────────────────────────────
## 停稳判据（m/s）：水平速度降到此值以下算「停稳」，结算落地评分。
const LANDING_STOP_MPS := 1.5
## 滑跑结算超时（秒）：一直停不下来（冲出场/缓撞未毁）也按当前速度强制结算，
## 避免 pending 挂到下次起飞、把两次落地混成一笔。
const LANDING_ROLL_TIMEOUT := 15.0

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
## 发动机状态（F 键启停）：熄火时油门锁 0、无推力，螺旋桨停转；
## 舵面仍可操纵（滑翔降高）。下机自动熄火。
var engine_running := false
## 当前骑乘者（Player），未骑乘为 null。
var rider: Player = null

var _state := AircraftFlight.State.new()
var _model: AircraftModel
## 蓝图零件外观容器（_build_part_visuals 建，整机机模路径为 null）。
var _part_meshes: Node3D = null
## 座舱内视开关（D-050）：true = 第一人称下隐藏整机外部外观（机模/蓝图
## 零件组），座舱内饰由 2D 像素座舱框 + 仪表簇提供。只切 visible，不碰
## 碰撞/气动/逻辑。
var _interior_view := false
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
## 首物理帧地面态是否已同步。新 add_child 的 CharacterBody3D 首帧 is_on_floor()
## 恒为 false（move_and_slide 尚未跑），据它判「刚离地」会让每架新落位飞机凭空
## 多发一次 aircraft_took_off（flew 成就 +1）。首帧只用当帧地面态同步 _was_on_floor、
## 不派发跳变事件，等价「出生即基准」——与落位高度无关。
var _ground_synced := false
## 本次飞行已达成的离地高度里程碑与里程里程碑（m）。
var _alt_milestone := 0.0
var _dist_milestone := 0.0
## 累计空中飞行距离（m）。
var _flight_distance := 0.0
## 燃油（升，D-034）：容量与油耗随聚合气动框（蓝图 2 油箱 = 110 L）；
## 出生 / 蓝图装配 / 每次登机补满（_refuel_full），耗尽自动熄火。
var fuel_liters := FUEL_CAPACITY
var fuel_capacity := FUEL_CAPACITY
## RPM 平滑值（转/分，0..2700，发动机参数表用；探针与仪表读 snapshot 的 "rpm"）。
var _rpm_value := 0.0
## 自动改平剩余时间（秒，双击左键触发；>0 时 integrate 用增强摆平增益）。
var _level_timer := 0.0
## 襟翼档位（0/1/2）是否在本次驾驶中变动过（HUD 指示灯用）。
var _flaps_moved := false
## 落地评分（U-7）：触地边沿记 vs，on_ground 期间累计滑跑，停稳/超时结算
## 并广播 Events.aircraft_landed（LandingQuality 口径，与任务评分同一份）。
var _landing_pending := false
var _landing_vs := 0.0
var _landing_timer := 0.0
var _landing_roll_dist := 0.0
## 触地帧真实垂直速度：move_and_slide 后「机轮支撑」会把向下速度抹零
## （568 行区块），而触地边沿要到下一帧的 _update_flight_tracking 才报到——
## 不在这里先存，评分读到的 vs 恒为 0（软硬着陆不分）。
var _last_touchdown_vs := 0.0


## 在世界里落下一架飞行器：机轮贴地、机头朝 heading。
static func spawn(parent: Node, at: Vector3, heading: float = 0.0) -> Aircraft:
	var craft := Aircraft.new()
	parent.add_child(craft)
	WorldAnchor.register(craft)  # D-062：Main 级实体，随 origin 搬迁
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
	WorldAnchor.register(craft)          # D-062：Main 级实体，随 origin 搬迁
	craft.place(at, heading)             # 落位并建默认气动框
	craft._state.airframe = blueprint.aggregate()  # 覆盖为零件聚合结果
	craft._refuel_full()                 # 蓝图油箱容量可能不同（2 油箱 = 110 L）
	return craft


## 浮动原点搬迁（D-062）：节点位置由 main 的组遍历整体 +delta，这里补纯
## 逻辑层的 _state.position——它每物理帧末尾才从节点回同步（589 行），
## 不立即重基的话搬迁当帧的 snapshot（HUD/遥测/录制）会读到旧坐标。
func rebase_state_after_shift(delta: Vector3) -> void:
	if _state != null:
		_state.position += delta


## 落位：把机轮放到地面上（at 为地面点）。
func place(at: Vector3, heading: float = 0.0) -> void:
	_state = AircraftFlight.make_state(
		at + Vector3(0.0, GROUND_CLEARANCE + 0.05, 0.0), heading)
	global_transform = Transform3D(_state.basis, _state.position)
	velocity = Vector3.ZERO
	_refuel_full()
	# 重落位作废未结算的落地评分（D-039 归位 / 试飞搬机都走这里）。
	_landing_pending = false
	_landing_vs = 0.0
	_landing_timer = 0.0
	_landing_roll_dist = 0.0


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
	_part_meshes = container
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


## 座舱内视开关（D-050）：第一人称下隐藏整机外部外观。
##
## 根因（用户实测截图 cockpit_inst_bank.png：机翼横贯全屏）：座舱相机眼位
## COCKPIT_OFFSET = (0, 1.15, -3.4) 落在机身盒内部，而机翼（y 1.335..1.785）
## 正压在视平线上、翼底面正对相机——不隐藏的话「第一人称」看到的先是自
## 己的机翼再是世界。座舱内饰改由 2D 像素座舱框 + 仪表簇提供
## （cockpit_instruments.gd 的 _draw，D-047 spec 的「驾驶舱像素背景」）。
## 蓝图零件组（PartMeshes 容器）同规则隐藏。
## 只切 visible：碰撞盒、气动、录制、逻辑全部不受影响。
func set_cockpit_interior(active: bool) -> void:
	if active == _interior_view:
		return
	_interior_view = active
	_apply_exterior_visibility()


## 当前是否座舱内视（探针回归闸用，避免摸私有 _model）。
func is_interior_view() -> bool:
	return _interior_view


func _apply_exterior_visibility() -> void:
	if _model != null and is_instance_valid(_model):
		_model.visible = not _interior_view
	if _part_meshes != null and is_instance_valid(_part_meshes):
		_part_meshes.visible = not _interior_view


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
	# 发动机状态：HUD 仪表据此显示「熄火」并置灰油门条。
	data["engine"] = engine_running
	# D-034 仪表契约：世界位置（HSI/CDI 直飞偏差用）、着地状态（地面屏蔽
	# 高度警告）、燃油与 RPM（燃油表/发动机参数）、襟翼与起落架。
	data["position"] = global_position
	data["on_ground"] = is_on_floor()
	data["fuel_liters"] = fuel_liters
	data["fuel_capacity"] = fuel_capacity
	data["fuel_ratio"] = fuel_ratio()
	data["rpm"] = _rpm()
	data["rpm_pct"] = clampf(_rpm() / RPM_MAX, 0.0, 1.0)
	data["flaps"] = _state.flaps
	data["flaps_moved"] = _flaps_moved
	data["gear_down"] = true  # 固定起落架：恒放下锁定向
	return data


func is_wrecked() -> bool:
	return _wrecked


## 油门归一化值（机模螺旋桨转速用）。
func throttle() -> float:
	return controls.throttle


## 座位变换：驾驶时玩家节点被贴到此处，相机随之跟随机体姿态。
func seat_transform() -> Transform3D:
	return global_transform * Transform3D(Basis.IDENTITY, SEAT_OFFSET)


## 鼠标操纵杆：累积杆量后限幅在单位圆内（P2-11）。分别钳 x/y 会让对角
## 推满时总杆量达 √2 ≈ 1.41——滚转与俯仰同时超订；先各自钳、再按模长
## 归一，任何方向总杆量不超过 1。
func add_mouse_motion(relative: Vector2) -> void:
	_stick.x = clampf(_stick.x + relative.x * MOUSE_STICK_SENSITIVITY, -1.0, 1.0)
	_stick.y = clampf(_stick.y + relative.y * MOUSE_STICK_SENSITIVITY, -1.0, 1.0)
	if _stick.length() > 1.0:
		_stick = _stick.normalized()


## 交给脚本/探针驾驶：纳入控制通路，但控制量完全由外部写 controls。
## （只设 use_player_input=false 而不设 piloted，会被当成无人停放机——杆与油门
## 每帧回零，飞机纹丝不动。这个组合是探针最容易踩的坑，故封一个入口。）
func drive_remotely() -> void:
	use_player_input = false
	set_piloted(true)


## 燃油比例（0..1；容量为 0 视为 0）。
func fuel_ratio() -> float:
	return clampf(fuel_liters / fuel_capacity, 0.0, 1.0) if fuel_capacity > 0.0 else 0.0


## 补满燃油：容量取聚合气动框（蓝图 2 油箱 = 110 L，D-034 Phase A）。
## 出生 / 蓝图装配 / 每次登机都调它——油是「这一程」的资源，不是飞机耐久
## （防挫败设计，与 D-031 赠机不落盘同哲学）。
func _refuel_full() -> void:
	fuel_capacity = _state.airframe.fuel_capacity
	fuel_liters = fuel_capacity


## 转速（转/分，绝对量，D-034）：运转时 RPM_IDLE + RPM_RANGE × 平滑油门
## （怠速 600 / 满油门 2700）；熄火后无怠速底数，按平滑值自旋减速到 0
## （螺旋桨惯性观感）。屏幕大数字百分比走 snapshot 的 rpm_pct。
func _rpm() -> float:
	var base := RPM_IDLE if (engine_running and fuel_liters > 0.0) else 0.0
	return base + RPM_RANGE * _rpm_value


## 燃油消耗与 RPM 平滑（D-034）：熄火/无油不耗；耗尽即自动熄火并播报。
## 油耗 = 聚合气动框 fuel_burn（默认发动机 0.10 L/s，涡轮 0.18）× 油门——
## Phase A 线性模型：儿童一句话能懂「油门越大越费油」，怠速不耗。
func _update_fuel(delta: float) -> void:
	if engine_running and fuel_liters > 0.0:
		var burn := _state.airframe.fuel_burn * controls.throttle * delta
		fuel_liters = maxf(fuel_liters - burn, 0.0)
		if fuel_liters <= 0.0:
			# 直接置熄火而非 set_engine(false)：避免叠发两条通知，油尽一句就够。
			engine_running = false
			controls.throttle = 0.0
			Events.notice.emit("⛽ 燃油耗尽，发动机熄火了——尽快找地方降落！")
	var rpm_target := controls.throttle if (engine_running and fuel_liters > 0.0) else 0.0
	var k := 1.0 - exp(-delta / RPM_TAU) if delta > 0.0 else 1.0
	_rpm_value = lerpf(_rpm_value, rpm_target, clampf(k, 0.0, 1.0))


## 滚轮油门微调（D-034 PC 鼠标操控）：步长 5%（±0.05），钳 0..1；
## 熄火或无人驾驶时忽略（油门锁 0 的语义不变）。
func adjust_throttle(step: float) -> void:
	if not piloted or not engine_running:
		return
	controls.throttle = clampf(controls.throttle + step, 0.0, 1.0)


## 自动改平（D-034 双击左键）：LEVEL_ASSIST_TIME 秒内以增强增益摆平。
func request_level() -> void:
	if piloted:
		_level_timer = LEVEL_ASSIST_TIME


## 襟翼档位（0/1/2，D-034）：0 = 洁净构型（与 D-031 标定一致）。放下提升
## 升力上限、增大阻力——起飞/着陆更慢更稳，巡航收起。气动系数见
## AircraftFlight 的 FLAP_* 常量（Phase A 结论回订）。
func set_flaps(detent: int) -> void:
	var d := clampi(detent, 0, 2)
	if d == _state.flaps:
		return
	# VFE 软门限（D-034 Phase A §1.4）：放襟翼仅限空速 < 30 m/s；超速下放
	# 只提示不硬拦（D-014「失败必须可解释」），收襟翼不限速度。
	if d > _state.flaps and _state.airspeed > AircraftFlight.FLAP_VFE:
		if piloted:
			Events.notice.emit("🐌 太快啦，先减速再放襟翼")
		return
	_state.flaps = d
	_flaps_moved = true
	if piloted:
		Events.notice.emit("🛬 襟翼 %s" % _flaps_name(d))


## 襟翼循环（一个键走完 0→1→2→0，儿童友好：不必记两个键）。
func cycle_flaps() -> void:
	set_flaps((_state.flaps + 1) % 3)


func flaps_detent() -> int:
	return _state.flaps


static func _flaps_name(d: int) -> String:
	match d:
		1: return "1 档（起飞）"
		2: return "2 档（着陆）"
		_: return "收起"


## 上机 / 下机。
## 交给 HUD 飞行触控层写入本帧操纵量（触屏专用）。桌面端不调用，故不影响键鼠通路。
func set_touch_flight_input(pitch: float, roll: float, yaw: float, throttle: float, brake: bool) -> void:
	_touch_active = true
	_touch_pitch = pitch
	_touch_roll = roll
	_touch_yaw = yaw
	_touch_throttle = throttle
	_touch_brake = brake


## 发动机启停（F 键，仅有人驾驶时有效）。启动无附加条件（儿童友好：
## 停在跑道上也能直接点火）；熄火后油门锁 0、无推力，滑翔仍可操纵舵面。
func set_engine(on: bool) -> bool:
	if not piloted:
		return engine_running
	if on == engine_running:
		return engine_running
	engine_running = on
	if on:
		Events.notice.emit("🔧 发动机已启动：W/S 油门，空格爬升，Shift 加速。")
	else:
		controls.throttle = 0.0
		Events.notice.emit("🔧 发动机已熄火：按 F 重新启动，舵面仍可滑翔。")
	return engine_running


func toggle_engine() -> bool:
	return set_engine(not engine_running)


func set_piloted(value: bool, who: Player = null) -> void:
	piloted = value
	rider = who if value else null
	if value:
		# 登机：满油 + 襟翼回 0 档（D-034 Phase A：油是「这一程」的资源；
		# 避免「上飞机就是 2 档」的困惑）。
		_refuel_full()
		_state.flaps = 0
		_flaps_moved = false
		return
	controls.throttle = 0.0
	controls.pitch = 0.0
	controls.roll = 0.0
	controls.yaw = 0.0
	engine_running = false
	_state.flaps = 0
	_stick = Vector2.ZERO
	_touch_active = false
	_touch_pitch = 0.0
	_touch_roll = 0.0
	_touch_yaw = 0.0
	_touch_throttle = 0.0
	_touch_brake = false


func _physics_process(delta: float) -> void:
	if _wrecked:
		# 残骸继续受重力坠落并滑动（P2-10）：原来直接 return——velocity 已在
		# wreck 置零，空中解体的残骸悬停 4 秒等消散，违反直觉。撞地即由 floor
		# 支撑停住，消散计时照常。气动/输入/跟踪全部停摆（残骸不飞行）。
		velocity += Vector3.DOWN * AircraftFlight.GRAVITY * delta
		move_and_slide()
		_state.position = global_position
		return

	_prepare_input(delta)
	_update_fuel(delta)
	if _level_timer > 0.0:
		_level_timer = maxf(_level_timer - delta, 0.0)
	var on_ground := is_on_floor()
	# 辅助稳定增益（FlightSettings 单例）；无设置/关闭档即纯气动模型。
	var assist := FlightSettings.current().gains()
	AircraftFlight.integrate(_state, controls, delta, on_ground, assist, _level_timer)
	_sync_livery()
	if on_ground:
		_apply_ground_forces(delta)

	# 姿态搬进场景（D-048）：纯逻辑层每帧重算 _state.basis，而节点位姿历来只在
	# place() 时写过一次——相机、座舱仪表、驾驶座、轨迹录制、流式窗口方向全读
	# global_transform，于是飞机「会转弯但不转身」：模型坡度 45° 时仪表恒 0°、
	# 第一人称视角永不随机头转、回放残影永不歪。这里把姿态补搬进节点；碰撞盒
	# 不跟转（见 _pin_collider），起降物理与修复前逐字节一致。
	global_transform = Transform3D(_state.basis, global_position)
	_pin_collider()

	# 撞击检测：比对 move_and_slide 前后的速度损失（硬着陆与撞墙同源）。
	var before := _state.velocity
	velocity = before
	move_and_slide()
	var impact := (velocity - before).length()
	_state.velocity = velocity
	_state.position = global_position
	if is_on_floor():
		# 触地帧真实垂直速度先存（下面抹零）：U-7 落地评分要的是「砸下来
		# 那一下」的速度，抹零后读恒 0，软硬着陆将无法区分。
		if _state.velocity.y < 0.0:
			_last_touchdown_vs = _state.velocity.y
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


## 碰撞盒钉回世界轴向（D-048）：整机盒 15.6 × 6.6 × 4.8 m 若随机体姿态旋转，
## 地面 12° 抬头（机轮限位内）就会把机尾埋进地面约 1.5 m、低空 20° 坡度把
## 翼尖埋约 1 m——move_and_slide 的分离速度会超过解体阈值 Δv 7 m/s，每次起飞/
## 降落都变成坠毁。故姿态旋转只作用于外观与读 global_transform 的下游（相机/
## 仪表/座位/录制/回放/流式窗口），碰撞盒恒定世界水平：起降物理与「机体不转」
## 的历史行为逐字节一致（flight_probe 起降/巡航段断言的前提）。残骸翻倒不钉——
## 那是演出，摔到哪算哪。
func _pin_collider() -> void:
	if _collider != null:
		_collider.global_transform = Transform3D(
			Basis.IDENTITY, global_position + COLLIDER_CENTER)


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
	# 首物理帧守卫：此处 on_ground 读自 move_and_slide() 之前，刚 add_child 的
	# CharacterBody3D 首帧恒为 false（与落位高度无关）。不能据此判「刚离地/刚触地」，
	# 否则每架新落位飞机都会凭空多发一次 aircraft_took_off。故首帧只把基准态
	# 同步为当帧地面态并跳过本帧跳变派发；油耗/气动/里程首帧均为零量，从下一帧起算。
	if not _ground_synced:
		_ground_synced = true
		_was_on_floor = on_ground
		if on_ground:
			_altitude_agl = 0.0
		return
	if not on_ground and _was_on_floor:
		# 起飞：本次飞行的里程碑从零起算（落地下次再飞可重新达成）。
		Events.aircraft_took_off.emit()
		_alt_milestone = 0.0
		_dist_milestone = 0.0
	# 触地边沿（U-7）：上帧空中、本帧着地——记下砸下来那一下的速度（帧首
	# 已捕获的抹零前真值），开始等停稳结算。wreck 路径不进来（残骸分支提前
	# return），摔烂不算「降落」。
	if on_ground and not _was_on_floor and not _landing_pending:
		_landing_pending = true
		_landing_vs = _last_touchdown_vs
		_landing_timer = 0.0
		_landing_roll_dist = 0.0
	_was_on_floor = on_ground

	if on_ground:
		_altitude_agl = 0.0
		_update_landing_score(delta)
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


## 落地评分结算（U-7）：滑跑期间累计水平距离，停稳（≤LANDING_STOP_MPS）或
## 超时（LANDING_ROLL_TIMEOUT）时按 LandingQuality 三项连续打分并广播。
## 落点评分传 −1（无参照区）：自由飞没有「标准落点」，中性分不奖不罚；
## 有降落区参照的任务场景由 MissionManager 用自己的 zone_center 结算。
func _update_landing_score(delta: float) -> void:
	if not _landing_pending:
		return
	_landing_timer += delta
	var horiz := Vector2(_state.velocity.x, _state.velocity.z).length()
	_landing_roll_dist += horiz * delta
	if horiz > LANDING_STOP_MPS and _landing_timer < LANDING_ROLL_TIMEOUT:
		return
	var result := LandingQuality.score(
		_landing_vs, -1.0, horiz * AircraftFlight.MPS_TO_KMH)
	result["roll_distance"] = _landing_roll_dist
	Events.aircraft_landed.emit(result)
	Events.notice.emit(LandingQuality.summary(result))
	_landing_pending = false


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
		controls.throttle = _touch_throttle if engine_running else 0.0
		controls.brake = _touch_brake
		return

	# 自动改平进行中：杆量快速回中，让位给 integrate 的摆平增益（否则鼠标
	# 杆量会把改平指令抵掉）。玩家重新移动鼠标即刻接管（_stick 又被写回）。
	var center_rate := STICK_CENTER_RATE
	if _level_timer > 0.0:
		center_rate = 6.0
	_stick = _stick.lerp(Vector2.ZERO, clampf(center_rate * delta, 0.0, 1.0))
	var kbd_pitch := Input.get_axis("aircraft_pitch_down", "aircraft_pitch_up")
	var kbd_roll := Input.get_axis("aircraft_roll_left", "aircraft_roll_right")
	# 空格 / Ctrl 在飞行上下文里重新定义（儿童友好的「上升 / 下降」）：
	# 地面时空格仍是机轮刹车；离地后空格=拉升、Ctrl=推杆下降。
	var on_floor := is_on_floor()
	var climb_cmd := 1.0 if Input.is_action_pressed("jump") and not on_floor else 0.0
	var descend_cmd := 1.0 if Input.is_action_pressed("fly_down") and not on_floor else 0.0
	controls.pitch = clampf(-_stick.y + kbd_pitch + climb_cmd - descend_cmd, -1.0, 1.0)
	controls.roll = clampf(_stick.x + kbd_roll, -1.0, 1.0)
	controls.yaw = Input.get_axis("move_left", "move_right")
	controls.brake = Input.is_action_pressed("jump") and on_floor
	var throttle_axis := Input.get_axis("move_back", "move_forward")
	# Shift 空中加速：油门快速推满（地面无效——玩家在机上，sprint 无冲突）。
	var boost := Input.is_action_pressed("sprint") and not on_floor
	# 发动机熄火：油门锁 0、无推力；舵面照常（上面已写入），滑翔仍可操纵。
	if not engine_running:
		controls.throttle = 0.0
		return
	controls.throttle = clampf(
		controls.throttle + throttle_axis * THROTTLE_RATE * delta, 0.0, 1.0)
	if boost:
		controls.throttle = clampf(
			controls.throttle + BOOST_RATE * delta, 0.0, 1.0)


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
		# 带上坠机原因（D-056）：生还时 Main 的自动归位提示要说清「为什么坠」
		ejected.exit_aircraft(CRASH_DAMAGE, reason)
	# 残骸：向一侧翻倒即完成演出（P2-10：坠落交给 _physics_process 的
	# _wrecked 分支——物理重力；原 tween 还带动 position 下沉 0.35 m，
	# 与物理坠落互相打架，故只保留翻倒）。
	var tween := create_tween()
	tween.tween_property(self, "rotation:z", 0.9, 0.6).set_trans(Tween.TRANS_BOUNCE)
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
