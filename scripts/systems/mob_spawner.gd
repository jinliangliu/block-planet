extends Node3D
class_name MobSpawner
## 生物生成器（昼夜双轨）：
## 白天在玩家周围草地上维持被动动物（牛/羊/鸡），夜晚生成敌对（僵尸/蜘蛛/骷髅）。
## 白天清空敌对但保留动物；创造模式全部不生成。

const MAX_MOBS := 8
const MAX_PASSIVE := 6
const SPAWN_INTERVAL := 4.0
const PASSIVE_INTERVAL := 6.0
const SPAWN_MIN := 12.0
const SPAWN_MAX := 26.0
const GROUND_SCAN_STEPS := 32

## 水生物生成：独立轨道，与陆地动物/敌对名额互不挤占，也不参与昼夜清空。
const MAX_WATER_LIFE := 6
const WATER_INTERVAL := 5.0
const WATER_SCAN_MIN := 6.0
const WATER_SCAN_MAX := 22.0
const WATER_SCAN_TRIES := 20
const SHORE_SEARCH_RADIUS := 6

## _find_spawn_position 的失败哨兵值。
const INVALID_POSITION := Vector3(INF, INF, INF)

var _player: Player
var _world: World
var _day_night: DayNightCycle
var _mobs: Array[Mob] = []
## 水生物独立列表：不占用陆地动物/敌对名额，也不参与昼夜清空。
var _water_mobs: Array[Mob] = []
var _spawn_timer := 0.0
var _passive_timer := 1.0
var _water_timer := 3.0


func setup(player: Player, world: World, day_night: DayNightCycle) -> void:
	_player = player
	_world = world
	_day_night = day_night


func _process(delta: float) -> void:
	if _player == null or _world == null or _day_night == null:
		return

	var alive: Array[Mob] = []
	for mob in _mobs:
		if is_instance_valid(mob) and not mob.is_queued_for_deletion():
			alive.append(mob)
	_mobs = alive

	if GameState.is_creative():
		_despawn_all()
		return

	_maintain_water_life(delta)

	if _day_night.is_day():
		_despawn_hostiles()
		_passive_timer -= delta
		if _passive_timer <= 0.0 and _passive_count() < MAX_PASSIVE:
			_passive_timer = PASSIVE_INTERVAL
			_spawn_one(_pick_passive_type())
		return

	# 夜晚：敌对生成；动物不再补充（白天已就位的动物继续存在）。
	_spawn_timer -= delta
	if _spawn_timer <= 0.0 and _hostile_count() < MAX_MOBS:
		_spawn_timer = SPAWN_INTERVAL
		_spawn_one(_pick_type())


func _passive_count() -> int:
	var count := 0
	for mob in _mobs:
		if is_instance_valid(mob) and Mob.is_passive(mob.type):
			count += 1
	return count


func _hostile_count() -> int:
	return _mobs.size() - _passive_count()


## 白天清空敌对、保留动物。
func _despawn_hostiles() -> void:
	var kept: Array[Mob] = []
	for mob in _mobs:
		if is_instance_valid(mob) and Mob.is_passive(mob.type):
			kept.append(mob)
		elif is_instance_valid(mob):
			mob.queue_free()
	_mobs = kept


func _spawn_one(mob_type: Mob.MobType) -> void:
	var pos := _find_spawn_position(Mob.is_passive(mob_type))
	if pos == INVALID_POSITION:
		return
	var mob := Mob.new()
	mob.setup(mob_type, _player, _day_night)
	add_child(mob)
	mob.global_position = pos
	_mobs.append(mob)


## 夜晚敌对概率：僵尸 40%、骷髅 30%、蜘蛛 15%、狼 15%。
func _pick_type() -> Mob.MobType:
	var r := randf()
	if r < 0.40:
		return Mob.MobType.ZOMBIE
	if r < 0.70:
		return Mob.MobType.SKELETON
	if r < 0.85:
		return Mob.MobType.SPIDER
	return Mob.MobType.WOLF


## 白天动物概率：牛 35%、羊 30%、鸡 20%、猪 15%。
func _pick_passive_type() -> Mob.MobType:
	var r := randf()
	if r < 0.35:
		return Mob.MobType.COW
	if r < 0.65:
		return Mob.MobType.SHEEP
	if r < 0.85:
		return Mob.MobType.CHICKEN
	return Mob.MobType.PIG


func _despawn_all() -> void:
	for mob in _mobs:
		if is_instance_valid(mob):
			mob.queue_free()
	_mobs.clear()
	for mob in _water_mobs:
		if is_instance_valid(mob):
			mob.queue_free()
	_water_mobs.clear()


## 水生物维护：清理失效引用，按节奏在大河/池塘附近补充。
func _maintain_water_life(delta: float) -> void:
	var alive: Array[Mob] = []
	for mob in _water_mobs:
		if is_instance_valid(mob) and not mob.is_queued_for_deletion():
			alive.append(mob)
	_water_mobs = alive

	_water_timer -= delta
	if _water_timer > 0.0 or _water_mobs.size() >= MAX_WATER_LIFE:
		return
	_water_timer = WATER_INTERVAL
	_spawn_water_life()


## 在玩家附近找一处水体生成生物：大河出鱼/虾/蟹，池塘出蜻蜓/青蛙。
## 返回是否成功生成（同时供探针直接调用）。
func _spawn_water_life() -> bool:
	for i in range(WATER_SCAN_TRIES):
		var angle := randf() * TAU
		var dist := randf_range(WATER_SCAN_MIN, WATER_SCAN_MAX)
		var wx := int(round(_player.global_position.x + cos(angle) * dist))
		var wz := int(round(_player.global_position.z + sin(angle) * dist))
		var kind := _world.water_kind(wx, wz)
		if kind == World.WATER_LARGE:
			if _spawn_in_large_water(_pick_large_water_type(), wx, wz):
				return true
		elif kind == World.WATER_POND:
			if _spawn_by_pond(_pick_pond_type(), wx, wz):
				return true
	return false


## 大河概率：鱼 50%、虾 25%、蟹 25%。
func _pick_large_water_type() -> Mob.MobType:
	var r := randf()
	if r < 0.50:
		return Mob.MobType.FISH
	if r < 0.75:
		return Mob.MobType.SHRIMP
	return Mob.MobType.CRAB


## 池塘概率：蜻蜓 45%、青蛙 55%。
func _pick_pond_type() -> Mob.MobType:
	return Mob.MobType.DRAGONFLY if randf() < 0.45 else Mob.MobType.FROG


## 大河：蟹贴水底、鱼虾在水柱中部（就近取一格水体，避开水面植物）。
func _spawn_in_large_water(mob_type: Mob.MobType, wx: int, wz: int) -> bool:
	var depth := _world.water_depth(wx, wz)
	if depth <= 0:
		return false
	var y := (World.SEA_LEVEL - depth + 1) if mob_type == Mob.MobType.CRAB else (World.SEA_LEVEL - depth / 2)
	var cell := _find_water_cell(wx, y, wz)
	if cell.y < 0:
		return false
	_place_water_mob(mob_type, Vector3(wx + 0.5, float(cell.y) + 0.1, wz + 0.5))
	return true


## 池塘：蜻蜓悬停在水面上方；青蛙放在岸边草地（水底不可站立）。
func _spawn_by_pond(mob_type: Mob.MobType, wx: int, wz: int) -> bool:
	if mob_type == Mob.MobType.DRAGONFLY:
		_place_water_mob(mob_type, Vector3(wx + 0.5, float(World.SEA_LEVEL) + 1.2, wz + 0.5))
		return true
	var shore := _find_pond_shore(wx, wz)
	if shore == INVALID_POSITION:
		return false
	_place_water_mob(mob_type, shore)
	return true


## 水柱中就近取一格水（目标高度 → 上下 ±1、±2）。
func _find_water_cell(wx: int, y: int, wz: int) -> Vector3i:
	for offset in [0, -1, 1, -2, 2]:
		var cell := Vector3i(wx, y + offset, wz)
		if _world.get_block(cell) == BlockTypes.Block.WATER:
			return cell
	return Vector3i(wx, -1, wz)


## 池塘岸边的可站立落点：环形向外找非水列，取草地/沙地上的两格空气位。
func _find_pond_shore(wx: int, wz: int) -> Vector3:
	for radius in range(1, SHORE_SEARCH_RADIUS + 1):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				var cx := wx + dx
				var cz := wz + dz
				if _world.water_kind(cx, cz) != World.WATER_NONE:
					continue
				var y := _find_ground_y(cx, cz)
				if y < 0:
					continue
				var below := _world.get_block(Vector3i(cx, y - 1, cz))
				if below != BlockTypes.Block.GRASS and below != BlockTypes.Block.SAND:
					continue
				return Vector3(cx + 0.5, float(y) + 0.2, cz + 0.5)
	return INVALID_POSITION


func _place_water_mob(mob_type: Mob.MobType, pos: Vector3) -> void:
	var mob := Mob.new()
	mob.setup(mob_type, _player, _day_night)
	add_child(mob)
	mob.global_position = pos
	_water_mobs.append(mob)


func _find_spawn_position(require_grass: bool) -> Vector3:
	for i in range(16):
		var angle := randf() * TAU
		var dist := randf_range(SPAWN_MIN, SPAWN_MAX)
		var wx := int(round(_player.global_position.x + cos(angle) * dist))
		var wz := int(round(_player.global_position.z + sin(angle) * dist))
		var y := _find_ground_y(wx, wz)
		if y < 0:
			continue
		if require_grass and _world.get_block(Vector3i(wx, y - 1, wz)) != BlockTypes.Block.GRASS:
			continue
		return Vector3(float(wx) + 0.5, float(y) + 0.2, float(wz) + 0.5)

	return INVALID_POSITION


## 从噪声地表高度起向上扫描，找到连续两格空气且脚下为实心方块的位置。
## 噪声高度不含树木与玩家建筑，直接使用会卡进树干或房屋。
func _find_ground_y(wx: int, wz: int) -> int:
	var y := _world.get_surface_height(wx, wz)
	for i in range(GROUND_SCAN_STEPS):
		if y >= World.CHUNK_SIZE.y - 2:
			return -1
		var at := _world.get_block(Vector3i(wx, y, wz))
		var above := _world.get_block(Vector3i(wx, y + 1, wz))
		var below := _world.get_block(Vector3i(wx, y - 1, wz))
		var below_solid := below != BlockTypes.Block.AIR and below != BlockTypes.Block.WATER
		if at == BlockTypes.Block.AIR and above == BlockTypes.Block.AIR and below_solid:
			return y
		y += 1
	return -1
