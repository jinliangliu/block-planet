class_name AirportBuilder
extends RefCounted
## 带跑道的小机场生成器（仅 RegionAtlas.has_airport 的区域）：
## 在给定中心整平一块地，铺 COBBLESTONE 跑道 + GRASS 道肩，南北两端 SAND 跑道头，
## 南端立一座开放式机库（圆石围墙 + 木顶 + 朝跑道门洞）。跑道沿 +Z 方向，长度留足
## 滑跑到抬轮；中央留净空，不挡起飞。
##
## 与 VillageBuilder 同套路：探测基准高度 → ensure_chunks → 批量写方块 → rebuild。
## 出生点改写到跑道南段，玩家开局即站在跑道上，落地即可起飞（main 调用方负责）。

const RUNWAY_LEN := 56           # 沿 +Z，满油门滑跑到抬轮有余量
const RUNWAY_WID := 12           # 沿 X；机身宽 6.6 格，留侧向余量
const CLEAR_H := 12              # 跑道 / 机库上方净空（块）
const HANGAR_DEPTH := 4

var origin := Vector3i.ZERO
var base_y := 30
var _world: World


## 在 center 处建造机场，返回建议出生点（跑道南段、机头朝 +Z）。
## 只写 center 周边的区块：其余区域（含村庄）不受影响。
func build(world: World, center: Vector3i) -> Vector3:
	_world = world
	origin = center
	_probe_base_y()

	var half_w := RUNWAY_WID / 2
	var min_c := Vector3i(
		center.x - half_w - 2, 0, center.z - RUNWAY_LEN / 2 - HANGAR_DEPTH - 2)
	var max_c := Vector3i(
		center.x + half_w + 2, 0, center.z + RUNWAY_LEN / 2 + 2)
	_world.ensure_chunks_in_region(min_c, max_c)

	# 整平地基：清上方（含树木）+ 填 DIRT 地基，统一落在一块平地上。
	for x in range(min_c.x, max_c.x + 1):
		for z in range(min_c.z, max_c.z + 1):
			for y in range(base_y - 3, base_y + CLEAR_H):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.AIR)
			for y in range(base_y - 3, base_y):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.DIRT)

	# 跑道铺面（圆石沥青感）+ 两侧 GRASS 道肩。
	for z in range(center.z - RUNWAY_LEN / 2, center.z + RUNWAY_LEN / 2 + 1):
		for dx in range(-half_w, half_w + 1):
			_world.set_block_deferred(
				Vector3i(center.x + dx, base_y, z), BlockTypes.Block.COBBLESTONE)
	# 南北跑道头：3 格宽 SAND 标记（与跑道面区分，提示起降边界）。
	for end_z in [center.z - RUNWAY_LEN / 2 - 1, center.z + RUNWAY_LEN / 2 + 1]:
		for dx in range(-half_w, half_w + 1):
			_world.set_block_deferred(
				Vector3i(center.x + dx, base_y, end_z), BlockTypes.Block.SAND)

	_build_hangar(center)

	_world.rebuild_chunks_in_region(min_c, max_c)

	# 出生点：跑道南段、机头朝 +Z，紧邻机库门口外。
	return Vector3(center.x + 0.5, float(base_y + 1), float(center.z - RUNWAY_LEN / 2 + 3) + 0.5)


## 机库：南端一座开放式圆石棚（围墙高 6 + 木顶），朝跑道（+Z）留 3 宽门洞。
## 与跑道同基准高度，独立于村庄结构。
func _build_hangar(center: Vector3i) -> void:
	var half_w := RUNWAY_WID / 2
	var z0 := center.z - RUNWAY_LEN / 2 - HANGAR_DEPTH
	var x0 := center.x - half_w - 1
	var x1 := center.x + half_w + 1
	var z1 := z0 + HANGAR_DEPTH - 1

	# 地坪。
	for x in range(x0, x1 + 1):
		for z in range(z0, z1 + 1):
			_world.set_block_deferred(Vector3i(x, base_y, z), BlockTypes.Block.COBBLESTONE)
	# 四围墙。
	for x in range(x0, x1 + 1):
		for h in range(1, 7):
			_world.set_block_deferred(Vector3i(x, base_y + h, z0), BlockTypes.Block.COBBLESTONE)
			_world.set_block_deferred(Vector3i(x, base_y + h, z1), BlockTypes.Block.COBBLESTONE)
	for z in range(z0, z1 + 1):
		for h in range(1, 7):
			_world.set_block_deferred(Vector3i(x0, base_y + h, z), BlockTypes.Block.COBBLESTONE)
			_world.set_block_deferred(Vector3i(x1, base_y + h, z), BlockTypes.Block.COBBLESTONE)
	# 朝跑道门洞（+Z 侧中央 3 宽 × 4 高）。
	for dx in range(-1, 2):
		for h in range(1, 5):
			_world.set_block_deferred(Vector3i(center.x + dx, base_y + h, z1), BlockTypes.Block.AIR)
	# 木顶封闭。
	for x in range(x0, x1 + 1):
		for z in range(z0, z1 + 1):
			_world.set_block_deferred(Vector3i(x, base_y + 7, z), BlockTypes.Block.WOOD)


## 机场基准地面高度：中心周边地表最高方块 y（种子固定，可离线探测）。
func _probe_base_y() -> void:
	var top := 0
	var r := RUNWAY_WID / 2 + 3
	for x in range(origin.x - r, origin.x + r + 1):
		for z in range(origin.z - RUNWAY_LEN / 2 - HANGAR_DEPTH, origin.z + RUNWAY_LEN / 2 + 1):
			top = maxi(top, _world.get_surface_height(x, z) - 1)
	base_y = top
