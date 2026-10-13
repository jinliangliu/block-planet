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

var _yaw := -30.0
var _pitch := 6.0
var _mesh_instance: MeshInstance3D
var _pole_markers: Array[Node3D] = []
var _region_labels: Array[Label3D] = []
## 机场标记：带跑道区域的红色小球，钉在区域名称旁，提示玩家该区可起飞。
var _airport_markers: Array[Node3D] = []


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
	_add_airport_markers()


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
		if RegionAtlas.has_airport(region_id):
			label_text += "（机场）"
		_region_labels.append(_make_region_label(label_text, pos, is_land))


## 机场标记：给每个带跑道区域在名称旁钉一颗红色小球，提示该区可起飞。
## 与区域标签共用锚点经纬度，球背面的标记会被球面自身遮挡（默认深度测试）。
## 可重复调用（幂等）。
func _add_airport_markers() -> void:
	for marker in _airport_markers:
		marker.queue_free()
	_airport_markers.clear()
	for region_id in RegionAtlas.COUNT:
		if not RegionAtlas.has_airport(region_id):
			continue
		var anchor: Vector2 = RegionAtlas.REGION_ANCHORS[region_id]
		var dir: Vector3 = RegionAtlas.lat_lon_to_dir(anchor.x, anchor.y)
		var pos: Vector3 = dir * (RADIUS + REGION_LABEL_LIFT + 0.02)
		# 沿球面切线方向偏移一小段，避免与名称标签重叠。
		var tangent := dir.cross(Vector3(0.0, 1.0, 0.0))
		if tangent.length_squared() < 0.001:
			tangent = Vector3(1.0, 0.0, 0.0)
		pos += tangent.normalized() * 0.05
		_airport_markers.append(_make_airport_marker(pos))


func _make_airport_marker(pos: Vector3) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.035
	sphere.height = 0.07
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.20, 0.18)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = mat
	mesh.position = pos
	add_child(mesh)
	return mesh


func _process(_delta: float) -> void:
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
