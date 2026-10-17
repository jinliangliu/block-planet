class_name MapGlobe
extends Node3D
## 3D 地球：按 RegionAtlas 的陆地掩码逐格生成球面网格（顶点色着色），
## 支持拖动旋转与射线拾取区域。
##
## 网格顶点由 RegionAtlas.lat_lon_to_dir 生成，拾取时用其逆函数
## RegionAtlas.dir_to_lat_lon 还原经纬度，两者严格互逆——屏幕上看到的色块
## 与点中的区域不会错位。

const RADIUS := 1.0
## 拖动灵敏度：像素 → 弧度。0.008 → 0.015 → 0.06（按手感逐步调快，当前为 4 倍速）。
const DRAG_SPEED := 0.06
## 俯仰限幅：留出余量，避免极点在视觉上翻过去。
const PITCH_LIMIT := 80.0
## 两极标记与球面的间距。
const POLE_MARKER_LIFT := 0.10
## 区域名称标签与球面的间距（略高于球面即可，避免与网格 z-fighting）。
const REGION_LABEL_LIFT := 0.03
## 球面立体标记（小飞机 / 小鱼）的离地抬升与沿北向切向的上下偏移：
## 抬升让标记浮在球面之上、不与网格 z-fighting；偏移让
## 「小飞机 / 区域名 / 小鱼」竖着排开——区域名标签在球面上约 0.23×0.076
## （Label3D pixel_size 0.0038），飞机放名称上方、小鱼放下方，
## 三者互不压字；四大洋同时有降落场与钓点，这样也不会两枚标记叠成一团。
const PLANE_MARKER_LIFT := 0.055
const PLANE_MARKER_OFFSET := 0.115
const FISH_MARKER_LIFT := 0.050
const FISH_MARKER_OFFSET := 0.130

var _yaw := -30.0
var _pitch := 6.0
var _mesh_instance: MeshInstance3D
var _pole_markers: Array[Node3D] = []
var _region_labels: Array[Label3D] = []
## 飞行标记：带跑道区域上方的小飞机（机场红涂装 / 降落场琥珀涂装），
## 钉在区域名称旁，取代文字标注与早先的小旗，提示该区可起飞。
var _airport_markers: Array[Node3D] = []
var _field_markers: Array[Node3D] = []
## 钓鱼标记：小鱼，钉在有钓点的海域（当前是四大洋）区域名旁的另一条切向。
## 判据走 FishingSystem 的钓点表，加新海域钓点无需改这里。
var _fish_markers: Array[Node3D] = []
## 标记动画累计时间（秒）：小飞机起伏+螺旋桨转、小鱼摆尾游动。
var _anim_time := 0.0


func _ready() -> void:
	_mesh_instance = MeshInstance3D.new()
	add_child(_mesh_instance)
	_build_sphere()
	_add_pole_markers()
	_apply_view()


func build() -> void:
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		add_child(_mesh_instance)
	_build_sphere()
	_add_pole_markers()
	_apply_view()


## 拖动旋转：delta 为鼠标位移（像素），右键/左键拖动均为同一手感。
func rotate_view(delta: Vector2) -> void:
	_yaw = wrapf(_yaw + delta.x * DRAG_SPEED, -180.0, 180.0)
	_pitch = clampf(_pitch + delta.y * DRAG_SPEED, -PITCH_LIMIT, PITCH_LIMIT)
	_apply_view()


func get_view_angles() -> Vector2:
	return Vector2(_yaw, _pitch)


func set_view_angles(yaw: float, pitch: float) -> void:
	_yaw = wrapf(yaw, -180.0, 180.0)
	_pitch = clampf(pitch, -PITCH_LIMIT, PITCH_LIMIT)
	_apply_view()


## 射线命中球面后返回区域 ID；未命中返回 -1。
## 参数为摄像机世界空间的原点与方向（单位向量）。
func region_at_world_ray(origin: Vector3, dir: Vector3) -> int:
	var to_local := global_transform.affine_inverse()
	var o := to_local * origin
	var d := (to_local.basis * dir).normalized()
	var b := o.dot(d)
	var c := o.length_squared() - RADIUS * RADIUS
	var disc := b * b - c
	if disc < 0.0:
		return -1
	var root := sqrt(disc)
	var t := -b - root
	if t < 0.0:
		t = -b + root
	if t < 0.0:
		return -1
	var lat_lon := RegionAtlas.dir_to_lat_lon(o + d * t)
	return RegionAtlas.region_at_lat_lon(lat_lon.x, lat_lon.y)


func _apply_view() -> void:
	rotation_degrees = Vector3(_pitch, _yaw, 0.0)


## 逐格生成球面：每个 5° 经纬格一个四边形（两三角），取该格区域配色。
## 用 SurfaceTool.index() 合并同色相邻顶点，使同区域内部平滑、
## 区域交界处因颜色不同自然形成清晰边界。
func _build_sphere() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for row in RegionAtlas.ROWS:
		for col in RegionAtlas.COLS:
			_add_cell(st, row, col)
	st.index()

	var mesh := st.commit()
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	# 无光照平涂：儿童向界面优先保证任何环境下颜色可辨、不发黑。
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, material)
	_mesh_instance.mesh = mesh


## 两极标记：Label3D「北极」「南极」，始终面向相机；位置挂在球节点下，
## 随俯仰旋转上下移动，直观指示自转轴两端。可重复调用（幂等）。
func _add_pole_markers() -> void:
	for marker in _pole_markers:
		marker.queue_free()
	_pole_markers.clear()
	_pole_markers.append(_make_pole_marker("北极", Color(0.95, 0.35, 0.30), RADIUS + POLE_MARKER_LIFT))
	_pole_markers.append(_make_pole_marker("南极", Color(0.94, 0.96, 0.99), -(RADIUS + POLE_MARKER_LIFT)))
	_add_region_labels()
	_add_vehicle_markers()


## 七大洲四大洋名称贴在球面对应位置：锚点经纬度经 lat_lon_to_dir 映射到球面
## （与网格/拾取共用同一函数对，保证「名贴其位」）。标签朝向由 _process
## 按与相机的夹角渐隐，转到背面时整条淡出，避免轮廓线截断文字。
## 可重复调用（幂等）。
func _add_region_labels() -> void:
	for label in _region_labels:
		label.queue_free()
	_region_labels.clear()
	for region_id in RegionAtlas.COUNT:
		var anchor: Vector2 = RegionAtlas.REGION_ANCHORS[region_id]
		var pos: Vector3 = RegionAtlas.lat_lon_to_dir(anchor.x, anchor.y) * (RADIUS + REGION_LABEL_LIFT)
		var is_land: bool = region_id >= RegionAtlas.ASIA
		var label_text := RegionAtlas.title_of(region_id)
		_region_labels.append(_make_region_label(label_text, pos, is_land))


## 球面玩法标记（D-044）：给每个有玩法的区域在名称旁钉一枚立体标记——
## 小飞机 = 可起飞（机场红涂装 / 降落场琥珀涂装），小鱼 = 可钓鱼。
## 二者都浮在球面之上、机头/鱼头沿切向，随球体旋转；球背面的标记会被
## 球面自身遮挡（默认深度测试），不会穿到正面来。可重复调用（幂等）。
##
## 四大洋同时有降落场和钓点，故小飞机沿东向切向、小鱼沿北向切向错开摆放，
## 加上区域名标签三者各占一角，互不遮挡。
func _add_vehicle_markers() -> void:
	_clear_markers(_airport_markers)
	_clear_markers(_field_markers)
	_clear_markers(_fish_markers)
	for region_id in RegionAtlas.COUNT:
		var anchor: Vector2 = RegionAtlas.REGION_ANCHORS[region_id]
		var dir: Vector3 = RegionAtlas.lat_lon_to_dir(anchor.x, anchor.y)
		var frame: Array = _tangent_frame(dir)
		var east: Vector3 = frame[0]
		var north: Vector3 = frame[1]
		var phase := float(region_id) * 0.8
		if RegionAtlas.has_airport(region_id):
			_airport_markers.append(_make_airplane_marker(
				dir * (RADIUS + PLANE_MARKER_LIFT) + north * PLANE_MARKER_OFFSET,
				dir, Color(0.95, 0.20, 0.18), phase))
		elif RegionAtlas.has_landing_field(region_id):
			_field_markers.append(_make_airplane_marker(
				dir * (RADIUS + PLANE_MARKER_LIFT) + north * PLANE_MARKER_OFFSET,
				dir, Color(0.98, 0.72, 0.15), phase))
		# 钓点判据与图例 🎣、介绍页「去钓鱼」按钮同源（FishingSystem 表），
		# 新增海域钓点时球面小鱼会自动跟上。小鱼挂在名称下方（-north）。
		if not FishingSystem.get_spots_for_atlas(region_id).is_empty():
			_fish_markers.append(_make_fish_marker(
				dir * (RADIUS + FISH_MARKER_LIFT) - north * FISH_MARKER_OFFSET,
				dir, phase))


## 飞行标记（小飞机）整体显隐：地图选择器只在「探索」模式显示它们（D-041）——
## 生存/创造模式下玩家还没有载具，挂着小飞机只会误导。
## 逐枚 set visible，不销毁重建：切回探索模式瞬间复现，零建造成本。
## 方法名沿用「flags」（历史：曾是旗子），语义已改为飞行标记。
func set_flight_flags_visible(value: bool) -> void:
	for marker in _airport_markers:
		marker.visible = value
	for marker in _field_markers:
		marker.visible = value


## 当前飞行标记是否可见（探针断言用）。机场机与降落场机同显同隐，
## 取第一枚为代表；一个可飞区域都没有的组合返回 false。
func flight_flags_visible() -> bool:
	for marker in _airport_markers:
		return marker.visible
	for marker in _field_markers:
		return marker.visible
	return false


## 钓鱼标记（小鱼）整体显隐：钓鱼不绑定载具、也不绑定模式，默认常显，
## 但保留开关给将来（如「纯净地图」只显示地理）与探针断言用。
func set_fish_markers_visible(value: bool) -> void:
	for marker in _fish_markers:
		marker.visible = value


func fish_markers_visible() -> bool:
	for marker in _fish_markers:
		return marker.visible
	return false


## 各类球面标记的枚数（探针断言用：飞机应覆盖全部可飞区域，鱼应恰好四大洋）。
func airport_marker_count() -> int:
	return _airport_markers.size()


func field_marker_count() -> int:
	return _field_markers.size()


func fish_marker_count() -> int:
	return _fish_markers.size()


## 球面上一点的切平面基底：返回 [东向切向, 北向切向]，两者与外法线 dir
## 两两正交。标记沿这两条切向摆开，既保证「机身水平贴合球面」，
## 又让同一区域上的多个标记互不重叠。
func _tangent_frame(dir: Vector3) -> Array:
	var up := dir.normalized()
	var east := up.cross(Vector3(0.0, 1.0, 0.0))
	if east.length_squared() < 0.001:
		east = Vector3(1.0, 0.0, 0.0)
	east = east.normalized()
	# 右手系：X × Y = Z，故北向 = 东向 × 外法线（不能写成 up × east，会镜像）。
	var north := east.cross(up).normalized()
	return [east, north]


## 一枚浮在球面上的小飞机：本地 +X 机头、+Y 球面外法线、+Z 右翼。
## 机身白 + accent 色主翼/尾翼（红=机场 / 琥珀=降落场），座舱浅蓝、桨深色，
## 全 unshaded（与球面同色系策略：任何视角都不发黑、颜色可辨）。
## 记下 base_pos/base_basis/up/phase 供 _animate_markers 做起伏与滚转。
func _make_airplane_marker(pos: Vector3, dir: Vector3, accent: Color, phase: float) -> Node3D:
	var plane := Node3D.new()
	plane.position = pos
	var frame: Array = _tangent_frame(dir)
	var east: Vector3 = frame[0]
	var north: Vector3 = frame[1]
	var up := dir.normalized()
	plane.basis = Basis(east, up, north)

	# 机身（沿机头方向的长条）+ 机头整流罩。
	_add_box(plane, Vector3(0.094, 0.020, 0.022), Color(0.96, 0.96, 0.98), Vector3(-0.006, 0.0, 0.0))
	var nose := CylinderMesh.new()
	nose.top_radius = 0.004
	nose.bottom_radius = 0.011
	nose.height = 0.026
	var nose_mi := _add_mesh(plane, nose, Color(0.94, 0.94, 0.97), Vector3(0.053, 0.0, 0.0))
	# CylinderMesh 默认沿 +Y 立着，绕 Z 转 -90° 让它躺倒指向机头 +X。
	nose_mi.rotation_degrees = Vector3(0.0, 0.0, -90.0)
	# 主翼拆左右两片并向后掠：俯视时是梯形翼而不是一根横杠——
	# 这一步是让它在小尺寸下仍能被看成「飞机」的关键。
	var wing_l := _add_box(plane, Vector3(0.026, 0.006, 0.058), accent, Vector3(0.006, 0.003, 0.030))
	wing_l.rotation_degrees = Vector3(0.0, -14.0, 0.0)
	var wing_r := _add_box(plane, Vector3(0.026, 0.006, 0.058), accent, Vector3(0.006, 0.003, -0.030))
	wing_r.rotation_degrees = Vector3(0.0, 14.0, 0.0)
	# 平尾 / 垂尾：accent 色，与介绍页「机场红 / 降落场琥珀」同一套语义。
	_add_box(plane, Vector3(0.020, 0.005, 0.042), accent, Vector3(-0.046, 0.006, 0.0))
	_add_box(plane, Vector3(0.022, 0.028, 0.005), accent, Vector3(-0.046, 0.019, 0.0))
	# 座舱盖：偏蓝的深色，压在机身上表面靠前。
	_add_box(plane, Vector3(0.028, 0.014, 0.018), Color(0.24, 0.44, 0.66), Vector3(0.016, 0.015, 0.0))
	# 螺旋桨：绕机头轴自转（_animate_markers 驱动），静止时也像一枚小圆盘。
	var prop_mesh := CylinderMesh.new()
	prop_mesh.top_radius = 0.019
	prop_mesh.bottom_radius = 0.019
	prop_mesh.height = 0.004
	var prop := _add_mesh(plane, prop_mesh, Color(0.30, 0.33, 0.40), Vector3(0.069, 0.0, 0.0))
	prop.name = "Propeller"
	prop.rotation_degrees = Vector3(0.0, 0.0, -90.0)

	plane.set_meta("base_pos", pos)
	plane.set_meta("base_basis", plane.basis)
	plane.set_meta("up", up)
	plane.set_meta("phase", phase)
	add_child(plane)
	return plane


## 一枚游在球面上的小鱼：本地 +X 鱼头、+Y 鱼背、+Z 指向球心（厚度方向）。
## 关键：鱼身平面（长×高）就铺在球面切平面上——从球外正对该海域看，
## 是一条完整的侧视小鱼（头朝右、背朝上、尾在左），而不是一根橙色胶囊。
## 橙身白肚 + 深色 V 形尾（尾鳍单独摆动），与深蓝海域对比强、儿童向醒目。
func _make_fish_marker(pos: Vector3, dir: Vector3, phase: float) -> Node3D:
	var fish := Node3D.new()
	fish.position = pos
	var frame: Array = _tangent_frame(dir)
	var east: Vector3 = frame[0]
	var north: Vector3 = frame[1]
	var up := dir.normalized()
	# X=东向(鱼头) · Y=北向(鱼背) · Z=-外法线(朝球心)：east×north = -up，右手系。
	fish.basis = Basis(east, north, -up)

	# 身体：球体压成沿鱼头方向拉长的椭球。
	var body := SphereMesh.new()
	body.radius = 0.033
	body.height = 0.066
	var body_mi := _add_mesh(fish, body, Color(0.98, 0.55, 0.18), Vector3.ZERO)
	body_mi.scale = Vector3(1.55, 0.80, 0.62)
	# 白肚：贴在身体腹侧（-Y 即球面内侧方向）的一条浅色，点出正反面。
	var belly := SphereMesh.new()
	belly.radius = 0.029
	belly.height = 0.058
	var belly_mi := _add_mesh(fish, belly, Color(0.99, 0.93, 0.80), Vector3(-0.005, -0.016, 0.0))
	belly_mi.scale = Vector3(1.34, 0.45, 0.55)
	# 背鳍：向后倾的小三角片，立在鱼背上（+Y）。
	var dorsal := _add_box(fish, Vector3(0.028, 0.022, 0.005), Color(0.86, 0.36, 0.12), Vector3(-0.005, 0.028, 0.0))
	dorsal.rotation_degrees = Vector3(0.0, 0.0, -18.0)
	# V 形尾鳍：上下两片斜置、张角略大，_animate_markers 绕本地 Z（球面法向）让它们摆。
	var tail_up := _add_box(fish, Vector3(0.007, 0.038, 0.005), Color(0.86, 0.36, 0.12), Vector3(-0.052, 0.017, 0.0))
	tail_up.rotation_degrees = Vector3(0.0, 0.0, 34.0)
	# 用 meta 而非 node.name 认尾鳍：同父下重名会被引擎自动改成 Tail_2。
	tail_up.set_meta("tail", true)
	tail_up.set_meta("base_rot", deg_to_rad(34.0))
	var tail_down := _add_box(fish, Vector3(0.007, 0.038, 0.005), Color(0.86, 0.36, 0.12), Vector3(-0.052, -0.017, 0.0))
	tail_down.rotation_degrees = Vector3(0.0, 0.0, -34.0)
	# 上下两片同相位摆动，V 形张合而不是被摆成「剪刀」。
	tail_down.set_meta("tail", true)
	tail_down.set_meta("base_rot", deg_to_rad(-34.0))
	# 白眼 + 黑瞳一对（沿厚度方向各一片）：球外正对该海域时看得到朝外的这只，
	# 一眼点出「头在哪」，避免鱼被看成一根橙色胶囊。
	_add_sphere(fish, 0.0085, Color(1.0, 1.0, 1.0), Vector3(0.038, 0.009, 0.013))
	_add_sphere(fish, 0.0085, Color(1.0, 1.0, 1.0), Vector3(0.038, 0.009, -0.013))
	# 黑瞳要落在白眼表面之外（中心 0.013 + 半径 0.0085 ≈ 0.0215），否则被白球包住看不见。
	_add_sphere(fish, 0.0045, Color(0.12, 0.10, 0.10), Vector3(0.040, 0.009, 0.020))
	_add_sphere(fish, 0.0045, Color(0.12, 0.10, 0.10), Vector3(0.040, 0.009, -0.020))

	fish.set_meta("base_pos", pos)
	fish.set_meta("base_basis", fish.basis)
	fish.set_meta("up", up)
	fish.set_meta("phase", phase)
	add_child(fish)
	return fish


## 清空一类标记（queue_free + 清数组），供 _add_vehicle_markers 幂等重建。
func _clear_markers(list: Array[Node3D]) -> void:
	for marker in list:
		if is_instance_valid(marker):
			marker.queue_free()
	list.clear()


func _add_box(parent: Node3D, size: Vector3, color: Color, pos: Vector3) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = size
	return _add_mesh(parent, box, color, pos)


func _add_sphere(parent: Node3D, radius: float, color: Color, pos: Vector3) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	return _add_mesh(parent, sphere, color, pos)


func _add_mesh(parent: Node3D, mesh: Mesh, color: Color, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _unshaded_mat(color)
	mi.position = pos
	parent.add_child(mi)
	return mi


## 无光照平涂材质：地球所在 SubViewport 没有灯光，用 unshaded 保证
## 小飞机/小鱼转到任何角度都是本色、不发黑（与球面网格同一策略）。
func _unshaded_mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


## 标记动画：小飞机轻微起伏 + 缓慢滚转 + 螺旋桨旋转；小鱼起伏 + 摆头 + 摆尾。
## 幅度都压得很小——这是「会呼吸的地图标记」，不是抢戏的特效；
## 只改 transform，不影响拾取（拾取走球面射线，与标记无关）。
func _animate_markers() -> void:
	var t := _anim_time
	for marker in _airport_markers:
		_animate_plane(marker, t)
	for marker in _field_markers:
		_animate_plane(marker, t)
	for marker in _fish_markers:
		_animate_fish(marker, t)


func _animate_plane(plane: Node3D, t: float) -> void:
	var base_pos: Vector3 = plane.get_meta("base_pos", plane.position)
	var up: Vector3 = plane.get_meta("up", Vector3.UP)
	var phase: float = plane.get_meta("phase", 0.0)
	plane.position = base_pos + up * sin(t * 1.7 + phase) * 0.008
	var base_basis: Basis = plane.get_meta("base_basis", plane.basis)
	# 绕本地 X（机头轴）小幅滚转，像在空中轻微侧倾。
	plane.basis = base_basis.rotated(Vector3(1.0, 0.0, 0.0), sin(t * 1.1 + phase) * 0.07)
	var prop := plane.get_node_or_null("Propeller")
	if prop != null:
		prop.rotation.x = t * 18.0


func _animate_fish(fish: Node3D, t: float) -> void:
	var base_pos: Vector3 = fish.get_meta("base_pos", fish.position)
	var up: Vector3 = fish.get_meta("up", Vector3.UP)
	var phase: float = fish.get_meta("phase", 0.0)
	fish.position = base_pos + up * sin(t * 1.5 + phase) * 0.006
	var base_basis: Basis = fish.get_meta("base_basis", fish.basis)
	# 绕本地 Y（外法线轴）小幅摆头，配合尾鳍摆动就是「游起来」。
	fish.basis = base_basis.rotated(Vector3(0.0, 1.0, 0.0), sin(t * 3.0 + phase) * 0.12)
	for child in fish.get_children():
		if not bool(child.get_meta("tail", false)):
			continue
		var base_rot: float = child.get_meta("base_rot", 0.0)
		child.rotation.z = base_rot + sin(t * 7.0 + phase) * 0.35


func _process(delta: float) -> void:
	# 标记动画先跑：它只改 transform，不依赖相机，无相机时也该继续动。
	_anim_time += delta
	_animate_markers()
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cam_pos := cam.global_position
	for label in _region_labels:
		var normal := (label.global_position - global_position).normalized()
		var facing := normal.dot((cam_pos - label.global_position).normalized())
		var fade := clampf((facing - 0.05) / 0.30, 0.0, 1.0)
		var base: float = label.get_meta("base_alpha", 1.0)
		label.modulate.a = base * fade
		label.outline_modulate.a = fade


func _make_pole_marker(text: String, color: Color, y: float) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font_size = 30
	label.pixel_size = 0.004
	label.modulate = color
	label.outline_size = 10
	label.outline_modulate = Color(0.08, 0.10, 0.16)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.position = Vector3(0.0, y, 0.0)
	add_child(label)
	return label


func _make_region_label(text: String, pos: Vector3, is_land: bool) -> Label3D:
	var label := Label3D.new()
	label.text = text
	var base_alpha := 1.0
	if is_land:
		label.font_size = 26
		label.modulate = Color(0.99, 0.97, 0.90)
	else:
		label.font_size = 20
		label.modulate = Color(0.74, 0.88, 1.0)
		base_alpha = 0.92
	label.pixel_size = 0.0038
	label.outline_size = 9
	label.outline_modulate = Color(0.06, 0.09, 0.16)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.set_meta("base_alpha", base_alpha)
	label.position = pos
	add_child(label)
	return label


func _add_cell(st: SurfaceTool, row: int, col: int) -> void:
	var lat_top := RegionAtlas.LAT_TOP - float(row) * RegionAtlas.CELL_DEG
	var lat_bot := lat_top - RegionAtlas.CELL_DEG
	var lon_left := RegionAtlas.LON_LEFT + float(col) * RegionAtlas.CELL_DEG
	var lon_right := lon_left + RegionAtlas.CELL_DEG

	var color := RegionAtlas.color_of(RegionAtlas.region_of_cell(row, col))
	var a := RegionAtlas.lat_lon_to_dir(lat_top, lon_left) * RADIUS
	var b := RegionAtlas.lat_lon_to_dir(lat_bot, lon_left) * RADIUS
	var c := RegionAtlas.lat_lon_to_dir(lat_top, lon_right) * RADIUS
	var d := RegionAtlas.lat_lon_to_dir(lat_bot, lon_right) * RADIUS

	for v: Vector3 in [a, b, c, c, b, d]:
		st.set_color(color)
		st.set_normal(v.normalized())
		st.add_vertex(v)
