class_name HarborBuilder
extends RefCounted
## 海岛港口建造器（D-042 航海玩法）：在简易降落场所在的岛子边缘建一座
## 小港——沙滩平台 + 木栈桥 + 灯塔 + 泊位。与 AirportBuilder 同套路：
## preload 不建网格 → 批量写入 → 统一重建（只重建出生点保留窗内）。
##
## 空间纪律（硬约束）：
##   - 场址搜索避开降落场足迹（FIELD_WID=10 × FIELD_LEN=32 + 施工缘），
##     栈桥从沙滩向海面外伸，永不压跑道；
##   - 只写港区周边区块，村庄/地形管线不受影响。
##
## 坐标：格（D-062 P1 起 1 格 = 1 m）。可站立顶面 = 方块 y + 1；水线 = SEA_LEVEL + 1
## （水填到 y≤22）。泊位返回「船体能浮的水面高度」。

## 沙滩平台尺寸（以岸点为中心的整平区）。
const APRON_HALF := 1
## 栈桥：宽 × 向海延伸长。
const DOCK_WID := 3
const DOCK_LEN := 5
## 岸点搜索：以场址为圆心的环带半径（内环避开降落场足迹）。
const SHORE_RING_MIN := 8
const SHORE_RING_MAX := 30
## 灯塔高度（格，约 4 m）。
const LIGHTHOUSE_H := 8

var _world: World
var _min_c := Vector3i.ZERO
var _max_c := Vector3i.ZERO


## 建港。field_site = 降落场场址（main._find_field_site 的返回值）。
## 返回 {"found", "dock_end", "moorings", "lighthouse", "dock_dir", "shore"}：
##   dock_end   玩家默认船的泊位（栈桥向海端，水线高度，船头朝外海）
##   moorings   港湾里装饰泊船的泊位（栈桥两侧）
##   lighthouse 灯塔位置（地标）
##   dock_dir   向海方向（Vector2，单位向量）
func build(world: World, field_site: Vector3i) -> Dictionary:
	_world = world
	var shore := _find_shore(field_site)
	if shore == Vector2i.ZERO:
		return {"found": false}
	var outward := _outward_dir(field_site, shore)
	var dock_end := Vector2i(shore.x + int(round(outward.x * DOCK_LEN)),
		shore.y + int(round(outward.y * DOCK_LEN)))
	var side := Vector2i(-outward.y, outward.x)
	var lighthouse_base := Vector2i(shore.x + side.x * 2, shore.y + side.y * 2)
	# 港区写入范围：沙滩平台 + 栈桥 + 灯塔 + 泊位 + 2 格施工缘（取并集）。
	var points := [
		Vector2i(shore.x - APRON_HALF - 2, shore.y - APRON_HALF - 2),
		Vector2i(shore.x + APRON_HALF + 2, shore.y + APRON_HALF + 2),
		Vector2i(dock_end.x - DOCK_WID, dock_end.y - DOCK_WID),
		Vector2i(dock_end.x + DOCK_WID, dock_end.y + DOCK_WID),
		Vector2i(lighthouse_base.x - 2, lighthouse_base.y - 2),
		Vector2i(lighthouse_base.x + 3, lighthouse_base.y + 3),
	]
	_min_c = Vector3i(points[0].x, 0, points[0].y)
	_max_c = Vector3i(points[0].x, 0, points[0].y)
	for p: Vector2i in points:
		_min_c.x = mini(_min_c.x, p.x)
		_min_c.z = mini(_min_c.z, p.y)
		_max_c.x = maxi(_max_c.x, p.x)
		_max_c.z = maxi(_max_c.z, p.y)
	_world.preload_chunks_in_region(_min_c, _max_c)
	_world.begin_bulk_writes()
	_build_apron(shore)
	_build_dock(shore, dock_end, outward)
	var lighthouse := _build_lighthouse(shore, outward)
	_world.end_bulk_writes()
	_world.rebuild_chunks_in_region_near(_min_c, _max_c, Vector3(shore.x + 0.5, float(World.SEA_LEVEL + 1), shore.y + 0.5))
	var water_y := float(World.SEA_LEVEL) + 1.0
	return {
		"found": true,
		"dock_end": Vector3(dock_end.x + 0.5, water_y + 0.3, dock_end.y + 0.5),
		"moorings": [
			Vector3(dock_end.x - side.x + 0.5, water_y + 0.3, dock_end.y - side.y + 0.5),
			Vector3(dock_end.x + side.x + 0.5, water_y + 0.3, dock_end.y + side.y + 0.5),
		],
		"lighthouse": lighthouse,
		"dock_dir": outward,
		"shore": Vector3(shore.x + 0.5, water_y, shore.y + 0.5),
	}


## 岸点搜索：绕场址逐环外扩，找「高于水面的陆地列、且四邻至少一列是水」。
## 优先挑 height == SEA_LEVEL + 1 的海滩列（栈桥能齐平接上）；找不到齐平的
## 才退而求其次（栈桥入口垫一级木阶）。降落场足迹内的列一律跳过。
func _find_shore(field_site: Vector3i) -> Vector2i:
	var best := Vector2i.ZERO
	var best_score := -1
	for radius in range(SHORE_RING_MIN, SHORE_RING_MAX + 1):
		for x in range(field_site.x - radius, field_site.x + radius + 1):
			for z in range(field_site.z - radius, field_site.z + radius + 1):
				if maxi(absi(x - field_site.x), absi(z - field_site.z)) != radius:
					continue
				if _in_field_footprint(x, z, field_site):
					continue
				var height := _world.get_surface_height(x, z)
				if height <= World.SEA_LEVEL:
					continue  # 水列
				if not _has_water_neighbor(x, z):
					continue  # 内陆
				# 评分：齐平海滩（height==23）满分；越高分越低（要垫阶）。
				var score := 100 - absi(height - (World.SEA_LEVEL + 1))
				if score > best_score:
					best_score = score
					best = Vector2i(x, z)
		if best != Vector2i.ZERO and best_score >= 100:
			break  # 找到齐平海滩就收工，不必搜更远的环
	return best


## 降落场足迹（含施工缘）：x∈[site.x-7, site.x+7]、z∈[site.z-19, site.z+19]。
## FIELD_WID=10（半 5）+ 2 缘；FIELD_LEN=32（半 16）+ 1 端头 + 2 缘。
func _in_field_footprint(x: int, z: int, field_site: Vector3i) -> bool:
	return absi(x - field_site.x) <= 7 and absi(z - field_site.z) <= 19


func _has_water_neighbor(x: int, z: int) -> bool:
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if _world.get_surface_height(x + d.x, z + d.y) <= World.SEA_LEVEL:
			return true
	return false


## 向海方向：岸点相对场址的单位向量（场址即岛心近似）。
func _outward_dir(field_site: Vector3i, shore: Vector2i) -> Vector2i:
	var d := Vector2(shore.x - field_site.x, shore.y - field_site.y)
	if d.length_squared() < 0.01:
		return Vector2i(1, 0)
	d = d.normalized()
	# 归一到四邻之一（栈桥只走正方向，简单且不会斜插地形）。
	if absf(d.x) > absf(d.y):
		return Vector2i(1 if d.x > 0.0 else -1, 0)
	return Vector2i(0, 1 if d.y > 0.0 else -1)


## 沙滩平台：岸点周边 (2·APRON_HALF+1)² 整平到水线高度（SEA_LEVEL+1 可站），
## 上方清 3 格空气（树冠让位），下方两格垫 SAND。齐平海滩本来就在这个高度，
## 整平是幂等的；高地列会被削成一级缓坡。
func _build_apron(shore: Vector2i) -> void:
	for x in range(shore.x - APRON_HALF, shore.x + APRON_HALF + 1):
		for z in range(shore.y - APRON_HALF, shore.y + APRON_HALF + 1):
			for y in range(World.SEA_LEVEL + 1, World.SEA_LEVEL + 4):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.AIR)
			for y in range(World.SEA_LEVEL - 2, World.SEA_LEVEL + 1):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.SAND)


## 栈桥：自岸点向海 DOCK_LEN 格、宽 DOCK_WID，铺 WOOD 甲板（水线高度），
## 向海端两根立柱下水（视觉）。甲板替换水列上方的空气（水只到 y≤22）。
func _build_dock(shore: Vector2i, dock_end: Vector2i, outward: Vector2i) -> void:
	var side := Vector2i(-outward.y, outward.x)
	for step in range(1, DOCK_LEN + 1):
		var cx := shore.x + outward.x * step
		var cz := shore.y + outward.y * step
		for w in range(-(DOCK_WID / 2), DOCK_WID / 2 + 1):
			var x := cx + side.x * w
			var z := cz + side.y * w
			_world.set_block_deferred(
				Vector3i(x, World.SEA_LEVEL + 1, z), BlockTypes.Block.WOOD)
	# 向海端立柱（两根，入水两格）。
	for w in [-(DOCK_WID / 2), DOCK_WID / 2]:
		var px: float = dock_end.x + side.x * w
		var pz: float = dock_end.y + side.y * w
		for y in range(World.SEA_LEVEL - 1, World.SEA_LEVEL + 1):
			_world.set_block_deferred(Vector3i(px, y, pz), BlockTypes.Block.WOOD)


## 灯塔：沙滩台一侧（垂直岸点方向挪 2 格）的 2×2 木塔，顶阁玻璃 + 红色航灯。
## 建在平台高度上，不占栈桥动线。
func _build_lighthouse(shore: Vector2i, outward: Vector2i) -> Vector3:
	var side := Vector2i(-outward.y, outward.x)
	var base := Vector2i(shore.x + side.x * 2, shore.y + side.y * 2)
	# 塔基也整到平台高度（可能在岸外水线上，填木台）。
	for x in range(base.x, base.x + 2):
		for z in range(base.y, base.y + 2):
			for y in range(World.SEA_LEVEL - 1, World.SEA_LEVEL + 1):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.WOOD)
	var bottom := World.SEA_LEVEL + 1
	for h in range(LIGHTHOUSE_H):
		for x in range(base.x, base.x + 2):
			for z in range(base.y, base.y + 2):
				var id := BlockTypes.Block.WOOD
				if h == LIGHTHOUSE_H - 1:
					id = BlockTypes.Block.NAV_RED  # 塔顶红灯
				elif h >= LIGHTHOUSE_H - 3:
					id = BlockTypes.Block.GLASS   # 顶阁玻璃
				_world.set_block_deferred(Vector3i(x, bottom + h, z), id)
	return Vector3(base.x + 1.0, float(bottom), base.y + 1.0)
