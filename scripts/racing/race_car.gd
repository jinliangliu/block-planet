class_name RaceCar
extends Node3D
## 赛车的外观节点：按「车型」程序化拼出体素风小车，并把 CarPhysics 的位姿
## 每帧搬到节点上（车轮跟着转、前轮跟着打方向）。
##
## 与 aircraft_model 同思路：物理/规则在纯逻辑层，这里只负责「看起来像在开车」。
## 车轮按 kind 摆放——三轮车三只、摩托两只、沙滩车/方程式四只。

const WHEEL_R := 0.45
const WHEEL_W := 0.34

var spec: Dictionary = {}
var body_color := Color.WHITE

var _body: Node3D
var _wheels: Array[Node3D] = []
var _front_wheels: Array[Node3D] = []
var _lamps: Array[MeshInstance3D] = []
var _lamp_mat: StandardMaterial3D
var _spin := 0.0
var _steer_vis := 0.0
var lights_on := false


## 按车辆数据拼装。tint 用于把机器人车染成区分色（默认不染）。
func build(p_spec: Dictionary, tint: Color = Color.WHITE) -> void:
	spec = p_spec
	body_color = Color(String(spec.get("color", "#B0B0B0")))
	if tint != Color.WHITE:
		body_color = body_color.lerp(tint, 0.45)
	for child in get_children():
		child.queue_free()
	_wheels.clear()
	_front_wheels.clear()
	_lamps.clear()
	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)

	var kind := String(spec.get("kind", "buggy"))
	match kind:
		"tricycle":
			_add_wheel(Vector3(0.0, WHEEL_R, 1.15), true)
			_add_wheel(Vector3(-0.95, WHEEL_R, -0.85), false)
			_add_wheel(Vector3(0.95, WHEEL_R, -0.85), false)
			_add_box(Vector3(0.0, 0.62, -0.25), Vector3(1.2, 0.55, 2.0), body_color)
			_add_box(Vector3(0.0, 1.05, -0.45), Vector3(0.8, 0.55, 0.8), body_color.darkened(0.25))
			_add_basket()
		"motorcycle":
			_add_wheel(Vector3(0.0, WHEEL_R, 1.05), true)
			_add_wheel(Vector3(0.0, WHEEL_R, -1.05), false)
			_add_box(Vector3(0.0, 0.75, 0.0), Vector3(0.42, 0.5, 1.9), body_color)
			_add_box(Vector3(0.0, 1.15, -0.15), Vector3(0.75, 0.42, 0.85), Color(0.20, 0.22, 0.28))
		"racer":
			_add_wheel(Vector3(-0.9, WHEEL_R, 1.35), true)
			_add_wheel(Vector3(0.9, WHEEL_R, 1.35), true)
			_add_wheel(Vector3(-0.95, WHEEL_R, -1.25), false)
			_add_wheel(Vector3(0.95, WHEEL_R, -1.25), false)
			_add_box(Vector3(0.0, 0.42, 0.2), Vector3(1.7, 0.4, 3.0), body_color)
			_add_box(Vector3(0.0, 0.72, -0.35), Vector3(0.9, 0.42, 1.0), body_color.darkened(0.3))
			# 前后翼
			_add_box(Vector3(0.0, 0.30, 1.62), Vector3(2.0, 0.12, 0.5), body_color.lightened(0.1))
			_add_box(Vector3(0.0, 1.05, -1.5), Vector3(1.9, 0.14, 0.7), body_color.lightened(0.1))
		_:
			_add_wheel(Vector3(-0.98, WHEEL_R, 1.05), true)
			_add_wheel(Vector3(0.98, WHEEL_R, 1.05), true)
			_add_wheel(Vector3(-0.98, WHEEL_R, -1.05), false)
			_add_wheel(Vector3(0.98, WHEEL_R, -1.05), false)
			_add_box(Vector3(0.0, 0.66, 0.0), Vector3(1.8, 0.6, 2.8), body_color)
			_add_box(Vector3(0.0, 1.12, -0.25), Vector3(1.5, 0.5, 1.4), body_color.darkened(0.28))
			_add_box(Vector3(0.0, 1.30, -1.15), Vector3(0.16, 0.7, 0.16), Color(0.75, 0.78, 0.82))
	_add_lamps()


func _add_box(at: Vector3, size: Vector3, color: Color) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.7
	mi.material_override = mat
	_body.add_child(mi)


## 车头两盏灯：平时暗着，按「车灯」键变成自发光的暖黄。
func _add_lamps() -> void:
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.albedo_color = Color(0.95, 0.92, 0.72)
	_lamp_mat.emission_enabled = false
	_lamp_mat.emission = Color(1.0, 0.95, 0.60)
	_lamp_mat.emission_energy_multiplier = 2.0
	for x in [-0.55, 0.55]:
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.34, 0.22, 0.14)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.position = Vector3(x, 0.72, 1.42)
		mi.material_override = _lamp_mat
		_body.add_child(mi)
		_lamps.append(mi)


## 小三轮车后斗：孩子一眼能认出「这是我那辆小三轮」。
func _add_basket() -> void:
	_add_box(Vector3(0.0, 0.95, -1.05), Vector3(1.0, 0.5, 0.7), body_color.darkened(0.15))


func _add_wheel(at: Vector3, is_front: bool) -> void:
	var pivot := Node3D.new()
	pivot.position = at
	var cyl := CylinderMesh.new()
	cyl.top_radius = WHEEL_R
	cyl.bottom_radius = WHEEL_R
	cyl.height = WHEEL_W
	cyl.radial_segments = 12
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.rotation.z = deg_to_rad(90.0)   # 圆柱轴由 Y 转到 X，成为车轮
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.16, 0.18)
	mat.roughness = 0.9
	mi.material_override = mat
	pivot.add_child(mi)
	_body.add_child(pivot)
	_wheels.append(pivot)
	if is_front:
		_front_wheels.append(pivot)


func set_lights(on: bool) -> void:
	lights_on = on
	if _lamp_mat != null:
		_lamp_mat.emission_enabled = on


## 把纯逻辑体的位姿搬到节点上。
func sync_from(car: CarPhysics, delta: float) -> void:
	position = Vector3(car.pos.x, 0.0, car.pos.y)
	rotation.y = car.heading
	_spin -= car.speed() * delta / WHEEL_R
	_steer_vis = lerpf(_steer_vis, -car.steer * 0.5, clampf(delta * 10.0, 0.0, 1.0))
	for w in _wheels:
		w.rotation.x = _spin
	for w in _front_wheels:
		w.rotation.y = _steer_vis
