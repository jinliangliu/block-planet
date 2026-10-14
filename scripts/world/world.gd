extends Node3D
class_name World
## 世界管理器：噪声地形生成、树木生成、以玩家为中心的区块流式加载/卸载。

const CHUNK_SIZE := Vector3i(16, 64, 16)
const LOAD_RADIUS := 2
# 每帧加载 2 个并按距玩家距离优先：缩短玩家到达未生成区域的窗口，
# 配合玩家防卡死检测（嵌入实心方块自动重生脱困）形成双保险。
const CHUNKS_PER_FRAME := 2
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
var _neighbor_lookup: Callable
# 储物箱内容物：按方块坐标记录独立 36 格背包，破坏时散落至地面。
var box_contents: Dictionary[Vector3i, Inventory] = {}
# 水体分类缓存：水面格 → WATER_LARGE / WATER_POND，同一水体只洪泛一次。
var _water_kind_cache: Dictionary[Vector2i, int] = {}
# 当前区域的生成配置（RegionAtlas.REGIONS 条目）：决定种子、地形起伏、
# 地表材质与树木密度。未显式设置时使用默认区域，保证场景可单独运行。
var _profile: Dictionary = {}


func _ready() -> void:
	_neighbor_lookup = Callable(self, "get_block")
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
## 村庄等固定建筑生成前调用，确保 set_block 落到已加载区块。
func ensure_chunks_in_region(min_cell: Vector3i, max_cell: Vector3i) -> void:
	var cmin := world_to_chunk(Vector3(min_cell))
	var cmax := world_to_chunk(Vector3(max_cell))
	for cx in range(cmin.x, cmax.x + 1):
		for cz in range(cmin.z, cmax.z + 1):
			_load_chunk(Vector3i(cx, 0, cz))


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
	var cmin := world_to_chunk(Vector3(min_cell))
	var cmax := world_to_chunk(Vector3(max_cell))
	for cx in range(cmin.x, cmax.x + 1):
		for cz in range(cmin.z, cmax.z + 1):
			_rebuild_chunk(Vector3i(cx, 0, cz))


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
		chunk.rebuild(_atlas_material, _emissive_material, _neighbor_lookup)


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
	var wanted := {}
	for x in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
		for z in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
			wanted[center + Vector3i(x, 0, z)] = true

	var to_unload := []
	for key in _chunks:
		if not wanted.has(key):
			to_unload.append(key)
	for key in to_unload:
		_unload_chunk(key)

	for key in _pending_load.keys():
		if not wanted.has(key):
			_pending_load.erase(key)

	for key in wanted:
		if not _chunks.has(key) and not _pending_load.has(key):
			_pending_load[key] = true

	var loaded := 0
	# 按曼哈顿距离升序加载：玩家脚下与前进方向区块优先，减少高速移动时
	# 前方地形尚未生成的窗口期。
	var keys := _pending_load.keys()
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		var da := absi(a.x - center.x) + absi(a.z - center.z)
		var db := absi(b.x - center.x) + absi(b.z - center.z)
		return da < db
	)
	for key in keys:
		if loaded >= CHUNKS_PER_FRAME:
			break
		if _chunks.has(key):
			continue
		_pending_load.erase(key)
		_load_chunk(key)
		loaded += 1

	var rebuilt := 0
	while rebuilt < 2 and not _pending_rebuilds.is_empty():
		_rebuild_chunk(_pending_rebuilds.pop_front())
		rebuilt += 1


func _load_chunk(coord: Vector3i) -> void:
	if _chunks.has(coord):
		return

	var chunk := Chunk.new()
	chunk.name = "Chunk_%d_%d" % [coord.x, coord.z]
	chunk.position = Vector3(chunk_to_world(coord))
	add_child(chunk)

	if _modified_data.has(coord):
		chunk.data = _modified_data[coord]
	else:
		_generate_chunk(chunk, coord)
	chunk.rebuild(_atlas_material, _emissive_material, _neighbor_lookup)
	_chunks[coord] = chunk


func _unload_chunk(coord: Vector3i) -> void:
	var chunk: Chunk = _chunks.get(coord)
	if chunk == null:
		return
	if _edited_coords.has(coord):
		_modified_data[coord] = chunk.data
	_chunks.erase(coord)
	chunk.queue_free()
	# 卸载后邻居外侧边界重新暴露，入队补面重建。
	for offset: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		_pending_rebuilds.append(coord + offset)


func _generate_chunk(chunk: Chunk, coord: Vector3i) -> void:
	var origin := chunk_to_world(coord)
	for x in CHUNK_SIZE.x:
		for z in CHUNK_SIZE.z:
			var wx := origin.x + x
			var wz := origin.z + z
			var height := _terrain_height(wx, wz)
			for y in CHUNK_SIZE.y:
				chunk.set_block_local(Vector3i(x, y, z), _block_at(wx, y, wz, height))

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
