extends CharacterBody3D
class_name Mob
## 生物基类。
## 敌对（夜晚由 MobSpawner 生成、白天清空）：僵尸近战、蜘蛛快速近战、骷髅远程射箭。
## 被动（白天生成、持续存在）：牛/羊/鸡/猪随机游荡，受击后短暂逃跑，不会攻击。
## 水生（由 MobSpawner 水生物轨道生成，不参与昼夜清空）：鱼/虾/蟹栖息大河，
## 蜻蜓/蝴蝶/青蛙栖息池塘与草地。
## 保护动物：大熊猫、金丝猴、朱鹮、白头海雕、北极熊、袋鼠，以及村民与益虫
## （蜻蜓/蝴蝶）。玩家无法伤害它们，名牌显示为绿色。
## 成长：多数动物有「卵/幼体 → 成体」的阶段链（见 MOB_STAGES），
## 每过一个游戏日推进一阶段（DayNightCycle.day_changed 驱动），
## 幼体不可狩猎，长大后才会有完整掉落。

const GRAVITY := 24.0
## 被动生物受击后的逃跑时长（秒）。
const FLEE_TIME := 3.0
## 会反击的被动生物被击中后的追击时长（秒）。
const COUNTER_TIME := 6.0
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
## 蜻蜓/蝴蝶悬停半径与上下浮动参数。
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
	BUTTERFLY,
	PANDA,
	GOLDEN_MONKEY,
	CRESTED_IBIS,
	BALD_EAGLE,
	POLAR_BEAR,
	KANGAROO,
}

## 栖息地：决定移动方式（陆地重力行走 / 水中游动 / 空中悬停）。
enum Habitat {
	LAND,
	WATER,
	AIR,
}

## 造型覆盖标记：卵 / 蝌蚪（孑孓、鱼苗共用）/ 毛毛虫 / 茧。
## 空字符串表示该阶段直接用类型模型按 scale 缩放。
const ART_EGG := "egg"
const ART_TADPOLE := "tadpole"
const ART_CATERPILLAR := "caterpillar"
const ART_COCOON := "cocoon"

## 生物成长阶段链。字段说明：
##   name        该阶段的显示名（成体阶段用 MOB_NAMES）
##   days        在当前阶段停留多少个游戏日后进入下一阶段（末段为 0，不再成长）
##   scale       视觉缩放（相对该类型的成体模型）
##   art         造型覆盖（空串＝用类型模型缩放）
##   health_mul  相对成体生命值的倍率
##   speed_mul   相对成体速度的倍率（0 表示原地不动，如卵）
##   loot        该阶段的掉落表 [[item, count], ...]；空数组即用类型默认掉落
##   variants    到达该阶段时随机挑选的分支名（如公鸡/母鸡、鲤鱼/金鱼）
const MOB_STAGES := {
	MobType.FROG: [
		{"name": "蛙卵", "days": 1, "scale": 0.50, "art": ART_EGG, "health_mul": 0.3, "speed_mul": 0.0, "loot": []},
		{"name": "蝌蚪", "days": 1, "scale": 0.55, "art": ART_TADPOLE, "health_mul": 0.5, "speed_mul": 0.7, "loot": []},
		{"name": "青蛙", "days": 0, "scale": 1.0, "art": "", "health_mul": 1.0, "speed_mul": 1.0, "loot": []},
	],
	MobType.DRAGONFLY: [
		{"name": "蜻蜓卵", "days": 1, "scale": 0.45, "art": ART_EGG, "health_mul": 0.4, "speed_mul": 0.0, "loot": []},
		{"name": "水虿", "days": 1, "scale": 0.60, "art": ART_TADPOLE, "health_mul": 0.6, "speed_mul": 0.6, "loot": []},
		{"name": "蜻蜓", "days": 0, "scale": 1.0, "art": "", "health_mul": 1.0, "speed_mul": 1.0, "loot": []},
	],
	MobType.BUTTERFLY: [
		{"name": "蝶卵", "days": 1, "scale": 0.45, "art": ART_EGG, "health_mul": 0.4, "speed_mul": 0.0, "loot": []},
		{"name": "毛毛虫", "days": 1, "scale": 0.70, "art": ART_CATERPILLAR, "health_mul": 0.7, "speed_mul": 0.5, "loot": []},
		{"name": "茧", "days": 1, "scale": 0.60, "art": ART_COCOON, "health_mul": 0.8, "speed_mul": 0.0, "loot": []},
		{"name": "蝴蝶", "days": 0, "scale": 1.0, "art": "", "health_mul": 1.0, "speed_mul": 1.0, "loot": [], "variants": ["凤蝶", "粉蝶"]},
	],
	MobType.CHICKEN: [
		{"name": "鸡蛋", "days": 1, "scale": 0.45, "art": ART_EGG, "health_mul": 0.3, "speed_mul": 0.0, "loot": []},
		{"name": "小鸡", "days": 1, "scale": 0.55, "art": "", "health_mul": 0.5, "speed_mul": 0.8, "loot": [[ItemTypes.FEATHER, 1]]},
		{"name": "鸡", "days": 0, "scale": 1.0, "art": "", "health_mul": 1.0, "speed_mul": 1.0, "loot": [], "variants": ["母鸡", "公鸡"]},
	],
	MobType.FISH: [
		{"name": "鱼苗", "days": 1, "scale": 0.40, "art": ART_TADPOLE, "health_mul": 0.4, "speed_mul": 0.7, "loot": []},
		{"name": "小鱼", "days": 1, "scale": 0.68, "art": "", "health_mul": 0.7, "speed_mul": 0.9, "loot": [[ItemTypes.RAW_FISH, 1]]},
		{"name": "鱼", "days": 0, "scale": 1.0, "art": "", "health_mul": 1.0, "speed_mul": 1.0, "loot": [], "variants": ["鲤鱼", "金鱼"]},
	],
	MobType.COW: [
		{"name": "牛犊", "days": 1, "scale": 0.55, "art": "", "health_mul": 0.5, "speed_mul": 0.9, "loot": [[ItemTypes.RAW_BEEF, 1]]},
		{"name": "牛", "days": 0, "scale": 1.0, "art": "", "health_mul": 1.0, "speed_mul": 1.0, "loot": []},
	],
	MobType.SHEEP: [
		{"name": "羊羔", "days": 1, "scale": 0.55, "art": "", "health_mul": 0.5, "speed_mul": 0.9, "loot": [[BlockTypes.Block.WOOL, 1]]},
		{"name": "羊", "days": 0, "scale": 1.0, "art": "", "health_mul": 1.0, "speed_mul": 1.0, "loot": []},
	],
	MobType.PIG: [
		{"name": "小猪", "days": 1, "scale": 0.55, "art": "", "health_mul": 0.5, "speed_mul": 0.9, "loot": [[ItemTypes.RAW_PORK, 1]]},
		{"name": "猪", "days": 0, "scale": 1.0, "art": "", "health_mul": 1.0, "speed_mul": 1.0, "loot": []},
	],
	MobType.PANDA: [
		{"name": "熊猫幼崽", "days": 2, "scale": 0.50, "art": "", "health_mul": 0.4, "speed_mul": 0.9, "loot": []},
		{"name": "大熊猫", "days": 0, "scale": 1.0, "art": "", "health_mul": 1.0, "speed_mul": 1.0, "loot": []},
	],
	MobType.GOLDEN_MONKEY: [
		{"name": "金丝猴幼崽", "days": 2, "scale": 0.50, "art": "", "health_mul": 0.4, "speed_mul": 0.9, "loot": []},
		{"name": "金丝猴", "days": 0, "scale": 1.0, "art": "", "health_mul": 1.0, "speed_mul": 1.0, "loot": []},
	],
	MobType.CRESTED_IBIS: [
		{"name": "朱鹮幼鸟", "days": 2, "scale": 0.55, "art": "", "health_mul": 0.4, "speed_mul": 0.9, "loot": []},
		{"name": "朱鹮", "days": 0, "scale": 1.0, "art": "", "health_mul": 1.0, "speed_mul": 1.0, "loot": []},
	],
	MobType.BALD_EAGLE: [
		{"name": "白头海雕雏鸟", "days": 2, "scale": 0.55, "art": "", "health_mul": 0.4, "speed_mul": 0.9, "loot": []},
		{"name": "白头海雕", "days": 0, "scale": 1.0, "art": "", "health_mul": 1.0, "speed_mul": 1.0, "loot": []},
	],
	MobType.POLAR_BEAR: [
		{"name": "北极熊幼崽", "days": 2, "scale": 0.50, "art": "", "health_mul": 0.4, "speed_mul": 0.9, "loot": []},
		{"name": "北极熊", "days": 0, "scale": 1.0, "art": "", "health_mul": 1.0, "speed_mul": 1.0, "loot": []},
	],
	MobType.KANGAROO: [
		{"name": "袋鼠幼崽", "days": 2, "scale": 0.50, "art": "", "health_mul": 0.4, "speed_mul": 0.9, "loot": []},
		{"name": "袋鼠", "days": 0, "scale": 1.0, "art": "", "health_mul": 1.0, "speed_mul": 1.0, "loot": []},
	],
}

## 保护名录：国家重点保护动物与益虫，玩家无法伤害它们（名牌绿色标识）。
const PROTECTED_MOBS := {
	MobType.PANDA: true,
	MobType.GOLDEN_MONKEY: true,
	MobType.CRESTED_IBIS: true,
	MobType.BALD_EAGLE: true,
	MobType.POLAR_BEAR: true,
	MobType.KANGAROO: true,
	MobType.VILLAGER: true,
	MobType.DRAGONFLY: true,
	MobType.BUTTERFLY: true,
}

## 保护原因（交互提示用）。
const PROTECTED_NOTES := {
	MobType.PANDA: "大熊猫",
	MobType.GOLDEN_MONKEY: "金丝猴",
	MobType.CRESTED_IBIS: "朱鹮",
	MobType.BALD_EAGLE: "白头海雕",
	MobType.POLAR_BEAR: "北极熊",
	MobType.KANGAROO: "袋鼠",
	MobType.VILLAGER: "村民",
	MobType.DRAGONFLY: "蜻蜓",
	MobType.BUTTERFLY: "蝴蝶",
}

## 被击中后会反击（而不是逃跑）的被动生物。名牌在反击期间转为红色。
const COUNTER_MOBS := {
	MobType.POLAR_BEAR: true,
	MobType.CRAB: true,
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

## 成长阶段索引（0 起），以及到达成体阶段时抽中的分支（如公鸡/母鸡）。
var stage := 0
var variant := -1

var _attack_timer := 0.0
# 被动生物游荡状态：方向为零表示驻足。
var _wander_dir := Vector3.ZERO
var _wander_timer := 0.0
var _flee_timer := 0.0
## 反击计时（>0 时追击玩家并攻击，名牌转红）。
var _counter_timer := 0.0
## 在当前阶段已停留的游戏天数。
var _days_in_stage := 0
# 头顶名称与生命标签（打猎时直接可读）。
var _nametag: Label3D
## 外观挂载点：所有部件挂在它下面，按成长阶段整体缩放。
var _visual_root: Node3D
var _collision: CollisionShape3D
# 水生/飞行生物用：世界引用、出生点活动中心、浮动相位与起跳计时。
var _world: World
var _home := Vector3.ZERO
var _home_ready := false
var _flight_phase := 0.0
var _hop_timer := 0.6
# 成体基准属性：阶段倍率在此之上相乘，保证阶段切换无损还原。
var _base_health := 5
var _base_speed := 2.2
var _base_drop_item: int = BlockTypes.Block.WOOD
var _base_drop_count := 1
var _base_drop_table: Array = []
var _base_attack_damage := 2

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
	MobType.BUTTERFLY: "蝴蝶",
	MobType.PANDA: "大熊猫",
	MobType.GOLDEN_MONKEY: "金丝猴",
	MobType.CRESTED_IBIS: "朱鹮",
	MobType.BALD_EAGLE: "白头海雕",
	MobType.POLAR_BEAR: "北极熊",
	MobType.KANGAROO: "袋鼠",
}


func display_name() -> String:
	return MOB_NAMES.get(type, "生物")


## 敌对生物名单：会主动追逐并攻击玩家。夜里由 MobSpawner 生成、白天清空。
## 单列一张表，而不是散在 is_passive 的一长串 or 里，为的是两件事：
##   ① 一眼看清「谁有害」；② 新增物种默认被动（安全的默认值），
##      想让某物种变敌对，必须在这里显式登记，不会因为漏写一项而悄悄变敌人。
const HOSTILE_MOBS := {
	MobType.ZOMBIE: true,
	MobType.SKELETON: true,
	MobType.SPIDER: true,
	MobType.WOLF: true,
	MobType.PILLAGER: true,
}

## 被动生物：不攻击、受击逃跑（反击名录中的会先反击）。水生物同为被动，
## 但不参与陆地生成轨道。判据由 HOSTILE_MOBS 派生，两张表因此不会互相矛盾。
static func is_passive(t: MobType) -> bool:
	return not HOSTILE_MOBS.has(t)


## 栖息地：鱼/虾/蟹在水中，蜻蜓/蝴蝶/白头海雕在空中，其余在陆地。
static func habitat_of(t: MobType) -> Habitat:
	match t:
		MobType.FISH, MobType.SHRIMP, MobType.CRAB:
			return Habitat.WATER
		MobType.DRAGONFLY, MobType.BUTTERFLY, MobType.BALD_EAGLE:
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


## 保护动物/益虫：玩家无法伤害。
static func is_protected(t: MobType) -> bool:
	return PROTECTED_MOBS.has(t)


## 保护名录中的中文名（用于提示）；非保护返回空串。
static func protected_note(t: MobType) -> String:
	return String(PROTECTED_NOTES.get(t, ""))


## 该类型是否有成长阶段（阶段数 > 1）。
static func has_growth(t: MobType) -> bool:
	return stage_count_of(t) > 1


## 该类型的阶段总数。
static func stage_count_of(t: MobType) -> int:
	if not MOB_STAGES.has(t):
		return 1
	var stages: Array = MOB_STAGES[t]
	return maxi(1, stages.size())


## 该类型的阶段定义表（无成长时返回单元素成体阶段）。
static func stages_of(t: MobType) -> Array:
	if MOB_STAGES.has(t):
		return MOB_STAGES[t]
	return [{"name": MOB_NAMES.get(t, "生物"), "days": 0, "scale": 1.0, "art": "",
		"health_mul": 1.0, "speed_mul": 1.0, "loot": []}]


## 生成时的阶段抽取：多数为成体，少数为卵或幼体，方便玩家观察成长过程。
static func pick_spawn_stage(t: MobType) -> int:
	var count := stage_count_of(t)
	if count <= 1:
		return 0
	var r := randf()
	if r < 0.12:
		return 0
	if count >= 3 and r < 0.24:
		return 1
	if count >= 4 and r < 0.28:
		return 2
	return count - 1


func setup(mob_type: MobType, target: Player, dn: DayNightCycle, start_stage: int = -1) -> void:
	type = mob_type
	player = target
	day_night = dn
	_apply_type_stats()
	# -1 表示直接以成体出现（默认行为，与旧版一致）；生成器可指定幼体阶段。
	stage = stage_count_of(type) - 1 if start_stage < 0 else clampi(start_stage, 0, stage_count_of(type) - 1)
	_apply_stage_stats()


func _ready() -> void:
	add_to_group("mobs")
	_visual_root = Node3D.new()
	add_child(_visual_root)
	_apply_variant()
	_build_visual()
	_build_collision()
	_build_nametag()
	if day_night != null:
		day_night.day_changed.connect(_on_day_changed)


func _exit_tree() -> void:
	if day_night != null and day_night.day_changed.is_connected(_on_day_changed):
		day_night.day_changed.disconnect(_on_day_changed)


func _physics_process(delta: float) -> void:
	if player == null or day_night == null:
		return

	_attack_timer = maxf(0.0, _attack_timer - delta)
	if _counter_timer > 0.0:
		_counter_timer = maxf(0.0, _counter_timer - delta)
		if _counter_timer == 0.0:
			_update_nametag()
	if _world == null:
		_world = player.get_world()

	_process_behaviour(delta)
	move_and_slide()


## ── 成长 ──────────────────────────────────────────────
## 跨过游戏日：在当前阶段多停留一天，够天数就进入下一阶段。
func _on_day_changed(_day: int) -> void:
	_days_in_stage += 1
	var stages := Mob.stages_of(type)
	if stage >= stages.size() - 1:
		return
	var need := maxi(1, int(stages[stage].get("days", 1)))
	if _days_in_stage < need:
		return
	advance_stage()


## 推进到下一阶段（探针可直接调用以跳过等待）。
func advance_stage() -> bool:
	var count := stage_count_of(type)
	if stage >= count - 1:
		return false
	stage += 1
	_days_in_stage = 0
	_apply_variant()
	_apply_stage_stats()
	if is_inside_tree():
		_rebuild_visual()
		_update_nametag()
	Events.mob_grown.emit(type, stage)
	return true


## 当前阶段定义。
func stage_data() -> Dictionary:
	var stages := Mob.stages_of(type)
	return stages[clampi(stage, 0, stages.size() - 1)]


## 当前阶段的显示名（成体阶段取 MOB_NAMES，分支名优先）。
func stage_name() -> String:
	if variant >= 0:
		var variants: Array = stage_data().get("variants", [])
		if variant < variants.size():
			return String(variants[variant])
	var data := stage_data()
	if stage >= stage_count_of(type) - 1:
		return display_name()
	return String(data.get("name", display_name()))


## 当前阶段是否已成年（未成年不可狩猎）。
func is_adult() -> bool:
	return stage >= stage_count_of(type) - 1


## 玩家能否狩猎：保护动物与幼体一律不可。
func is_huntable() -> bool:
	return not Mob.is_protected(type) and is_adult()


## 被击中后是否反击。
func counters_back() -> bool:
	return COUNTER_MOBS.has(type)


## 反击中（名牌红色）。
func is_countering() -> bool:
	return _counter_timer > 0.0


## 视觉缩放（阶段倍率）。
func stage_scale() -> float:
	return float(stage_data().get("scale", 1.0))


## 该阶段是否原地不动（卵、茧）。
func is_still() -> bool:
	return float(stage_data().get("speed_mul", 1.0)) <= 0.001


func _apply_variant() -> void:
	var variants: Array = stage_data().get("variants", [])
	if variants.is_empty():
		variant = -1
	elif variant < 0 or variant >= variants.size():
		variant = randi() % variants.size()


## 行为分发：陆地（重力 + 被动游荡 / 敌对追击 / 青蛙跳跃）、
## 水中（鱼虾悬停游动、蟹贴底爬行）、空中（蜻蜓/蝴蝶/海雕悬停）。
func _process_behaviour(delta: float) -> void:
	if is_still():
		# 卵与茧：待在原地，只保留重力让陆地生物贴地。
		velocity = Vector3.ZERO
		if Mob.habitat_of(type) == Habitat.LAND:
			_apply_gravity(delta)
		return
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
			player.take_damage(attack_damage, display_name())
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


## 被动行为：反击优先（北极熊/蟹），其次受击逃跑；否则按计时器在
## "随机方向慢走"与"驻足"间切换。
func _process_passive(delta: float) -> void:
	if _counter_timer > 0.0:
		_process_counter()
		return

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


## 反击：朝玩家靠近并在射程内挥击（北极熊会还手，别欺负它）。
func _process_counter() -> void:
	var to_player := player.global_position - global_position
	to_player.y = 0.0
	var dist := to_player.length()
	var flat := to_player / maxf(dist, 0.001)
	if dist > attack_range:
		_move_toward(flat)
		return
	velocity.x = 0.0
	velocity.z = 0.0
	look_at(global_position + flat, Vector3.UP)
	if _attack_timer <= 0.0 and _has_line_of_sight():
		player.take_damage(maxi(1, _base_attack_damage), display_name())
		_attack_timer = attack_cooldown


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


## 蜻蜓/蝴蝶/海雕：无重力悬停，在水面上方或草地上方小幅游荡并上下浮动。
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
			velocity.y = HOP_SPEED * maxf(0.6, stage_scale())
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
	# 先落定反击/逃跑状态，再刷新名牌——否则名牌会停留在受击前的颜色。
	if Mob.is_passive(type):
		if counters_back():
			_counter_timer = COUNTER_TIME
		else:
			_flee_timer = FLEE_TIME
	_update_nametag()
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
	Events.mob_killed.emit(type)
	_spawn_drop()
	queue_free()


func _spawn_drop() -> void:
	if get_parent() == null:
		return
	# 幼体阶段有自己的掉落表（通常更少）；成体沿用类型默认掉落。
	var stage_loot: Array = stage_data().get("loot", [])
	if not stage_loot.is_empty() and not is_adult():
		for entry: Array in stage_loot:
			_spawn_one_drop(int(entry[0]), int(entry[1]))
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
			drop_table = [[ItemTypes.RAW_BEEF, 2], [ItemTypes.HIDE, 1]]
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
			drop_table = [[ItemTypes.RAW_CHICKEN, 1], [ItemTypes.FEATHER, 2]]
		MobType.PIG:
			health = 8
			speed = 1.5
			drop_item = ItemTypes.RAW_PORK
			drop_count = 2
			drop_table = [[ItemTypes.RAW_PORK, 2], [ItemTypes.HIDE, 1]]
		MobType.WOLF:
			health = 7
			speed = 3.2
			attack_damage = 2
			attack_range = 1.5
			attack_cooldown = 1.0
			drop_item = BlockTypes.Block.AIR
			drop_count = 0
			drop_table = [[ItemTypes.FANG, 1]]
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
			attack_damage = 1
			attack_range = 1.2
			attack_cooldown = 1.4
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
		MobType.BUTTERFLY:
			health = 1
			speed = 2.4
			drop_item = BlockTypes.Block.AIR
			drop_count = 0
		MobType.PANDA:
			health = 14
			speed = 1.3
			drop_item = BlockTypes.Block.AIR
			drop_count = 0
		MobType.GOLDEN_MONKEY:
			health = 8
			speed = 2.6
			drop_item = BlockTypes.Block.AIR
			drop_count = 0
		MobType.CRESTED_IBIS:
			health = 6
			speed = 2.2
			drop_item = BlockTypes.Block.AIR
			drop_count = 0
		MobType.BALD_EAGLE:
			health = 7
			speed = 3.0
			drop_item = BlockTypes.Block.AIR
			drop_count = 0
		MobType.POLAR_BEAR:
			health = 16
			speed = 2.0
			attack_damage = 3
			attack_range = 1.7
			attack_cooldown = 1.3
			drop_item = BlockTypes.Block.AIR
			drop_count = 0
		MobType.KANGAROO:
			health = 9
			speed = 2.8
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
	# 记录成体基准值，阶段倍率在此之上换算。
	_base_health = health
	_base_speed = speed
	_base_attack_damage = attack_damage
	_base_drop_item = drop_item
	_base_drop_count = drop_count
	_base_drop_table = drop_table.duplicate()


## 按当前阶段换算属性：生命与速度乘阶段倍率，其余沿用成体基准。
func _apply_stage_stats() -> void:
	var data := stage_data()
	var health_mul := float(data.get("health_mul", 1.0))
	var speed_mul := float(data.get("speed_mul", 1.0))
	max_health = maxi(1, int(round(float(_base_health) * health_mul)))
	health = max_health
	speed = _base_speed * speed_mul
	attack_damage = _base_attack_damage
	drop_item = _base_drop_item
	drop_count = _base_drop_count
	drop_table = _base_drop_table.duplicate()
	if is_inside_tree() and _collision != null:
		_apply_collision_scale()


## 头顶名称与生命标签：面向摄像机，打猎时直接可读，受击后刷新。
## 保护动物绿名、反击中红名，其余白名。
func _build_nametag() -> void:
	_nametag = Label3D.new()
	_nametag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_nametag.pixel_size = 0.006
	_nametag.font_size = 40
	_nametag.outline_size = 10
	_nametag.outline_modulate = Color(0.05, 0.05, 0.05, 0.9)
	_nametag.position = Vector3(0.0, _nametag_height(), 0.0)
	add_child(_nametag)
	_update_nametag()


## 按体型确定标签高度：水生小生物最矮、鸡次之、牛羊居中、直立生物最高。
## 幼体阶段按缩放比例下移，避免名牌飘在小小身体上方太远。
func _nametag_height() -> float:
	var base := 1.7
	match type:
		MobType.SHRIMP, MobType.CRAB:
			base = 0.55
		MobType.FROG:
			base = 0.7
		MobType.FISH:
			base = 0.75
		MobType.DRAGONFLY, MobType.BUTTERFLY:
			base = 0.95
		MobType.CHICKEN:
			base = 1.0
		MobType.KANGAROO, MobType.GOLDEN_MONKEY:
			base = 1.45
		MobType.PANDA, MobType.POLAR_BEAR, MobType.COW, MobType.SHEEP:
			base = 1.35
		MobType.CRESTED_IBIS:
			base = 1.15
		MobType.BALD_EAGLE:
			base = 1.2
	return base * maxf(0.55, stage_scale())


func _update_nametag() -> void:
	if _nametag == null:
		return
	_nametag.text = "%s %d/%d" % [stage_name(), maxi(health, 0), max_health]
	if is_countering():
		_nametag.modulate = Color(1.0, 0.42, 0.38, 0.95)
	elif Mob.is_protected(type):
		_nametag.modulate = Color(0.55, 1.0, 0.62, 0.95)
	else:
		_nametag.modulate = Color(1.0, 1.0, 1.0, 0.95)
	if _nametag.is_inside_tree():
		_nametag.position = Vector3(0.0, _nametag_height(), 0.0)


## 重建外观（阶段变化时调用）。
func _rebuild_visual() -> void:
	if _visual_root == null:
		return
	for child in _visual_root.get_children():
		_visual_root.remove_child(child)
		child.queue_free()
	_build_visual()
	_apply_collision_scale()


## 组装盒体外观：身体 + 头 + 眼睛，动物额外加腿，水生生物各有造型。
## 卵/蝌蚪/毛毛虫/茧这几个阶段走专用小模型，其余按类型模型整体缩放。
## 造型构造表：物种 → 构造方法名。新增物种必须在这里登记一行。
## 用表而不是内联 match，是为了让「漏登记造型」能被机器发现——
## life_probe 阶段 R 会断言本表覆盖 MobType 全枚举。
const ART_BUILDERS := {
	MobType.ZOMBIE: "_build_hostile",
	MobType.SKELETON: "_build_hostile",
	MobType.SPIDER: "_build_hostile",
	MobType.COW: "_build_cow",
	MobType.SHEEP: "_build_sheep",
	MobType.CHICKEN: "_build_chicken",
	MobType.PIG: "_build_pig",
	MobType.VILLAGER: "_build_villager",
	MobType.PILLAGER: "_build_pillager",
	MobType.WOLF: "_build_wolf",
	MobType.FISH: "_build_fish",
	MobType.SHRIMP: "_build_shrimp",
	MobType.CRAB: "_build_crab",
	MobType.DRAGONFLY: "_build_dragonfly",
	MobType.FROG: "_build_frog",
	MobType.BUTTERFLY: "_build_butterfly",
	MobType.PANDA: "_build_panda",
	MobType.GOLDEN_MONKEY: "_build_monkey",
	MobType.CRESTED_IBIS: "_build_ibis",
	MobType.BALD_EAGLE: "_build_eagle",
	MobType.POLAR_BEAR: "_build_polar_bear",
	MobType.KANGAROO: "_build_kangaroo",
}


## 造型兜底：未登记的物种画成品红方块并打警告。
## 宁可丑得刺眼，也不要静默地长成别的东西——那会让漏项一路藏到上线。
func _build_unregistered() -> void:
	push_warning("Mob: 物种 %d 未在 ART_BUILDERS 登记造型" % type)
	_add_box(Vector3(0.6, 0.6, 0.6), Color(1.0, 0.0, 1.0), Vector3(0.0, 0.5, 0.0))


func _build_visual() -> void:
	_visual_root.scale = Vector3.ONE * stage_scale()
	var art := String(stage_data().get("art", ""))
	if not art.is_empty():
		_build_stage_art(art)
		return
	var method := String(ART_BUILDERS.get(type, ""))
	if method.is_empty() or not has_method(method):
		_build_unregistered()
		return
	@warning_ignore("return_value_discarded")
	call(method)


## 四足家畜与狼：共用 _build_animal，只是配色与体型不同。
func _build_cow() -> void:
	_build_animal(
		Color(0.45, 0.30, 0.20),
		Vector3(0.8, 0.7, 0.5),
		Color(0.82, 0.80, 0.76),
		Vector3(0.34, 0.32, 0.30),
		0.92,
		4
	)


func _build_sheep() -> void:
	_build_animal(
		Color(0.93, 0.93, 0.90),
		Vector3(0.75, 0.65, 0.55),
		Color(0.72, 0.68, 0.64),
		Vector3(0.30, 0.30, 0.28),
		0.88,
		4
	)


func _build_pig() -> void:
	_build_animal(
		Color(0.96, 0.72, 0.75),
		Vector3(0.72, 0.62, 0.52),
		Color(0.98, 0.78, 0.80),
		Vector3(0.32, 0.30, 0.28),
		0.82,
		4
	)


func _build_wolf() -> void:
	_build_animal(
		Color(0.62, 0.62, 0.64),
		Vector3(0.70, 0.55, 0.62),
		Color(0.50, 0.50, 0.54),
		Vector3(0.30, 0.28, 0.30),
		0.80,
		4
	)


func _build_villager() -> void:
	_build_villager_like(
		Color(0.52, 0.38, 0.27),
		Color(0.90, 0.76, 0.62),
		Color(0.05, 0.05, 0.05)
	)


func _build_pillager() -> void:
	_build_villager_like(
		Color(0.38, 0.40, 0.47),
		Color(0.70, 0.66, 0.60),
		Color(0.12, 0.08, 0.24)
	)


## 阶段专用小模型：卵、蝌蚪/孑孓/鱼苗、毛毛虫、茧。
func _build_stage_art(art: String) -> void:
	match art:
		ART_EGG:
			var egg_color := Color(0.95, 0.94, 0.88)
			match type:
				MobType.FROG, MobType.FISH:
					egg_color = Color(0.80, 0.88, 0.62)
				MobType.DRAGONFLY:
					egg_color = Color(0.70, 0.86, 0.86)
				MobType.BUTTERFLY:
					egg_color = Color(0.94, 0.90, 0.70)
				_:
					egg_color = Color(0.96, 0.94, 0.88)
			var sphere := MeshInstance3D.new()
			var ball := SphereMesh.new()
			ball.radius = 0.13
			ball.height = 0.26
			sphere.mesh = ball
			sphere.material_override = _flat(egg_color)
			sphere.position = Vector3(0.0, 0.13, 0.0)
			_visual_root.add_child(sphere)
		ART_TADPOLE:
			var color := Color(0.32, 0.36, 0.30)
			match type:
				MobType.FISH:
					color = Color(0.72, 0.78, 0.72)
				MobType.DRAGONFLY:
					color = Color(0.42, 0.50, 0.40)
				MobType.FROG:
					color = Color(0.30, 0.34, 0.28)
				_:
					color = Color(0.34, 0.38, 0.32)
			var body := MeshInstance3D.new()
			var ball := SphereMesh.new()
			ball.radius = 0.11
			ball.height = 0.22
			body.mesh = ball
			body.material_override = _flat(color)
			body.position = Vector3(0.0, 0.12, -0.04)
			_visual_root.add_child(body)
			# 尾巴：细长盒体向后方摆动。
			_add_box(Vector3(0.04, 0.04, 0.20), color.darkened(0.15), Vector3(0.0, 0.12, 0.14))
			_add_eye_at(Vector3(0.05, 0.16, -0.12), 0.025)
			_add_eye_at(Vector3(-0.05, 0.16, -0.12), 0.025)
		ART_CATERPILLAR:
			var color := Color(0.52, 0.76, 0.32)
			for i in range(4):
				var r := 0.085 - float(i) * 0.008
				var seg := MeshInstance3D.new()
				var ball := SphereMesh.new()
				ball.radius = r
				ball.height = r * 2.0
				seg.mesh = ball
				seg.material_override = _flat(color.lerp(color.lightened(0.2), float(i) / 3.0))
				seg.position = Vector3(0.0, 0.10, 0.16 - float(i) * 0.11)
				_visual_root.add_child(seg)
			_add_eye_at(Vector3(0.045, 0.16, -0.22), 0.022)
			_add_eye_at(Vector3(-0.045, 0.16, -0.22), 0.022)
		ART_COCOON:
			var cocoon := MeshInstance3D.new()
			var ball := SphereMesh.new()
			ball.radius = 0.13
			ball.height = 0.34
			cocoon.mesh = ball
			cocoon.material_override = _flat(Color(0.78, 0.72, 0.50))
			cocoon.position = Vector3(0.0, 0.17, 0.0)
			_visual_root.add_child(cocoon)
			# 悬丝：从茧顶向上的一根细线。
			_add_box(Vector3(0.015, 0.2, 0.015), Color(0.86, 0.84, 0.72), Vector3(0.0, 0.44, 0.0))


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


## 鸡：通用动物造型 + 鸡冠（公鸡为鲜红大冠、母鸡为浅红小冠）+ 喙。
func _build_chicken() -> void:
	_build_animal(
		Color(0.95, 0.94, 0.90),
		Vector3(0.42, 0.42, 0.48),
		Color(0.98, 0.80, 0.30),
		Vector3(0.24, 0.24, 0.22),
		0.68,
		2
	)
	var male := variant == 1
	var comb := Color(0.90, 0.22, 0.18) if male else Color(0.88, 0.50, 0.46)
	var comb_size := Vector3(0.06, 0.14, 0.12) if male else Vector3(0.05, 0.08, 0.09)
	_add_box(comb_size, comb, Vector3(0.0, 0.90, -0.06))
	_add_box(Vector3(0.07, 0.05, 0.09), Color(0.96, 0.72, 0.20), Vector3(0.0, 0.74, -0.24))


func _add_eyes(head_size: Vector3, eye_y: float, head_front_z: float) -> void:
	for sx in [-0.08, 0.08]:
		_add_eye_at(Vector3(sx * head_size.x * 6.0, eye_y + 0.05, head_front_z - head_size.z * 0.5 - 0.01), 0.05)


## 村民/掠夺者外观：长袍 + 头 + 标志性大鼻子 + 眼。
func _build_villager_like(robe_color: Color, skin_color: Color, eye_color: Color) -> void:
	_add_box(Vector3(0.56, 0.95, 0.42), robe_color, Vector3(0.0, 0.475, 0.0))
	var head_y := 1.16
	_add_box(Vector3(0.42, 0.42, 0.42), skin_color, Vector3(0.0, head_y, 0.0))
	# 大鼻子：头部正前中央突出的长盒。
	_add_box(Vector3(0.12, 0.22, 0.14), skin_color.darkened(0.08), Vector3(0.0, head_y - 0.06, -0.28))
	for sx in [-0.09, 0.09]:
		_add_eye_at(Vector3(sx, head_y + 0.06, -0.235), 0.045, eye_color)


func _build_hostile() -> void:
	_add_box(Vector3(0.7, 0.9, 0.5), _type_color(), Vector3(0.0, 0.45, 0.0))
	for sx in [-0.12, 0.12]:
		_add_eye_at(Vector3(sx, 0.55, -0.26), 0.06, Color(1.0, 1.0, 1.0))


## 鱼：纺锤身体 + 尾鳍 + 背鳍（朝向 -Z）。金鱼分支偏红。
func _build_fish() -> void:
	var body := Color(0.88, 0.56, 0.28)
	if variant == 1:
		body = Color(0.92, 0.42, 0.34)
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


## 蝴蝶：细身 + 两对彩色大翅（凤蝶偏暖橙、粉蝶偏粉白）。
func _build_butterfly() -> void:
	var wing := Color(0.95, 0.62, 0.24) if variant != 1 else Color(0.96, 0.82, 0.88)
	var edge := wing.darkened(0.30)
	_add_box(Vector3(0.06, 0.06, 0.34), Color(0.32, 0.26, 0.22), Vector3(0.0, 0.55, 0.0))
	_add_box(Vector3(0.11, 0.11, 0.11), Color(0.28, 0.22, 0.20), Vector3(0.0, 0.56, -0.20))
	for sx in [-1.0, 1.0]:
		_add_box_alpha(Vector3(0.30, 0.02, 0.24), wing, Vector3(sx * 0.19, 0.60, -0.04), 0.92)
		_add_box_alpha(Vector3(0.22, 0.02, 0.18), edge, Vector3(sx * 0.15, 0.58, 0.14), 0.90)
	# 触须：两根前伸的细线。
	for sx in [-1.0, 1.0]:
		_add_box(Vector3(0.015, 0.015, 0.16), Color(0.30, 0.26, 0.22), Vector3(sx * 0.04, 0.62, -0.30))
	_add_eye_at(Vector3(0.06, 0.60, -0.24), 0.035)
	_add_eye_at(Vector3(-0.06, 0.60, -0.24), 0.035)


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


## 大熊猫：白色圆身 + 黑色四肢/耳朵/眼圈（黑眼圈是它最醒目的特征）。
func _build_panda() -> void:
	var white := Color(0.96, 0.96, 0.94)
	var black := Color(0.14, 0.14, 0.16)
	_add_box(Vector3(0.86, 0.72, 0.62), white, Vector3(0.0, 0.76, 0.0))
	for sx in [-0.30, 0.30]:
		_add_box(Vector3(0.16, 0.44, 0.16), black, Vector3(sx, 0.22, -0.18))
		_add_box(Vector3(0.16, 0.44, 0.16), black, Vector3(sx, 0.22, 0.18))
	_add_box(Vector3(0.44, 0.42, 0.40), white, Vector3(0.0, 1.30, -0.30))
	for sx in [-0.22, 0.22]:
		_add_box(Vector3(0.16, 0.16, 0.10), black, Vector3(sx, 1.50, -0.34))
		_add_eye_at(Vector3(sx * 0.62, 1.34, -0.50), 0.055, white)
		_add_eye_at(Vector3(sx * 0.62, 1.34, -0.53), 0.032, black)


## 金丝猴：金黄色身体 + 蓝色面孔 + 长尾。
func _build_monkey() -> void:
	var fur := Color(0.94, 0.72, 0.28)
	var face := Color(0.42, 0.62, 0.86)
	_add_box(Vector3(0.36, 0.44, 0.30), fur, Vector3(0.0, 0.62, 0.0))
	_add_box(Vector3(0.30, 0.30, 0.28), face, Vector3(0.0, 0.98, -0.06))
	for sx in [-0.24, 0.24]:
		_add_box(Vector3(0.09, 0.36, 0.09), fur.darkened(0.12), Vector3(sx, 0.24, 0.0))
	_add_box(Vector3(0.09, 0.09, 0.36), fur.lightened(0.08), Vector3(0.0, 0.66, 0.30))
	_add_eye_at(Vector3(0.08, 1.03, -0.20), 0.04)
	_add_eye_at(Vector3(-0.08, 1.03, -0.20), 0.04)


## 朱鹮：白色身体、红色面颊、细长黑腿与长喙（中国特有珍禽）。
func _build_ibis() -> void:
	var white := Color(0.96, 0.94, 0.90)
	var face := Color(0.90, 0.34, 0.30)
	var legs := Color(0.32, 0.26, 0.24)
	_add_box(Vector3(0.34, 0.34, 0.42), white, Vector3(0.0, 0.62, 0.0))
	_add_box(Vector3(0.38, 0.04, 0.24), Color(0.96, 0.72, 0.72), Vector3(0.0, 0.62, 0.22))
	_add_box(Vector3(0.24, 0.24, 0.26), face, Vector3(0.0, 0.90, -0.14))
	_add_box(Vector3(0.05, 0.05, 0.26), legs.lightened(0.30), Vector3(0.0, 0.86, -0.36))
	for sx in [-0.08, 0.08]:
		_add_box(Vector3(0.04, 0.44, 0.04), legs, Vector3(sx, 0.22, 0.0))
	_add_eye_at(Vector3(0.08, 0.94, -0.27), 0.032)
	_add_eye_at(Vector3(-0.08, 0.94, -0.27), 0.032)


## 白头海雕：褐身 + 白色头颈 + 黄色钩喙（美国国鸟，濒危后受保护）。
func _build_eagle() -> void:
	var brown := Color(0.42, 0.28, 0.16)
	var head := Color(0.97, 0.97, 0.95)
	_add_box(Vector3(0.32, 0.30, 0.50), brown, Vector3(0.0, 0.58, 0.02))
	_add_box_alpha(Vector3(0.62, 0.03, 0.30), brown.darkened(0.10), Vector3(0.0, 0.62, 0.02), 0.92)
	_add_box(Vector3(0.22, 0.22, 0.24), head, Vector3(0.0, 0.78, -0.24))
	_add_box(Vector3(0.06, 0.06, 0.16), Color(0.94, 0.76, 0.20), Vector3(0.0, 0.76, -0.42))
	_add_box(Vector3(0.06, 0.10, 0.06), Color(0.94, 0.76, 0.20), Vector3(0.0, 0.68, -0.44))
	_add_eye_at(Vector3(0.08, 0.83, -0.34), 0.03)
	_add_eye_at(Vector3(-0.08, 0.83, -0.34), 0.03)


## 北极熊：乳白大型身体 + 黑鼻（北极顶级掠食者，受气候变化与保护名录关注）。
func _build_polar_bear() -> void:
	var fur := Color(0.96, 0.96, 0.93)
	_add_box(Vector3(0.98, 0.82, 0.70), fur, Vector3(0.0, 0.86, 0.0))
	for sx in [-0.34, 0.34]:
		_add_box(Vector3(0.18, 0.50, 0.18), fur.darkened(0.06), Vector3(sx, 0.25, -0.20))
		_add_box(Vector3(0.18, 0.50, 0.18), fur.darkened(0.06), Vector3(sx, 0.25, 0.20))
	_add_box(Vector3(0.44, 0.42, 0.44), fur, Vector3(0.0, 1.42, -0.40))
	_add_box(Vector3(0.30, 0.24, 0.24), fur.lightened(0.04), Vector3(0.0, 1.26, -0.60))
	_add_box(Vector3(0.13, 0.11, 0.10), Color(0.18, 0.16, 0.16), Vector3(0.0, 1.44, -0.74))
	_add_eye_at(Vector3(0.13, 1.52, -0.62), 0.045)
	_add_eye_at(Vector3(-0.13, 1.52, -0.62), 0.045)


## 袋鼠：直立身体 + 粗长尾 + 大脚（澳洲特有有袋类）。
func _build_kangaroo() -> void:
	var fur := Color(0.72, 0.52, 0.30)
	_add_box(Vector3(0.42, 0.66, 0.38), fur, Vector3(0.0, 0.92, 0.0))
	_add_box(Vector3(0.26, 0.24, 0.26), fur.lightened(0.06), Vector3(0.0, 1.40, -0.10))
	for sx in [-0.18, 0.18]:
		_add_box(Vector3(0.22, 0.10, 0.44), fur.darkened(0.18), Vector3(sx, 0.06, -0.10))
		_add_box(Vector3(0.10, 0.30, 0.10), fur, Vector3(sx * 1.4, 0.34, 0.02))
	for sx in [-0.20, 0.20]:
		_add_box(Vector3(0.14, 0.14, 0.10), fur.lightened(0.12), Vector3(sx, 1.48, -0.20))
	# 粗尾巴：向后下方延伸的斜盒。
	var tail := _add_box(Vector3(0.16, 0.40, 0.16), fur.darkened(0.10), Vector3(0.0, 0.34, 0.34))
	tail.rotation_degrees = Vector3(-32.0, 0.0, 0.0)
	_add_eye_at(Vector3(0.10, 1.44, -0.23), 0.035)
	_add_eye_at(Vector3(-0.10, 1.44, -0.23), 0.035)


func _add_box(size: Vector3, color: Color, pos: Vector3) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh_instance.mesh = box
	mesh_instance.material_override = _flat(color)
	mesh_instance.position = pos
	_visual_root.add_child(mesh_instance)
	return mesh_instance


## 半透明盒体（蜻蜓/蝴蝶翅膀等）。
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
	_visual_root.add_child(mesh_instance)


## 单颗眼球：位置逐一指定，可指定颜色（青蛙用白色眼白 + 深色瞳孔）。
func _add_eye_at(pos: Vector3, radius: float, color := Color(0.05, 0.05, 0.06)) -> void:
	var eye := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	eye.mesh = sphere
	eye.material_override = _flat(color)
	eye.position = pos
	_visual_root.add_child(eye)


func _flat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


func _build_collision() -> void:
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	match type:
		MobType.CHICKEN:
			capsule.radius = 0.2
			capsule.height = 0.6
			shape.position = Vector3(0.0, 0.3, 0.0)
		MobType.COW, MobType.SHEEP, MobType.PANDA, MobType.POLAR_BEAR, MobType.KANGAROO, MobType.GOLDEN_MONKEY, MobType.CRESTED_IBIS:
			capsule.radius = 0.35
			capsule.height = 1.0
			shape.position = Vector3(0.0, 0.5, 0.0)
		MobType.BUTTERFLY, MobType.DRAGONFLY, MobType.BALD_EAGLE:
			capsule.radius = 0.13
			capsule.height = 0.3
			shape.position = Vector3(0.0, 0.56, 0.0)
		MobType.FISH:
			capsule.radius = 0.15
			capsule.height = 0.36
			shape.position = Vector3(0.0, 0.28, 0.0)
		MobType.SHRIMP, MobType.CRAB, MobType.FROG:
			capsule.radius = 0.16
			capsule.height = 0.36
			shape.position = Vector3(0.0, 0.17, 0.0)
		_:
			capsule.radius = 0.3
			capsule.height = 1.2
			shape.position = Vector3(0.0, 0.6, 0.0)
	shape.shape = capsule
	_collision = shape
	add_child(shape)
	_apply_collision_scale()


## 碰撞体随阶段缩放：小小身体配小小的碰撞胶囊，避免幼体被空气挡住。
func _apply_collision_scale() -> void:
	if _collision == null:
		return
	_collision.scale = Vector3.ONE * maxf(0.45, stage_scale())


func _type_color() -> Color:
	match type:
		MobType.SKELETON:
			return Color(0.88, 0.88, 0.82)
		MobType.SPIDER:
			return Color(0.30, 0.30, 0.36)
		_:
			return Color(0.42, 0.78, 0.42)
