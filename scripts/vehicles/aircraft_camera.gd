class_name AircraftCamera
extends Camera3D
## 飞行视角 rig（D-033）：第一人称座舱 / 第三人称追尾 / 后视 / 自由观察 /
## 战术俯视（MAP）/ 回放（REPLAY）。
##
## 场景级独立节点（main 装配，不是飞机子节点）：每帧按机体 Transform3D 计算
## 目标位姿，再以「距离自适应速率」的指数阻尼逼近——远距慢移（模式切换柔和
## 过渡）、近距快跟（高速飞行不拖影），且指数阻尼永不过冲，杜绝瞬移。
##
## 儿童友好（dylan 2026-10-15 定稿）：
## - 默认追尾 13 m / FOV 75°（比旧弹簧臂 9 m / 70° 更远更宽）；
## - 追尾与后视抑制滚转，地平线保持稳定（防晕）；
## - 自由观察松手自动回正（FlightSettings.auto_recenter 可关）；
## - 镜头抖动微量且可关（FlightSettings.camera_shake）；
## - 追尾/后视射线防穿模（被地形挡住时自动拉近）。
##
## 自驱动：_process 内部完成全部更新，集成方只需 setup / set_active /
## set_mode / set_free_look / zoom / set_replay_transform。REPLAY 模式下
## 相机位姿由 FlightReplay 直写，本类不覆盖。

enum ViewMode { FIRST_PERSON, CHASE, REAR, FREE_LOOK, MAP, REPLAY }

## 视角切换时广播（HUD 视角指示灯监听）。
signal view_mode_changed(mode: ViewMode)

# ── 座舱（第一人称）──────────────────────────────────────────
## 座舱眼位（机体局部坐标；机头为局部 −Z）。与 SEAT_OFFSET 同族：
## 眼位落在座舱罩内，第一人称才是「坐在舱里」。
const COCKPIT_OFFSET := Vector3(0.0, 1.15, -3.4)
## 座舱视线在机头上仰基础上再抬升的量（m @ 10 m 前视），看得见前方天地线。
const COCKPIT_LOOK_UP := 1.1
# ── 追尾（第三人称）──────────────────────────────────────────
## 默认追尾距离（m）：比旧弹簧臂 9 m 远，机体不糊满屏（dylan 要求「稍远、视野更宽」）。
const CHASE_DISTANCE_DEFAULT := 13.0
const CHASE_DISTANCE_MIN := 8.0
const CHASE_DISTANCE_MAX := 20.0
const CHASE_HEIGHT := 4.5
## 追尾视线前视 lead（m）：看向机体前方一点，转弯时更有方向感。
const CHASE_LEAD := 2.0
# ── 后视 ─────────────────────────────────────────────────────
const REAR_DISTANCE := 7.0
const REAR_HEIGHT := 2.6
# ── 战术俯视（MAP）───────────────────────────────────────────
const MAP_HEIGHT_DEFAULT := 60.0
const MAP_HEIGHT_MIN := 20.0
const MAP_HEIGHT_MAX := 120.0
# ── 阻尼速率（1/s，指数阻尼的时间常数倒数）──────────────────
## 远距（模式切换大位移）速率：τ ≈ 0.25 s，柔和过渡不瞬移。
const RATE_FAR := 4.0
## 近距（跟随机体）速率：τ ≈ 0.04 s，55 m/s 全速也只拖影约 2 m。
const RATE_NEAR := 25.0
## 远/近速率的过渡距离阈值（m）：距目标小于此值按近距速率跟。
const TRANSITION_DIST := 2.0
const RATE_ROT := 10.0
const RATE_FOV := 3.3
## 自由观察灵敏度（rad/px）。
const LOOK_SENS := 0.0025
const LOOK_PITCH_LIMIT := 1.1
## 松手自动回正速率（1/s）：τ ≈ 0.4 s。
const RECENTER_RATE := 2.5
# ── 抖动 ─────────────────────────────────────────────────────
## 抖动幅度（m）与频率基数：发动机运转时按油门/空速缩放的微量平移噪声。
const SHAKE_AMP := 0.05

var _craft: Aircraft = null
var _player: Node3D = null
var _active := false
var _mode: ViewMode = ViewMode.CHASE
## 底层模式（只有 FIRST_PERSON / CHASE）：后视 / 自由观察 / 地图都是
## 覆盖层，退出时回到它。
var _base_mode: ViewMode = ViewMode.CHASE
## 自由观察球面偏移（rad）。
var _look_yaw := 0.0
var _look_pitch := 0.0
## 追尾距离 / 地图高度（滚轮可调）。
var chase_distance := CHASE_DISTANCE_DEFAULT
var map_height := MAP_HEIGHT_DEFAULT
## 镜头抖动开关（FlightSettings.camera_shake 每帧同步）。
var camera_shake_enabled := true
var _auto_recenter := true
var _shake_t := 0.0
## 复用的射线查询（禁止每帧 new 分配；10 Hz 节流，见 _update_occlusion）。
var _ray_query := PhysicsRayQueryParameters3D.new()
var _ray_exclude: Array = []
var _occl_timer := 0.0
## 防穿模缓存（m）：≥0 = 命中时机体到相机的允许距离；-1 = 无命中（不拉近）。
var _occl_dist := -1.0
## 防穿模刷新间隔（s）：相机被地形遮挡是低频事件，10 Hz 足够。
const OCCLUSION_INTERVAL := 0.1


func setup(craft: Aircraft, player: Node3D) -> void:
	_craft = craft
	_player = player
	fov = FOV_FLIGHT
	_ray_query.collide_with_areas = false
	_ray_query.collide_with_bodies = true
	_ray_exclude = [craft.get_rid()]
	if is_instance_valid(player):
		_ray_exclude.append(player.get_rid())
	_ray_query.exclude = _ray_exclude
	# 首次落位直接吸附目标，避免从世界原点飞入。
	if is_instance_valid(_craft):
		var target := _target_transform(_mode)
		global_position = target.origin
		global_transform.basis = target.basis


func set_active(active: bool) -> void:
	if active == _active:
		return
	_active = active
	current = active
	set_process(active)
	if active and is_instance_valid(_craft):
		# 重新激活时吸附到目标：不活跃期间机体可能已大幅机动。
		var target := _target_transform(_mode)
		global_position = target.origin
		global_transform.basis = target.basis


func is_active() -> bool:
	return _active


func current_mode() -> ViewMode:
	return _mode


## 设置模式。REPLAY 由回放系统经 set_replay_transform 驱动，此处只切状态。
func set_mode(mode: ViewMode) -> void:
	if mode == _mode:
		return
	_mode = mode
	view_mode_changed.emit(mode)


## 登机默认视角（D-049）：每次登机复位到第一人称座舱——「默认登机后进入
## 第一人称视角，界面突出座舱驾驶界面」。必须同时写 _mode 与 _base_mode：
## 后视/自由观察/地图都是覆盖层，退出时 set_mode(_base_mode) 会掀回底层
## 模式，只写 _mode 的话覆盖层一退就弹回追尾。自由观察偏移一并清零——
## 新登机不该继承上一次飞行攒下的环顾角度。
func reset_to_cockpit() -> void:
	_base_mode = ViewMode.FIRST_PERSON
	_look_yaw = 0.0
	_look_pitch = 0.0
	if _mode != ViewMode.FIRST_PERSON:
		set_mode(ViewMode.FIRST_PERSON)


## C 键：第一 / 第三人称互切（任何覆盖层模式下也会退出覆盖层）。
func toggle_first_third() -> void:
	if _mode == ViewMode.REPLAY:
		return
	_base_mode = ViewMode.CHASE if _base_mode == ViewMode.FIRST_PERSON else ViewMode.FIRST_PERSON
	set_mode(_base_mode)


## R 键：后视开 / 关（关时回到底层模式）。
func toggle_rear() -> void:
	if _mode == ViewMode.REPLAY:
		return
	if _mode == ViewMode.REAR:
		set_mode(_base_mode)
	else:
		set_mode(ViewMode.REAR)


## V 键 / 按住右键：自由观察开 / 关（关时回到底层模式并按设置回正）。
func set_free_look(active: bool) -> void:
	if active:
		if _mode == ViewMode.REPLAY:
			return
		set_mode(ViewMode.FREE_LOOK)
	else:
		if _mode == ViewMode.FREE_LOOK:
			set_mode(_base_mode)
		if not _auto_recenter:
			# 关闭回正：保留当前环顾角度，下次自由观察从此继续。
			return
		_look_yaw = 0.0
		_look_pitch = 0.0


## M 键（HUD 战术地图）：俯视开 / 关（关时回到底层模式）。
func set_map_view(on: bool) -> void:
	if _mode == ViewMode.REPLAY:
		return
	if on:
		set_mode(ViewMode.MAP)
	else:
		set_mode(_base_mode)


## 回放结束：退出 REPLAY 回到底层模式（集成方在 replay_finished 时调用）。
func exit_replay() -> void:
	if _mode == ViewMode.REPLAY:
		set_mode(_base_mode)


## 鼠标 / 右摇杆环顾增量（仅 FREE_LOOK 生效）。
func apply_look_delta(delta: Vector2) -> void:
	if _mode != ViewMode.FREE_LOOK:
		return
	_look_yaw += delta.x * LOOK_SENS
	_look_pitch = clampf(_look_pitch - delta.y * LOOK_SENS, -LOOK_PITCH_LIMIT, LOOK_PITCH_LIMIT)


## 滚轮缩放：MAP 调高度、CHASE 调距离；其余模式忽略。
func zoom(delta: float) -> void:
	if _mode == ViewMode.MAP:
		map_height = clampf(map_height - delta * 4.0, MAP_HEIGHT_MIN, MAP_HEIGHT_MAX)
	elif _mode == ViewMode.CHASE:
		chase_distance = clampf(chase_distance + delta * 0.8, CHASE_DISTANCE_MIN, CHASE_DISTANCE_MAX)


## 视角回正（D-034 鼠标中键）：清除环顾偏移、追尾距离与地图高度归默认。
## 自由观察松手本就会自动回正（auto_recenter），本入口给「一键归位」用。
func recenter() -> void:
	_look_yaw = 0.0
	_look_pitch = 0.0
	chase_distance = CHASE_DISTANCE_DEFAULT
	map_height = MAP_HEIGHT_DEFAULT


## 回放系统直写相机位姿（REPLAY 模式，无阻尼）。
func set_replay_transform(xform: Transform3D) -> void:
	global_transform = xform


func _process(delta: float) -> void:
	if not _active or not is_instance_valid(_craft):
		return
	_auto_recenter = FlightSettings.current().auto_recenter
	camera_shake_enabled = FlightSettings.current().camera_shake
	if _mode == ViewMode.REPLAY:
		return   # 位姿由回放系统直写
	# 自由观察回正：松手后按设置把偏移指数归零。
	if _mode != ViewMode.FREE_LOOK and _auto_recenter:
		_look_yaw = _damp(_look_yaw, 0.0, RECENTER_RATE, delta)
		_look_pitch = _damp(_look_pitch, 0.0, RECENTER_RATE, delta)
	var target := _target_transform(_mode)
	_update_occlusion(delta, target)
	var dist := global_position.distance_to(target.origin)
	var rate := lerpf(RATE_FAR, RATE_NEAR, clampf(1.0 - dist / TRANSITION_DIST, 0.0, 1.0))
	global_position = global_position.lerp(target.origin, _damp_rate(rate, delta))
	global_transform.basis = Basis(
		Quaternion(global_transform.basis).slerp(Quaternion(target.basis), _damp_rate(RATE_ROT, delta)))
	fov = _damp(fov, _mode_fov(), RATE_FOV, delta)
	_apply_shake(delta)


## 各模式目标位姿（世界坐标，无阻尼的「虚拟 rig」）。
func _target_transform(mode: ViewMode) -> Transform3D:
	var craft_xform := _craft.global_transform
	var craft_basis := craft_xform.basis
	# 机头方向（局部 −Z）与仅偏航的对齐基（抑制滚转 / 俯仰，地平线稳定）。
	var nose: Vector3 = craft_basis * Vector3(0.0, 0.0, -1.0)
	var yaw := atan2(nose.x, nose.z)
	var leveled := Basis(Vector3.UP, yaw)
	var xf := Transform3D()
	match mode:
		ViewMode.FIRST_PERSON:
			var eye: Vector3 = craft_xform * COCKPIT_OFFSET
			xf.origin = eye
			var look := eye + nose * 10.0 + (craft_basis * Vector3.UP) * COCKPIT_LOOK_UP
			xf = xf.looking_at(look, craft_basis * Vector3.UP)
		ViewMode.CHASE:
			# leveled 基 +Z = 机头方向（Basis(UP, atan2(nose.x, nose.z)) 的性质），
			# 故追尾相机在机体后方：偏移取 −Z。
			var offset := leveled * Vector3(0.0, CHASE_HEIGHT, -chase_distance)
			xf.origin = craft_xform.origin + offset
			xf = xf.looking_at(
				craft_xform.origin + nose * CHASE_LEAD, Vector3.UP)
		ViewMode.REAR:
			# 后视（后视镜式）：相机在机头前方，回头拍机体与机尾方向。
			xf.origin = craft_xform.origin + leveled * Vector3(0.0, REAR_HEIGHT, REAR_DISTANCE)
			xf = xf.looking_at(craft_xform.origin, Vector3.UP)
		ViewMode.FREE_LOOK:
			if _base_mode == ViewMode.FIRST_PERSON:
				var eye2: Vector3 = craft_xform * COCKPIT_OFFSET
				xf.origin = eye2
				# 座舱内环顾：偏航符号与玩家鼠标视角一致（player.gd
				# rotate_y(-delta.x)）——鼠标右移 → 视野朝机体局部 +X（右）转。
				var dir := (Basis(craft_basis * Vector3.UP, -_look_yaw)
					* Basis(craft_basis * Vector3.RIGHT, _look_pitch)) * nose
				xf = xf.looking_at(eye2 + dir * 10.0, craft_basis * Vector3.UP)
			else:
				# 追尾自由观察：相机绕机体球面环顾，仍看向机体。
				# 默认位（偏航 0）在机体正后；偏航正向 = 相机移向机体左侧
				# （ leveled +X = 机体局部 −X ），屏幕观感与第一人称一致：
				# 鼠标右移 → 视野右转 → 画面内容左移。
				# 俯仰正向 = 相机下沉、仰视机体（与玩家弹簧臂「鼠标上移=看上方」
				# 的观感一致）；贴地时禁止沉入地下（保留偏航环顾）。
				var el := clampf(_look_pitch, -1.2, 1.2)
				var dir2 := Vector3(sin(_look_yaw) * cos(el), -sin(el), -cos(_look_yaw) * cos(el))
				xf.origin = craft_xform.origin + leveled * dir2 * chase_distance \
					+ Vector3.UP * (CHASE_HEIGHT * 0.5)
				if is_instance_valid(_craft) and _craft.is_on_floor():
					xf.origin.y = maxf(xf.origin.y, craft_xform.origin.y + 0.6)
				xf = xf.looking_at(craft_xform.origin, Vector3.UP)
		ViewMode.MAP:
			xf.origin = craft_xform.origin + Vector3.UP * map_height
			# north-up：相机 +Y 对齐世界 +Z（本工程 +Z 即北）。
			# 注意 Godot 右手基的固有特性：俯视 north-up 时屏幕右向 = 世界 −X
			# （东在左、西在右）；若将来要 Cartographic 标准（东在右）需改用
			# up=(0,0,-1)（south-up）。战术地图面板（flight_tactical_map.gd）
			# 是 2D 自绘，不受此限。
			xf = xf.looking_at(xf.origin + Vector3.DOWN * 10.0, Vector3(0.0, 0.0, 1.0))
		_:
			# 同 CHASE：机体正后上方。
			xf.origin = craft_xform.origin + leveled * Vector3(0.0, CHASE_HEIGHT, -chase_distance)
			xf = xf.looking_at(craft_xform.origin, Vector3.UP)
	return xf


## 防穿模（10 Hz 节流）：机体重心射向相机目标位姿，命中则记录允许距离，
## 相机被拉到命中点前 0.5 m。FP / MAP / REPLAY 不做（座舱在机体内部、
## 地图在高空、回放直写）。节流期内沿用上次结果，避免每帧射线分配。
func _update_occlusion(delta: float, target: Transform3D) -> void:
	if _mode != ViewMode.CHASE and _mode != ViewMode.REAR and _mode != ViewMode.FREE_LOOK:
		_occl_dist = -1.0
		return
	if not is_instance_valid(_craft):
		return
	_occl_timer -= delta
	if _occl_timer > 0.0:
		_apply_occlusion_cache(target)
		return
	_occl_timer = OCCLUSION_INTERVAL
	var from := _craft.global_position
	var to := target.origin
	var span := from.distance_to(to)
	if span < 0.1:
		_occl_dist = -1.0
		return
	_ray_query.from = from
	_ray_query.to = to
	var hit := get_world_3d().direct_space_state.intersect_ray(_ray_query)
	if hit.is_empty():
		_occl_dist = -1.0
	else:
		_occl_dist = maxf(0.5, from.distance_to(hit["position"]) - 0.5)
	_apply_occlusion_cache(target)


## 按缓存的命中距离拉近相机目标位姿（无命中时不动）。
func _apply_occlusion_cache(target: Transform3D) -> void:
	if _occl_dist < 0.0 or not is_instance_valid(_craft):
		return
	var from := _craft.global_position
	var dir := target.origin - from
	var span := dir.length()
	if span <= _occl_dist or span < 0.1:
		return
	target.origin = from + dir.normalized() * _occl_dist


## 飞行视场：俯视战术地图 70°（要的是「图上比例稳定」），其余视角 82°。
## 75° → 82° 是 dylan「视场不够宽」的定量化落地：飞行需要的是周边感知——
## 地平线、侧向地标、进近跑道与目标点都要进画面，而徒步时 75° 的窄视场在
## 座舱里被仪表盘与舱框一挡就只剩一条缝。82° 仍是儿童友好的安全区间
## （≥90° 边缘拉伸明显，长时间注视容易累）。
const FOV_FLIGHT := 82.0
const FOV_MAP := 70.0


func _mode_fov() -> float:
	if _mode == ViewMode.MAP:
		return FOV_MAP
	return FOV_FLIGHT


## 镜头抖动：发动机运转时的微量平移噪声（幅度 < 8 cm，低频），可整项关闭。
## 在阻尼之后的最终位姿上叠加，不参与下一帧阻尼（不累积）。
func _apply_shake(delta: float) -> void:
	if not camera_shake_enabled or not is_instance_valid(_craft) or not _craft.engine_running:
		return
	_shake_t += delta
	var t := _shake_t
	var power := 0.25 + 0.75 * _craft.controls.throttle
	global_position += Vector3(
		sin(t * 37.1) + 0.5 * sin(t * 71.3),
		sin(t * 53.7) + 0.5 * sin(t * 83.1),
		sin(t * 29.3) + 0.5 * sin(t * 61.9)) * (SHAKE_AMP * power)


## 指数阻尼步长（帧率无关）：1 − e^(−rate·dt)。
func _damp_rate(rate: float, delta: float) -> float:
	return 1.0 - exp(-rate * delta)


func _damp(current: float, target: float, rate: float, delta: float) -> float:
	return lerpf(current, target, _damp_rate(rate, delta))
