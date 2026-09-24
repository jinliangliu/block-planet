extends CharacterBody3D
class_name Mob
## 生物基类。
## 敌对（夜晚由 MobSpawner 生成、白天清空）：僵尸近战、蜘蛛快速近战、骷髅远程射箭。
## 被动（白天生成、持续存在）：牛/羊/鸡/猪随机游荡，受击后短暂逃跑，不会攻击。
## 水生（由 MobSpawner 水生物轨道生成，不参与昼夜清空）：鱼/虾/蟹栖息大河，
## 蜻蜓/青蛙栖息小池塘。

const GRAVITY := 24.0
## 被动生物受击后的逃跑时长（秒）。
const FLEE_TIME := 3.0
## 被动生物游荡节奏：走一段（随机方向）→ 驻足一会儿 → 再走，交替进行。
const WANDER_WALK_MIN := 1.5
const WANDER_WALK_MAX := 3.5
const WANDER_IDLE_MIN := 1.5
const WANDER_IDLE_MAX := 4.0
## 骷髅与玩家保持的射击距离：更近后撤、更远逼近。
const SKELETON_STANDOFF_MIN := 4.0
const SKELETON_STANDOFF_MAX := 9.0
## 鱼虾游动节奏与活动半径（围绕出生点，避免游上岸）。
const SWIM_WALK_MIN := 2.0
const SWIM_WALK_MAX := 4.5
const SWIM_RADIUS := 6.0
## 蜻蜓悬停半径与上下浮动参数。
const FLY_RADIUS := 5.0
const FLY_BOB_SPEED := 2.6
const FLY_BOB_AMPLITUDE := 0.6
## 青蛙起跳初速与两次起跳的间隔（秒）。
const HOP_SPEED := 5.2
const HOP_INTERVAL_MIN := 1.2
const HOP_INTERVAL_MAX := 2.6

enum MobType {
	ZOMBIE,
	SKELETON,
	SPIDER,
	COW,
	SHEEP,
	CHICKEN,
	PIG,
	VILLAGER,
	PILLAGER,
	WOLF,
	FISH,
	SHRIMP,
	CRAB,
	DRAGONFLY,
	FROG,
}

## 栖息地：决定移动方式（陆地重力行走 / 水中游动 / 空中悬停）。
enum Habitat {
	LAND,
	WATER,
	AIR,
}

var type: MobType = MobType.ZOMBIE
var player: Player
var day_night: DayNightCycle

var health := 5
var max_health := 5
var speed := 2.2
var attack_damage := 2
var attack_range := 1.5
var attack_cooldown := 1.2
var drop_item: int = BlockTypes.Block.WOOD
var drop_count := 1
## 多物品掉落表（[[id, count], ...]）；非空时优先于 drop_item。
var drop_table: Array = []

var _attack_timer := 0.0
# 被动生物游荡状态：方向为零表示驻足。
var _wander_dir := Vector3.ZERO
var _wander_timer := 0.0
var _flee_timer := 0.0
# 头顶名称与生命标签（打猎时直接可读）。
var _nametag: Label3D
# 水生/飞行生物用：世界引用、出生点活动中心、浮动相位与起跳计时。
var _world: World
var _home := Vector3.ZERO
var _home_ready := false
var _flight_phase := 0.0
var _hop_timer := 0.6

## 生物类型 → 显示名。
const MOB_NAMES := {
	MobType.ZOMBIE: "小僵尸",
	MobType.SKELETON: "小骷髅",
	MobType.SPIDER: "小蜘蛛",
	MobType.COW: "牛",
	MobType.SHEEP: "羊",
	MobType.CHICKEN: "鸡",
	MobType.PIG: "猪",
	MobType.VILLAGER: "村民",
	MobType.PILLAGER: "掠夺者",
	MobType.WOLF: "狼",
	MobType.FISH: "鱼",
	MobType.SHRIMP: "虾",
	MobType.CRAB: "蟹",
	MobType.DRAGONFLY: "蜻蜓",
	MobType.FROG: "青蛙",
}


func display_name() -> String:
	return MOB_NAMES.get(type, "生物")


## 被动生物：不攻击、受击逃跑。水生物同为被动，但不参与陆地生成轨道。
static func is_passive(t: MobType) -> bool:
	return (
		t == MobType.COW
		or t == MobType.SHEEP
		or t == MobType.CHICKEN
		or t == MobType.PIG
		or t == MobType.VILLAGER
		or t == MobType.FISH
		or t == MobType.SHRIMP
		or t == MobType.CRAB
		or t == MobType.DRAGONFLY
		or t == MobType.FROG
	)


## 栖息地：鱼/虾/蟹在水中，蜻蜓在空中，其余在陆地。
static func habitat_of(t: MobType) -> Habitat:
	match t:
		MobType.FISH, MobType.SHRIMP, MobType.CRAB:
			return Habitat.WATER
		MobType.DRAGONFLY:
			return Habitat.AIR
		_:
			return Habitat.LAND


## 水生物：鱼/虾/蟹（大河）与蜻蜓/青蛙（池塘），由水生物轨道生成。
static func is_aquatic(t: MobType) -> bool:
	return (
		t == MobType.FISH
		or t == MobType.SHRIMP
		or t == MobType.CRAB
		or t == MobType.DRAGONFLY
		or t == MobType.FROG
	)


func setup(mob_type: MobType, target: Player, dn: DayNightCycle) -> void:
	type = mob_type
	player = target
	day_night = dn
	_apply_type_stats()


func _ready() -> void:
	add_to_group("mobs")
	_build_visual()
	_build_collision()
	_build_nametag()


func _physics_process(delta: float) -> void:
	if player == null or day_night == null:
		return

	_attack_timer = maxf(0.0, _attack_timer - delta)
	if _world == null:
		_world = player.get_world()

	_process_behaviour(delta)
	move_and_slide()


## 行为分发：陆地（重力 + 被动游荡 / 敌对追击 / 青蛙跳跃）、
## 水中（鱼虾悬停游动、蟹贴底爬行）、空中（蜻蜓悬停）。
func _process_behaviour(delta: float) -> void:
	match Mob.habitat_of(type):
		Habitat.WATER:
			if type == MobType.CRAB:
				_crawl_on_bed(delta)
			else:
				_process_swimming(delta)
		Habitat.AIR:
			_process_flying(delta)
		_:
			_apply_gravity(delta)
			if type == MobType.FROG:
				_process_hopping(delta)
			elif Mob.is_passive(type):
				_process_passive(delta)
			else:
				_process_hostile(delta)


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = -0.5


## 敌对行为：白天远离玩家，夜晚追逐；僵尸/蜘蛛近战，骷髅远程。
func _process_hostile(delta: float) -> void:
	var to_player := player.global_position - global_position
	var flat := Vector3(to_player.x, 0.0, to_player.z)
	var dist := flat.length()
	if dist > 0.001:
		flat = flat / dist

	var is_day := day_night.is_day()
	if is_day:
		# 掠夺者是塔的常驻守卫：白天不逃跑，原地驻守。
		if type == MobType.PILLAGER:
			velocity.x = 0.0
			velocity.z = 0.0
			return
		_move_toward(-flat)
		return

	if type == MobType.SKELETON:
		_process_skeleton(dist, flat)
		return

	# 僵尸/蜘蛛：贴近后近战。
	if dist > attack_range:
		_move_toward(flat)
	else:
		velocity.x = 0.0
		velocity.z = 0.0
		if _attack_timer <= 0.0 and _has_line_of_sight():
			player.take_damage(attack_damage)
			_attack_timer = attack_cooldown


## 骷髅远程：太近后撤、太远逼近，射程内且有视线时定时放箭。
func _process_skeleton(dist: float, flat: Vector3) -> void:
	if dist < SKELETON_STANDOFF_MIN:
		_move_toward(-flat)
	elif dist > SKELETON_STANDOFF_MAX:
		_move_toward(flat)
	else:
		velocity.x = 0.0
		velocity.z = 0.0
		look_at(global_position + flat, Vector3.UP)
		if _attack_timer <= 0.0 and _has_line_of_sight():
			_shoot_arrow()
			_attack_timer = attack_cooldown


func _move_toward(dir: Vector3) -> void:
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	if dir.length_squared() > 0.001:
		look_at(global_position + dir, Vector3.UP)


func _shoot_arrow() -> void:
	if get_parent() == null:
		return
	var arrow := ArrowProjectile.new()
	var target := player.global_position + Vector3(0.0, 0.9, 0.0)
	arrow.setup(player, (target - _chest_position()).normalized(), self)
	get_parent().add_child(arrow)
	arrow.global_position = _chest_position()


func _chest_position() -> Vector3:
	return global_position + Vector3(0.0, 0.9, 0.0)


## 被动行为：受击逃跑优先；否则按计时器在"随机方向慢走"与"驻足"间切换。
func _process_passive(delta: float) -> void:
	if _flee_timer > 0.0:
		_flee_timer -= delta
		var away := global_position - player.global_position
		away.y = 0.0
		if away.length_squared() > 0.001:
			var dir := away.normalized()
			velocity.x = dir.x * speed
			velocity.z = dir.z * speed
			look_at(global_position + dir, Vector3.UP)
		else:
			velocity.x = 0.0
			velocity.z = 0.0
		return

	_wander_timer -= delta
	if _wander_dir != Vector3.ZERO:
		velocity.x = _wander_dir.x * speed
		velocity.z = _wander_dir.z * speed
		look_at(global_position + _wander_dir, Vector3.UP)
		# 撞墙即重新选向，避免卡在障碍上持续推挤。
		if is_on_wall():
			_start_wander()
	else:
		velocity.x = 0.0
		velocity.z = 0.0

	if _wander_timer <= 0.0:
		if _wander_dir != Vector3.ZERO:
			# 走够了：原地驻足一会儿再出发。
			_wander_dir = Vector3.ZERO
			_wander_timer = randf_range(WANDER_IDLE_MIN, WANDER_IDLE_MAX)
		else:
			_start_wander()


func _start_wander() -> void:
	var angle := randf() * TAU
	_wander_dir = Vector3(cos(angle), 0.0, sin(angle))
	_wander_timer = randf_range(WANDER_WALK_MIN, WANDER_WALK_MAX)


## 鱼虾水下游动：无重力悬停，受击逃向远离玩家方向，活动范围围绕出生点。
func _process_swimming(delta: float) -> void:
	_remember_home()
	if _flee_timer > 0.0:
		_flee_timer -= delta
		_swim_toward(global_position - player.global_position)
		return

	_wander_timer -= delta
	if _wander_timer <= 0.0 or is_on_wall():
		_pick_swim_direction()
	if global_position.distance_to(_home) > SWIM_RADIUS:
		_swim_toward(_home - global_position)
		return
	_swim_toward(_wander_dir)


## 蟹：贴着水底爬行——与被动动物同款游荡逻辑，但保留重力。
func _crawl_on_bed(delta: float) -> void:
	_apply_gravity(delta)
	_process_passive(delta)


## 蜻蜓：无重力悬停，在水面上方小幅游荡并上下浮动。
func _process_flying(delta: float) -> void:
	_remember_home()
	_wander_timer -= delta
	if _wander_timer <= 0.0 or is_on_wall():
		_pick_swim_direction()

	_flight_phase += delta * FLY_BOB_SPEED
	var bob := sin(_flight_phase) * FLY_BOB_AMPLITUDE
	var dir := _wander_dir
	if global_position.distance_to(_home) > FLY_RADIUS:
		var back := _home - global_position
		if back.length_squared() > 0.001:
			dir = back.normalized()
	velocity = Vector3(dir.x * speed, bob, dir.z * speed)
	_face(dir)


## 青蛙：被动游荡 + 落地蓄力后间歇起跳（一蹦一蹦）。
func _process_hopping(delta: float) -> void:
	_process_passive(delta)
	if is_on_floor():
		_hop_timer -= delta
		if _hop_timer <= 0.0:
			velocity.y = HOP_SPEED
			_hop_timer = randf_range(HOP_INTERVAL_MIN, HOP_INTERVAL_MAX)


## 水中移动：速度含竖直分量（上下游动），并校正以免跃出水面。
func _swim_toward(dir: Vector3) -> void:
	if dir.length_squared() > 0.001:
		velocity = dir.normalized() * speed
		_face(dir)
	else:
		velocity = Vector3.ZERO
	_keep_submerged()


## 鱼虾不得跃出水面：整个身体离开水体就立刻下潜；撞到岸边则换向。
func _keep_submerged() -> void:
	if _world == null:
		return
	if _world.get_block(Vector3i(global_position.floor())) == BlockTypes.Block.AIR:
		velocity.y = -speed
	if is_on_wall():
		_pick_swim_direction()


## 转向水平方向；竖直分量过强时跳过，避免 look_at 基向量退化。
func _face(dir: Vector3) -> void:
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length_squared() > 0.01:
		look_at(global_position + flat, Vector3.UP)


func _pick_swim_direction() -> void:
	var angle := randf() * TAU
	_wander_dir = Vector3(cos(angle), randf_range(-0.35, 0.35), sin(angle)).normalized()
	_wander_timer = randf_range(SWIM_WALK_MIN, SWIM_WALK_MAX)


## 记录出生点为活动中心（首个物理帧，此时 global_position 已就位）。
func _remember_home() -> void:
	if not _home_ready:
		_home = global_position
		_home_ready = true


func take_damage(amount: int) -> void:
	health -= amount
	_update_nametag()
	if Mob.is_passive(type):
		_flee_timer = FLEE_TIME
	if health <= 0:
		_die()


## 攻击前的视线检测：被方块阻挡时不攻击，保证庇护所可以防怪。
func _has_line_of_sight() -> bool:
	if player == null:
		return false
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3(0.0, 0.6, 0.0)
	var to := player.global_position + Vector3(0.0, 0.9, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return true
	return hit["collider"] == player


func _die() -> void:
	_spawn_drop()
	queue_free()


func _spawn_drop() -> void:
	if get_parent() == null:
		return
	if drop_table.is_empty():
		if drop_item == BlockTypes.Block.AIR or drop_count <= 0:
			return
		_spawn_one_drop(drop_item, drop_count)
		return
	for entry: Array in drop_table:
		_spawn_one_drop(int(entry[0]), int(entry[1]))


func _spawn_one_drop(id: int, count: int) -> void:
	var drop := DroppedItem.new()
	drop.setup(player, id, count)
	get_parent().add_child(drop)
	drop.global_position = global_position


func _apply_type_stats() -> void:
	match type:
		MobType.SKELETON:
			health = 4
			speed = 2.4
			attack_damage = 2
			attack_range = 1.6
			attack_cooldown = 2.0
			drop_item = ItemTypes.BONE
			drop_count = 2
		MobType.SPIDER:
			health = 3
			speed = 3.0
			attack_damage = 1
			attack_range = 1.3
			attack_cooldown = 0.8
			drop_item = ItemTypes.STRING
			drop_count = 1
		MobType.COW:
			health = 8
			speed = 1.6
			drop_item = ItemTypes.RAW_BEEF
			drop_count = 2
		MobType.SHEEP:
			health = 6
			speed = 1.8
			drop_item = BlockTypes.Block.WOOL
			drop_count = 2
		MobType.CHICKEN:
			health = 3
			speed = 2.0
			drop_item = ItemTypes.RAW_CHICKEN
			drop_count = 1
		MobType.PIG:
			health = 8
			speed = 1.5
			drop_item = ItemTypes.RAW_PORK
			drop_count = 2
		MobType.WOLF:
			health = 7
			speed = 3.2
			attack_damage = 2
			attack_range = 1.5
			attack_cooldown = 1.0
			drop_item = BlockTypes.Block.AIR
			drop_count = 0
		MobType.VILLAGER:
			health = 10
			speed = 1.2
			drop_item = BlockTypes.Block.AIR
			drop_count = 0
		MobType.PILLAGER:
			health = 6
			speed = 2.6
			attack_damage = 2
			attack_range = 1.5
			attack_cooldown = 1.2
			drop_table = [[ItemTypes.TOTEM, 1], [ItemTypes.EMERALD, 2]]
		MobType.FISH:
			health = 3
			speed = 1.8
			drop_item = ItemTypes.RAW_FISH
			drop_count = 2
		MobType.SHRIMP:
			health = 2
			speed = 1.6
			drop_item = ItemTypes.RAW_SHRIMP
			drop_count = 1
		MobType.CRAB:
			health = 4
			speed = 1.3
			drop_item = ItemTypes.CRAB_MEAT
			drop_count = 2
		MobType.DRAGONFLY:
			health = 2
			speed = 2.6
			drop_item = BlockTypes.Block.AIR
			drop_count = 0
		MobType.FROG:
			health = 3
			speed = 1.4
			drop_item = BlockTypes.Block.AIR
			drop_count = 0
		_:
			health = 5
			speed = 2.2
			attack_damage = 2
			attack_range = 1.5
			attack_cooldown = 1.2
			drop_item = BlockTypes.Block.WOOD
			drop_count = 1
	max_health = health


## 头顶名称与生命标签：面向摄像机，打猎时直接可读，受击后刷新。
func _build_nametag() -> void:
	_nametag = Label3D.new()
	_nametag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_nametag.pixel_size = 0.006
	_nametag.font_size = 40
	_nametag.outline_size = 10
	_nametag.modulate = Color(1.0, 1.0, 1.0, 0.95)
	_nametag.outline_modulate = Color(0.05, 0.05, 0.05, 0.9)
	_nametag.position = Vector3(0.0, _nametag_height(), 0.0)
	add_child(_nametag)
	_update_nametag()


## 按体型确定标签高度：水生小生物最矮、鸡次之、牛羊居中、直立生物最高。
func _nametag_height() -> float:
	match type:
		MobType.SHRIMP, MobType.CRAB:
			return 0.55
		MobType.FROG:
			return 0.7
		MobType.FISH:
			return 0.75
		MobType.DRAGONFLY:
			return 0.95
		MobType.CHICKEN:
			return 1.0
		MobType.COW, MobType.SHEEP:
			return 1.35
		_:
			return 1.7


func _update_nametag() -> void:
	if _nametag == null:
		return
	_nametag.text = "%s %d/%d" % [display_name(), maxi(health, 0), max_health]


## 组装盒体外观：身体 + 头 + 眼睛，动物额外加腿，水生生物各有造型。
func _build_visual() -> void:
	match type:
		MobType.COW:
			_build_animal(
				Color(0.45, 0.30, 0.20),
				Vector3(0.8, 0.7, 0.5),
				Color(0.82, 0.80, 0.76),
				Vector3(0.34, 0.32, 0.30),
				0.92,
				4
			)
		MobType.SHEEP:
			_build_animal(
				Color(0.93, 0.93, 0.90),
				Vector3(0.75, 0.65, 0.55),
				Color(0.72, 0.68, 0.64),
				Vector3(0.30, 0.30, 0.28),
				0.88,
				4
			)
		MobType.CHICKEN:
			_build_animal(
				Color(0.95, 0.94, 0.90),
				Vector3(0.42, 0.42, 0.48),
				Color(0.98, 0.80, 0.30),
				Vector3(0.24, 0.24, 0.22),
				0.68,
				2
			)
		MobType.PIG:
			_build_animal(
				Color(0.96, 0.72, 0.75),
				Vector3(0.72, 0.62, 0.52),
				Color(0.98, 0.78, 0.80),
				Vector3(0.32, 0.30, 0.28),
				0.82,
				4
			)
		MobType.WOLF:
			_build_animal(
				Color(0.62, 0.62, 0.64),
				Vector3(0.70, 0.55, 0.62),
				Color(0.50, 0.50, 0.54),
				Vector3(0.30, 0.28, 0.30),
				0.80,
				4
			)
		MobType.VILLAGER:
			_build_villager_like(
				Color(0.52, 0.38, 0.27),
				Color(0.90, 0.76, 0.62),
				Color(0.05, 0.05, 0.05)
			)
		MobType.PILLAGER:
			_build_villager_like(
				Color(0.38, 0.40, 0.47),
				Color(0.70, 0.66, 0.60),
				Color(0.12, 0.08, 0.24)
			)
		MobType.FISH:
			_build_fish()
		MobType.SHRIMP:
			_build_shrimp()
		MobType.CRAB:
			_build_crab()
		MobType.DRAGONFLY:
			_build_dragonfly()
		MobType.FROG:
			_build_frog()
		_:
			_build_hostile()


## 动物通用外观：躯干 + 头 + 眼 + 腿（脚底贴地 y=0）。
func _build_animal(body_color: Color, body_size: Vector3, head_color: Color, head_size: Vector3, body_center_y: float, leg_count: int) -> void:
	_add_box(body_size, body_color, Vector3(0.0, body_center_y, 0.0))
	var head_front_z := -body_size.z * 0.5 - head_size.z * 0.5 + 0.04
	var head_y := body_center_y + body_size.y * 0.28
	_add_box(head_size, head_color, Vector3(0.0, head_y, head_front_z))
	_add_eyes(head_size, head_y, head_front_z)
	var leg_size := Vector3(0.12, body_center_y - body_size.y * 0.5, 0.12)
	var leg_color := body_color.darkened(0.25)
	for sx in [-0.18, 0.18]:
		for sz in [-0.14, 0.14]:
			if leg_count == 2 and sz > 0.0:
				continue
			_add_box(leg_size, leg_color, Vector3(sx, leg_size.y * 0.5, sz))


func _add_eyes(head_size: Vector3, eye_y: float, head_front_z: float) -> void:
	for sx in [-0.08, 0.08]:
		var eye := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.05
		sphere.height = 0.1
		var eye_mat := StandardMaterial3D.new()
		eye_mat.albedo_color = Color(0.05, 0.05, 0.05)
		eye.mesh = sphere
		eye.material_override = eye_mat
		eye.position = Vector3(sx * head_size.x * 6.0, eye_y + 0.05, head_front_z - head_size.z * 0.5 - 0.01)
		add_child(eye)


## 村民/掠夺者外观：长袍 + 头 + 标志性大鼻子 + 眼。
func _build_villager_like(robe_color: Color, skin_color: Color, eye_color: Color) -> void:
	_add_box(Vector3(0.56, 0.95, 0.42), robe_color, Vector3(0.0, 0.475, 0.0))
	var head_y := 1.16
	_add_box(Vector3(0.42, 0.42, 0.42), skin_color, Vector3(0.0, head_y, 0.0))
	# 大鼻子：头部正前中央突出的长盒。
	_add_box(Vector3(0.12, 0.22, 0.14), skin_color.darkened(0.08), Vector3(0.0, head_y - 0.06, -0.28))
	for sx in [-0.09, 0.09]:
		var eye := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.045
		sphere.height = 0.09
		var eye_mat := StandardMaterial3D.new()
		eye_mat.albedo_color = eye_color
		eye.mesh = sphere
		eye.material_override = eye_mat
		eye.position = Vector3(sx, head_y + 0.06, -0.235)
		add_child(eye)


func _build_hostile() -> void:
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.7, 0.9, 0.5)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _type_color()
	body.mesh = box
	body.material_override = mat
	body.position = Vector3(0.0, 0.45, 0.0)
	add_child(body)

	for sx in [-0.12, 0.12]:
		var eye := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.06
		sphere.height = 0.12
		var eye_mat := StandardMaterial3D.new()
		eye_mat.albedo_color = Color(1.0, 1.0, 1.0)
		eye.mesh = sphere
		eye.material_override = eye_mat
		eye.position = Vector3(sx, 0.55, -0.26)
		add_child(eye)


## 鱼：纺锤身体 + 尾鳍 + 背鳍（朝向 -Z）。
func _build_fish() -> void:
	var body := Color(0.88, 0.56, 0.28)
	_add_box(Vector3(0.20, 0.26, 0.50), body, Vector3(0.0, 0.30, 0.0))
	_add_box(Vector3(0.06, 0.22, 0.18), body.darkened(0.15), Vector3(0.0, 0.30, 0.33))
	_add_box(Vector3(0.04, 0.13, 0.20), body.lightened(0.15), Vector3(0.0, 0.47, -0.02))
	_add_eye_at(Vector3(0.11, 0.37, -0.21), 0.045)
	_add_eye_at(Vector3(-0.11, 0.37, -0.21), 0.045)


## 虾：分节小身 + 尾扇 + 长触须。
func _build_shrimp() -> void:
	var shell := Color(0.94, 0.55, 0.48)
	_add_box(Vector3(0.14, 0.14, 0.26), shell, Vector3(0.0, 0.20, 0.06))
	_add_box(Vector3(0.12, 0.10, 0.12), shell.darkened(0.12), Vector3(0.0, 0.18, 0.23))
	_add_box(Vector3(0.16, 0.16, 0.16), shell.lightened(0.08), Vector3(0.0, 0.22, -0.16))
	_add_box(Vector3(0.02, 0.02, 0.20), shell.darkened(0.30), Vector3(0.05, 0.28, -0.32))
	_add_box(Vector3(0.02, 0.02, 0.20), shell.darkened(0.30), Vector3(-0.05, 0.28, -0.32))
	_add_eye_at(Vector3(0.06, 0.28, -0.24), 0.03)
	_add_eye_at(Vector3(-0.06, 0.28, -0.24), 0.03)


## 蟹：宽壳 + 双螯 + 六足 + 眼柱。
func _build_crab() -> void:
	var shell := Color(0.86, 0.34, 0.28)
	_add_box(Vector3(0.46, 0.18, 0.36), shell, Vector3(0.0, 0.20, 0.0))
	_add_box(Vector3(0.14, 0.12, 0.14), shell.darkened(0.10), Vector3(0.28, 0.16, -0.22))
	_add_box(Vector3(0.14, 0.12, 0.14), shell.darkened(0.10), Vector3(-0.28, 0.16, -0.22))
	for sx in [-0.24, 0.24]:
		_add_box(Vector3(0.05, 0.16, 0.05), shell.darkened(0.30), Vector3(sx, 0.09, -0.10))
		_add_box(Vector3(0.05, 0.16, 0.05), shell.darkened(0.30), Vector3(sx, 0.09, 0.10))
	for sx in [-0.10, 0.10]:
		_add_box(Vector3(0.04, 0.12, 0.04), shell, Vector3(sx, 0.32, -0.14))
		_add_eye_at(Vector3(sx, 0.41, -0.14), 0.035)


## 蜻蜓：细长身体 + 四片半透明翅膀 + 复眼。
func _build_dragonfly() -> void:
	var body := Color(0.22, 0.62, 0.66)
	_add_box(Vector3(0.07, 0.07, 0.44), body, Vector3(0.0, 0.55, 0.0))
	_add_box(Vector3(0.13, 0.13, 0.13), body.darkened(0.20), Vector3(0.0, 0.56, -0.26))
	_add_box_alpha(Vector3(0.30, 0.02, 0.10), Color(0.86, 0.96, 1.0), Vector3(0.20, 0.60, -0.08), 0.55)
	_add_box_alpha(Vector3(0.30, 0.02, 0.10), Color(0.86, 0.96, 1.0), Vector3(-0.20, 0.60, -0.08), 0.55)
	_add_box_alpha(Vector3(0.28, 0.02, 0.09), Color(0.86, 0.96, 1.0), Vector3(0.19, 0.60, 0.10), 0.55)
	_add_box_alpha(Vector3(0.28, 0.02, 0.09), Color(0.86, 0.96, 1.0), Vector3(-0.19, 0.60, 0.10), 0.55)
	_add_eye_at(Vector3(0.07, 0.60, -0.30), 0.05)
	_add_eye_at(Vector3(-0.07, 0.60, -0.30), 0.05)


## 青蛙：绿色圆身 + 凸眼 + 四足。
func _build_frog() -> void:
	var skin := Color(0.35, 0.70, 0.32)
	_add_box(Vector3(0.36, 0.26, 0.40), skin, Vector3(0.0, 0.18, 0.0))
	_add_box(Vector3(0.30, 0.20, 0.16), skin.lightened(0.06), Vector3(0.0, 0.20, -0.22))
	_add_box(Vector3(0.16, 0.03, 0.06), skin.darkened(0.35), Vector3(0.0, 0.16, -0.30))
	for sx in [-0.16, 0.16]:
		_add_box(Vector3(0.09, 0.14, 0.09), skin.darkened(0.20), Vector3(sx, 0.07, -0.12))
		_add_box(Vector3(0.10, 0.16, 0.10), skin.darkened(0.20), Vector3(sx, 0.08, 0.16))
	for sx in [-0.11, 0.11]:
		_add_eye_at(Vector3(sx, 0.33, -0.24), 0.06, Color(0.96, 0.96, 0.94))
		_add_eye_at(Vector3(sx, 0.34, -0.285), 0.032)


func _add_box(size: Vector3, color: Color, pos: Vector3) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh_instance.mesh = box
	mesh_instance.material_override = mat
	mesh_instance.position = pos
	add_child(mesh_instance)
	return mesh_instance


## 半透明盒体（蜻蜓翅膀等）。
func _add_box_alpha(size: Vector3, color: Color, pos: Vector3, alpha: float) -> void:
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_instance.mesh = box
	mesh_instance.material_override = mat
	mesh_instance.position = pos
	add_child(mesh_instance)


## 单颗眼球：位置逐一指定，可指定颜色（青蛙用白色眼白 + 深色瞳孔）。
func _add_eye_at(pos: Vector3, radius: float, color := Color(0.05, 0.05, 0.06)) -> void:
	var eye := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	eye.mesh = sphere
	eye.material_override = mat
	eye.position = pos
	add_child(eye)


func _build_collision() -> void:
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	match type:
		MobType.CHICKEN:
			capsule.radius = 0.2
			capsule.height = 0.6
			shape.position = Vector3(0.0, 0.3, 0.0)
		MobType.COW, MobType.SHEEP:
			capsule.radius = 0.35
			capsule.height = 1.0
			shape.position = Vector3(0.0, 0.5, 0.0)
		MobType.FISH:
			capsule.radius = 0.15
			capsule.height = 0.36
			shape.position = Vector3(0.0, 0.28, 0.0)
		MobType.SHRIMP, MobType.CRAB, MobType.FROG:
			capsule.radius = 0.16
			capsule.height = 0.36
			shape.position = Vector3(0.0, 0.17, 0.0)
		MobType.DRAGONFLY:
			capsule.radius = 0.13
			capsule.height = 0.3
			shape.position = Vector3(0.0, 0.56, 0.0)
		_:
			capsule.radius = 0.3
			capsule.height = 1.2
			shape.position = Vector3(0.0, 0.6, 0.0)
	shape.shape = capsule
	add_child(shape)


func _type_color() -> Color:
	match type:
		MobType.SKELETON:
			return Color(0.88, 0.88, 0.82)
		MobType.SPIDER:
			return Color(0.30, 0.30, 0.36)
		_:
			return Color(0.42, 0.78, 0.42)
