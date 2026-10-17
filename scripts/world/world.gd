extends Node3D
class_name World
## 世界管理器：噪声地形生成、树木生成、以玩家为中心的区块流式加载/卸载。

const CHUNK_SIZE := Vector3i(16, 64, 16)
const LOAD_RADIUS := 2
# 每帧加载 2 个并按距玩家距离优先：缩短玩家到达未生成区域的窗口，
# 配合玩家防卡死检测（嵌入实心方块自动重生脱困）形成双保险。
const CHUNKS_PER_FRAME := 2
## 徒步每帧加载时间预算（ms）：与飞行的 FLIGHT_BUDGET_MS 同思路——按耗时限量而非
## 按块数。实测单块重建 23~29 ms，「每帧 2 块」最坏就是 46 ms 级的走向新地形卡顿；
## 低端机单块更慢时也不会因固定块数吃掉整帧。每帧至少加载 1 块保证队列推进。
const WALK_BUDGET_MS := 10.0
# ── 飞行流式加载（D-035）────────────────────────────────────────────────
# 徒步的 5×5 区块 = 40 m 见方对步行够用；飞行满油门 50 m/s 时每 0.16 s 就要
# 换一行区块，前方地形会永远慢半拍。故飞行时把预算集中到真正会被看到的
# 方向：以机头为 +u 轴的偏置矩形——前方 5 块（48 m）、侧向 2 块、后方 1 块，
# 共 35 块，比各向同性的 9×9（81 块）省一半以上，前方视距反而更远。
const FLIGHT_FORWARD := 5
const FLIGHT_SIDE := 2
const FLIGHT_BACK := 1
## 卸载滞后（区块）：超出加载范围再外扩这么多圈才卸载。飞行时中心区块随速度
## 频繁变化，没有滞后会在边界反复装卸，每次卸载还要触发邻居补面重建。
const UNLOAD_PAD := 1
## 飞行时每帧的加载时间预算（ms）：按耗时限量而非按块数——低端机单块更慢时
## 不会因「固定 N 块」吃掉整帧；每帧至少加载 1 块，保证队列一定在推进。
const FLIGHT_BUDGET_MS := 8.0
const FLIGHT_CHUNKS_PER_FRAME := 6
const SEA_LEVEL := 22

## 水体分类：按连通水面格数区分「大河/湖泊」与「小池塘」。
## 阈值取自世界水情勘察（321×321 采样区共 23 处水体，最大 352 格，
## 6 处 ≥150 格，其余 ≤128 格），故以 120 格为界。
const WATER_NONE := 0
const WATER_LARGE := 1
const WATER_POND := 2
const LARGE_WATER_MIN_TILES := 120
## 洪泛格数上限：达到上限即判定为大水体，避免超大水体拖慢区块生成。
const WATER_FLOOD_CAP := 300

@export var seed_value := 12345

var _chunks: Dictionary[Vector3i, Chunk] = {}
var _pending_load: Dictionary[Vector3i, bool] = {}
# 玩家修改过的区块坐标；卸载时留存数据，重载时恢复，避免建筑凭空消失。
var _edited_coords: Dictionary[Vector3i, bool] = {}
var _modified_data: Dictionary[Vector3i, PackedByteArray] = {}
# 卸载区块后需要补面的邻居重建队列，每帧限量处理以平滑卡顿。
var _pending_rebuilds: Array[Vector3i] = []
var _atlas_material: StandardMaterial3D
var _emissive_material: StandardMaterial3D
var _noise := FastNoiseLite.new()
# 极地冰山噪声：低频成团，决定哪里隆起露出海面的冰山（D-028）。
var _iceberg_noise := FastNoiseLite.new()
var _player: Player
## 飞行流式开关（main 在登机 / 下机时切换）：开启后加载窗口改为沿机头方向
## 的偏置矩形，并把每帧限量改为时间预算。
var _flight_stream := false
## 飞行时的机头水平方向（单位向量）：偏置窗口与加载优先级都以它为 +u 轴。
var _stream_dir := Vector3(0.0, 0.0, -1.0)
var _neighbor_lookup: Callable
# ── 流式加载缓存（性能优化，2026-10-17）──────────────────────────────────
# _update_chunks 原先每帧重建 wanted 集（飞行窗口 169 次字典插入 ≈1.16 ms/帧）、
# 每帧用新建 lambda 排序待加载队列。 wanted 集只在「中心区块变化」或「飞行时
# 机头方向转过阈值」时才真正改变，故缓存之；排序同理加脏位。
var _wanted: Dictionary = {}
var _wanted_center := Vector3i(1 << 30, 0, 1 << 30)  # 不可能的中心值：首帧必重算
var _wanted_dir := Vector3(0.0, 0.0, -1.0)
var _wanted_flight := false
var _pending_dirty := true
var _sort_center := Vector3i.ZERO
var _priority_cmp: Callable
# 储物箱内容物：按方块坐标记录独立 36 格背包，破坏时散落至地面。
var box_contents: Dictionary[Vector3i, Inventory] = {}
# 水体分类缓存：水面格 → WATER_LARGE / WATER_POND，同一水体只洪泛一次。
var _water_kind_cache: Dictionary[Vector2i, int] = {}
# 当前区域的生成配置（RegionAtlas.REGIONS 条目）：决定种子、地形起伏、
# 地表材质与树木密度。未显式设置时使用默认区域，保证场景可单独运行。
var _profile: Dictionary = {}


func _ready() -> void:
	_neighbor_lookup = Callable(self, "get_block")
	_priority_cmp = Callable(self, "_cmp_load_priority")
	_build_atlas_material()
	_build_emissive_material()
	if _profile.is_empty():
		_profile = RegionAtlas.profile(RegionAtlas.DEFAULT_REGION)
		seed_value = int(_profile["seed"])
	_configure_noise()


## 切换区域：同步种子与生成配置。区域切换由 Main 通过重载主场景完成
## （村庄、生物、储物箱等全部随场景重建），此处只负责地形参数。
func set_region(region_id: int) -> void:
	_profile = RegionAtlas.profile(region_id)
	seed_value = int(_profile["seed"])
	_configure_noise()


func get_region() -> int:
	return int(_profile.get("id", RegionAtlas.DEFAULT_REGION))


func set_player(player: Player) -> void:
	_player = player
	# 先同步加载玩家所在区块，避免出生时脚下没有地形。
	_load_chunk(world_to_chunk(player.global_position))


func _process(_delta: float) -> void:
	if _player == null:
		return
	_update_chunks()


func get_surface_height(wx: int, wz: int) -> int:
	return _terrain_height(wx, wz) + 1


## 该列最高的非空气格（未加载返回 AIR）。供小地图采样：一次定位区块后直接在
## 区块数据内取顶，避免逐格 get_block 的 world_to_chunk + 字典查询
## （实测采样 6.5 ms/次 → 目标 <1 ms）。pristine 区块走列顶表 O(1)，
## 被改动过的区块退回列内扫描（仍只做一次区块定位）。
func top_block_at(wx: int, wz: int) -> int:
	var coord := Vector3i(
		floori(float(wx) / float(CHUNK_SIZE.x)), 0,
		floori(float(wz) / float(CHUNK_SIZE.z)))
	var chunk: Chunk = _chunks.get(coord)
	if chunk == null:
		return BlockTypes.Block.AIR
	var sx := CHUNK_SIZE.x
	var plane := sx * CHUNK_SIZE.z
	var lx := wx - coord.x * sx
	var lz := wz - coord.z * CHUNK_SIZE.z
	var base := lx + lz * sx
	if chunk.pristine and not chunk.col_top.is_empty():
		var top := int(chunk.col_top[base])
		if top == 255:
			return BlockTypes.Block.AIR
		return chunk.data[base + top * plane]
	for y in range(CHUNK_SIZE.y - 1, -1, -1):
		var id := chunk.data[base + y * plane]
		if id != BlockTypes.Block.AIR:
			return id
	return BlockTypes.Block.AIR


## 该列水深（水面到地形顶面的格数）；陆地返回 0。
func water_depth(wx: int, wz: int) -> int:
	return maxi(0, SEA_LEVEL - _terrain_height(wx, wz))


## 该列是否为水面（地形顶面低于海平面即为水）。
func is_water_column(wx: int, wz: int) -> bool:
	return _terrain_height(wx, wz) < SEA_LEVEL


## 水体类型：以连通水面格数区分「大河/湖泊」（≥120 格）与「小池塘」。
## 连通域用有界洪泛计算，同一水体的结果缓存到每个水格，区块生成时均摊常数级。
func water_kind(wx: int, wz: int) -> int:
	var cell := Vector2i(wx, wz)
	if _water_kind_cache.has(cell):
		return _water_kind_cache[cell]
	if not is_water_column(wx, wz):
		_water_kind_cache[cell] = WATER_NONE
		return WATER_NONE

	var region := _flood_water(cell)
	# 洪泛上限（300）大于大水体阈值（120），故被截断的水体必然是大水体。
	var kind := WATER_LARGE if region.size() >= LARGE_WATER_MIN_TILES else WATER_POND
	for c: Vector2i in region:
		_water_kind_cache[c] = kind
	return kind


## 有界洪泛：返回起始格所在水体的水面格（最多 WATER_FLOOD_CAP 格）。
func _flood_water(start: Vector2i) -> Array[Vector2i]:
	var region: Array[Vector2i] = [start]
	var seen := {start: true}
	var queue: Array[Vector2i] = [start]
	while not queue.is_empty() and region.size() < WATER_FLOOD_CAP:
		var cur: Vector2i = queue.pop_back()
		for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nxt: Vector2i = cur + offset
			if seen.has(nxt) or not is_water_column(nxt.x, nxt.y):
				continue
			seen[nxt] = true
			queue.append(nxt)
			region.append(nxt)
	return region


## 结构生成支持：强制同步加载区域内全部区块。
## 村庄等固定建筑生成前调用，确保 set_block 落到已加载区块（含网格重建）。
func ensure_chunks_in_region(min_cell: Vector3i, max_cell: Vector3i) -> void:
	var cmin := world_to_chunk(Vector3(min_cell))
	var cmax := world_to_chunk(Vector3(max_cell))
	for cx in range(cmin.x, cmax.x + 1):
		for cz in range(cmin.z, cmax.z + 1):
			_load_chunk(Vector3i(cx, 0, cz))


## 结构生成预加载：只落数据、不建网格（供机场/村庄在统一重建前把整片区域
## 的方块写入已加载区块）。_load_chunk 自带的 rebuild 在邻居尚未加载时也要
## 做一遍（边界列全扫 ≈20 ms），随后 rebuild_chunks_in_region 又会带着齐备
## 的邻居重做一遍——每块双倍重建，机场 + 三村约 80 块 ≈ 1 s 级白工。预加载把
## 网格创建推后到统一重建：邻居齐备、列边界可信，一遍即终态。探针与常规流式
## 仍走 ensure_chunks_in_region（带网格），不受影响。
func preload_chunks_in_region(min_cell: Vector3i, max_cell: Vector3i) -> void:
	var cmin := world_to_chunk(Vector3(min_cell))
	var cmax := world_to_chunk(Vector3(max_cell))
	for cx in range(cmin.x, cmax.x + 1):
		for cz in range(cmin.z, cmax.z + 1):
			_load_chunk(Vector3i(cx, 0, cz), false)


## 结构生成支持：批量写方块但不触发网格重建（配合 rebuild_chunks_in_region 一次重建）。
## 避免逐方块重建导致结构生成时数秒级卡顿；写入仍计入修改留存。
func set_block_deferred(world_pos: Vector3i, id: int) -> void:
	var coord := world_to_chunk(Vector3(world_pos))
	var chunk: Chunk = _chunks.get(coord)
	if chunk == null:
		return
	chunk.set_block_local(world_pos - chunk_to_world(coord), id)
	_edited_coords[coord] = true


## 结构生成支持：重建区域内全部已加载区块（批量写入完成后调用一次）。
func rebuild_chunks_in_region(min_cell: Vector3i, max_cell: Vector3i) -> void:
	_rebuild_region(min_cell, max_cell, Vector3.INF)


## 结构生成支持（boot 场景）：同上，但只同步重建 near 所在「步行保留窗」
## （LOAD_RADIUS + UNLOAD_PAD 方格，与 _update_chunks 首帧卸载判定同参）内的
## 区块；窗外区块跳过——玩家首帧就在 near（出生点/停机位），窗外区块本来
## 就会被流式首帧卸载，等玩家靠近时按正常加载路径重建（写入过的数据经
## _modified_data 往返，不丢）。机场跑道长度加倍后区域达 32 区块，其中北半场
## 16 块在旧实现里「建完网格即被卸载」，实测白工约 250 ms。
func rebuild_chunks_in_region_near(min_cell: Vector3i, max_cell: Vector3i, near: Vector3) -> void:
	_rebuild_region(min_cell, max_cell, near)


func _rebuild_region(min_cell: Vector3i, max_cell: Vector3i, near: Vector3) -> void:
	var cmin := world_to_chunk(Vector3(min_cell))
	var cmax := world_to_chunk(Vector3(max_cell))
	var use_near := is_finite(near.x) and is_finite(near.z)
	var near_c := world_to_chunk(near) if use_near else Vector3i.ZERO
	for cx in range(cmin.x, cmax.x + 1):
		for cz in range(cmin.z, cmax.z + 1):
			var coord := Vector3i(cx, 0, cz)
			if use_near and (absi(coord.x - near_c.x) > LOAD_RADIUS + UNLOAD_PAD
					or absi(coord.z - near_c.z) > LOAD_RADIUS + UNLOAD_PAD):
				continue
			_rebuild_chunk(coord)


func world_to_chunk(pos: Vector3) -> Vector3i:
	return Vector3i(floori(pos.x / CHUNK_SIZE.x), 0, floori(pos.z / CHUNK_SIZE.z))


func chunk_to_world(coord: Vector3i) -> Vector3i:
	return Vector3i(coord.x * CHUNK_SIZE.x, 0, coord.z * CHUNK_SIZE.z)


func get_block(world_pos: Vector3i) -> int:
	var coord := world_to_chunk(Vector3(world_pos))
	var chunk: Chunk = _chunks.get(coord)
	if chunk == null:
		return BlockTypes.Block.AIR
	return chunk.get_block_local(world_pos - chunk_to_world(coord))


## 体素射线：从 from 向 to 步进采样，找第一个「可破坏」方块（非 AIR 且在
## HARDNESS 表中）。物理射线只能命中碰撞面，而作物/水草等非固体方块没有
## 碰撞面——玩家对着稻田左键毫无反应的根因就在这。水不在 HARDNESS 表，
## 射线自然穿过水面，可以采到水下的作物。未命中返回空字典。
## 体素步进射线（Amanatides & Woo DDA）：返回射线上第一个有硬度的方块。
## "distance" 为从起点到进入该格边界的精确距离，供与物理射线命中比近——
## 瞄准作物等非固体方块时，其进入面与脚下实心块的物理命中面重合，须视为同时命中。
func raycast_blocks(from: Vector3, to: Vector3) -> Dictionary:
	var dir := to - from
	var length := dir.length()
	if length < 0.001:
		return {}
	var step := dir / length
	var cell := Vector3i(from.floor())
	var t_max := Vector3(
		_boundary_t(from.x, step.x),
		_boundary_t(from.y, step.y),
		_boundary_t(from.z, step.z),
	)
	var t_delta := Vector3(_axis_delta(step.x), _axis_delta(step.y), _axis_delta(step.z))
	var normal := Vector3.ZERO
	var t := 0.0
	while t <= length:
		var id := get_block(cell)
		if id != BlockTypes.Block.AIR and BlockTypes.HARDNESS.has(id):
			return {
				"position": from + step * t,
				"normal": normal,
				"cell": cell,
				"id": id,
				"distance": t,
			}
		# 沿最近的格边界推进（平次序无妨，同一边界只跨一格）。
		if t_max.x <= t_max.y and t_max.x <= t_max.z:
			t = t_max.x
			t_max.x += t_delta.x
			cell.x += 1 if step.x > 0.0 else -1
			normal = Vector3(-1.0 if step.x > 0.0 else 1.0, 0.0, 0.0)
		elif t_max.y <= t_max.z:
			t = t_max.y
			t_max.y += t_delta.y
			cell.y += 1 if step.y > 0.0 else -1
			normal = Vector3(0.0, -1.0 if step.y > 0.0 else 1.0, 0.0)
		else:
			t = t_max.z
			t_max.z += t_delta.z
			cell.z += 1 if step.z > 0.0 else -1
			normal = Vector3(0.0, 0.0, -1.0 if step.z > 0.0 else 1.0)
	return {}


## 射线沿某轴到达下一条格边界的参数距离；该轴无分量时为无穷远。
static func _boundary_t(origin: float, step_c: float) -> float:
	if absf(step_c) < 0.0000001:
		return INF
	return (floorf(origin) + 1.0 - origin) / step_c if step_c > 0.0 \
		else (origin - floorf(origin)) / -step_c


## 该轴每跨一格消耗的参数距离；无分量时为无穷大。
static func _axis_delta(step_c: float) -> float:
	return absf(1.0 / step_c) if absf(step_c) > 0.0000001 else INF


func set_block(world_pos: Vector3i, id: int) -> void:
	var coord := world_to_chunk(Vector3(world_pos))
	var chunk: Chunk = _chunks.get(coord)
	if chunk == null:
		return

	var local := world_pos - chunk_to_world(coord)
	chunk.set_block_local(local, id)
	_edited_coords[coord] = true
	_rebuild_chunk(coord)

	# 修改位于区块边界时，重建相邻区块以更新交界处的可见面。
	if local.x == 0:
		_rebuild_chunk(coord + Vector3i(-1, 0, 0))
	elif local.x == CHUNK_SIZE.x - 1:
		_rebuild_chunk(coord + Vector3i(1, 0, 0))
	if local.z == 0:
		_rebuild_chunk(coord + Vector3i(0, 0, -1))
	elif local.z == CHUNK_SIZE.z - 1:
		_rebuild_chunk(coord + Vector3i(0, 0, 1))


## 获取指定储物箱的背包；首次访问时创建 36 格空背包。
func get_box(cell: Vector3i) -> Inventory:
	if not box_contents.has(cell):
		box_contents[cell] = Inventory.new(36)
	return box_contents[cell]


## 破坏储物箱：箱内所有物品在方块位置生成掉落物，随后移除记录。
func spill_box(cell: Vector3i, player: Player) -> void:
	if not box_contents.has(cell):
		return
	var inv := box_contents[cell]
	var center := Vector3(cell) + Vector3(0.5, 0.5, 0.5)
	for slot_index in range(inv.slots.size()):
		var item: int = inv.slots[slot_index]["item"]
		var count: int = inv.slots[slot_index]["count"]
		if item == BlockTypes.Block.AIR or count <= 0:
			continue
		var drop := DroppedItem.new()
		drop.setup(player, item, count)
		player.add_child(drop)
		drop.global_position = center
	box_contents.erase(cell)


func _rebuild_chunk(coord: Vector3i) -> void:
	var chunk: Chunk = _chunks.get(coord)
	if chunk:
		if chunk.pristine:
			chunk.compute_col_top()
		_prepare_columns(coord, chunk)
		chunk.rebuild(_atlas_material, _emissive_material, _neighbor_lookup)


## 刷新区块的列顶扩展表（rebuild 的快路径输入）：(SIZE.x+2)×(SIZE.z+2)，
## 中心是本区块，外圈是四邻区块贴边的那一列。每列按可信度编码：
## - tops=255：整列为空（rebuild 直接跳过该列）；
## - tops=真实列顶 + grounds=真实列地：边界可信，收窄扫描；
## - tops=63 + grounds=255：该列被地下开挖作废 / 从未计算（邻列未知同理），
##   rebuild 对该列全扫。邻列未知经 grounds=255 让贴邻的列也全扫——这正是
##   开挖后需要向四邻传播的语义（邻列侧向可能在任意高度露出新面）。
## 区块刚生成时尚未进 _chunks，故由参数带入。
func _prepare_columns(coord: Vector3i, chunk: Chunk) -> void:
	if chunk.col_top.is_empty():
		# 整块未知（被覆写恢复且尚未被编辑过）：不给表，rebuild 全量遍历。
		chunk.tops_ext = PackedByteArray()
		chunk.grounds_ext = PackedByteArray()
		return
	var n := CHUNK_SIZE.x
	var w := n + 2
	var tops := PackedByteArray()
	var grounds := PackedByteArray()
	tops.resize(w * w)
	grounds.resize(w * w)
	tops.fill(255)
	grounds.fill(255)
	for z in n:
		for x in n:
			_encode_column(tops, grounds, (z + 1) * w + (x + 1), chunk, x + z * n)
	for z in n:
		var nb: Chunk = _chunks.get(coord + Vector3i(-1, 0, 0))
		if _has_columns(nb):
			_encode_column(tops, grounds, (z + 1) * w, nb, (n - 1) + z * n)
		nb = _chunks.get(coord + Vector3i(1, 0, 0))
		if _has_columns(nb):
			_encode_column(tops, grounds, (z + 1) * w + (n + 1), nb, z * n)
	for x in n:
		var nbz: Chunk = _chunks.get(coord + Vector3i(0, 0, -1))
		if _has_columns(nbz):
			_encode_column(tops, grounds, x + 1, nbz, x + (n - 1) * n)
		nbz = _chunks.get(coord + Vector3i(0, 0, 1))
		if _has_columns(nbz):
			_encode_column(tops, grounds, (n + 1) * w + (x + 1), nbz, x)
	chunk.tops_ext = tops
	chunk.grounds_ext = grounds


## 把 src 区块第 i 列的边界编码进扩展表的 slot（编码规则见 _prepare_columns）。
func _encode_column(tops: PackedByteArray, grounds: PackedByteArray, slot: int,
		src: Chunk, i: int) -> void:
	var t := int(src.col_top[i])
	if t == 255:
		return  # 整列为空：保持 255，rebuild 跳过
	var valid := 0 if src.col_valid.is_empty() else int(src.col_valid[i])
	if t == 254 or valid == 0:
		# 未知或被地下开挖作废：全扫（tops 给满高、grounds 给未知）。
		tops[slot] = 63
		grounds[slot] = 255
		return
	tops[slot] = t
	grounds[slot] = src.col_ground[i]


## 该邻块的列顶表是否可用（已加载且已计算过列顶）。pristine 与否不再重要：
## 编辑过的区块同样逐列维护 col_top/col_valid（见 Chunk.set_block_local）。
func _has_columns(chunk: Chunk) -> bool:
	return chunk != null and not chunk.col_top.is_empty()


## 树干砍完后让树冠「落下消失」：由 Player 在破坏 WOOD 后调用。
## 判据：这一格所在竖列上下 16 格内都不再有木头（整根树干被砍光）。
## 清除范围：该格上方 15 层、每层水平 ±4 的树叶（树冠始终长在树干顶端，
## 同一 (x,z) 只生成一棵树；相邻树的树冠若在此范围内相接，一并清落也符合直觉）。
## 树叶不进背包、不掉落——伴随每片叶子一撮向下飘散的叶屑，「落下消失」。
## 返回清除的树叶格数。
func decay_tree_leaves(cell: Vector3i, force: bool = false) -> int:
	# force：树干被砍断、上半截正倒下去时用——此时树冠属于「正在倒的那截」，
	# 不能因为下方还残留树桩就把叶子留在半空。
	if not force and _column_has_wood(cell):
		return 0
	var removed := _canopy_cells(cell)
	if removed.is_empty():
		return 0

	# 批量写入 + 涉及区块统一重建：树冠常跨区块边界，逐块 set_block 会连 rebuild 一起做，
	# 一棵树几十片叶子就是几十次网格重建；deferred 写入后各重建一次即可。
	var touched := {}
	for p in removed:
		set_block_deferred(p, BlockTypes.Block.AIR)
		touched[world_to_chunk(Vector3(p))] = true
	for coord: Vector3i in touched:
		_rebuild_chunk(coord)

	for p in removed:
		BreakFx.leaf_fall(self, Vector3(p) + Vector3(0.5, 0.5, 0.5))
	return removed.size()


## 树冠：砍口上方 15 层、每层 ±4 范围内的全部树叶。
func _canopy_cells(cell: Vector3i) -> Array[Vector3i]:
	var found: Array[Vector3i] = []
	for dy in range(1, 16):
		for dx in range(-4, 5):
			for dz in range(-4, 5):
				var p := cell + Vector3i(dx, dy, dz)
				if get_block(p) == BlockTypes.Block.LEAVES:
					found.append(p)
	return found


## 砍口上方还有没有树冠（区分天然树与手搭的木柱：木柱上方是空的，不该倒）。
func has_canopy_above(cell: Vector3i, trunk_height: int) -> bool:
	if not _canopy_cells(cell + Vector3i(0, trunk_height, 0)).is_empty():
		return true
	return not _canopy_cells(cell).is_empty()


## 砍口上方连续的树干节数（被砍的那一格本身不算）。
func trunk_height_above(cell: Vector3i) -> int:
	var height := 0
	for i in range(1, 17):
		if get_block(cell + Vector3i(0, i, 0)) != BlockTypes.Block.WOOD:
			break
		height += 1
	return height


## 砍断：清除砍口上方那截树干，返回清掉的木头数（供落地时铺回地面）。
## 同样走批量写入 + 区块统一重建，避免逐块 rebuild。
func fell_trunk_above(cell: Vector3i) -> int:
	var cells: Array[Vector3i] = []
	for i in range(1, 17):
		var p := cell + Vector3i(0, i, 0)
		if get_block(p) != BlockTypes.Block.WOOD:
			break
		cells.append(p)
	if cells.is_empty():
		return 0
	var touched := {}
	for p in cells:
		set_block_deferred(p, BlockTypes.Block.AIR)
		touched[world_to_chunk(Vector3(p))] = true
	for coord: Vector3i in touched:
		_rebuild_chunk(coord)
	return cells.size()


## 倒下的木头铺回地面：沿倒向逐格找最近的可放位置（脚下实心、自身为空），
## 返回实际落地的格子。放不下的就当碎在林间——总比悬在空中强。
func place_fallen_logs(cell: Vector3i, logs: int, dir: Vector3i) -> Array[Vector3i]:
	var placed: Array[Vector3i] = []
	if logs <= 0:
		return placed
	var touched := {}
	for i in range(logs):
		var column := cell + dir * (i + 1)
		for dy in range(0, 20):
			var y := cell.y - dy
			var p := Vector3i(column.x, y, column.z)
			if get_block(p) != BlockTypes.Block.AIR:
				continue
			if get_block(p + Vector3i(0, -1, 0)) == BlockTypes.Block.AIR:
				continue
			set_block_deferred(p, BlockTypes.Block.WOOD)
			touched[world_to_chunk(Vector3(p))] = true
			placed.append(p)
			break
	for coord: Vector3i in touched:
		_rebuild_chunk(coord)
	return placed


## 该竖列上下是否还有树干残留（玩家手搭的木头列也会被视为树干，一并尊重）。
func _column_has_wood(cell: Vector3i) -> bool:
	for i in range(1, 17):
		if get_block(cell + Vector3i(0, i, 0)) == BlockTypes.Block.WOOD \
				or get_block(cell + Vector3i(0, -i, 0)) == BlockTypes.Block.WOOD:
			return true
	return false


func _configure_noise() -> void:
	_noise.seed = seed_value
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 0.012
	_noise.fractal_octaves = 3
	_iceberg_noise.seed = seed_value + 7717
	_iceberg_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_iceberg_noise.frequency = 0.05
	_iceberg_noise.fractal_octaves = 2


func _build_atlas_material() -> void:
	var texture := TextureAtlas.build_atlas_texture()
	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	# 玻璃瓦片中心 alpha=0（见 TextureAtlas._paint_tile）：alpha scissor 把
	# 半透明像素直接剔除，得到「透明窗」，且无需排序、其余不透明瓦片零开销。
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.5
	# 面绕向已保证法线朝外，使用默认背面剔除，减半片元开销并避免看到内壁。
	_atlas_material = material


## 导航灯自发光材质：unshaded + 顶点色，恒亮（昼/夜均可见），不额外吃光照
## pass；颜色由方块顶点色提供，整片导航灯合并为 1 个 draw call（见 Chunk）。
func _build_emissive_material() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Godot 4 无 vertex_colors_enabled（Godot 3 遗留名，赋值仅触发 remap 警告并忽略）；
	# 正确属性是 vertex_color_use_as_albedo——把 ARRAY_COLOR 用作反照率，
	# 配合 unshaded + 白色 albedo_color，使每块导航灯按自身顶点色恒亮输出。
	material.vertex_color_use_as_albedo = true
	material.albedo_color = Color(1, 1, 1)
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	_emissive_material = material


func _update_chunks() -> void:
	var center := world_to_chunk(_player.global_position)
	_update_stream_dir()

	# wanted 集缓存：只有中心区块变化、或飞行时机头方向转过阈值才重算
	# （卸载判定仍每帧用实时中心精确计算，不受缓存影响）。
	var rebuild_wanted := center != _wanted_center or _flight_stream != _wanted_flight
	if _flight_stream and not rebuild_wanted and _stream_dir.distance_to(_wanted_dir) > 0.12:
		rebuild_wanted = true
	if rebuild_wanted:
		_rebuild_wanted(center)

	var to_unload := []
	for key in _chunks:
		# 用外扩 UNLOAD_PAD 圈的窗口判定卸载：刚划出加载范围的区块不立即卸载。
		if not _in_stream_window(key - center, UNLOAD_PAD):
			to_unload.append(key)
	for key in to_unload:
		_unload_chunk(key)

	# 待加载队列的增删只在 wanted 变化时需要进行：之后每加载一块就从队列移除，
	# 不会有新的「该加载而未入队」项出现。
	if rebuild_wanted:
		for key in _pending_load.keys():
			if not _wanted.has(key):
				_pending_load.erase(key)
		for key in _wanted:
			if not _chunks.has(key) and not _pending_load.has(key):
				_pending_load[key] = true
				_pending_dirty = true

	var keys := _pending_load.keys()
	if _pending_dirty:
		# 排序比较器用预建 Callable（_cmp_load_priority 读 _sort_center），
		# 避免每帧新建 lambda 的分配；仅队列变化时排一次。
		_sort_center = center
		keys.sort_custom(_priority_cmp)
		_pending_dirty = false
	var max_chunks := FLIGHT_CHUNKS_PER_FRAME if _flight_stream else CHUNKS_PER_FRAME
	var budget_us := int((FLIGHT_BUDGET_MS if _flight_stream else WALK_BUDGET_MS) * 1000.0)
	var t0 := Time.get_ticks_usec()
	var loaded := 0
	for key in keys:
		if loaded >= max_chunks:
			break
		if _chunks.has(key):
			continue
		_pending_load.erase(key)
		_load_chunk(key)
		loaded += 1
		# 时间预算（徒步与飞行都生效）：单块耗时随机器波动，限量按块数会在
		# 低端机上把多块重建堆在同一帧。每帧至少加载 1 块保证队列一定在推进。
		if Time.get_ticks_usec() - t0 >= budget_us:
			break

	# 卸载后重新暴露的边界面：邻居区块由 _unload_chunk 入队，这里每帧至多
	# 补重建 2 个（首个不限预算保证队列推进，第二个受同一预算约束）。
	# 注意：该循环在初始提交里本就在 _update_chunks 末尾，后来提取
	# _load_priority 时被误放到其 return 之后成了死代码——走出加载范围时
	# 边界永远缺面（2026-10-17 性能优化时归位）。
	var rebuilt := 0
	while rebuilt < 2 and not _pending_rebuilds.is_empty():
		if rebuilt > 0 and Time.get_ticks_usec() - t0 >= budget_us:
			break
		_rebuild_chunk(_pending_rebuilds.pop_front())
		rebuilt += 1


## 重建 wanted 集（见 _wanted 缓存说明）：以中心区块为原点的保留窗口。
func _rebuild_wanted(center: Vector3i) -> void:
	var wanted := {}
	var reach := LOAD_RADIUS + UNLOAD_PAD
	if _flight_stream:
		reach = maxi(FLIGHT_FORWARD, maxi(FLIGHT_SIDE, FLIGHT_BACK)) + UNLOAD_PAD
	for ex in range(-reach, reach + 1):
		for ez in range(-reach, reach + 1):
			var off := Vector3i(ex, 0, ez)
			if _in_stream_window(off, 0):
				wanted[center + off] = true
	_wanted = wanted
	_wanted_center = center
	_wanted_dir = _stream_dir
	_wanted_flight = _flight_stream


## 加载优先级排序比较器（预建 Callable，中心由 _sort_center 带入）。
func _cmp_load_priority(a: Vector3i, b: Vector3i) -> bool:
	return _load_priority(a, _sort_center) < _load_priority(b, _sort_center)


## 飞行流式开关：main 在登机 / 下机时切换。关闭后下一帧即回落到徒步窗口，
## 多出的待加载区块随之从队列清除、超出的已载区块逐步卸载。
func set_flight_stream(enabled: bool) -> void:
	if _flight_stream == enabled:
		return
	_flight_stream = enabled
	if enabled:
		_update_stream_dir()


## 取当前机头的水平方向作为流式窗口的 +u 轴（未骑乘时保持上一次方向，
## 窗口退化为各向同性也不影响正确性——只是失去前方偏置）。
func _update_stream_dir() -> void:
	if not _flight_stream or _player == null:
		return
	var craft := _player.aircraft()
	if craft == null or not is_instance_valid(craft):
		return
	var fwd := -craft.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() > 1e-4:
		_stream_dir = fwd.normalized()


## 该偏移（相对中心区块）是否落在保留窗口内：徒步是 LOAD_RADIUS 方形（外扩
## pad 圈）；飞行是以机头为 +u 轴的偏置矩形——前方 FLIGHT_FORWARD、侧向
## FLIGHT_SIDE、后方 FLIGHT_BACK，再整体外扩 pad 圈。
func _in_stream_window(offset: Vector3i, pad: int) -> bool:
	if not _flight_stream:
		return absi(offset.x) <= LOAD_RADIUS + pad and absi(offset.z) <= LOAD_RADIUS + pad
	var u := float(offset.x) * _stream_dir.x + float(offset.z) * _stream_dir.z
	var v := float(offset.x) * -_stream_dir.z + float(offset.z) * _stream_dir.x
	var p := float(pad)
	return (
		u >= -float(FLIGHT_BACK) - p
		and u <= float(FLIGHT_FORWARD) + p
		and absf(v) <= float(FLIGHT_SIDE) + p
	)


## 加载优先级（越小越先）：
## - 徒步：曼哈顿距离（脚下与近处优先）。
## - 飞行：机体系曼哈顿距离 − 0.6·前向量，即「近处优先，同距离时前方优先」。
##   不能反过来只按「前方越远越先」：登机瞬间队列里有整窗三十余块，而每帧时间
##   预算只够一两块，纯前方优先会把玩家脚下的区块排到队尾——实测飞机因此悬在
##   半空（脚下区块迟迟未加载、跑道尚未回填）。近处优先保证机体周围先落地，
##   前方偏置只在同一距离档内起作用。
func _load_priority(coord: Vector3i, center: Vector3i) -> float:
	if not _flight_stream:
		return float(absi(coord.x - center.x) + absi(coord.z - center.z))
	var off := coord - center
	var u := float(off.x) * _stream_dir.x + float(off.z) * _stream_dir.z
	var v := float(off.x) * -_stream_dir.z + float(off.z) * _stream_dir.x
	return absf(u) + absf(v) - 0.6 * u


func _load_chunk(coord: Vector3i, with_rebuild: bool = true) -> void:
	if _chunks.has(coord):
		return

	var chunk := Chunk.new()
	chunk.name = "Chunk_%d_%d" % [coord.x, coord.z]
	chunk.position = Vector3(chunk_to_world(coord))
	add_child(chunk)

	if _modified_data.has(coord):
		chunk.data = _modified_data[coord]
		# 玩家改动过的区块：列结构不再由高度图决定，走全量遍历。
		chunk.pristine = false
	else:
		# 生成期批量写入：树木/水草的 set_block_local 跳过逐列维护，
		# end_bulk 里的 compute_col_top 反正会全量重算（每村省 ~16 ms）。
		chunk.begin_bulk()
		_generate_chunk(chunk, coord)
		chunk.end_bulk()
	_prepare_columns(coord, chunk)
	if with_rebuild:
		chunk.rebuild(_atlas_material, _emissive_material, _neighbor_lookup)
	_chunks[coord] = chunk


## 批量写入开关（结构生成用，与 rebuild_chunks_in_region 配对）：期间所有已载
## 区块的 set_block_local 跳过逐列维护，end 时统一重算列顶表。机场 + 三村
## 一次写入数万方块，逐列重扫合计 0.5 s 级；统一重算每块 1~2 ms。
func begin_bulk_writes() -> void:
	for chunk: Chunk in _chunks.values():
		chunk.begin_bulk()


func end_bulk_writes() -> void:
	for chunk: Chunk in _chunks.values():
		chunk.end_bulk()


func _unload_chunk(coord: Vector3i) -> void:
	var chunk: Chunk = _chunks.get(coord)
	if chunk == null:
		return
	if _edited_coords.has(coord):
		_modified_data[coord] = chunk.data
	_chunks.erase(coord)
	chunk.queue_free()
	# 卸载后邻居外侧边界重新暴露，入队补面重建（去重：多个卸载共享同一邻居
	# 时只留一份，避免同一coord 被反复重建）。
	for offset: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		var nb := coord + offset
		if not _pending_rebuilds.has(nb):
			_pending_rebuilds.append(nb)


## 区块数据生成（判据与 _block_at 同源，逐格结果一致）。
## 区域参数与逐列量提到循环外：原先每格都要做 3~5 次 _profile 字典查询、
## 极地列还要每格再算一次冰山噪声，16384 格累计占数据生成耗时的一半以上。
func _generate_chunk(chunk: Chunk, coord: Vector3i) -> void:
	var origin := chunk_to_world(coord)
	var water_policy := String(_profile.get("water", "normal"))
	var low_line := int(_profile.get("low_line", SEA_LEVEL))
	var surface_high := int(_profile.get("surface", BlockTypes.Block.GRASS))
	var surface_low := int(_profile.get("surface_low", BlockTypes.Block.SAND))
	var sub_high := int(_profile.get("sub", BlockTypes.Block.DIRT))
	var sub_low := int(_profile.get("sub_low", BlockTypes.Block.SAND))
	var is_dry := water_policy == "dry"
	var is_iceberg := water_policy == "iceberg"
	var sx := CHUNK_SIZE.x
	var sz := CHUNK_SIZE.z
	var sy := CHUNK_SIZE.y
	var plane := sx * sz
	var data := chunk.data
	for x in sx:
		for z in sz:
			var wx := origin.x + x
			var wz := origin.z + z
			var height := _terrain_height(wx, wz)
			var high := height > low_line
			var surface_id := surface_high if high else surface_low
			var sub_id := sub_high if high else sub_low
			var ice_top := _iceberg_top(wx, wz) if is_iceberg else 0
			var col := x + z * sx
			for y in sy:
				var id: int
				if y > height:
					if is_dry:
						id = BlockTypes.Block.AIR
					elif is_iceberg and height < SEA_LEVEL:
						if ice_top > 0 and y <= ice_top:
							id = BlockTypes.Block.SNOW if y == ice_top else BlockTypes.Block.ICE
						elif y == SEA_LEVEL:
							id = BlockTypes.Block.ICE
						else:
							id = BlockTypes.Block.WATER if y < SEA_LEVEL else BlockTypes.Block.AIR
					else:
						id = BlockTypes.Block.WATER if y <= SEA_LEVEL else BlockTypes.Block.AIR
				elif y == height:
					id = surface_id
				elif y >= height - 3:
					id = sub_id
				else:
					id = _ore_or_stone(wx, y, wz)
				data[col + y * plane] = id

	_generate_trees(chunk, origin)
	_generate_water_life(chunk, origin)


func _terrain_height(wx: int, wz: int) -> int:
	var base := float(_profile.get("base_height", 28.0))
	var amplitude := float(_profile.get("amplitude", 10.0))
	var n := _noise.get_noise_2d(float(wx), float(wz))
	return int(round(base + n * amplitude))


## 地表材质由区域配置决定：高于 low_line 用 surface，低于等于则用 surface_low。
## 例如非洲低地为沙（沙漠）、高地长草；两极一律为雪。地下三格同理。
## 水体策略（D-028）：dry 沙漠洼地不留河塘；iceberg 极地海面封冻成冰、
## 噪声成团处隆起从海底长到海面之上的冰山（顶面积雪）。
func _block_at(wx: int, wy: int, wz: int, height: int) -> int:
	if wy > height:
		var policy := String(_profile.get("water", "normal"))
		if policy == "dry":
			return BlockTypes.Block.AIR
		if policy == "iceberg" and height < SEA_LEVEL:
			var top := _iceberg_top(wx, wz)
			if top > 0 and wy <= top:
				return BlockTypes.Block.SNOW if wy == top else BlockTypes.Block.ICE
			if wy == SEA_LEVEL:
				return BlockTypes.Block.ICE
			return BlockTypes.Block.WATER if wy < SEA_LEVEL else BlockTypes.Block.AIR
		return BlockTypes.Block.WATER if wy <= SEA_LEVEL else BlockTypes.Block.AIR
	var low_line := int(_profile.get("low_line", SEA_LEVEL))
	var high := height > low_line
	var surface: int = _profile.get("surface", BlockTypes.Block.GRASS) if high else _profile.get("surface_low", BlockTypes.Block.SAND)
	if wy == height:
		return surface
	if wy >= height - 3:
		return int(_profile.get("sub", BlockTypes.Block.DIRT)) if high else int(_profile.get("sub_low", BlockTypes.Block.SAND))
	return _ore_or_stone(wx, wy, wz)


## 极地冰山：该列冰山的顶格高度（无冰山返回 0）。
## 噪声超过阈值即成团隆起，超出越多山体越高——冰山成群且高低错落，
## 从海底一直长到海面以上，看上去像搁浅的浮冰山。确定性哈希，可复现。
func _iceberg_top(wx: int, wz: int) -> int:
	var n := _iceberg_noise.get_noise_2d(float(wx), float(wz))
	if n < 0.5:
		return 0
	return SEA_LEVEL + 1 + int(round((n - 0.5) * 14.0))


## 石层矿物：确定性哈希散布矿物。铜（约 2.5%）见于全部石层，锡（约 1%）
## 仅见于较浅岩层底部；铁（约 1%）在地表以下 6 格起、金（约 0.4%）在
## 地表以下 12 格起才出现，构成「越深越珍贵」的挖掘动力。种子固定，矿点可复现。
func _ore_or_stone(wx: int, wy: int, wz: int) -> int:
	var r := _ore_rng(wx, wy, wz)
	if r < 0.025:
		return BlockTypes.Block.COPPER_ORE
	if r < 0.035:
		return BlockTypes.Block.TIN_ORE if wy <= SEA_LEVEL + 2 else BlockTypes.Block.STONE
	if r < 0.045:
		return BlockTypes.Block.IRON_ORE if wy <= SEA_LEVEL - 6 else BlockTypes.Block.STONE
	if r < 0.049:
		return BlockTypes.Block.GOLD_ORE if wy <= SEA_LEVEL - 12 else BlockTypes.Block.STONE
	return BlockTypes.Block.STONE


func _ore_rng(x: int, y: int, z: int) -> float:
	var h := hash(Vector3i(x, y * 8191 + seed_value, z))
	return float(h & 0xFFFF) / 65535.0


func _generate_trees(chunk: Chunk, origin: Vector3i) -> void:
	for x in CHUNK_SIZE.x:
		for z in CHUNK_SIZE.z:
			if x < 5 or x > CHUNK_SIZE.x - 6 or z < 5 or z > CHUNK_SIZE.z - 6:
				continue

			var wx := origin.x + x
			var wz := origin.z + z
			var density := float(_profile.get("tree_density", 0.02))
			if density <= 0.0 or _tree_rng(wx, wz) > density:
				continue

			var height := _terrain_height(wx, wz)
			if height <= SEA_LEVEL + 1:
				continue
			_place_tree(chunk, Vector3i(x, height + 1, z))


func _place_tree(chunk: Chunk, base: Vector3i) -> void:
	var trunk_height := 8
	for i in range(trunk_height):
		var p := base + Vector3i(0, i, 0)
		if _in_chunk(p):
			chunk.set_block_local(p, BlockTypes.Block.WOOD)

	var top := base + Vector3i(0, trunk_height, 0)
	for dx in range(-4, 5):
		for dz in range(-4, 5):
			for dy in range(-2, 7):
				if abs(dx) == 4 and abs(dz) == 4 and dy != -2:
					continue
				var p := top + Vector3i(dx, dy, dz)
				if _in_chunk(p) and chunk.get_block_local(p) == BlockTypes.Block.AIR:
					chunk.set_block_local(p, BlockTypes.Block.LEAVES)


func _tree_rng(x: int, z: int) -> float:
	var h := hash(Vector3i(x, seed_value, z))
	return float(h & 0xFFFF) / 65535.0


func _in_chunk(p: Vector3i) -> bool:
	return (
		p.x >= 0
		and p.x < CHUNK_SIZE.x
		and p.y >= 0
		and p.y < CHUNK_SIZE.y
		and p.z >= 0
		and p.z < CHUNK_SIZE.z
	)


## 水生植物：大河底部生成水草/藻类，小池塘水面生成浮萍/荷叶/莲花。
## 逐列确定性散布（种子固定），密度稀疏以免遮挡水体本身。
## 仅常规水体策略生效：干燥沙漠没有水可生，极地封冻冰面不容浮萍打洞。
func _generate_water_life(chunk: Chunk, origin: Vector3i) -> void:
	if String(_profile.get("water", "normal")) != "normal":
		return
	for x in CHUNK_SIZE.x:
		for z in CHUNK_SIZE.z:
			var wx := origin.x + x
			var wz := origin.z + z
			var depth := SEA_LEVEL - _terrain_height(wx, wz)
			if depth <= 0:
				continue

			var r := _water_life_rng(wx, wz)
			var kind := water_kind(wx, wz)
			if kind == WATER_LARGE:
				# 水下植物贴在水底（地形顶面之上），需至少两格水深才在水面之下。
				if depth < 2:
					continue
				if r < 0.10:
					_set_chunk_block(chunk, Vector3i(x, SEA_LEVEL - depth + 1, z), BlockTypes.Block.WATERWEED)
				elif r < 0.16:
					_set_chunk_block(chunk, Vector3i(x, SEA_LEVEL - depth + 1, z), BlockTypes.Block.ALGAE)
				continue

			# 池塘：水面浮生植物。
			if r < 0.14:
				_set_chunk_block(chunk, Vector3i(x, SEA_LEVEL, z), BlockTypes.Block.DUCKWEED)
			elif r < 0.22:
				_set_chunk_block(chunk, Vector3i(x, SEA_LEVEL, z), BlockTypes.Block.LILY_PAD)
			elif r < 0.26:
				_set_chunk_block(chunk, Vector3i(x, SEA_LEVEL, z), BlockTypes.Block.LOTUS)


func _set_chunk_block(chunk: Chunk, local: Vector3i, id: int) -> void:
	if _in_chunk(local):
		chunk.set_block_local(local, id)


func _water_life_rng(x: int, z: int) -> float:
	var h := hash(Vector3i(x, seed_value * 31 + 7, z))
	return float(h & 0xFFFF) / 65535.0
