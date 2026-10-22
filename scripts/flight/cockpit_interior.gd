class_name CockpitInterior
extends Node3D
## 第一人称 3D 座舱内装（L1 环绕框 + L2 仪表台承托 + L3 杆手生命感）。
##
## 为什么需要它：D-050 的第一人称是「隐藏整机外观 + 全屏 2D 像素座舱」，代价是
## 环顾时框不动、低头无物（横评 U-1/U-2）。本节点补的是「我坐在哪」这一层——
## 几何随相机产生视差、低头有仪表台与杆手；读数仍由 2D 簇与 CockpitPanel 提供，
## 单一数据链路（FlightInstruments）不变，2D 簇一个像素都不动（D-053 红线）。
##
## 为什么以眼位为原点：座舱眼位 (0, 1.15, -3.4) 落在不透明机身盒内部、比座舱罩
## 底面（y=1.335）还低 0.185 m（机模尺寸是按米写死的，1 格=1 m 的尺度重构不改它），
## 所以内装不能对着舱罩盒布，只能对着「眼睛」布：整棵树挂在眼位上，每个盒体的坐标
## 就是「相对眼睛多少米」，眼位若调整只改 setup() 里的一行 position。
##   出处：aircraft_camera.gd:29 COCKPIT_OFFSET = Vector3(0.0, 1.15, -3.4)。
##   注意：这里复制同一数值而没有写 AircraftCamera.COCKPIT_OFFSET，是因为
##   aircraft_camera.gd 的 _set_exterior_hidden 会对本类做 `child is CockpitInterior`
##   类型判定——两边互相引用会形成循环 class_name 依赖（GDScript 4 对循环依赖里的
##   常量引用会直接报 cyclic reference）。数值一致性由探针断言兜底。
##
## 为什么可见性极性与 CockpitPanel 相反：CockpitPanel 在座舱内视时隐藏（读数交给
## 2D 簇），内装恰恰相反——内视时才显示。两者由 aircraft_camera._set_exterior_hidden
## 的同一个子节点遍历循环驱动，靠各自的 set_interior_view 消化这层相反语义。
##
## 为什么 L3 自驱动而不回调 Aircraft：与 aircraft.gd 的 _animate_bp_surfaces 同帧域
## （都读 controls）、不必新增 Aircraft→内装 的反向依赖，舱机改动面保持为零。
##
## 性能（Mobile 渲染器 / 中低端 Android）：39 个 BoxMesh、9 个共享 StandardMaterial3D、
## cast_shadow 全关、无贴图无透明。draw call ≈ 盒体数（每 MeshInstance3D 一次），后续
## 可把静态盒按材质合并成 9 个 surface 再压到 9 次，本版不做（先保可读性）。

## 座舱眼位（机体局部，米）。必须与 aircraft_camera.gd:29 COCKPIT_OFFSET 一致。
const EYE := Vector3(0.0, 1.15, -3.4)
## L2 承托板相对面板的四周边距（米）：面板四周留一圈金属边，螺钉落在边上。
## 0.09 → 0.05 是第一轮窗口取证的结论：9 cm 边 + 0.40 m 板高在低头视角里读成
## 一整块黑板（板面 1.16×0.395 占满视线）。收到 5 cm 后板变 1.08×0.315，
## 仍是「面板嵌在板里」的观感，且板顶沿的屏幕位置从 527 px 落到 549 px
## （> 2D dash 上沿 538.67）——第一人称下整块承托板都藏进 2D dash 带内，
## 顺带消掉了「板沿随镜头抖动在 dash 上沿外呼吸」的残余风险。
const DASH_RIM := 0.05
## 承托板厚度（米）。
const DASH_THICK := 0.08
## 面板贴在承托板前方 2 cm（「面板在底板前方」的语义，同时避开共面 z-fighting）。
const DASH_GAP := 0.02
## 承托板中心在 Dash 局部的 z（局部 +Z = 面板法线方向 = 指向飞行员）。
const DASH_PLATE_Z := -(DASH_THICK * 0.5 + DASH_GAP)
## Dash 枢轴（眼位相对）：与 CockpitPanel 的面板中心、倾角同源，不重复写米数。
const DASH_POS := CockpitPanel.PANEL_POS - EYE
## 承托板尺寸：面板 + 四周边距。
const PLATE_SIZE := Vector3(
	CockpitPanel.PANEL_W + DASH_RIM * 2.0,
	CockpitPanel.PANEL_H + DASH_RIM * 2.0,
	DASH_THICK)
## 操纵杆枢轴（眼位相对，米）：两膝之间、地板之上，眼位前 0.40 m、下 1.31 m。
## 从 z=-0.55 后撤到 -0.40 是为了给杆加长腾出「不挡面板」的余量：眼→面板下沿
## 那条视线在杆处的高度随 z 变大而升高（斜率 0.707 m/m），后撤 15 cm 换来
## 11 cm 净空，才装得下更长的杆身（见 _build_stick 的注释与探针 F1）。
const STICK_POS := Vector3(0.0, -1.31, -0.40)
## 杆偏转上限（rad ≈ 12.6°）：足够读出"拉/推/压杆"，又不至于穿进仪表台。
const STICK_MAX_PITCH := 0.22
const STICK_MAX_ROLL := 0.22
## 方向舵踏板行程（米）：真机踏板行程很小，0.06 m 已能读出踩舵方向。
const PEDAL_TRAVEL := 0.06
## 发动机微颤基准幅度（rad）：频率与相机抖动同源（aircraft_camera.gd:415-417 的
## 37.1 / 71.3 / 53.7 / 83.1），杆与镜头一起抖才像"同一个发动机"。
const TREMOR_AMP := 0.012
## 滑跑颠簸基准幅度（rad）：按地速比例缩放，离地自动消失。
const BUMP_AMP := 0.03

var _craft: Aircraft = null
## 基础可见性（蓝图机契约 = false：无座舱罩几何，setup 早退不建任何节点）。
var _base_visible := true
var _interior_view := false
var _stick_pivot: Node3D = null
var _pedal_l: MeshInstance3D = null
var _pedal_r: MeshInstance3D = null
var _pedal_l_z := 0.0
var _pedal_r_z := 0.0
## 噪声相位（秒）：物理帧固定步长累加，探针可复现。
var _t := 0.0
var _mat_frame: StandardMaterial3D = null
var _mat_console: StandardMaterial3D = null
var _mat_dash: StandardMaterial3D = null
var _mat_dash_dark: StandardMaterial3D = null
var _mat_metal: StandardMaterial3D = null
var _mat_leather: StandardMaterial3D = null
var _mat_stick: StandardMaterial3D = null
var _mat_skin: StandardMaterial3D = null
var _mat_accent: StandardMaterial3D = null


func setup(craft: Node) -> void:
	_craft = craft as Aircraft
	# 蓝图拼装机无座舱罩，按契约隐藏且不建任何节点（同 cockpit_panel.gd:27-33 模式）。
	if craft != null and "blueprint_built" in craft and bool(craft.get("blueprint_built")):
		_base_visible = false
		visible = false
		return
	position = EYE
	_init_materials()
	_build_frame()
	_build_dash()
	_build_stick()
	# 先隐：等相机在第一帧内 apply_cockpit_interior() 打开，避免挂载到渲染之间的闪现。
	visible = false


## 座舱内视开关（与 CockpitPanel 极性相反）：active=true 表示"当前是座舱内视"，
## 此时外部机模被隐藏、内装必须显示。蓝图机 _base_visible=false 时恒隐。
func set_interior_view(active: bool) -> void:
	if active == _interior_view:
		return
	_interior_view = active
	visible = _base_visible and active


func _physics_process(delta: float) -> void:
	if not _base_visible or not visible or _craft == null or not is_instance_valid(_craft):
		return
	if _craft.is_wrecked():
		# 残骸只做"随机体翻倒"的演出：杆位冻结，别让 controls 的冻结值继续抖。
		return
	var c := _craft.controls
	# 地速直接读节点 velocity（snapshot() 会新建 Dictionary，不能每帧调）。
	var ground_speed := Vector2(_craft.velocity.x, _craft.velocity.z).length()
	update_stick_input(c.pitch, c.roll, c.yaw, c.throttle, _craft.is_on_floor(),
		_craft.engine_running, ground_speed, delta)


## 纯状态写入：把一帧操纵量映射到杆/踏板位姿。探针可直接调它做确定性断言，
## 不依赖树、相机或输入的到达时机。
func update_stick_input(pitch: float, roll: float, yaw: float, throttle: float,
		on_floor: bool, engine_running: bool, ground_speed: float, delta: float) -> void:
	if _stick_pivot == null:
		return
	_t += delta
	var jx := 0.0
	var jz := 0.0
	if engine_running:
		var power := 0.25 + 0.75 * clampf(throttle, 0.0, 1.0)
		jz += (sin(_t * 37.1) + 0.5 * sin(_t * 71.3)) * TREMOR_AMP * power
		jx += (sin(_t * 53.7) + 0.5 * sin(_t * 83.1)) * TREMOR_AMP * 0.6 * power
	if on_floor and ground_speed > 0.5:
		var bump := clampf(ground_speed / 20.0, 0.0, 1.0) * BUMP_AMP
		jx += sin(_t * 13.7) * sin(_t * 29.3) * bump
	# 拉杆（pitch=+1）→ 绕 +X 正转把杆顶推向 +Z（朝飞行员）；压杆反之。
	_stick_pivot.rotation.x = clampf(pitch, -1.0, 1.0) * STICK_MAX_PITCH + jz
	# 右滚（roll=+1）→ 杆顶推向 +X，绕 +Z 需负角。
	_stick_pivot.rotation.z = -clampf(roll, -1.0, 1.0) * STICK_MAX_ROLL + jx
	# 右舵（yaw=+1）→ 右踏前（-Z 即机头方向）、左踏后。
	var y := clampf(yaw, -1.0, 1.0)
	_pedal_r.position.z = _pedal_r_z - PEDAL_TRAVEL * y
	_pedal_l.position.z = _pedal_l_z + PEDAL_TRAVEL * y


# ── 探针钩子 ─────────────────────────────────────────────────────────────

## 当前杆位（rad）：x = 俯仰轴角，y = 滚转轴角（含噪声分量）。
func stick_angles() -> Vector2:
	if _stick_pivot == null:
		return Vector2.ZERO
	return Vector2(_stick_pivot.rotation.x, _stick_pivot.rotation.z)


## 当前踏板相对零位的 z 偏移（米）：x = 左踏，y = 右踏。
func pedal_offsets() -> Vector2:
	if _pedal_l == null or _pedal_r == null:
		return Vector2.ZERO
	return Vector2(_pedal_l.position.z - _pedal_l_z, _pedal_r.position.z - _pedal_r_z)


## 真实 MeshInstance3D 子节点数：几何预算闸（预期 39，超了立即红）。
func interior_box_count() -> int:
	return find_children("*", "MeshInstance3D", true, false).size()


func is_base_visible() -> bool:
	return _base_visible


# ── 材质 ────────────────────────────────────────────────────────────────

## 9 个共享材质：albedo 直给（不走顶点色单 surface——项目基线要求 srgb_to_linear，
## 且 SurfaceTool.append_from 的 COLOR 传递不可靠）。
func _init_materials() -> void:
	# 与 2D 像素座舱同源取色：COL_FRAME(0.09,0.10,0.13) / COL_DASH(0.145,0.155,0.185)。
	# 但 3D 里 COL_FRAME 原值在正午也只渲成 rgb(29,32,40)（实测 cockpit3d_fp.png），
	# A 柱/顶檐读成纯黑条、舱内失去体积感；框体与 console 各提亮一档到 0.11 / 0.17。
	# 仪表台板**故意不动**（保持 COL_DASH 原值）：它与 2D 簇同矩形贴合，提亮会在
	# 「板沿露出 2D 簇外」的那圈上显出明暗台阶。
	_mat_frame = _make_mat(Color(0.11, 0.12, 0.155), 0.10, 0.65)
	_mat_console = _make_mat(Color(0.17, 0.19, 0.22), 0.10, 0.70)
	_mat_dash = _make_mat(Color(0.145, 0.155, 0.185), 0.08, 0.75)
	_mat_dash_dark = _make_mat(Color(0.105, 0.112, 0.14), 0.08, 0.80)
	_mat_metal = _make_mat(Color(0.55, 0.58, 0.62), 0.55, 0.35)
	_mat_leather = _make_mat(Color(0.42, 0.29, 0.22), 0.02, 0.85)
	_mat_stick = _make_mat(Color(0.20, 0.20, 0.22), 0.20, 0.45)
	_mat_skin = _make_mat(Color(0.86, 0.66, 0.55), 0.00, 0.80)
	_mat_accent = _make_mat(Color(0.84, 0.26, 0.22), 0.15, 0.50)


func _make_mat(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = metallic
	mat.roughness = roughness
	return mat


# ── L1 环绕框（22 盒）────────────────────────────────────────────────────

## 语义镜像 2D 框体：顶檐 = 舱盖前拱（抬头才进场），A 柱 = 风挡两侧边角的斜柱，
## 侧 console = CONSOLE_W=92 的侧壁，下方 = 地板/椅背/踏板。
## 坐标全部眼位相对；上框在 y=1.30~1.36（眼上 1.30 m）→ 第一人称下整条横梁在屏外，
## 中线 ±200 px 内无 3D 几何（儿童向先保证看得见世界）。
## 注意 A 柱**不照抄** 2D 的 PILLAR_TOP_W=44 px：那是画在屏幕中央附近的装饰性
## 收纳边，按它布柱会让两根柱子在中线并拢成「Λ」把视野劈成两半（第一轮取证实测
## 3D 框占了 1/3 屏）。真实立柱在风挡两侧，柱身从屏顶屏中心外 226 px 处进场。
func _build_frame() -> void:
	# 顶檐横梁横跨两根 A 柱顶端（±0.65）。两处都是第一轮取证的结论：
	#  1) 原本顶檐只有 0.36 m 宽、A 柱顶端收到 ±0.18（照抄 2D 的 PILLAR_TOP_W=44 px），
	#     结果两根柱子几乎在中线并拢成一个巨大的「Λ」劈开视野——2D 那个 44 px 是画在
	#     屏幕中央附近的装饰性收纳边，不代表真实风挡立柱位置；真实 A 柱在风挡两侧边角。
	#  2) 整个上框抬到 2.45 m（眼上 1.30 m）：第一人称下横梁投影落在屏外（y≈−16 px），
	#     中线上方 ±200 px 内**没有任何** 3D 几何；抬头 ≥2° 它才作为舱盖前拱进场。
	#     2D 顶檐（0…20 px）本来就盖着这一带，第一人称不缺这条语义。
	_add_box(self, Vector3(1.30, 0.12, 0.26), Vector3(0.0, 1.36, -1.15),
		_mat_frame, "Header")
	_add_box(self, Vector3(1.30, 0.12, 0.16), Vector3(0.0, 1.27, 0.95),
		_mat_frame, "RearBow")
	for side: float in [-1.0, 1.0]:
		var tag := "L" if side < 0.0 else "R"
		_add_box(self, Vector3(0.10, 0.10, 2.10), Vector3(0.60 * side, 1.30, -0.10),
			_mat_frame, "RoofRail" + tag)
		# A 柱：顶端 (±0.65, 眼上 1.30, 前 1.15) → 底端 console 前上角 (±0.92, 眼下 0.57,
		# 前 0.48)。屏幕预算：柱宽 0.052 m 在 1.29 m 处张角 2.3°（屏上 17 px），两根
		# 合计占屏 ~3.4%（≤7%）；柱身从屏顶 (±226 px, 0) 斜出右下角，内缘最近处
		# 距中心 226 px（> 200 px 禁区）。
		_add_pillar(Vector3(0.65 * side, 1.30, -1.15),
			Vector3(0.92 * side, -0.57, -0.48), _mat_frame, "Pillar" + tag,
			0.052, 0.10)
		_add_box(self, Vector3(0.26, 0.75, 1.60), Vector3(1.02 * side, -0.95, 0.30),
			_mat_console, "Console" + tag)
		_add_box(self, Vector3(0.03, 0.03, 1.30), Vector3(0.885 * side, -0.65, 0.30),
			_mat_metal, "Trim" + tag)
		_add_box(self, Vector3(0.05, 0.13, 0.05), Vector3(1.02 * side, -0.51, -0.25),
			_mat_accent, "Lever" + tag + "1")
		_add_box(self, Vector3(0.05, 0.13, 0.05), Vector3(1.02 * side, -0.51, 0.05),
			_mat_accent, "Lever" + tag + "2")
	# 通风栅只在右 console（对应 2D 右 console 的通风栅 5 道）。
	_add_box(self, Vector3(0.03, 0.16, 0.40), Vector3(0.885, -0.85, -0.05),
		_mat_stick, "Grille")
	# 地板顶面 y=-1.27（眼下方 1.27 m ≈ 坐姿眼高），前缘伸到仪表台下方。
	_add_box(self, Vector3(2.30, 0.12, 2.50), Vector3(0.0, -1.33, -0.05),
		_mat_console, "Floor")
	_add_box(self, Vector3(0.62, 0.75, 0.16), Vector3(0.0, -0.50, 0.65),
		_mat_console, "SeatBack")
	_add_box(self, Vector3(0.62, 0.14, 0.55), Vector3(0.0, -0.87, 0.30),
		_mat_leather, "SeatCushion")
	# 头枕齐眼高（眼下 0.10 m）：低头/回头第一眼就看到它，U-2 的主件之一。
	_add_box(self, Vector3(0.34, 0.22, 0.14), Vector3(0.0, -0.10, 0.60),
		_mat_leather, "Headrest")
	# 后隔板：回头视角的**必需件**。没有它，回头看到的是「椅背 + 头枕两块浮在
	# 半空、四周直接透出天空与山头」的箱子（2026-10-22 首轮取证），读不出「在舱里」。
	# 顶到后拱下沿（RearBow 1.27 − 0.06 = 1.21），底压地板（−1.27），一次封住整个
	# 尾舱；后拱仍露在它上方，留一条「后窗」语义。放在椅背之后 0.45 m（z=1.10）。
	# 宽度 4.40 是**按视场算的**：82° 竖直 FOV + 16:9 → 水平半角 57°，在 1.10 m 处
	# 要 ±1.70 m 才铺满；2.30 宽漏一条天空、3.40 仍在最右角漏一小块（两轮取证实测），
	# 4.40 留 0.5 m 余量。多出来的宽度只在回望时可见，正视完全在身后。
	_add_box(self, Vector3(4.40, 2.48, 0.10), Vector3(0.0, -0.03, 1.10),
		_mat_console, "RearBulkhead")
	for side: float in [-1.0, 1.0]:
		var tag := "L" if side < 0.0 else "R"
		var pedal := _add_box(self, Vector3(0.18, 0.05, 0.28),
			Vector3(0.21 * side, -1.24, -0.80), _mat_stick, "Pedal" + tag)
		if side < 0.0:
			_pedal_l = pedal
			_pedal_l_z = pedal.position.z
		else:
			_pedal_r = pedal
			_pedal_r_z = pedal.position.z


# ── L2 仪表台承托（12 盒）────────────────────────────────────────────────

## 承托板不画仪表（面板贴图负责），只提供"屏嵌进板里"的物理边：四周边距
## DASH_RIM、顶沿受光条、暗下沿、6 颗螺钉（落在面板两侧的边条上）、两根到
## 地板的支架。倾角与位置全部取自 CockpitPanel.PANEL_*，面板换位这里自动跟随。
func _build_dash() -> void:
	var dash := Node3D.new()
	dash.name = "Dash"
	dash.position = DASH_POS
	dash.rotation.x = deg_to_rad(CockpitPanel.PANEL_TILT_DEG)
	add_child(dash)
	_add_box(dash, PLATE_SIZE, Vector3(0.0, 0.0, DASH_PLATE_Z), _mat_dash, "Plate")
	var edge_y := PLATE_SIZE.y * 0.5
	# 面板上沿与板沿之间那道线是**暗缝**而不是高光：受光条语义已由 uiux 的贴图
	# 承担（texture y8..11 → 屏 y≈579），3D 这里若再放亮银条，就是紧贴 2D dash
	# 上沿（538.67）的第二条亮线——镜头抖动在 0.85 m 处有 ±36.6 px（满油门），
	# 峰值帧会把它甩到 dash 上方闪成 6–13 Hz 的亮条。M_DASH_DARK 与 2D dash 的
	# 「暗线」同语言，甩出去也读作 dash 自己的上沿。
	var strip_y := CockpitPanel.PANEL_H * 0.5 + 0.006
	_add_box(dash, Vector3(PLATE_SIZE.x, 0.02, 0.02),
		Vector3(0.0, strip_y, -0.015), _mat_dash_dark, "TopStrip")
	_add_box(dash, Vector3(PLATE_SIZE.x, 0.03, 0.02),
		Vector3(0.0, -edge_y + 0.015, -0.015), _mat_dash_dark, "BottomStrip")
	# 下唇：板下沿再往下一段的实心边沿。没有它，低头看到的是「一块带框的屏
	# 挂在两根细腿之间」，屏幕像相框而不是仪表台（首轮取证）。它只向下长出
	# 0.10 m、向后贴住板背，**不朝飞行员方向前伸** —— 前伸会吃掉杆顶净空
	# （F1 断言眼→面板下沿在杆处 0.867，现余量 0.221 m）。
	_add_box(dash, Vector3(PLATE_SIZE.x, 0.10, 0.06),
		Vector3(0.0, -edge_y - 0.05, 0.0), _mat_dash, "Lip")
	# 螺钉落在面板边缘与板边之间的中线上：投影在面板两侧可见，读作"屏嵌在板里"。
	var screw_x := CockpitPanel.PANEL_W * 0.5 + DASH_RIM * 0.5
	var screw_y := CockpitPanel.PANEL_H * 0.5 + DASH_RIM * 0.5
	var n := 0
	for sx: float in [-1.0, 1.0]:
		for sy: float in [1.0, 0.0, -1.0]:
			n += 1
			_add_box(dash, Vector3(0.025, 0.025, 0.02),
				Vector3(screw_x * sx, screw_y * sy, -0.02), _mat_metal,
				"Screw%d" % n)
	# 支架是机体轴对齐的，不能挂 Dash 旋转系（否则随面板倾角歪掉）。
	# 0.10×0.72×0.12 的两块板在低头视角里与承托板连成一整面墙 → 换成两根
	# 0.06 见方的细撑杆：仍然从地板(−0.17)顶到板下沿(0.583)，但视觉上只剩两条腿，
	# 脚窝透得过去，低头读表时不再「顶着一块黑板」。
	var bracket_h := 0.77
	var bracket_y := 0.215 - EYE.y
	for side: float in [-1.0, 1.0]:
		var tag := "L" if side < 0.0 else "R"
		_add_box(self, Vector3(0.06, bracket_h, 0.06),
			Vector3(0.42 * side, bracket_y, -0.74), _mat_dash_dark, "Bracket" + tag)


# ── L3 杆 + 手（5 盒）───────────────────────────────────────────────────

## 三个杆件 + 手全部挂在 StickPivot 下：一次旋转带全部；手不单独动（不做手指细节）。
## 尺寸是第一轮取证后放大的（原先 0.16/0.06×0.46/0.09×0.14 + 0.11 的手，在低头视角
## 里只是地板中央一个 30 px 的小方块，读不出「握着一根杆」）：杆身 0.54、握把 0.20 高、
## 手 0.16×0.22×0.17 且**中心与握把重合**（只朝飞行员偏 1.5 cm）→ 手真的包住握把，
## 不再浮在旁边。横截面同时加粗 30~45%（杆身 0.06→0.08、握把 0.09→0.13、手 0.11→0.16），
## 这才是「看起来小一档」的主因——杆顶高度受探针 F1 的净空约束封顶在 0.86
## （眼→面板下沿视线在杆处 0.867，净空 0.167 m），所以加长靠后撤枢轴换来的余量，
## 加粗不占预算。
func _build_stick() -> void:
	_stick_pivot = Node3D.new()
	_stick_pivot.name = "StickPivot"
	_stick_pivot.position = STICK_POS
	add_child(_stick_pivot)
	var p := _stick_pivot
	_add_box(p, Vector3(0.20, 0.12, 0.20), Vector3(0.0, 0.06, 0.0), _mat_stick, "StickBase")
	_add_box(p, Vector3(0.08, 0.54, 0.08), Vector3(0.0, 0.39, 0.0), _mat_stick, "StickShaft")
	_add_box(p, Vector3(0.13, 0.20, 0.13), Vector3(0.0, 0.76, 0.0), _mat_stick, "StickGrip")
	# 单手：右手成拳**包住**握把（比握把每个方向都大 3 cm），只朝飞行员侧偏 1.5 cm。
	_add_box(p, Vector3(0.16, 0.22, 0.17), Vector3(0.0, 0.76, 0.015), _mat_skin, "Hand")
	# 小臂：握把往飞行员方向伸直的一段。少了它，低头只看到「地板中央一块悬浮的
	# 肤色方块」，大脑不会把它认成自己的手；有小臂才有「我在握着杆」的归属感。
	# 挂在 StickPivot 下（跟着杆一起偏转）——摆幅上限 STICK_MAX_* = 0.22 rad，
	# 位移仅 8 cm 量级，肉眼看不出「手臂跟着杆转」这个物理瑕疵。
	_add_box(p, Vector3(0.14, 0.14, 0.42), Vector3(0.0, 0.70, 0.28), _mat_skin, "Forearm")


# ── 小工具 ──────────────────────────────────────────────────────────────

## 建一个盒体并挂到 parent 下。cast_shadow 全关：舱内没有阳光直射的收益，
## 省一遍 shadow pass（移动端预算）。
func _add_box(parent: Node3D, size: Vector3, pos: Vector3,
		mat: StandardMaterial3D, node_name: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = pos
	parent.add_child(mi)
	return mi


## 两点间立一根方柱：局部 +Y 对准 bottom−top，用来立 A 柱（唯一非轴对齐件）。
## 体素风只约束"几何是盒体"，不约束朝向；斜柱是"绕过支柱看世界"的必要件。
## thick/depth 由调用方给：A 柱要细（0.052 → 屏上 17 px），粗了就把风挡切碎。
func _add_pillar(top: Vector3, bottom: Vector3, mat: StandardMaterial3D,
		node_name: String, thick: float = 0.052, depth: float = 0.10) -> void:
	var dir := (bottom - top).normalized()
	var x_axis := dir.cross(Vector3.UP)
	if x_axis.length_squared() < 1e-6:
		# 支柱恰好竖直时叉积退化为零，退到一个确定的正交向量。
		x_axis = Vector3.RIGHT
	x_axis = x_axis.normalized()
	# 局部名不叫 basis：Node3D 本身有 basis 属性，同名局部变量会触发
	# SHADOWED_VARIABLE_BASE_CLASS（本项目警告即错误）。
	var pil_basis := Basis(x_axis, dir, x_axis.cross(dir))
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var box := BoxMesh.new()
	box.size = Vector3(thick, top.distance_to(bottom), depth)
	mi.mesh = box
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.transform = Transform3D(pil_basis, (top + bottom) * 0.5)
	add_child(mi)
