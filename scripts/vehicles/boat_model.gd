class_name BoatModel
extends Node3D
## 程序化体素风船模（D-042）：按船型数据用盒子拼出船体——与 RaceCar 同思路
## （BoxMesh + StandardMaterial3D，零外部资源），木筏/小渔船/快艇三型各异。
##
## 局部坐标约定（必须与 Boat 一致）：
##   原点 = 水线中心；+Z = 船头（北）；+Y = 向上。
##   船体高度约 2 格，驾驶座落在 y≈2.2（Boat.SEAT_OFFSET）。
## 尺寸取自数据表 length_blocks / width_blocks（1 格 = 0.5 m）。

## 船舱深色玻璃色（驾驶室窗户）。
const GLASS_DARK := Color(0.16, 0.20, 0.28)
## 木筏原木色第二色（深浅交替才像扎起来的木排）。
const LOG_DARK := Color(0.45, 0.30, 0.15)

var spec: Dictionary = {}
var _root: Node3D


func _ready() -> void:
	_root = Node3D.new()
	add_child(_root)
	_build()


func setup(boat_spec: Dictionary) -> void:
	spec = boat_spec
	if _root != null:
		_build()


func _build() -> void:
	if spec.is_empty() or _root == null:
		return
	for child in _root.get_children():
		child.queue_free()
	var hull := Color(float(spec.get("hull_color", [0.5, 0.4, 0.3])[0]),
		float(spec.get("hull_color", [0.5, 0.4, 0.3])[1]),
		float(spec.get("hull_color", [0.5, 0.4, 0.3])[2]))
	var trim := Color(float(spec.get("trim_color", [0.8, 0.8, 0.8])[0]),
		float(spec.get("trim_color", [0.8, 0.8, 0.8])[1]),
		float(spec.get("trim_color", [0.8, 0.8, 0.8])[2]))
	var length := float(spec.get("length_blocks", 11.0))
	var width := float(spec.get("width_blocks", 4.2))
	match String(spec.get("id", "")):
		"raft":
			_build_raft(hull, trim, length, width)
		"speedboat":
			_build_speedboat(hull, trim, length, width)
		_:
			_build_fishing_boat(hull, trim, length, width)


## 小渔船：平底船身 + 船舱 + 船头旗杆。
func _build_fishing_boat(hull: Color, trim: Color, length: float, width: float) -> void:
	# 船底（窄一点，入水部分）。
	_add_box(Vector3(0.0, 0.45, 0.0), Vector3(width * 0.72, 0.9, length * 0.94), hull.darkened(0.15))
	# 船身主体（舷侧高出水线）。
	_add_box(Vector3(0.0, 1.15, 0.0), Vector3(width, 0.9, length), hull)
	# 舷侧描边（trim 色压条，让船身有层次）。
	_add_box(Vector3(0.0, 1.62, 0.0), Vector3(width * 1.02, 0.16, length * 1.0), trim)
	# 船头楔形（前窄后宽的尖感：前部收一档）。
	_add_box(Vector3(0.0, 1.15, length * 0.5 - 0.6), Vector3(width * 0.62, 0.8, 1.2), hull.darkened(0.1))
	# 船舱（中后部）。
	var cabin_z := -length * 0.08
	_add_box(Vector3(0.0, 2.05, cabin_z), Vector3(width * 0.62, 1.5, length * 0.34), trim)
	# 船舱玻璃（前壁一条深色）。
	_add_box(Vector3(0.0, 2.25, cabin_z + length * 0.17), Vector3(width * 0.5, 0.7, 0.12), GLASS_DARK)
	# 船头小旗杆 + 旗布（橙）。
	_add_box(Vector3(0.0, 2.5, length * 0.5 - 0.2), Vector3(0.1, 1.2, 0.1), trim.darkened(0.3))
	_add_box(Vector3(0.28, 2.95, length * 0.5 - 0.2), Vector3(0.5, 0.34, 0.06), Color(0.95, 0.45, 0.15))


## 快艇：低趴流线船身 + 大块风挡 + 艇尾两台「发动机」。
func _build_speedboat(hull: Color, trim: Color, length: float, width: float) -> void:
	_add_box(Vector3(0.0, 0.5, 0.0), Vector3(width * 0.7, 0.8, length * 0.95), hull.darkened(0.2))
	_add_box(Vector3(0.0, 1.05, 0.0), Vector3(width, 0.7, length), hull)
	_add_box(Vector3(0.0, 1.45, 0.0), Vector3(width * 0.98, 0.14, length), trim)
	# 尖艇头（更陡的收窄）。
	_add_box(Vector3(0.0, 1.0, length * 0.5 - 0.5), Vector3(width * 0.5, 0.6, 1.0), hull.darkened(0.1))
	# 风挡（一大块深色斜置感：用两层错位盒子模拟）。
	_add_box(Vector3(0.0, 1.85, length * 0.12), Vector3(width * 0.55, 0.9, 1.6), GLASS_DARK)
	_add_box(Vector3(0.0, 1.62, length * 0.12), Vector3(width * 0.6, 0.3, 1.7), trim)
	# 艇尾双引擎（两个深色小箱）。
	for sx in [-1.0, 1.0]:
		_add_box(Vector3(sx * width * 0.22, 1.0, -length * 0.46), Vector3(0.7, 0.9, 1.1), GLASS_DARK)
	# 艇头旗。
	_add_box(Vector3(0.0, 2.2, length * 0.5 - 0.2), Vector3(0.08, 0.9, 0.08), trim.darkened(0.3))
	_add_box(Vector3(0.24, 2.55, length * 0.5 - 0.2), Vector3(0.42, 0.28, 0.06), Color(0.95, 0.75, 0.1))


## 木筏：三根原木 + 一根横木 + 小旗（无舱，站上去就是驾驶位）。
func _build_raft(hull: Color, _trim: Color, length: float, width: float) -> void:
	# 三根原木（纵向排列，中间高两边低，像扎起来的筏子）。
	var log_len := length * 0.9
	for i in range(3):
		var off := (float(i) - 1.0) * width * 0.3
		var color: Color = hull if i != 1 else LOG_DARK
		_add_box(Vector3(off, 0.55, 0.0), Vector3(width * 0.3, 0.7, log_len), color)
	# 两根横木（捆扎）。
	for fz in [-0.28, 0.28]:
		_add_box(Vector3(0.0, 0.95, log_len * fz), Vector3(width * 0.95, 0.22, 0.5), LOG_DARK)
	# 桅杆 + 三角小旗。
	_add_box(Vector3(0.0, 1.9, -log_len * 0.28), Vector3(0.1, 1.8, 0.1), LOG_DARK.darkened(0.2))
	_add_box(Vector3(0.3, 2.55, -log_len * 0.28), Vector3(0.55, 0.4, 0.06), Color(0.9, 0.3, 0.25))


func _add_box(at: Vector3, size: Vector3, color: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.75
	mi.material_override = mat
	_root.add_child(mi)
