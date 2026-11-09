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

const RUNWAY_LEN := 336          # 沿 +Z。D-091：在 D-040（56→112）基础上「延长 3 倍」→ 112→336 格（56 m → 168 m）。
## 半长 168 格内：南端 spawn+3 / 停机位 +22 / 机库 4 格，北端仍留 ≥140 格净空供满油门滑跑抬轮。
## 机场中心由 main._airport_center 南移到 (114,0,-40)（见该函注释）：跑道北端 = -40+168 = 128，
## 与村庄 C 南缘 z=160 保持 32 格（16 m）间隔，避让村庄结构；南端 = -40-168 = -208，
## 朝负 Z 无村庄，净空充足。两端再各清 APPROACH_LEN 格进近/离场净空通道（削山 + 清树，见 _clear_approaches）。
## 沿 X。用户选定「跑道加宽到翼展全包」：翼展 48 格 + 每侧 2 格余量 = 52 格（52 m，D-040 已订正）。
const RUNWAY_WID := 52
const CLEAR_H := 12              # 跑道 / 机库上方净空（块）
const HANGAR_DEPTH := 4
## 机库宽度（格）。机库宽度与跑道宽度**解耦**（D-040 已定）：保持 12 格原有外观，
## 不被 336 长跑道连带拉宽（它进深仅 4 格，本就不是能停机的库）。
const HANGAR_WID := 12
const FIELD_LEN := 32            # 简易降落场：短跑道，够起飞 / 停稳即用（独立变体，不随机场跑道 3× 延长）
const FIELD_WID := 10
const FIELD_CLEAR_H := 8
## 进近 / 离场净空通道（格）：跑道两端各延伸此长度，削平高山、清除树木，保持航道通畅
## （呼应 D-091「跑道尽头不要障碍物，例如高山、树木」）。宽度 = 跑道 + 两侧 SHOULDER。
const APPROACH_LEN := 48
const APPROACH_H := 56           # 通道上方净空高度（块）：自跑道面向上，覆盖绝大多数树木与丘陵（含谷地 ≤50 的余量）
const SHOULDER := 4              # 跑道两侧额外净空（格），避开翼尖擦树

var origin := Vector3i.ZERO
var base_y := 30
var _world: World
var _min_c := Vector3i.ZERO
var _max_c := Vector3i.ZERO
var _core_min := Vector3i.ZERO
var _core_max := Vector3i.ZERO
var _half_w := RUNWAY_WID / 2
var _len := RUNWAY_LEN
var _clear_h := CLEAR_H


## 在 center 处建造机场，返回建议出生点（跑道南段、机头朝 +Z）。
## 只写 center 周边的区块：其余区域（含村庄）不受影响。
func build(world: World, center: Vector3i) -> Vector3:
	_begin(world, center, RUNWAY_WID, RUNWAY_LEN, HANGAR_DEPTH, CLEAR_H)
	_flatten_ground()
	_clear_approaches()
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
	_clear_approaches()
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
	var half_ws := _half_w + SHOULDER
	# 整平核心区：跑道 + 两侧 SHOULDER + 施工缘（+2）。
	_core_min = Vector3i(
		center.x - half_ws - 2, 0, center.z - length / 2 - south_extra - 2)
	_core_max = Vector3i(
		center.x + half_ws + 2, 0, center.z + length / 2 + 2)
	# 预加载 / 重建范围：在核心区基础上向两端各延伸 APPROACH_LEN（进近/离场净空通道）。
	_min_c = Vector3i(_core_min.x, 0, _core_min.z - APPROACH_LEN)
	_max_c = Vector3i(_core_max.x, 0, _core_max.z + APPROACH_LEN)
	# 预加载（不建网格）：统一放到 _end 的 rebuild_chunks_in_region 一遍完成，
	# 避免每块「无邻居重建 + 有邻居再重建」的双倍白工（约 530 ms）。
	# 随后开批量写入：整平/铺面/导航灯数万次 set_block_deferred 跳过逐列维护，
	# _end 统一重算列顶表（又省约 500 ms）。
	_world.preload_chunks_in_region(_min_c, _max_c)
	_world.begin_bulk_writes()


## 整平地基：清上方（含树木）+ 填 DIRT 地基，统一落在一块平地上。
## 仅作用于核心区（跑道 + 两侧 SHOULDER + 施工缘）；两端进近/离场净空通道由
## _clear_approaches 单独处理（削山更高、且不在跑道铺面范围内）。
func _flatten_ground() -> void:
	for x in range(_core_min.x, _core_max.x + 1):
		for z in range(_core_min.z, _core_max.z + 1):
			for y in range(base_y - 3, base_y + _clear_h):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.AIR)
			for y in range(base_y - 3, base_y):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.DIRT)


## 进近 / 离场净空通道：跑道两端各清 APPROACH_LEN 格，宽度 = 跑道 + 两侧 SHOULDER。
## 自跑道面向上清到 APPROACH_H（削平高山）、下方填 DIRT 成平台，保证起飞/降落航道
## 在跑道头之外仍通畅（呼应 D-091「跑道尽头不要障碍物，例如高山、树木」）。
## 北端通道会探入村庄 C 以南的空地（村庄在机场 build 之后才生成，见 main._build_village，
## 故此处清出的地形随后被村庄结构覆盖，无冲突）。
func _clear_approaches() -> void:
	var x0 := origin.x - _half_w - SHOULDER
	var x1 := origin.x + _half_w + SHOULDER
	var z_n0 := origin.z + _len / 2 + 1
	var z_n1 := z_n0 + APPROACH_LEN
	var z_s1 := origin.z - _len / 2 - 1
	var z_s0 := z_s1 - APPROACH_LEN
	for z in range(z_s0, z_s1 + 1):
		for x in range(x0, x1 + 1):
			for y in range(base_y - 3, base_y + 1):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.DIRT)
			for y in range(base_y + 1, base_y + APPROACH_H + 1):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.AIR)
	for z in range(z_n0, z_n1 + 1):
		for x in range(x0, x1 + 1):
			for y in range(base_y - 3, base_y + 1):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.DIRT)
			for y in range(base_y + 1, base_y + APPROACH_H + 1):
				_world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.AIR)


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
## 宽度用 HANGAR_WID（与跑道宽度解耦），纵向仍以跑道南端 RUNWAY_LEN 定位。
func _build_hangar(center: Vector3i) -> void:
	var half_w := HANGAR_WID / 2
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
	# ── 水面以上硬保底 ──
	# `get_surface_height()` 返回的是**地形高度**（h + 1），不含其后的水/冰填充层，
	# 所以 `- 1` 得到的是「裸地形顶面」，而不是「玩家真正站的那一层表面」。
	# 大洋区域的地形基准本就低于海平面（大西洋 base_height=19 / 振幅 9，印度洋与
	# 北冰洋同理），于是：
	#   · 大西洋 (8,8) 半径 10 内 441 列全部低于 SEA_LEVEL=22、最高只有 21
	#     ⇒ 跑道面铺在 21，被海面 22 淹掉一层，跑道上全是水；
	#   · 北冰洋最高只有 19 而冰面封在 22 ⇒ 跑道被埋进冰层底下 3 格。
	# 这两种情况下整片搜索窗都没有陆地可选（见 main._find_field_site 的兜底），
	# 与其让跑道沉底，不如把跑道面顶到水面以上 2 格、用既有的「填 DIRT 地基」
	# 造出一块高出水面的平台。+2 而非 +1：留一格空气，避免浪/冰紧贴道面。
	base_y = maxi(top, World.SEA_LEVEL + 2)


func _end() -> void:
	# 退出批量写入（内部统一重算列顶表）后重建区域：只同步重建出生点保留窗
	# 内的区块（玩家首帧站立/停机/机库的碰撞保障），窗外区块跳过——流式首帧
	# 即卸载它们，等玩家靠近时按正常路径重建（数据不丢）。跑道长度加倍后
	# 区域 32 区块，北半场 16 块「建完即卸」，旧实现为它白建网格约 250 ms。
	_world.end_bulk_writes()
	_world.rebuild_chunks_in_region_near(_min_c, _max_c, _spawn_point())


## 出生点：跑道南段、机头朝 +Z，紧邻机库门口外（降落场无机库同理）。
func _spawn_point() -> Vector3:
	return Vector3(
		origin.x + 0.5, float(base_y + 1), float(origin.z - _len / 2 + 3) + 0.5)


## 停机位：跑道南段、出生点（南端 center-25）以北约 19 格（center-6）处，
## 机头朝 +Z（北端，沿跑道进近方向的反向 = 起飞方向，对齐红端/北端导航灯）。
## 与出生点拉开 ≥19 格（≈9.5 m）以避开机身碰撞盒半长 7.8 m，否则玩家开局
## 会生成在机体碰撞盒内被物理挤出；同时距北端仍有整条跑道余量供满油门滑跑抬轮。
## 返回点是跑道的**可站立顶面**（= base_y + 1）：base_y 是跑道铺装方块自身的 y，
## 方块占据 [base_y, base_y + 1]，顶面在 base_y + 1 —— 与 _spawn_point() 同一语义。
## 若误返回 base_y（方块自身 y）会让机轮/碰撞盒陷进跑道 0.95 m，首物理帧因
## is_on_floor()==false 误发 aircraft_took_off（见 tmp/park_dbg 落位回归）。Aircraft.spawn 的
## place() 会在此顶面之上再加 GROUND_CLEARANCE，与手持右键放机共用同一条落位路径。
func parking_spot() -> Vector3:
	return Vector3(
		origin.x + 0.5, float(base_y + 1), float(origin.z - _len / 2 + 22) + 0.5)
