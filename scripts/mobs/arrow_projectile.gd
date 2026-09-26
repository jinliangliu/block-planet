extends Node3D
class_name ArrowProjectile
## 箭：直线飞行带轻微下坠。
## 每物理帧用射线扫过本帧位移：命中扣血、命中方块消失、超时自动回收。
## 不依赖 World 引用与物理体，纯视觉网格 + 逻辑检测。
## 两种来源：骷髅射向玩家（HOSTILE），玩家蓄力射向生物（PLAYER_SHOT）。

const SPEED := 28.0
const GRAVITY := 8.0
const LIFETIME := 3.0
const HIT_RADIUS := 1.4
## 玩家射击的速度区间（蓄力比例 0..1 映射）。
const PLAYER_SPEED_MIN := 18.0
const PLAYER_SPEED_MAX := 36.0

enum Mode { HOSTILE, PLAYER_SHOT }

var _player: Player
var _shooter: Node3D
var _velocity := Vector3.ZERO
var _age := 0.0
var _mode := Mode.HOSTILE
var _damage := 1


## 骷髅射箭：朝向玩家，命中玩家扣 1 点生命。
func setup(target: Player, dir: Vector3, shooter: Node3D) -> void:
	_player = target
	_shooter = shooter
	_mode = Mode.HOSTILE
	_damage = 1
	_velocity = dir.normalized() * SPEED


## 玩家射箭：按蓄力比例决定初速，命中生物按其规则扣血。
func setup_player_shot(shooter: Node3D, dir: Vector3, charge: float, damage: int) -> void:
	_player = null
	_shooter = shooter
	_mode = Mode.PLAYER_SHOT
	_damage = maxi(1, damage)
	_velocity = dir.normalized() * lerpf(PLAYER_SPEED_MIN, PLAYER_SPEED_MAX, clampf(charge, 0.0, 1.0))


func _ready() -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.2, 0.2, 1.8)
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
		if _mode == Mode.PLAYER_SHOT:
			# 玩家射出的箭只伤生物：保护动物与幼体由 HuntRules 判定为免伤。
			if collider is Mob:
				var strike := HuntRules.arrow_damage(collider as Mob, _damage)
				if strike > 0:
					(collider as Mob).take_damage(strike)
				else:
					Events.notice.emit("🛡 %s 受到保护，箭被弹开了。" % (collider as Mob).stage_name())
		elif collider is Player:
			(collider as Player).take_damage(_damage, Player.REASON_ARROW)
		queue_free()
		return

	global_position = next
	if _velocity.length_squared() > 0.001:
		look_at(global_position + _velocity, Vector3.UP)

	# 兜底：极少数穿透情况下按距离判定。
	if _mode == Mode.HOSTILE and _player != null and is_instance_valid(_player):
		if global_position.distance_to(_player.global_position + Vector3(0.0, 1.8, 0.0)) < HIT_RADIUS:
			_player.take_damage(_damage, Player.REASON_ARROW)
			queue_free()
