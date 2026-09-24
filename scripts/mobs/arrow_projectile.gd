extends Node3D
class_name ArrowProjectile
## 骷髅射出的箭：直线飞行带轻微下坠。
## 每物理帧用射线扫过本帧位移：命中玩家扣血，命中方块消失，超时自动回收。
## 不依赖 World 引用与物理体，纯视觉网格 + 逻辑检测。

const SPEED := 14.0
const GRAVITY := 4.0
const LIFETIME := 3.0
const HIT_RADIUS := 0.7

var _player: Player
var _shooter: Node3D
var _velocity := Vector3.ZERO
var _age := 0.0


func setup(target: Player, dir: Vector3, shooter: Node3D) -> void:
	_player = target
	_shooter = shooter
	_velocity = dir.normalized() * SPEED


func _ready() -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.05, 0.05, 0.45)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.40, 0.22)
	mesh.mesh = box
	mesh.material_override = mat
	add_child(mesh)
	if _velocity.length_squared() > 0.001:
		look_at(global_position + _velocity, Vector3.UP)


func _physics_process(delta: float) -> void:
	_age += delta
	if _age >= LIFETIME:
		queue_free()
		return

	_velocity.y -= GRAVITY * delta
	var step := _velocity * delta
	var next := global_position + step

	# 扫描本帧位移：命中玩家扣血，命中方块终止；排除发射者自身。
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(global_position, next)
	if _shooter != null and is_instance_valid(_shooter):
		query.exclude = [_shooter.get_rid()]
	var hit := space.intersect_ray(query)
	if not hit.is_empty():
		var collider: Object = hit["collider"]
		if collider is Player:
			(collider as Player).take_damage(1)
		queue_free()
		return

	global_position = next
	if _velocity.length_squared() > 0.001:
		look_at(global_position + _velocity, Vector3.UP)

	# 兜底：极少数穿透情况下按距离判定。
	if _player != null and is_instance_valid(_player):
		if global_position.distance_to(_player.global_position + Vector3(0.0, 0.9, 0.0)) < HIT_RADIUS:
			_player.take_damage(1)
			queue_free()
