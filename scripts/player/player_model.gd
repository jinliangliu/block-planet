class_name PlayerModel
extends Node3D
## 方块风格玩家模型（头 / 躯干 / 双臂 / 双腿），第三人称时显示。
## 行走时四肢摆动（速度由 Player 每帧经 set_move_speed 推入）；
## swing_arms() 播放一次右手挥动动画，与第一人称手持模型同步触发。

const SKIN_COLOR := Color(0.87, 0.66, 0.51)
const SHIRT_COLOR := Color(0.30, 0.55, 0.85)
const PANTS_COLOR := Color(0.25, 0.28, 0.42)
const HAIR_COLOR := Color(0.25, 0.16, 0.10)
const WALK_SWING := 0.55
const WALK_PHASE_RATE := 1.8
const SPEED_THRESHOLD := 0.5

var _arm_pivot_l: Node3D
var _arm_pivot_r: Node3D
var _leg_pivot_l: Node3D
var _leg_pivot_r: Node3D
var _walk_phase := 0.0
var _move_speed := 0.0
var _third_person := false
var _swing_tween: Tween


func _ready() -> void:
	# D-062 P1：1 格 = 1 m，玩家模型按真实米制（1.8 m ≈ 1.8 格），不再 ×2。
	scale = Vector3.ONE
	_build()
	set_third_person(false)


## 切换第三人称显示；第一人称隐藏模型避免遮挡视线。
func set_third_person(value: bool) -> void:
	_third_person = value
	visible = value
	if not value and _swing_tween and _swing_tween.is_valid():
		_swing_tween.kill()


## Player 每帧推入水平速度大小，驱动行走摆动。
func set_move_speed(speed: float) -> void:
	_move_speed = speed


## 挥动手臂（破坏 / 攻击 / 放置时由 Player 调用，与手持模型同步）。
## 移动中不播放，避免与行走摆动叠加闪烁。
func swing_arms() -> void:
	if not _third_person or _move_speed > SPEED_THRESHOLD:
		return
	if _swing_tween and _swing_tween.is_valid():
		_swing_tween.kill()
	_arm_pivot_r.rotation.x = 0.0
	_swing_tween = create_tween()
	_swing_tween.tween_property(_arm_pivot_r, "rotation:x", -1.4, 0.08)
	_swing_tween.tween_property(_arm_pivot_r, "rotation:x", 0.0, 0.15)


func _process(delta: float) -> void:
	if not _third_person:
		return
	if _move_speed > SPEED_THRESHOLD:
		_walk_phase += delta * _move_speed * WALK_PHASE_RATE
		var swing := sin(_walk_phase) * WALK_SWING
		_arm_pivot_l.rotation.x = swing
		_arm_pivot_r.rotation.x = -swing
		_leg_pivot_l.rotation.x = -swing
		_leg_pivot_r.rotation.x = swing
	else:
		_walk_phase = 0.0
		for pivot: Node3D in [_arm_pivot_l, _arm_pivot_r, _leg_pivot_l, _leg_pivot_r]:
			pivot.rotation.x = lerpf(pivot.rotation.x, 0.0, minf(10.0 * delta, 1.0))


func _build() -> void:
	_add_box(Vector3(0.5, 0.4, 0.5), Vector3(0.0, 1.6, 0.0), SKIN_COLOR)
	_add_hair()
	_add_box(Vector3(0.5, 0.7, 0.25), Vector3(0.0, 1.05, 0.0), SHIRT_COLOR)
	_arm_pivot_l = _add_limb(Vector3(-0.375, 1.4, 0.0), Vector3(0.22, 0.7, 0.22), SKIN_COLOR)
	_arm_pivot_r = _add_limb(Vector3(0.375, 1.4, 0.0), Vector3(0.22, 0.7, 0.22), SKIN_COLOR)
	_leg_pivot_l = _add_limb(Vector3(-0.125, 0.7, 0.0), Vector3(0.24, 0.7, 0.24), PANTS_COLOR)
	_leg_pivot_r = _add_limb(Vector3(0.125, 0.7, 0.0), Vector3(0.24, 0.7, 0.24), PANTS_COLOR)


## 头发：头顶盖片 + 后脑 + 刘海，三块深棕盒体贴合头部（供测试断言的 Hair 命名）。
func _add_hair() -> void:
	var top := _add_box(Vector3(0.54, 0.12, 0.54), Vector3(0.0, 1.83, 0.0), HAIR_COLOR)
	top.name = "HairTop"
	var back := _add_box(Vector3(0.54, 0.32, 0.14), Vector3(0.0, 1.67, 0.21), HAIR_COLOR)
	back.name = "HairBack"
	var fringe := _add_box(Vector3(0.54, 0.08, 0.10), Vector3(0.0, 1.77, -0.23), HAIR_COLOR)
	fringe.name = "HairFringe"


## 是否已生成头发（供测试断言）。
func has_hair() -> bool:
	return find_child("HairTop", false, false) != null


func _add_box(size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _flat_material(color)
	mesh_instance.position = pos
	add_child(mesh_instance)
	return mesh_instance


## 四肢：枢轴在肩/髋部，网格悬挂于枢轴下方，旋转枢轴即摆动整条肢体。
func _add_limb(pivot_pos: Vector3, size: Vector3, color: Color) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = pivot_pos
	add_child(pivot)

	var mesh := BoxMesh.new()
	mesh.size = size
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _flat_material(color)
	mesh_instance.position = Vector3(0.0, -size.y * 0.5, 0.0)
	pivot.add_child(mesh_instance)
	return pivot


func _flat_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	return material
