class_name VillageBuilder
extends RefCounted
## 固定坐标村庄生成器（世界种子固定，地形可探测）：
## 三座民居 + 圆石广场 + 酿灶台 + 掠夺塔（塔顶/塔门各一名掠夺者守卫）+ 村民。
## 生成流程：探测基准高度 → 强制加载覆盖区块 → 整平地基 →
## 延迟批量写方块 → 统一重建网格 → 放置村民与掠夺者（挂载于 parent，不受昼夜清空管理）。

const REGION_MIN := Vector3i(13, 0, 16)
const REGION_MAX := Vector3i(41, 0, 40)
const TOWER_CENTER := Vector3i(37, 0, 22)
const HOUSE_POSITIONS: Array[Vector3i] = [
	Vector3i(15, 0, 18),
	Vector3i(15, 0, 30),
	Vector3i(27, 0, 30),
]
const PLAZA_ORIGIN := Vector3i(22, 0, 24)
# 农田西北角：6×6 区域，位于民居东侧、掠夺塔与广场之间的空地（无重叠）。
const FARM_ORIGIN := Vector3i(34, 0, 27)
const FARM_SIZE := 6

var base_y := 30
## 村庄原点偏移：同一区域可建多座村庄（主场景传不同 origin），
## 所有常量坐标均相对原点，探针用 origin=Vector3i.ZERO 复算村庄 A。
var origin := Vector3i.ZERO
var _world: World
var _parent: Node3D
var _player: Player
var _day_night: DayNightCycle


func build(world: World, player: Player, day_night: DayNightCycle, parent: Node3D,
		origin_offset := Vector3i.ZERO) -> void:
	_world = world
	_player = player
	_day_night = day_night
	_parent = parent
	origin = origin_offset
	_probe_base_y()
	world.ensure_chunks_in_region(_min_cell(), _max_cell())
	_flatten()
	for pos: Vector3i in HOUSE_POSITIONS:
		_build_house(pos)
	_build_plaza(PLAZA_ORIGIN)
	_build_tower()
	_build_farm()
	world.rebuild_chunks_in_region(_min_cell(), _max_cell())
	_spawn_npcs()


func _min_cell() -> Vector3i:
	return REGION_MIN + origin


func _max_cell() -> Vector3i:
	return REGION_MAX + origin


## 村庄基准地面高度：区域内地表最高方块 y（种子固定，可离线探测）。
func _probe_base_y() -> void:
	var top := 0
	for x in range(_min_cell().x, _max_cell().x + 1):
		for z in range(_min_cell().z, _max_cell().z + 1):
			top = maxi(top, _world.get_surface_height(x, z) - 1)
	base_y = top


## 整平：清空区域上方（含树木），统一铺设 DIRT 地基 + GRASS 地面。
func _flatten() -> void:
	for x in range(_min_cell().x, _max_cell().x + 1):
		for z in range(_min_cell().z, _max_cell().z + 1):
			for y in range(base_y - 4, base_y + 12):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.AIR)
			for y in range(base_y - 3, base_y):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.DIRT)
			_world.set_block_deferred(Vector3i(x, base_y, z), BlockTypes.Block.GRASS)


## 民居：6×6 圆石外墙、木质平顶、北门 1×2 门洞、玻璃窗。
func _build_house(o: Vector3i) -> void:
	o += origin
	for x in range(6):
		for z in range(6):
			var edge := x == 0 or x == 5 or z == 0 or z == 5
			if edge:
				_world.set_block_deferred(Vector3i(o.x + x, base_y + 1, o.z + z), BlockTypes.Block.COBBLESTONE)
				_world.set_block_deferred(Vector3i(o.x + x, base_y + 2, o.z + z), BlockTypes.Block.COBBLESTONE)
			_world.set_block_deferred(Vector3i(o.x + x, base_y + 3, o.z + z), BlockTypes.Block.WOOD)
	# 门洞（北侧中央）与窗。
	_world.set_block_deferred(Vector3i(o.x + 2, base_y + 1, o.z), BlockTypes.Block.AIR)
	_world.set_block_deferred(Vector3i(o.x + 2, base_y + 2, o.z), BlockTypes.Block.AIR)
	for gz: int in [2, 3]:
		_world.set_block_deferred(Vector3i(o.x, base_y + 2, o.z + gz), BlockTypes.Block.GLASS)
		_world.set_block_deferred(Vector3i(o.x + 5, base_y + 2, o.z + gz), BlockTypes.Block.GLASS)
	_world.set_block_deferred(Vector3i(o.x + 4, base_y + 2, o.z), BlockTypes.Block.GLASS)


## 广场：5×5 圆石地面，东侧立一座酿灶台。
func _build_plaza(o: Vector3i) -> void:
	o += origin
	for x in range(5):
		for z in range(5):
			_world.set_block_deferred(Vector3i(o.x + x, base_y, o.z + z), BlockTypes.Block.COBBLESTONE)
	_world.set_block_deferred(Vector3i(o.x + 5, base_y + 1, o.z + 2), BlockTypes.Block.BREWING)


## 掠夺塔：3×3 圆石塔体高 8、木质 5×5 顶平台、四角护栏与旗帜，南侧门洞。
func _build_tower() -> void:
	var c := TOWER_CENTER + origin
	for x in range(c.x - 1, c.x + 2):
		for z in range(c.z - 1, c.z + 2):
			for y in range(base_y + 1, base_y + 9):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.COBBLESTONE)
	_world.set_block_deferred(Vector3i(c.x, base_y + 1, c.z - 1), BlockTypes.Block.AIR)
	_world.set_block_deferred(Vector3i(c.x, base_y + 2, c.z - 1), BlockTypes.Block.AIR)
	for x in range(c.x - 2, c.x + 3):
		for z in range(c.z - 2, c.z + 3):
			_world.set_block_deferred(Vector3i(x, base_y + 9, z), BlockTypes.Block.WOOD)
	for cx: int in [c.x - 2, c.x + 2]:
		for cz: int in [c.z - 2, c.z + 2]:
			_world.set_block_deferred(Vector3i(cx, base_y + 10, cz), BlockTypes.Block.WOOD)
	# 旗帜：西北角立杆 + 树叶旗面。
	_world.set_block_deferred(Vector3i(c.x - 2, base_y + 11, c.z - 2), BlockTypes.Block.WOOD)
	_world.set_block_deferred(Vector3i(c.x - 2, base_y + 12, c.z - 2), BlockTypes.Block.LEAVES)


## 农田：6×6 耕地，中间一列灌水，其余格种作物——小麦为主，
## 混种胡萝卜/土豆/白萝卜（按坐标哈希决定品种，种子固定可复现）。
func _build_farm() -> void:
	var o := FARM_ORIGIN + origin
	var water_x := FARM_SIZE / 2
	for x in range(FARM_SIZE):
		for z in range(FARM_SIZE):
			var cell := Vector3i(o.x + x, base_y, o.z + z)
			if x == water_x:
				_world.set_block_deferred(cell, BlockTypes.Block.WATER)
				continue
			_world.set_block_deferred(cell, BlockTypes.Block.FARMLAND)
			_world.set_block_deferred(cell + Vector3i(0, 1, 0), _farm_crop(x, z))


## 农田品种：约六成小麦，其余均分三种新蔬菜（哈希确定性，探针可复现）。
func _farm_crop(x: int, z: int) -> int:
	var h := absi((x * 73856093) ^ (z * 19349663)) % 10
	match h:
		0, 1:
			return BlockTypes.Block.CARROT_CROP
		2, 3:
			return BlockTypes.Block.POTATO_CROP
		4:
			return BlockTypes.Block.RADISH_CROP
		_:
			return BlockTypes.Block.WHEAT_CROP


func _spawn_npcs() -> void:
	# 村民：广场一只 + 三座民居内各一只。
	_spawn_mob(Mob.MobType.VILLAGER, Vector3(24.5, base_y + 1.0, 26.5) + Vector3(origin))
	_spawn_mob(Mob.MobType.VILLAGER, Vector3(17.5, base_y + 1.0, 20.5) + Vector3(origin))
	_spawn_mob(Mob.MobType.VILLAGER, Vector3(17.5, base_y + 1.0, 32.5) + Vector3(origin))
	_spawn_mob(Mob.MobType.VILLAGER, Vector3(29.5, base_y + 1.0, 32.5) + Vector3(origin))
	# 掠夺者：塔门守卫 + 塔顶守卫。
	_spawn_mob(Mob.MobType.PILLAGER, Vector3(37.5, base_y + 1.0, 19.5) + Vector3(origin))
	_spawn_mob(Mob.MobType.PILLAGER, Vector3(37.5, base_y + 10.0, 22.5) + Vector3(origin))


func _spawn_mob(type: Mob.MobType, pos: Vector3) -> void:
	var mob := Mob.new()
	mob.setup(type, _player, _day_night)
	_parent.add_child(mob)
	mob.global_position = pos
