class_name AirportBuilder
extends RefCounted
## 带跑道的小机场生成器（RegionAtlas.has_airport 的区域）：
## 在给定中心整平一块地，铺 COBBLESTONE 跑道 + GRASS 道肩，南北两端 SAND 跑道头，
## 南端立一座开放式机库（圆石围墙 + 木顶 + 朝跑道门洞）。跑道沿 +Z 方向，长度留足
## 滑跑到抬轮；中央留净空，不挡起飞。
##
## 与 VillageBuilder 同套路：探测基准高度 → ensure_chunks → 批量写方块 → rebuild。
## 出生点改写到跑道南段，玩家开局即站在跑道上，落地即可起飞（main 调用方负责）。
##
## build_field() 为简易降落场变体（RegionAtlas.has_landing_field 的区域）：
## 无机库的短窄跑道，供大洋（岛上）/ 极地（冰面）区域使用；铺装、出生点
## 逻辑与机场一致。

const RUNWAY_LEN := 56           # 沿 +Z，满油门滑跑到抬轮有余量
const RUNWAY_WID := 12           # 沿 X；机身宽 6.6 格，留侧向余量
const CLEAR_H := 12              # 跑道 / 机库上方净空（块）
const HANGAR_DEPTH := 4
const FIELD_LEN := 32            # 简易降落场：短跑道，够起飞 / 停稳即用
const FIELD_WID := 10
const FIELD_CLEAR_H := 8

var origin := Vector3i.ZERO
var base_y := 30
var _world: World
var _min_c := Vector3i.ZERO
var _max_c := Vector3i.ZERO
var _half_w := RUNWAY_WID / 2
var _len := RUNWAY_LEN
var _clear_h := CLEAR_H


## 在 center 处建造机场，返回建议出生点（跑道南段、机头朝 +Z）。
## 只写 center 周边的区块：其余区域（含村庄）不受影响。
func build(world: World, center: Vector3i) -> Vector3:
	_begin(world, center, RUNWAY_WID, RUNWAY_LEN, HANGAR_DEPTH, CLEAR_H)
	_flatten_ground()
	_pave_runway()
	_mark_approach(false)
	_build_hangar(center)
	_end()
	return _spawn_point()


## 简易降落场：整平 + COBBLESTONE 短跑道 + SAND 跑道头，无机库。
## 返回跑道南段出生点（与机场一致的开场站位）。
func build_field(world: World, center: Vector3i) -> Vector3:
	_begin(world, center, FIELD_WID, FIELD_LEN, 0, FIELD_CLEAR_H)
	_flatten_ground()
	_pave_runway()
	_mark_approach(true)
	_end()
	return _spawn_point()


## 公共开场：记录参数、探测基准高度、确保周边区块（数据写入是同步的）。
func _begin(world: World, center: Vector3i, wid: int, length: int,
		south_extra: int, clear_h: int) -> void:
	_world = world
	origin = center
	_half_w = wid / 2
	_len = length
	_clear_h = clear_h
	_probe_base_y(south_extra)
	_min_c = Vector3i(
		center.x - _half_w - 2, 0, center.z - length / 2 - south_extra - 2)
	_max_c = Vector3i(
		center.x + _half_w + 2, 0, center.z + length / 2 + 2)
	_world.ensure_chunks_in_region(_min_c, _max_c)


## 整平地基：清上方（含树木）+ 填 DIRT 地基，统一落在一块平地上。
func _flatten_ground() -> void:
	for x in range(_min_c.x, _max_c.x + 1):
		for z in range(_min_c.z, _max_c.z + 1):
			for y in range(base_y - 3, base_y + _clear_h):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.AIR)
			for y in range(base_y - 3, base_y):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.DIRT)


## 跑道铺面（圆石沥青感）+ 两端 SAND 跑道头（与道面区分，提示起降边界）。
func _pave_runway() -> void:
	for z in range(origin.z - _len / 2, origin.z + _len / 2 + 1):
		for dx in range(-_half_w, _half_w + 1):
			_world.set_block_deferred(
				Vector3i(origin.x + dx, base_y, z), BlockTypes.Block.COBBLESTONE)
	for end_z in [origin.z - _len / 2 - 1, origin.z + _len / 2 + 1]:
		for dx in range(-_half_w, _half_w + 1):
			_world.set_block_deferred(
				Vector3i(origin.x + dx, base_y, end_z), BlockTypes.Block.SAND)


## 进近助视导航灯：自发光方块（独立 emissive 渲染面，零动态光）。
## 颜色即方向语义：绿=进场门槛（南端）/ 红=跑道远端（北端）/ 黄=中线 / 白=边缘。
## 标记全部落在已整平足迹内（z∈[origin.z-_len/2-1, +_len/2+1]、x∈±_half_w），
## 不碰地形管线；跑道逻辑进近方向（+Z、由南向北）由此在视觉上对齐。
## with_approach=true 时（简易降落场，无南端机库）额外在南 SAND 头加一排绿，
## 强化「从南进场」引导；机场用 false（南端已有非对称机库作朝向地标）。
func _mark_approach(with_approach: bool) -> void:
	var z_s := origin.z - _len / 2          # 跑道南缘（进场端）
	var z_n := origin.z + _len / 2          # 跑道北缘（远端）
	# 南端绿门槛行（进场端）+ 北端红端行（远端）。
	for dx in range(-_half_w, _half_w + 1):
		_world.set_block_deferred(Vector3i(origin.x + dx, base_y, z_s), BlockTypes.Block.NAV_GREEN)
		_world.set_block_deferred(Vector3i(origin.x + dx, base_y, z_n), BlockTypes.Block.NAV_RED)
	# 黄色虚线中线（对齐）：x=中线，每 3 格放 1 格。
	for z in range(z_s + 1, z_n, 3):
		_world.set_block_deferred(Vector3i(origin.x, base_y, z), BlockTypes.Block.NAV_YELLOW)
	# 白色边缘线：x=±_half_w，每 2 格放 1 格（避开已铺绿/红的南北端行）。
	for z in range(z_s + 1, z_n, 2):
		_world.set_block_deferred(Vector3i(origin.x - _half_w, base_y, z), BlockTypes.Block.NAV_WHITE)
		_world.set_block_deferred(Vector3i(origin.x + _half_w, base_y, z), BlockTypes.Block.NAV_WHITE)
	# 简易降落场（无南端机库）：南 SAND 头再加一排绿，强化「从南进场」引导。
	if with_approach:
		var z_app := origin.z - _len / 2 - 1
		for dx in range(-_half_w, _half_w + 1):
			_world.set_block_deferred(Vector3i(origin.x + dx, base_y, z_app), BlockTypes.Block.NAV_GREEN)


## 机库：南端一座开放式圆石棚（围墙高 6 + 木顶），朝跑道（+Z）留 3 宽门洞。
## 与跑道同基准高度，独立于村庄结构。仅机场（build）建造。
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


## 基准地面高度：中心周边地表最高方块 y（种子固定，可离线探测）。
## 扫描范围覆盖整平区（南侧另含机库 / 施工缘 extra）。
func _probe_base_y(south_extra: int) -> void:
	var top := 0
	var r := _half_w + 3
	for x in range(origin.x - r, origin.x + r + 1):
		for z in range(origin.z - _len / 2 - south_extra, origin.z + _len / 2 + 1):
			top = maxi(top, _world.get_surface_height(x, z) - 1)
	base_y = top


func _end() -> void:
	_world.rebuild_chunks_in_region(_min_c, _max_c)


## 出生点：跑道南段、机头朝 +Z，紧邻机库门口外（降落场无机库同理）。
func _spawn_point() -> Vector3:
	return Vector3(
		origin.x + 0.5, float(base_y + 1), float(origin.z - _len / 2 + 3) + 0.5)
