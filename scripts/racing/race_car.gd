class_name RaceCar
extends Node3D
## 赛车的外观节点：按「车型」程序化拼出体素风小车，并把 CarPhysics 的位姿
## 每帧搬到节点上（车轮跟着转、前轮跟着打方向）。
##
## 与 aircraft_model 同思路：物理/规则在纯逻辑层，这里只负责「看起来像在开车」。
## 车轮按 kind 摆放——三轮车三只、摩托两只、沙滩车/方程式四只。

const WHEEL_R := 0.45
const WHEEL_W := 0.34
## 地形粒子（M9 粒子反馈）：沙石扬尘 / 湿地水花各一路。数据侧 `terrain.json`
## 的 dust / wet 标志早已写就但一直无人消费，这里是它唯一的消费方。
## 中低端 Android 硬约束：CPU 粒子（与 BreakFx 同族，不依赖 GPU 特性）、
## 数量压到 12、不投影、寿命 0.5 s——单帧开销可忽略。
const FX_AMOUNT := 12
const FX_LIFETIME := 0.5
## 低于该速度比例不出特效：慢速挪车扬尘会显得莫名其妙。
const FX_MIN_RATIO := 0.22

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
var _dust_fx: CPUParticles3D
var _splash_fx: CPUParticles3D


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
	_dust_fx = null
	_splash_fx = null
	_body = Node3D.new()
	_body.name = "Body"
	add_child(_body)
	_build_fx()

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


## 地形粒子开关（M9）：由当前地形数据的 dust / wet 标志 + 车速比例驱动。
## speed_ratio 为该车当前车速 / 本车极速（0~1）。两路特效互斥（数据里不会
## 同时为真，但这里也按「湿优先」处理，避免将来数据写错时两层粒子叠加）。
func set_terrain_fx(terrain: Dictionary, speed_ratio: float) -> void:
	var ratio := clampf(speed_ratio, 0.0, 1.0)
	var fast := ratio >= FX_MIN_RATIO
	var wet := fast and bool(terrain.get("wet", false))
	var dust := fast and not wet and bool(terrain.get("dust", false))
	if _splash_fx != null:
		_splash_fx.emitting = wet
	if _dust_fx != null:
		_dust_fx.emitting = dust


func _build_fx() -> void:
	# 扬尘：沙土色，从车底往后上方翻起。
	_dust_fx = _make_fx(Color(0.80, 0.72, 0.56, 0.55), 0.24, 0.5)
	_dust_fx.name = "DustFx"
	add_child(_dust_fx)
	# 水花：淡青白，更碎更快地溅开。
	_splash_fx = _make_fx(Color(0.70, 0.88, 0.98, 0.55), 0.18, 0.9)
	_splash_fx.name = "SplashFx"
	add_child(_splash_fx)


func _make_fx(color: Color, size: float, up_bias: float) -> CPUParticles3D:
	var particles := CPUParticles3D.new()
	particles.amount = FX_AMOUNT
	particles.lifetime = FX_LIFETIME
	# 关闭 emitting 起步：只有真的跑到沙石/湿地上才开，柏油路面一路零开销。
	particles.emitting = false
	particles.local_coords = false
	particles.direction = Vector3(0.0, up_bias, 0.0).normalized()
	particles.spread = 38.0
	particles.initial_velocity_min = 1.8
	particles.initial_velocity_max = 3.6
	particles.gravity = Vector3(0.0, -4.5, 0.0)
	particles.scale_amount_min = 0.55
	particles.scale_amount_max = 1.35
	particles.position = Vector3(0.0, 0.10, 0.0)
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * size
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.roughness = 1.0
	mesh.material = material
	particles.mesh = mesh
	return particles


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
