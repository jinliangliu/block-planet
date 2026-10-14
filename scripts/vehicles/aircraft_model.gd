class_name AircraftModel
extends Node3D
## 轻型机机模：全部代码生成（机身/机翼/尾翼/起落架/螺旋桨），不依赖外部资源。
## 只负责表现——不做物理、不做决策，物理在 Aircraft，气动在 AircraftFlight。
## 机头朝 −Z（Godot 约定），原点位于重心，机轮着地面在 y = −GROUND_CLEARANCE。
##
## MODEL_SCALE = 3：玩家身高 1.8 m（3.6 格），机模必须随之放大才能「坐进座舱」——
## 原始 1:1 机模全机最高仅约 1.13 m（2.28 格，座舱罩顶），飞行员坐进座位后眼位
## 1.85 m 反而高于全机最高点，第一人称实为「骑在机背」。放大后（渲染米）翼展
## 24 m（48 格）、机长 10.2 m（约 20 格）、垂尾顶 4.28 m（8.55 格），座舱罩顶
## 2.99 m，飞行员眼位 2.75 m 落在罩内。

## 机模整体缩放（无单位）：所有部件尺寸与位置统一乘这个系数。
const MODEL_SCALE := 3.0

const GROUND_CLEARANCE := 0.85 * MODEL_SCALE

const BODY_COLOR := Color(0.93, 0.94, 0.96)
const ACCENT_COLOR := Color(0.84, 0.26, 0.22)
const GLASS_COLOR := Color(0.62, 0.80, 0.90, 0.35)
const DARK_COLOR := Color(0.22, 0.23, 0.26)
const PROP_COLOR := Color(0.32, 0.32, 0.35)

## 螺旋桨转速上限（rad/s 视觉转速），满油门时到达。
const PROP_MAX_SPIN := 42.0

var _propeller: Node3D
var _elevator: Node3D
var _aileron_left: Node3D
var _aileron_right: Node3D
## 角色 → 材质数组：机身/强调两块可随涂装改色，其余（玻璃/暗件/桨）固定。
var _role_materials: Dictionary = {}
## 当前已应用的涂装索引（-1 = 尚未应用）。
var _livery_index := -1


func _ready() -> void:
	build()


## 生成全部部件。幂等：重复调用不重复添加。
## 括号里的尺寸/位置是设计米数，渲染时统一乘 MODEL_SCALE。
func build() -> void:
	if _propeller != null:
		return
	# 机身：前段略窄 + 座舱 + 尾锥。
	_add_box(self, Vector3(0.92, 0.86, 3.4) * MODEL_SCALE, BODY_COLOR,
		Vector3(0.0, 0.15, -0.5) * MODEL_SCALE, "body")
	_add_box(self, Vector3(0.78, 0.70, 1.6) * MODEL_SCALE, ACCENT_COLOR,
		Vector3(0.0, 0.10, 1.9) * MODEL_SCALE, "accent")
	# 座舱罩：抬高的玻璃舱，第一人称眼位要落进这个盒子里。
	_add_box(self, Vector3(0.9, 0.55, 0.9) * MODEL_SCALE, BODY_COLOR,
		Vector3(0.0, 0.72, -1.1) * MODEL_SCALE, "body")
	# 风挡：座舱罩前缘的半透明玻璃，从舱内看是一块真正的风挡。
	_add_box(self, Vector3(0.7, 0.42, 0.16) * MODEL_SCALE, GLASS_COLOR,
		Vector3(0.0, 0.78, -1.52) * MODEL_SCALE)
	# 机翼：上单翼，横贯机身。
	_add_box(self, Vector3(8.0, 0.14, 1.5) * MODEL_SCALE, BODY_COLOR,
		Vector3(0.0, 0.52, -0.7) * MODEL_SCALE, "body")
	_add_box(self, Vector3(1.4, 0.16, 1.5) * MODEL_SCALE, ACCENT_COLOR,
		Vector3(3.4, 0.52, -0.7) * MODEL_SCALE, "accent")
	_add_box(self, Vector3(1.4, 0.16, 1.5) * MODEL_SCALE, ACCENT_COLOR,
		Vector3(-3.4, 0.52, -0.7) * MODEL_SCALE, "accent")
	# 副翼：机翼后缘外侧，随滚转杆偏转。
	_aileron_left = _add_box(self, Vector3(1.5, 0.09, 0.42) * MODEL_SCALE, ACCENT_COLOR,
		Vector3(-2.9, 0.52, 0.08) * MODEL_SCALE, "accent")
	_aileron_right = _add_box(self, Vector3(1.5, 0.09, 0.42) * MODEL_SCALE, ACCENT_COLOR,
		Vector3(2.9, 0.52, 0.08) * MODEL_SCALE, "accent")
	# 尾翼：垂直安定面 + 水平安定面 + 升降舵。
	_add_box(self, Vector3(0.12, 1.15, 1.0) * MODEL_SCALE, ACCENT_COLOR,
		Vector3(0.0, 0.85, 2.6) * MODEL_SCALE, "accent")
	_add_box(self, Vector3(2.6, 0.12, 0.9) * MODEL_SCALE, BODY_COLOR,
		Vector3(0.0, 0.42, 2.7) * MODEL_SCALE, "body")
	_elevator = _add_box(self, Vector3(2.4, 0.09, 0.42) * MODEL_SCALE, ACCENT_COLOR,
		Vector3(0.0, 0.42, 3.2) * MODEL_SCALE, "accent")
	# 起落架：前三点式（前轮 + 左右主轮），机轮底面即 y = −GROUND_CLEARANCE。
	_add_box(self, Vector3(0.08, 0.5, 0.08) * MODEL_SCALE, DARK_COLOR,
		Vector3(0.0, -0.58, -1.7) * MODEL_SCALE)
	_add_box(self, Vector3(0.24, 0.24, 0.16) * MODEL_SCALE, DARK_COLOR,
		Vector3(0.0, -0.73, -1.7) * MODEL_SCALE)
	for side: float in [-1.0, 1.0]:
		_add_box(self, Vector3(0.1, 0.55, 0.1) * MODEL_SCALE, DARK_COLOR,
			Vector3(0.85 * side, -0.55, 0.35) * MODEL_SCALE)
		_add_box(self, Vector3(0.3, 0.3, 0.2) * MODEL_SCALE, DARK_COLOR,
			Vector3(0.85 * side, -0.72, 0.35) * MODEL_SCALE)
	# 螺旋桨：一枚绕 Z 轴旋转的细桨叶 + 桨毂。
	var hub := Node3D.new()
	hub.position = Vector3(0.0, 0.62, -2.24) * MODEL_SCALE
	add_child(hub)
	_propeller = hub
	_add_box(hub, Vector3(0.16, 2.3, 0.06) * MODEL_SCALE, PROP_COLOR, Vector3.ZERO)
	_add_box(hub, Vector3(2.3, 0.16, 0.06) * MODEL_SCALE, PROP_COLOR, Vector3.ZERO)
	_add_box(hub, Vector3(0.22, 0.22, 0.3) * MODEL_SCALE, DARK_COLOR, Vector3(0.0, 0.0, 0.1))

	# 建模完成后套用当前涂装（默认经典红白，与重构前外观一致）。
	set_livery_index(_livery_index if _livery_index >= 0 else 0)


## 按涂装索引给机身/强调两块换色；越界自动夹回。玻璃、暗件、桨叶保持固定色。
func set_livery_index(index: int) -> void:
	if _role_materials.is_empty():
		# 尚未 build（材质还没建）：记住索引，build() 末尾会套用。
		_livery_index = clampi(index, 0, AircraftLivery.count() - 1)
		return
	_livery_index = clampi(index, 0, AircraftLivery.count() - 1)
	_apply_role("body", AircraftLivery.body_of(_livery_index))
	_apply_role("accent", AircraftLivery.accent_of(_livery_index))


## 当前已应用的涂装索引。
func livery_index() -> int:
	return _livery_index


func _apply_role(role: String, color: Color) -> void:
	var mats: Array = _role_materials.get(role, [])
	for mat: StandardMaterial3D in mats:
		mat.albedo_color = color


## 螺旋桨视觉转速：rpm01 为油门归一化值，delta 为帧间隔。
func spin_propeller(rpm01: float, delta: float) -> void:
	if _propeller == null:
		return
	_propeller.rotate_z(-PROP_MAX_SPIN * clampf(rpm01, 0.0, 1.0) * delta)


## 操纵面偏转：roll 为副翼杆量（+1 右滚），pitch 为升降舵（+1 抬头）。
func deflect_controls(roll: float, pitch: float) -> void:
	if _aileron_left != null:
		_aileron_left.rotation.z = roll * 0.5
		_aileron_right.rotation.z = -roll * 0.5
	if _elevator != null:
		_elevator.rotation.x = -pitch * 0.5


func _add_box(
		parent: Node3D, size: Vector3, color: Color, pos: Vector3, role: String = ""
) -> Node3D:
	var holder := Node3D.new()
	holder.position = pos
	parent.add_child(holder)
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.55
	mat.metallic = 0.15
	if color.a < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material_override = mat
	holder.add_child(mesh)
	if role != "":
		if not _role_materials.has(role):
			_role_materials[role] = []
		var list: Array = _role_materials[role]
		list.append(mat)
	return holder
