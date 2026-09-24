class_name MapGlobe
extends Node3D
## 3D 地球：按 RegionAtlas 的陆地掩码逐格生成球面网格（顶点色着色），
## 支持拖动旋转与射线拾取区域。
##
## 网格顶点由 RegionAtlas.lat_lon_to_dir 生成，拾取时用其逆函数
## RegionAtlas.dir_to_lat_lon 还原经纬度，两者严格互逆——屏幕上看到的色块
## 与点中的区域不会错位。

const RADIUS := 1.0
## 拖动灵敏度：像素 → 弧度。
const DRAG_SPEED := 0.008
## 俯仰限幅：留出余量，避免极点在视觉上翻过去。
const PITCH_LIMIT := 80.0

var _yaw := -30.0
var _pitch := 12.0
var _mesh_instance: MeshInstance3D


func _ready() -> void:
	_mesh_instance = MeshInstance3D.new()
	add_child(_mesh_instance)
	_build_sphere()
	_apply_view()


func build() -> void:
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		add_child(_mesh_instance)
	_build_sphere()
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
