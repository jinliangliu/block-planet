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
## - 座舱内鼠标 = 驾驶员环顾（D-070，持久：视线停在落下的地方，回正只归
##   鼠标中键 / 下次登机）；自由观察松手自动回正（FlightSettings.auto_recenter 可关）；
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
## 环顾偏航限幅（rad ≈ 137°，D-070）：座舱里这是「驾驶员的头」不是「绕飞机
## 的轨道相机」——能回头看同侧机翼与座舱壁，但不该原地整圈自转（超过 ±90°
## 后 up 仍取机体 UP，画面会越来越别扭）。座舱内鼠标环顾与自由观察共用。
const LOOK_YAW_LIMIT := 2.4
## 松手自动回正速率（1/s）：τ ≈ 0.4 s。
const RECENTER_RATE := 2.5
# ── 抖动 ─────────────────────────────────────────────────────
## 抖动幅度（m）与频率基数：**外部视角**的满幅；座舱内视再乘 COCKPIT_SHAKE_SCALE。
## 实际缩放量由 Aircraft.shake_envelope()（0..1）给出——旧版只用油门，那句
## 「按油门/空速缩放」的注释从来没在代码里兑现过（D-075 补回）。
## D-097 只把座舱内视这一路收敛为 0；外部视角抖动完全不变。
const SHAKE_AMP := 0.05
## 座舱内视位置抖动收敛为 0（D-097，2026-11-13，用户裁决「座舱内关抖」）。
## 根因：_apply_shake() 在相机 global_position 吸附到眼位之后
## 才叠加机体系位置噪声；3D A 柱（scripts/flight/cockpit_interior.gd）挂在
## Aircraft 下、原点=眼位、与机体刚性，不随相机抖——相机一动，相对位移全落在
## 近距硬边上。A 柱底端距眼位约 0.48 m（近距透视 ≈863 px/m），0.030 m 峰值被
## 放大成三连拍实测内缘 ±9~12 px 跳动，4.7~13.2 Hz 正落在硬边闪动敏感区，即
## 用户投诉的红圈闪边。D-075 只修了「抖动包络」（怠速不再抖），没回答「座舱内
## 视该不该抖」；0.40 是妥协产物，其自身注释就写着「真人把头靠在头枕上时看到
## 的仪表台是不抖的」。而 cockpit_shake_probe.gd 把该乘子排除在契约外（探针盲
## 点），故 D-075 全绿与投诉共存。发动机存在感自 D-075 起已交给 CockpitInterior
## 的杆手微颤（TREMOR_AMP / BUMP_AMP），不靠镜头位移。据此置 0.0，彻底收敛。
const COCKPIT_SHAKE_SCALE := 0.0
## 座舱内视**沿视线（机体系 −Z）分量**的再衰减：旧版 0.075 m / 0.702 m = ±10.7%
## 的深度涨落会让仪表台「忽大忽小」±57 px——呼吸比平移更廉价，故单独再打五折。
## 注：COCKPIT_SHAKE_SCALE 归零后 amp=0，本分量实际不再生效（不再有深度涨落）；
## 按 D-097「其余全不动」裁决保留 0.50，勿误以为座舱内仍有轴向呼吸。
const COCKPIT_SHAKE_AXIAL := 0.50
## 包络平滑速率（1/s，τ ≈ 0.33 s）：开关发动机、接地、进出风切变都不许突变——
## 旧版是布尔门，一帧之内从 0 跳到满幅，那个「啪」本身就很廉价。
const SHAKE_GAIN_RATE := 3.0
## 包络低于此值直接跳过 6 个 sin（中低端安卓上省一点算一点）。
const SHAKE_GAIN_EPS := 0.002

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
## 当前抖动包络（0..1，已按 SHAKE_GAIN_RATE 平滑）：发动机启停、接地、进出风切变
## 都不做开关式突变。熄火或关设置时**立即**归零（防晕动症开关要一键到底，不淡出）。
var _shake_gain := 0.0
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
	apply_cockpit_interior()


## 座舱内视联动（D-050）：第一人称（含以座舱为底层的自由观察）隐藏机体
## 外观——相机眼位在机身盒内部，机翼正压视平线，不隐藏的话「第一人称」
## 看到的先是自己的机翼再是世界（用户实测截图：机翼横贯全屏）。座舱内饰
## 由 2D 像素座舱框 + 仪表簇提供（cockpit_instruments.gd 的 _draw）。
## 所有模式切换都经 set_mode；装配/激活各同步一次，覆盖登机与下机旁路。
## 公开：main 在「相机激活后才挂上机体的晚到者」（座舱 3D 面板/内装）装载后
## 补调一次，把晚到者纳入同一份规则。
func apply_cockpit_interior() -> void:
	_set_exterior_hidden(is_cockpit_view())


## 当前是否「座舱内视」：第一人称，或以第一人称为底层的自由观察。
## 提成公开谓词是为了一处定义两处用——机体外观显隐与座舱相机前馈（L2 对齐）
## 必须基于同一个事实，否则「面板藏着但相机已经按座舱处理」这类错配查不出来。
func is_cockpit_view() -> bool:
	return _mode == ViewMode.FIRST_PERSON or (
		_mode == ViewMode.FREE_LOOK and _base_mode == ViewMode.FIRST_PERSON)


## 按「是否座舱内视」同步机体外观与座舱 3D 内装。只切 visible：碰撞、气动、
## 录制、逻辑不受影响。
## 座舱 3D 面板（D-034）**不再经这里**：L2 反转后它在第一人称也要显示（正视时
## 与 2D 簇重合），只剩「蓝图机无座舱罩」这一个闸门，由面板自己的 setup 收敛。
## 3D 内装（L1/L3）则在这里驱动，且**极性相反**（内视=true 时显示）——差异写在
## CockpitInterior.set_interior_view 里，这一层只管把「是否座舱内视」发下去。
func _set_exterior_hidden(hidden: bool) -> void:
	if not is_instance_valid(_craft):
		return
	_craft.set_cockpit_interior(hidden)
	for child: Node in _craft.get_children():
		# 鸭子型而非 `is CockpitInterior`：新增 class_name 后若类缓存没重扫，
		# 这里会在编译期报「标识符未声明」，把整条飞行相机链路一起带塌
		# （项目踩过：新增 class_name 后 headless 报未声明，须重扫类缓存）。
		# has_method + call 也不依赖装配顺序：内装是登机后才挂的晚到者。
		if child.has_method("set_interior_view"):
			child.call("set_interior_view", hidden)


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
	if active:
		apply_cockpit_interior()
	else:
		# 下机：机体外观必须恢复——飞机仍停在场上，隐藏着会变「幽灵飞机」。
		_set_exterior_hidden(false)


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
	apply_cockpit_interior()


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


## 鼠标 / 右摇杆环顾增量。D-070 起座舱内视（第一人称）也接受——座舱里
## 鼠标就是驾驶员的视线；自由观察（FREE_LOOK 覆盖层）同样走这里。两者
## 共用同一组偏移，符号约定一致：鼠标右移 → 视野右转，鼠标上移 → 抬头。
func apply_look_delta(delta: Vector2) -> void:
	if _mode != ViewMode.FREE_LOOK and _mode != ViewMode.FIRST_PERSON:
		return
	_look_yaw = clampf(_look_yaw + delta.x * LOOK_SENS, -LOOK_YAW_LIMIT, LOOK_YAW_LIMIT)
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
	# 环顾回正：只对**非座舱模式**（追尾/后视/地图）按设置把偏移指数归零——
	# 从座舱经覆盖层攒下的偏移，切回普通视角时回正，避免「视线被上次飞行
	# 锁定」。座舱内视**不回正**（D-070）：鼠标就是驾驶员的视线，gaze 应当
	# 停在落下的地方；回正交给鼠标中键（recenter）与下次登机
	# （reset_to_cockpit）。auto_recenter 只管「松手」——即 V / 按住右键的
	# 自由观察覆盖层退出那一刻（见 set_free_look）。
	if _mode != ViewMode.FREE_LOOK and not is_cockpit_view() and _auto_recenter:
		_look_yaw = _damp(_look_yaw, 0.0, RECENTER_RATE, delta)
		_look_pitch = _damp(_look_pitch, 0.0, RECENTER_RATE, delta)
	var target := _target_transform(_mode)
	_update_occlusion(delta, target)
	# 座舱内视：位置**直接吸附**到眼位，不走阻尼（L2 对齐的硬前提）。
	# 阻尼对匀速目标有稳态滞后 = v/rate，`rate` 在距目标超过 TRANSITION_DIST 时
	# 跌到 RATE_FAR=4 —— 实测 50 m/s 巡航稳定滞后 12.09 m、55 m/s 13.30 m
	# （600 帧数值模拟）。3D 仪表台距眼只有 0.85 m，滞后十几米会把面板投影缩到
	# 1/14 并甩到画面中部，「与 2D 簇重合」在数学上就不可能。
	# 先试过「按机体速度前馈一帧位移」：不够——无头环境下 _process 只有约 20~30 Hz
	# （物理 60 Hz），前馈按 process 帧补位移与物理帧错拍，残余仍有 4 m 量级的锯齿。
	# 根子上就不该给座舱加位移阻尼：真人把头靠在头枕上，眼位与机体是**刚性**关系，
	# 阻尼只会让座舱在世界里漂。姿态仍走 slerp（旋转平滑是舒适度需要，与位置无关）。
	# 这个缺陷 D-050 起就存在：整机外观在座舱里被隐藏，玩家看不出自己其实是从座舱
	# 后方十几米处看世界；2D 读数又是屏幕空间的，所以一直没暴露。
	if is_cockpit_view():
		global_position = target.origin
	else:
		var dist := global_position.distance_to(target.origin)
		var rate := lerpf(RATE_FAR, RATE_NEAR, clampf(1.0 - dist / TRANSITION_DIST, 0.0, 1.0))
		global_position = global_position.lerp(target.origin, _damp_rate(rate, delta))
	global_transform.basis = Basis(
		Quaternion(global_transform.basis).slerp(Quaternion(target.basis), _damp_rate(RATE_ROT, delta)))
	fov = _damp(fov, _mode_fov(), RATE_FOV, delta)
	_apply_shake(delta)


## 座舱视线方向（未归一，looking_at 只用方向）：机头 + 天地线抬升，再叠
## 环顾偏移。D-070 起第一人称也接受鼠标环顾，与座舱底自由观察共用本条
## 式子——偏移为零时逐位退回 D-050 的原方向（nose×10 + UP×1.1）。
## 偏航符号与玩家徒步视角一致（player.gd 的 rotate_y(-delta.x)）：鼠标右移
## → 视野朝机体局部 +X（右）转；俯仰正向 = 抬头（绕机体 RIGHT）。
func _cockpit_look_dir(craft_basis: Basis, nose: Vector3) -> Vector3:
	var dir := nose + (craft_basis * Vector3.UP) * (COCKPIT_LOOK_UP / 10.0)
	if is_zero_approx(_look_yaw) and is_zero_approx(_look_pitch):
		return dir
	return Basis(craft_basis * Vector3.UP, -_look_yaw) \
		* Basis(craft_basis * Vector3.RIGHT, _look_pitch) * dir


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
			var look := eye + _cockpit_look_dir(craft_basis, nose) * 10.0
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
				# 座舱内环顾：与第一人称同一条视线式子（D-070 统一，含天地线
				# 抬升）——偏移为零时自由观察与座舱视角完全重合，覆盖层只是
				# 「多一个 V / 按住右键的入口 + 松手回正」，不再有视线差。
				var eye2: Vector3 = craft_xform * COCKPIT_OFFSET
				xf.origin = eye2
				var look2 := eye2 + _cockpit_look_dir(craft_basis, nose) * 10.0
				xf = xf.looking_at(look2, craft_basis * Vector3.UP)
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


## 镜头抖动：幅度由 Aircraft.shake_envelope() 调制的微量平移噪声，座舱内视再乘
## COCKPIT_SHAKE_SCALE。在阻尼之后的最终位姿上叠加，不参与下一帧阻尼（座舱模式
## 每帧硬吸附，本来就不会累积）。
##
## 旧版门控只有 `engine_running` + `0.25 + 0.75*throttle`，等于「发动机一转就以
## 恒定幅度抖到底」——停放、滑行、巡航、俯冲四种状态看不出区别，这就是用户报的
## 「一直在抖」（D-075）。现在幅度改由飞行状态驱动：收油门 0、巡航约 0.09（座舱
## ≈1.6 px，不可见）、起飞滑跑/接地颠簸/失速抖振/风切变才明显。满幅上界不变
## （包络钳在 1.0 ⇒ 单轴峰值恒 ≤0.075 m）。
func _apply_shake(delta: float) -> void:
	if not camera_shake_enabled or not is_instance_valid(_craft) or not _craft.engine_running:
		# 关设置 / 熄火：立即归零，不淡出（防晕动症开关要的就是一键到底）。
		_shake_gain = 0.0
		return
	_shake_gain = _damp(_shake_gain, _craft.shake_envelope(), SHAKE_GAIN_RATE, delta)
	if _shake_gain < SHAKE_GAIN_EPS:
		return
	_shake_t += delta
	var t := _shake_t
	var amp := SHAKE_AMP * _shake_gain
	var axial := 1.0
	if is_cockpit_view():
		amp *= COCKPIT_SHAKE_SCALE
		axial = COCKPIT_SHAKE_AXIAL
	# 机体系而不是世界系：发动机装在机体上，抖动方向必须随姿态转——旧版直接加世界
	# Vector3，盘旋 60° 坡度时所谓「竖直」其实沿着机翼，滚转中还多出一段莫名的
	# 平移。机体系 −Z 即机头 ≈ 视线方向，故 axial 就是「沿视线分量」的折扣。
	global_position += _craft.global_transform.basis * Vector3(
		(sin(t * 37.1) + 0.5 * sin(t * 71.3)) * amp,
		(sin(t * 53.7) + 0.5 * sin(t * 83.1)) * amp,
		(sin(t * 29.3) + 0.5 * sin(t * 61.9)) * amp * axial)


## 指数阻尼步长（帧率无关）：1 − e^(−rate·dt)。
func _damp_rate(rate: float, delta: float) -> float:
	return 1.0 - exp(-rate * delta)


func _damp(current: float, target: float, rate: float, delta: float) -> float:
	return lerpf(current, target, _damp_rate(rate, delta))
