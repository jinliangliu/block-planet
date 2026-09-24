extends Node3D
class_name FishingBobber
## 鱼竿浮标：抛到水面上后轻轻上下浮动，咬钩瞬间下沉抖动；
## 同时用一根细长方体把浮标与玩家手中的竿尖连起来（每帧重新摆放）。
## 由 Player 创建与回收，自身不判断钓况——咬钩时机由 Player 的垂钓状态机掌管。

const BOB_SPEED := 3.4
const BOB_AMPLITUDE := 0.06
const LINE_THICKNESS := 0.012
## 浮标与竿尖（相机）距离过远时视为脱线。
const LINE_MAX := 40.0

var _player: Player
var _line: MeshInstance3D
var _body: MeshInstance3D
var _phase := 0.0
var _biting := false
var _base_y := 0.0


func setup(player: Player) -> void:
	_player = player


func _ready() -> void:
	_body = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.09
	sphere.height = 0.18
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.92, 0.30, 0.26)
	_body.mesh = sphere
	_body.material_override = mat
	add_child(_body)
	# 上半白、下半红的标准浮标配色。
	var cap := MeshInstance3D.new()
	var cap_mesh := SphereMesh.new()
	cap_mesh.radius = 0.089
	cap_mesh.height = 0.1
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = Color(0.95, 0.95, 0.93)
	cap.mesh = cap_mesh
	cap.material_override = cap_mat
	cap.position = Vector3(0.0, 0.045, 0.0)
	add_child(cap)

	_line = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(LINE_THICKNESS, LINE_THICKNESS, 1.0)
	var line_mat := StandardMaterial3D.new()
	line_mat.albedo_color = Color(0.92, 0.92, 0.88, 0.85)
	line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_line.mesh = box
	_line.material_override = line_mat
	add_child(_line)

	_base_y = global_position.y


## 咬钩表现：浮标下沉并加快抖动。
func set_biting(biting: bool) -> void:
	_biting = biting


func is_biting() -> bool:
	return _biting


func _process(delta: float) -> void:
	_phase += delta * (BOB_SPEED * (2.6 if _biting else 1.0))
	var sink := -0.12 if _biting else 0.0
	var offset := sin(_phase) * (BOB_AMPLITUDE * (2.4 if _biting else 1.0))
	_body.position.y = offset + sink
	_update_line()


## 钓线：从玩家相机的竿尖拉到浮标，位置取中点、朝向对齐、Z 轴缩放到距离。
func _update_line() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var from := _player.camera_position()
	var to := global_position
	var span := to - from
	var length := span.length()
	if length < 0.01 or length > LINE_MAX:
		_line.visible = false
		return
	_line.visible = true
	_line.global_position = (from + to) * 0.5 + Vector3(0.0, 0.12, 0.0)
	_line.look_at(to, Vector3.UP)
	_line.scale = Vector3(1.0, 1.0, length)
