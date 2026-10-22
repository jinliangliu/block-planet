extends Node3D
class_name World
## 世界管理器：噪声地形生成、树木生成、以玩家为中心的区块流式加载/卸载。

## D-055：高度 64 → 256 格（32 m → 128 m），为亚洲分层地形（青藏高原 /
## 喜马拉雅与昆仑山脊 / 长江黄河深切河谷）留出垂直空间。列顶表随之升为
## PackedInt32Array（见 Chunk.col_top 注释）；机场选址扫描起点也必须从
## CHUNK_SIZE.y-1 起（见 main._field_column_ok）。
const CHUNK_SIZE := Vector3i(16, 256, 16)
## 高模环半径（区块）：17 m/块…见下方 D-064 实测表，1 格 = 1 m 后单块 16 m。
## D-064 定 4（64 m 视野）：单块冷加载实测 41 ms（生成 24 + 网格碰撞 11 + 保守
## 边界全扫），环 8 需 289 块 ≈ 12 s 且每跨一格区块就要补 17 块——按时间预算
## 每帧只够 1 块，玩家会长期停在 24 fps。环 4 每跨一格补 9 块（≈0.37 s/次），
## 冷启动 81 块 ≈ 3.3 s，交给出生加载屏。视野远近由低模环承担（见 LOW_RADIUS）。
const LOAD_RADIUS := 4

## ── 低模环（D-064 双环加载）─────────────────────────────────────────────
## 高模环之外到 LOW_RADIUS 区块（256 m）由「高度图粗网格」填充：每 4×4 区块
## 合并成一组、每 4 格采样一个高度，顶点色上色、无方块数据、无碰撞。
## 它只解决「看得见远处地形」，玩家撞不到也挖不到——细节仍由高模环负责。
const LOW_RADIUS := 16
## 低模合并粒度（区块/组）：4 区块 = 64 格 = 64 m，一组 17×17 顶点。
const LOW_GROUP_CHUNKS := 4
## 低模高度采样步长（格）：4 格 = 4 m。采样点落在 4 的倍数上，区块边界
## （16 的倍数）必然落在采样网格上，故低模与高模在接缝处高度逐点相等。
const LOW_SAMPLE := 4

## ── 世界边界（D-064，128 km 区域）──────────────────────────────────────
## ±64000 格：软边界——加载环在界外截断不生成（不产生区块键），海面与雾
## 自然延伸到界，HUD 提示「已到世界边缘」。设硬空气墙违反本作铁律
## （MEMORY.md：全域无空气墙，见 D-055 陡壁教训）。
const WORLD_HALF := 64000
## 每轴区块数的一半：chunk 4000 从 64000 起算，已在界外，故合法区间是
## [-4000, 3999]。
const HALF_CHUNKS := 4000
## 进入边界这个距离（格）内开始提示「已到世界边缘」，离开时提示一次恢复。
const EDGE_NOTICE_DIST := 512
# 每帧加载 2 个并按距玩家距离优先：缩短玩家到达未生成区域的窗口，
# 配合玩家防卡死检测（嵌入实心方块自动重生脱困）形成双保险。
const CHUNKS_PER_FRAME := 2
## 徒步每帧加载时间预算（ms）：与飞行的 FLIGHT_BUDGET_MS 同思路——按耗时限量而非
## 按块数。实测单块重建 23~29 ms，「每帧 2 块」最坏就是 46 ms 级的走向新地形卡顿；
## 低端机单块更慢时也不会因固定块数吃掉整帧。每帧至少加载 1 块保证队列推进。
const WALK_BUDGET_MS := 10.0
## 出生预填期（D-064）：加载屏挡着画面时不必顾忌帧率，每帧多塞几块把高模环
## 尽快填满（4 块 × 41 ms = 164 ms/帧 ≈ 6 fps，但屏幕上只有一块进度条）。
## 环填满后自动回落常规预算——玩家看到的第一帧起就不会再卡。
const BOOTSTRAP_CHUNKS_PER_FRAME := 4
const BOOTSTRAP_BUDGET_MS := 220.0
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

## ── 浮动原点（origin shifting，128 km 大世界 D-062）──────────────────────
## 世界 ±64000 格：float32 在 64 km 处量化约 8 mm——区块节点位置量化会让相邻
## 区块共享边错位（地面裂缝）、相机与物理体抖动。故逻辑坐标一律整数（世界
## 空间，真相），渲染坐标 = 世界坐标 − origin；玩家越过阈值即 recenter，
## 全部世界内容随之搬迁。
## 搬迁分工：World 节点位置 = −origin（其下区块/结构/树木自动跟随）；
## Main 级实体（玩家/飞机/船/箭/倒树/浮漂/飞行标记）与渲染空间锚点
## （player.spawn_position）经 Events.origin_shifted 信号搬迁。
const ORIGIN_SHIFT_THRESHOLD := 4096   # 玩家距 origin 超此值即搬迁（4 km 处 float32 量化 0.5 mm，不可见）
const ORIGIN_SHIFT_GRID := 4096        # 新 origin 对齐网格：同一世界位置经不同路径到达时渲染坐标一致（探针可复现）

## ── D-055 亚洲分层地形的尺度常量（单位：格，1 格 = 0.5 m） ──────────────
## 世界高 256 格 = 128 m，分配如下：
##   平原丘陵  22..42   老单一噪声的地盘，玩家日常活动区
##   青藏高原  ..112    超低频抬升的台地（≈56 m 海拔）
##   两大雪脊  ..212    ridged 山脊（≈106 m 海拔，留 44 格顶部空间）
##   深切河谷  10..22   河床下切，水面回到 SEA_LEVEL
## 材质分界：>SNOW_LINE 积雪、>ROCK_LINE 裸岩、河岸草甸、河床砾石。
const PLATEAU_H := 70.0        # 高原抬升增益（叠加在丘陵基底之上）
const RIDGE_H := 100.0         # 山脊抬升增益
const RIDGE_SHARP := 3.0       # ridged 指数：越大脊线越尖、谷越窄
## D-055 陡壁教训（改了三轮才对）：高原与山脊的 smoothstep 门限区间必须
## 覆盖 FastNoiseLite 2D simplex 的**实际**输出分布（集中在 ±0.35，不是理论
## 的 ±1）。早期取 0.05/0.40，pn 一越过 0.2 整片高原瞬间饱和到1.0，山脊门限
## 随之瞬时拉满——实测山脊 194 格与平原 30 格直接相邻，单步落差 164 格（82m），
## 巡航速度撞上必解体，玩家在山脚下被「空气墙」拦住飞不过去。
## 关键不是「过渡带宽」，而是**区间要落在噪声真实取值范围内**，否则再宽也无效。
## 改成 0.10..0.95（覆盖 ±0.35 全域）后抬升才连续渐变。
## PLATEAU_* 管高原台地，RIDGE_GATE_* 管山脊附着，两者取同一区间保持一致。
const PLATEAU_MIN := 0.10      # 高原噪声下阈（低于它视为平原）
const PLATEAU_FULL := 0.95     # 高原噪声上阈（高于它才算「够高」）
## 保护区边缘渐变带宽度（格）。硬边界会让区外山脊与区内平原一步相接
## （实测单步落差 162 格＝81m），玩家在机场外遇到空气墙、飞机撞上必解体。
## 30 格 = 15m 的平缓过渡带，既有可飞性又保住机场/村庄选址的平整要求。
const FLAT_FEATHER := 30
const RIDGE_GATE := 0.10# 山脊门限下阈：高原归一化高度低于它完全不长山
const RIDGE_GATE_FULL := 0.95  # 上阈：高于它才满增益长山
const RIVER_CUT := 15.0        # 河床下切深度（平原段）
const RIVER_ANISO_X := 0.40    # 河道各向异性：x 慢 → 河道沿东西向延伸
const RIVER_ANISO_Z := 1.50    #                z 快
const RIVER_T0 := 0.06         # 河心阈值（|rv| 小于它 = 河心）
const RIVER_T1 := 0.20         # 河岸阈值（|rv| 大于它 = 完全陆地）
const SNOW_LINE := 150         # 雪线（格）：实测最高山188 格，150 起积雪才能
const ROCK_LINE := 100         # 裸岩线（格）：雪线以下的山体用裸岩
const TREE_LINE_DEFAULT := 118.0   # 树线（profile 未指定时的兜底）

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

var _chunks: Dictionary[Vector2i, Chunk] = {}
var _pending_load: Dictionary[Vector2i, bool] = {}
# 玩家修改过的区块坐标；卸载时留存数据，重载时恢复，避免建筑凭空消失。
var _edited_coords: Dictionary[Vector2i, bool] = {}
var _modified_data: Dictionary[Vector2i, PackedByteArray] = {}
# 卸载区块后需要补面的邻居重建队列，每帧限量处理以平滑卡顿。
var _pending_rebuilds: Array[Vector2i] = []
var _atlas_material: StandardMaterial3D
var _emissive_material: StandardMaterial3D
var _noise := FastNoiseLite.new()
# D-055 平整保护区缓存：_profile 只在 set_region 时整份替换，故可按区域缓存
# 一次 Rect2i 列表；否则每列都要遍历 profile 数组并做 4 次 int 转换。
var _flat_zone_cache: Array[Rect2i] = []
var _flat_zone_loaded := false
# 极地冰山噪声：低频成团，决定哪里隆起露出海面的冰山（D-028）。
var _iceberg_noise := FastNoiseLite.new()
# ── D-055 亚洲分层地形噪声（仅 "terrain": "layered" 的区域使用） ──────────
# 青藏高原地基：超低频、大幅值，smoothstep 后成片抬升（不逐格漫射，才能
# 形成「一大块台地」而不是到处发皱的丘陵）。
var _plateau_noise := FastNoiseLite.new()
# 山脊噪声：取 1-|n| 的 ridged 形态把脊线收尖，只在高原足够高处才放行，
# 于是喜马拉雅/昆仑长在高原边缘而不是平白冒在平原上。
var _ridge_noise := FastNoiseLite.new()
# 河道噪声：极低频 + 输入各向异性缩放（x 慢 z 快），等值线沿东西向延伸，
# 得到「自西向东奔流」的长条河道，闭合小水塘交给 _flood_water 归类。
var _river_noise := FastNoiseLite.new()
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
## 出生预填期开关（D-064）：见 BOOTSTRAP_CHUNKS_PER_FRAME。
var _bootstrap := true
## 低模环（D-064）：高模环之外的地形粗网格。为 null 时整条低模路径跳过
## （世界尚未 setup 早期帧、或被探针单独构造的情形）。
var _low_terrain: LowTerrain
## 边界提示状态（D-064）：只在进出临近区时各提示一次，不做每帧播报。
var _edge_notice_on := false
var _wanted_center := Vector2i(1 << 30, 1 << 30)  # 不可能的中心值：首帧必重算
var _wanted_dir := Vector3(0.0, 0.0, -1.0)
var _wanted_flight := false
var _pending_dirty := true
var _sort_center := Vector2i.ZERO
var _priority_cmp: Callable
## 浮动原点（D-062）：渲染坐标 = 世界坐标 − origin。世界节点位置 = −origin，
## 其下子节点保持绝对（世界）坐标不变。origin 恒为 ORIGIN_SHIFT_GRID 的倍数。
var _origin := Vector2i.ZERO
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
	# 低模环（D-064）：作为 World 的子节点，自动跟随「World.position = −origin」
	# 的浮动原点搬迁，无需单独注册 WorldAnchor。
	_low_terrain = LowTerrain.new()
	_low_terrain.name = "LowTerrain"
	add_child(_low_terrain)
	_low_terrain.setup(self)


## 低模环驱动（D-064）：高模环之外到 LOW_RADIUS 的粗网格。
## LowTerrain 内部按「中心区块 + 跳过高模方形」签名做增量，签名不变时是
## 一次比较即返回，故每帧调用无成本。
func _update_low_ring(center: Vector2i) -> int:
	if _low_terrain == null:
		return 0
	var skip := LOAD_RADIUS
	if _flight_stream:
		# 飞行窗口是沿机头的偏置矩形，低模按它的 AABB 整体让位：宁可让高模
		# 多承担几块，也不让 4 m 粗网格从精细地形里穿出来（穿出来会看到尖刺）。
		skip = FLIGHT_FORWARD + FLIGHT_SIDE
	return _low_terrain.update_window(center, skip)


## 边界提示（D-064 软边界）：临近世界边缘各提示一次。不阻止移动——硬空气墙
## 违反本作铁律；界外没有地形，玩家自然会在海面上被雾挡住视线后掉头。
func _update_edge_notice() -> void:
	var near := is_near_world_edge(to_world(_player.global_position))
	if near == _edge_notice_on:
		return
	_edge_notice_on = near
	Events.notice.emit("已到世界边缘" if near else "已回到世界内部")


## 切换区域：同步种子与生成配置。区域切换由 Main 通过重载主场景完成
## （村庄、生物、储物箱等全部随场景重建），此处只负责地形参数。
func set_region(region_id: int) -> void:
	_profile = RegionAtlas.profile(region_id)
	seed_value = int(_profile["seed"])
	_configure_noise()
	# D-055：平整保护区随区域切换而变（亚洲的机场在 z=96，其它区域在 z=8），
	# 缓存必须在此作废，否则切区域后会拿旧区域的矩形去否决新地形。
	_flat_zone_cache.clear()
	_flat_zone_loaded = false


func get_region() -> int:
	return int(_profile.get("id", RegionAtlas.DEFAULT_REGION))


func set_player(player: Player) -> void:
	_player = player
	# 先同步加载玩家所在区块，避免出生时脚下没有地形。
	_load_chunk(chunk_at(player.global_position))


## 出生预填（D-064）：同步载入 center 周围 radius 圈区块，返回实际新建块数。
## 供 Main 的出生流程在「加载屏」期间分步调用：先把近处填实，玩家一放行
## 就看得到完整地面，剩下的高模环由常规定时预算在随后几秒内补齐。
func fill_ring_sync(center: Vector2i, radius: int) -> int:
	var n := 0
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			var key := center + Vector2i(dx, dz)
			if _chunks.has(key) or not is_chunk_in_bounds(key):
				continue
			_load_chunk(key)
			n += 1
	return n


## 高模环填装进度（0..1）：加载屏据此决定何时放行。分母是 wanted 集
## （已扣掉界外区块），故在边界处也算得对。
func ring_fill_ratio() -> float:
	if _wanted.is_empty():
		return 1.0
	var have := 0
	for key: Vector2i in _wanted:
		if _chunks.has(key):
			have += 1
	return float(have) / float(_wanted.size())


## 高模环是否已填满（加载屏放行条件）。
func is_ring_filled() -> bool:
	for key: Vector2i in _wanted:
		if not _chunks.has(key):
			return false
	return true


## 低模环组数（探针用；未 setup 返回 0）。
func low_group_count() -> int:
	return 0 if _low_terrain == null else _low_terrain.group_count()


func _process(_delta: float) -> void:
	if _player == null:
		return
	_update_chunks()


func get_surface_height(wx: int, wz: int) -> int:
	return _terrain_height(wx, wz) + 1


## 低模层（D-064）采样用：该列地表的显示颜色。
## 与 Chunk 的上色同源——地表方块的**顶面瓦片**主色（雪线/裸岩/河床等分层
## 材质经 _surface_ids 判定）；水面/冰面按水体策略覆盖。
## 世界坐标、纯噪声，不依赖区块加载（低模环远超高模环，不能要求有数据）。
func surface_color_at(wx: int, wz: int) -> Color:
	return surface_color_at_height(wx, wz, _terrain_height(wx, wz))


## 同上，但高度由调用方提供（低模采样已经在同一列算过高度，不重复算：
## 地形高度在多噪声叠加的分层区域每列约 13 μs，是低模构建的主要成本）。
func surface_color_at_height(wx: int, wz: int, h: int) -> Color:
	var policy := String(_profile.get("water", "normal"))
	if policy == "iceberg":
		if _iceberg_top(wx, wz) > 0:
			return _tile_color(BlockTypes.Block.SNOW)
		if h < SEA_LEVEL:
			return _tile_color(BlockTypes.Block.ICE)
	elif policy != "dry" and h < SEA_LEVEL:
		return _tile_color(BlockTypes.Block.WATER)
	var ids := _surface_ids(wx, wz, h)
	return _tile_color(ids.x)


## 方块 → 其顶面瓦片的代表色（低模顶点色用）。未知方块退回石头色。
func _tile_color(block_id: int) -> Color:
	var tiles: Vector3i = BlockTypes.TILES.get(block_id, Vector3i(3, 3, 3))
	return TextureAtlas.tile_color(tiles.x)


## 该列最高的非空气格（未加载返回 AIR）。供小地图采样：一次定位区块后直接在
## 区块数据内取顶，避免逐格 get_block 的 world_to_chunk + 字典查询
## （实测采样 6.5 ms/次 → 目标 <1 ms）。pristine 区块走列顶表 O(1)，
## 被改动过的区块退回列内扫描（仍只做一次区块定位）。
## wx/wz 为**渲染空间**格（小地图持玩家节点坐标），内部转世界空间。
func top_block_at(wx: int, wz: int) -> int:
	var w := to_world(Vector3(float(wx), 0.0, float(wz)))
	var coord := world_to_chunk(w)
	var chunk: Chunk = _chunks.get(coord)
	if chunk == null:
		return BlockTypes.Block.AIR
	var sx := CHUNK_SIZE.x
	var plane := sx * CHUNK_SIZE.z
	var lx := floori(w.x) - coord.x * sx
	var lz := floori(w.z) - coord.y * CHUNK_SIZE.z
	var base := lx + lz * sx
	if chunk.pristine and not chunk.col_top.is_empty():
		var top := int(chunk.col_top[base])
		if top == -1:
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
## min_cell/max_cell 为**世界空间**格（建筑创作 API，绝对坐标）。
func ensure_chunks_in_region(min_cell: Vector3i, max_cell: Vector3i) -> void:
	var cmin := world_to_chunk(Vector3(min_cell))
	var cmax := world_to_chunk(Vector3(max_cell))
	for cx in range(cmin.x, cmax.x + 1):
		for cz in range(cmin.y, cmax.y + 1):
			_load_chunk(Vector2i(cx, cz))


## 结构生成预加载：只落数据、不建网格（供机场/村庄在统一重建前把整片区域
## 的方块写入已加载区块）。_load_chunk 自带的 rebuild 在邻居尚未加载时也要
## 做一遍（边界列全扫 ≈20 ms），随后 rebuild_chunks_in_region 又会带着齐备
## 的邻居重做一遍——每块双倍重建，机场 + 三村约 80 块 ≈ 1 s 级白工。预加载把
## 网格创建推后到统一重建：邻居齐备、列边界可信，一遍即终态。探针与常规流式
## 仍走 ensure_chunks_in_region（带网格），不受影响。
## min_cell/max_cell 为**世界空间**格（同 ensure_chunks_in_region）。
func preload_chunks_in_region(min_cell: Vector3i, max_cell: Vector3i) -> void:
	var cmin := world_to_chunk(Vector3(min_cell))
	var cmax := world_to_chunk(Vector3(max_cell))
	for cx in range(cmin.x, cmax.x + 1):
		for cz in range(cmin.y, cmax.y + 1):
			_load_chunk(Vector2i(cx, cz), false)


## 结构生成支持：批量写方块但不触发网格重建（配合 rebuild_chunks_in_region 一次重建）。
## 避免逐方块重建导致结构生成时数秒级卡顿；写入仍计入修改留存。
## pos 为**渲染空间**格（建造器开机时 origin=0，与运行时砍树路径同语义）。
func set_block_deferred(pos: Vector3i, id: int) -> void:
	var w := to_world(Vector3(pos))
	var coord := world_to_chunk(w)
	var chunk: Chunk = _chunks.get(coord)
	if chunk == null:
		return
	chunk.set_block_local(_cell_local(floori(w.x), floori(w.y), floori(w.z), coord), id)
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
	# near 是渲染坐标（出生点/停机位经玩家节点传入），转世界区块再比窗口。
	var near_c := chunk_at(near) if use_near else Vector2i.ZERO
	for cx in range(cmin.x, cmax.x + 1):
		for cz in range(cmin.y, cmax.y + 1):
			var coord := Vector2i(cx, cz)
			if use_near and (absi(coord.x - near_c.x) > LOAD_RADIUS + UNLOAD_PAD
					or absi(coord.y - near_c.y) > LOAD_RADIUS + UNLOAD_PAD):
				continue
			_rebuild_chunk(coord)


## 世界坐标（绝对，格）→ 区块坐标。底层接口：对负坐标同样正确（floori 向下
## 取整）。区块竖直不分段，故只取 x/z 两维（Vector2i）。
func world_to_chunk(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / float(CHUNK_SIZE.x)), floori(pos.z / float(CHUNK_SIZE.z)))


## 区块坐标 → 该区块最小角的世界坐标（浮点；逻辑层用整数时自行 floori）。
## 底层接口：与 world_to_chunk 互逆（world_to_chunk(chunk_to_world(c)) == c）。
func chunk_to_world(coord: Vector2i) -> Vector3:
	return Vector3(float(coord.x * CHUNK_SIZE.x), 0.0, float(coord.y * CHUNK_SIZE.z))


## 渲染坐标 → 世界坐标（浮动原点逆变换，D-062）。
func to_world(render_pos: Vector3) -> Vector3:
	return render_pos + Vector3(float(_origin.x), 0.0, float(_origin.y))


## 世界坐标 → 渲染坐标（浮动原点正变换，D-062）。origin=0 时恒等。
func to_render(world_pos: Vector3) -> Vector3:
	return world_pos - Vector3(float(_origin.x), 0.0, float(_origin.y))


## 玩家/实体所在的区块（渲染坐标入，世界区块出）——流式加载的中心。
func chunk_at(render_pos: Vector3) -> Vector2i:
	return world_to_chunk(to_world(render_pos))


## 区块坐标是否在世界边界内（D-064 软边界）。
## 区块 c 覆盖 [c*16, c*16+15] 格，故 ±64000 对应合法区间 [-4000, 3999]：
## 负数侧多一格是因为 -4000 覆盖 [-64000, -63985]，恰好在界内。
func is_chunk_in_bounds(coord: Vector2i) -> bool:
	return coord.x >= -HALF_CHUNKS and coord.x < HALF_CHUNKS \
		and coord.y >= -HALF_CHUNKS and coord.y < HALF_CHUNKS


## 世界坐标是否已贴到边界（供 HUD 提示用；不阻止移动——软边界，禁空气墙）。
func is_near_world_edge(world_pos: Vector3) -> bool:
	return absf(world_pos.x) > float(WORLD_HALF - EDGE_NOTICE_DIST) \
		or absf(world_pos.z) > float(WORLD_HALF - EDGE_NOTICE_DIST)


## 当前浮动原点（世界格）。
func origin() -> Vector2i:
	return _origin


## 请求搬迁到指定 origin（生产路径由 _maybe_shift_origin 按玩家位置自动判定；
## 探针/测试可直接调用）。语义见 Events.origin_shifted：delta = 旧−新 origin，
## 世界锚定节点 position += delta、渲染空间锚点同步重基。
func request_shift_origin(new_origin: Vector2i) -> void:
	if new_origin == _origin:
		return
	var delta := Vector3(float(_origin.x - new_origin.x), 0.0, float(_origin.y - new_origin.y))
	_origin = new_origin
	# 世界节点位置 = −origin：其下全部子节点（区块/结构/树木，保持绝对坐标）
	# 随之平移，无需逐个处理。
	position = Vector3(-float(new_origin.x), 0.0, -float(new_origin.y))
	# 储物箱以渲染格为键：同一世界位置的键随 origin 平移（+delta）。
	if not box_contents.is_empty():
		var rekeyed: Dictionary[Vector3i, Inventory] = {}
		for cell: Vector3i in box_contents:
			rekeyed[cell + Vector3i(delta)] = box_contents[cell]
		box_contents = rekeyed
	Events.origin_shifted.emit(delta)


## 玩家越过阈值即把 origin 对齐到网格并搬迁（每帧一次，判定为两次整数比较）。
func _maybe_shift_origin(player_render: Vector3) -> void:
	var w := to_world(player_render)
	var wx := floori(w.x)
	var wz := floori(w.z)
	var nx := _origin.x
	var nz := _origin.y
	if absi(wx - _origin.x) > ORIGIN_SHIFT_THRESHOLD:
		nx = int(floorf(float(wx) / float(ORIGIN_SHIFT_GRID))) * ORIGIN_SHIFT_GRID
	if absi(wz - _origin.y) > ORIGIN_SHIFT_THRESHOLD:
		nz = int(floorf(float(wz) / float(ORIGIN_SHIFT_GRID))) * ORIGIN_SHIFT_GRID
	if nx != _origin.x or nz != _origin.y:
		request_shift_origin(Vector2i(nx, nz))


## 渲染格 → 所在区块内的局部格（世界格 − 区块世界原点）。
func _cell_local(wx: int, wy: int, wz: int, coord: Vector2i) -> Vector3i:
	return Vector3i(wx - coord.x * CHUNK_SIZE.x, wy, wz - coord.y * CHUNK_SIZE.z)


func get_block(world_pos: Vector3i) -> int:
	# 渲染空间格坐标（调用方持有的是节点坐标）；内部转世界空间查区块。
	var w := to_world(Vector3(world_pos))
	var coord := world_to_chunk(w)
	var chunk: Chunk = _chunks.get(coord)
	if chunk == null:
		return BlockTypes.Block.AIR
	return chunk.get_block_local(_cell_local(floori(w.x), floori(w.y), floori(w.z), coord))


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


## 写方块（玩家编辑路径）：world_pos 为**渲染空间**格（调用方持有节点坐标），
## 内部转世界空间落账；编辑记录按世界区块键存，跨浮动原点搬迁不丢。
func set_block(world_pos: Vector3i, id: int) -> void:
	var w := to_world(Vector3(world_pos))
	var coord := world_to_chunk(w)
	var chunk: Chunk = _chunks.get(coord)
	if chunk == null:
		return

	var local := _cell_local(floori(w.x), floori(w.y), floori(w.z), coord)
	chunk.set_block_local(local, id)
	_edited_coords[coord] = true
	_rebuild_chunk(coord)

	# 修改位于区块边界时，重建相邻区块以更新交界处的可见面。
	if local.x == 0:
		_rebuild_chunk(coord + Vector2i(-1, 0))
	elif local.x == CHUNK_SIZE.x - 1:
		_rebuild_chunk(coord + Vector2i(1, 0))
	if local.z == 0:
		_rebuild_chunk(coord + Vector2i(0, -1))
	elif local.z == CHUNK_SIZE.z - 1:
		_rebuild_chunk(coord + Vector2i(0, 1))


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


func _rebuild_chunk(coord: Vector2i) -> void:
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
func _prepare_columns(coord: Vector2i, chunk: Chunk) -> void:
	if chunk.col_top.is_empty():
		# 整块未知（被覆写恢复且尚未被编辑过）：不给表，rebuild 全量遍历。
		chunk.tops_ext = PackedInt32Array()
		chunk.grounds_ext = PackedInt32Array()
		return
	var n := CHUNK_SIZE.x
	var w := n + 2
	var tops := PackedInt32Array()
	var grounds := PackedInt32Array()
	tops.resize(w * w)
	grounds.resize(w * w)
	tops.fill(-1)
	grounds.fill(-1)
	for z in n:
		for x in n:
			_encode_column(tops, grounds, (z + 1) * w + (x + 1), chunk, x + z * n)
	for z in n:
		var nb: Chunk = _chunks.get(coord + Vector2i(-1, 0))
		if _has_columns(nb):
			_encode_column(tops, grounds, (z + 1) * w, nb, (n - 1) + z * n)
		nb = _chunks.get(coord + Vector2i(1, 0))
		if _has_columns(nb):
			_encode_column(tops, grounds, (z + 1) * w + (n + 1), nb, z * n)
	for x in n:
		var nbz: Chunk = _chunks.get(coord + Vector2i(0, -1))
		if _has_columns(nbz):
			_encode_column(tops, grounds, x + 1, nbz, x + (n - 1) * n)
		nbz = _chunks.get(coord + Vector2i(0, 1))
		if _has_columns(nbz):
			_encode_column(tops, grounds, (n + 1) * w + (x + 1), nbz, x)
	chunk.tops_ext = tops
	chunk.grounds_ext = grounds


## 把 src 区块第 i 列的边界编码进扩展表的 slot。
## 编码规则（D-055 起为 32 位表，哨兵 -1/-2）：
##   tops_ext    -1 = 整列为空；-2 = 未知（全扫）；其余 = 列顶高度
##   grounds_ext -1 = 未知（全扫）；其余 = 列地高度
func _encode_column(tops: PackedInt32Array, grounds: PackedInt32Array, slot: int,
		src: Chunk, i: int) -> void:
	var t := int(src.col_top[i])
	if t == -1:
		return  # 整列为空：保持 -1，rebuild 跳过
	var valid := 0 if src.col_valid.is_empty() else int(src.col_valid[i])
	if t < 0 or valid == 0:
		# 未知或被地下开挖作废：全扫（tops 给满高、grounds 给未知）。
		tops[slot] = CHUNK_SIZE.y - 1
		grounds[slot] = -1
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
		touched[chunk_at(Vector3(p))] = true
	for coord: Vector2i in touched:
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
		touched[chunk_at(Vector3(p))] = true
	for coord: Vector2i in touched:
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
			touched[chunk_at(Vector3(p))] = true
			placed.append(p)
			break
	for coord: Vector2i in touched:
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
	# D-055 分层地形噪声：三者种子错开（+101/+202/+303），否则高原、山脊、
	# 河道会因同源而互相绑定，出现「山脊永远长在河谷正上方」的假关联。
	_plateau_noise.seed = seed_value + 101
	_plateau_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_plateau_noise.frequency = 0.0022   # 超低频：单块台地横跨数百格
	_plateau_noise.fractal_octaves = 2
	_ridge_noise.seed = seed_value + 202
	_ridge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_ridge_noise.frequency = 0.0075     # 中频：脊线间距约 60~130 格
	_ridge_noise.fractal_octaves = 2
	_river_noise.seed = seed_value + 303
	_river_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_river_noise.frequency = 0.0040     # 极低频：主干河道长数百格
	_river_noise.fractal_octaves = 1    # 单 octave：不要支流分形，保持河形干净


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
	# 浮动原点判定先行：玩家越过阈值先搬迁（世界内容整体平移，区块键不变），
	# 随后一切按「玩家所在世界区块」计算——搬迁前后语义一致。
	_maybe_shift_origin(_player.global_position)
	var center := chunk_at(_player.global_position)
	_update_stream_dir()
	_update_low_ring(center)
	_update_edge_notice()

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
	if _bootstrap:
		max_chunks = BOOTSTRAP_CHUNKS_PER_FRAME
	var budget_us := int((FLIGHT_BUDGET_MS if _flight_stream else WALK_BUDGET_MS) * 1000.0)
	if _bootstrap:
		budget_us = int(BOOTSTRAP_BUDGET_MS * 1000.0)
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

	# 出生预填结束判定：wanted 全部到齐即回落常规预算（此后不再进 bootstrap）。
	if _bootstrap and _pending_load.is_empty():
		_bootstrap = false


## 重建 wanted 集（见 _wanted 缓存说明）：以中心区块为原点的保留窗口。
func _rebuild_wanted(center: Vector2i) -> void:
	var wanted := {}
	var reach := LOAD_RADIUS + UNLOAD_PAD
	if _flight_stream:
		reach = maxi(FLIGHT_FORWARD, maxi(FLIGHT_SIDE, FLIGHT_BACK)) + UNLOAD_PAD
	for ex in range(-reach, reach + 1):
		for ez in range(-reach, reach + 1):
			var off := Vector2i(ex, ez)
			if not _in_stream_window(off, 0):
				continue
			var key := center + off
			# D-064 软边界：界外区块不进 wanted（进也不会被生成，白占队列）。
			if is_chunk_in_bounds(key):
				wanted[key] = true
	_wanted = wanted
	_wanted_center = center
	_wanted_dir = _stream_dir
	_wanted_flight = _flight_stream


## 加载优先级排序比较器（预建 Callable，中心由 _sort_center 带入）。
func _cmp_load_priority(a: Vector2i, b: Vector2i) -> bool:
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
func _in_stream_window(offset: Vector2i, pad: int) -> bool:
	if not _flight_stream:
		return absi(offset.x) <= LOAD_RADIUS + pad and absi(offset.y) <= LOAD_RADIUS + pad
	var u := float(offset.x) * _stream_dir.x + float(offset.y) * _stream_dir.z
	var v := float(offset.x) * -_stream_dir.z + float(offset.y) * _stream_dir.x
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
func _load_priority(coord: Vector2i, center: Vector2i) -> float:
	if not _flight_stream:
		return float(absi(coord.x - center.x) + absi(coord.y - center.y))
	var off := coord - center
	var u := float(off.x) * _stream_dir.x + float(off.y) * _stream_dir.z
	var v := float(off.x) * -_stream_dir.z + float(off.y) * _stream_dir.x
	return absf(u) + absf(v) - 0.6 * u


func _load_chunk(coord: Vector2i, with_rebuild: bool = true) -> void:
	if _chunks.has(coord):
		return
	# D-064 软边界：界外不生成（不产生区块键），玩家走到界外只会看到海面与雾。
	if not is_chunk_in_bounds(coord):
		return

	var chunk := Chunk.new()
	chunk.name = "Chunk_%d_%d" % [coord.x, coord.y]
	# 子节点保持绝对（世界）坐标：World 节点位置 = −origin 负责整体平移（D-062）。
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


func _unload_chunk(coord: Vector2i) -> void:
	var chunk: Chunk = _chunks.get(coord)
	if chunk == null:
		return
	if _edited_coords.has(coord):
		_modified_data[coord] = chunk.data
	_chunks.erase(coord)
	chunk.queue_free()
	# 不变式：_wanted 里的区块「应载」。_update_chunks 的重新入队只在中心
	# 区块变化时跑（D-038 缓存），窗口内区块若被直接卸载（探针/未来调用方），
	# 队列不会自愈——这里补上：仍在 wanted 且未排队的重新入队。正常路径卸载的
	# 是窗口外区块，不在 _wanted，本检查直接跳过，零行为变化。
	if _wanted.has(coord) and not _pending_load.has(coord):
		_pending_load[coord] = true
		_pending_dirty = true
	# 卸载后邻居外侧边界重新暴露，入队补面重建（去重：多个卸载共享同一邻居
	# 时只留一份，避免同一coord 被反复重建）。
	for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nb := coord + offset
		if not _pending_rebuilds.has(nb):
			_pending_rebuilds.append(nb)


## 区块数据生成（判据与 _block_at 同源，逐格结果一致）。
## 区域参数与逐列量提到循环外：原先每格都要做 3~5 次 _profile 字典查询、
## 极地列还要每格再算一次冰山噪声，16384 格累计占数据生成耗时的一半以上。
func _generate_chunk(chunk: Chunk, coord: Vector2i) -> void:
	var origin_f := chunk_to_world(coord)
	var origin := Vector3i(floori(origin_f.x), 0, floori(origin_f.z))
	var water_policy := String(_profile.get("water", "normal"))
	var low_line := int(_profile.get("low_line", SEA_LEVEL))
	var surface_high := int(_profile.get("surface", BlockTypes.Block.GRASS))
	var surface_low := int(_profile.get("surface_low", BlockTypes.Block.SAND))
	var sub_high := int(_profile.get("sub", BlockTypes.Block.DIRT))
	var sub_low := int(_profile.get("sub_low", BlockTypes.Block.SAND))
	var is_dry := water_policy == "dry"
	var is_iceberg := water_policy == "iceberg"
	var is_layered := String(_profile.get("terrain", "")) == "layered"
	var sx := CHUNK_SIZE.x
	var sz := CHUNK_SIZE.z
	var plane := sx * sz
	var data := chunk.data
	# D-055：高度 64→256 后，逐列全扫 256 层会让单块生成耗时涨 4 倍（流式
	# 加载直接卡顿）。data 在 Chunk._init 已整块填 AIR，故只需写到「本列
	# 最高可能非空气格」：地形顶与海面取大者（iceberg 的封冻海面要到
	# SEA_LEVEL），其余保持 AIR 不动。山越高写得越深，平原仍只写 ~30 层。
	for x in sx:
		for z in sz:
			var wx := origin.x + x
			var wz := origin.z + z
			var height := _terrain_height(wx, wz)
			var high := height > low_line
			# D-055 分层地表：按高度换材质（雪线积雪 / 裸岩坡），再按河心
			# 强度换河床砾石与两岸草甸。classic 区域两条新判据都恒不触发，
			# 走的仍是老 profile 材质，几何与旧版完全一致。
			var ids := Vector2i(surface_high if high else surface_low,
				sub_high if high else sub_low)
			if is_layered:
				ids = _surface_ids(wx, wz, height)
			var surface_id := ids.x
			var sub_id := ids.y
			var ice_top := _iceberg_top(wx, wz) if is_iceberg else 0
			var col := x + z * sx
			# 本列需写入的上限：dry 只到地形顶；normal 要到海面（水）；
			# iceberg 还要算上冰山顶。上限以上保持 AIR 不动。
			var y_cap := height
			if not is_dry:
				y_cap = maxi(y_cap, SEA_LEVEL)
			if ice_top > y_cap:
				y_cap = ice_top
			for y in range(y_cap + 1):
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


## 地形高度（格）。classic = 单一噪声丘陵；layered（D-055，亚洲）在丘陵
## 基底上叠加三层：青藏高原地基 → 喜马拉雅/昆仑 ridged 山脊 → 长江/黄河
## 深切河谷，再由平整保护区把山与河挡在机场/村庄/降落场之外。
func _terrain_height(wx: int, wz: int) -> int:
	var base := float(_profile.get("base_height", 28.0))
	var amplitude := float(_profile.get("amplitude", 10.0))
	var n := _noise.get_noise_2d(float(wx), float(wz))
	var h := base + n * amplitude
	if String(_profile.get("terrain", "")) == "layered":
		h = _layered_height(wx, wz, h)
	# 上限留 8 格：树冠、村庄/机场的 C1EAR_H 净空、雪顶都要向上空间；
	# 下限不低于 2：别让河床把 data 索引逼到 0 以下（ore 分布按绝对高度算）。
	var out := clampi(int(round(h)), 2, CHUNK_SIZE.y - 8)
	if String(_profile.get("terrain", "")) == "layered":
		# D-055 限坡：分层项叠加后可能出「空气墙」——高原 smoothstep 与
		# ridged 三次方陡化叠加，实测单步落差达170 格（85m），巡航速度
		# 撞上必解体，玩家在山脚下就飞不过去。噪声参数怎么调都难保证全域
		# 无陡壁，故在此对最终高度做邻域坡度钳制：任一方向单步不超过
		# MAX_SLOPE 格。迭代固定轮数（松弛法），避免递归。
		out = _limit_slope(wx, wz, out)
	return out


## 限坡松弛（D-055）：反复把本格高度拉向「与四邻的最大落差 ≤ MAX_SLOPE」。
## 纯函数式实现——每轮用已钳制的邻域高度重算本格，跑 SLOPE_RELAX_ROUNDS
## 轮。不做递归（_terrain_height 调四邻、四邻又调回本格会无限展开）。
## 代价是每列多 4×ROUNDS 次噪声采样，故轮数取小值（实测 2 轮已足够：
## 陡壁率从 10.4% 降到 1% 以下），且只在 layered 区域付出。
const MAX_SLOPE := 6          # 单格最大落差（格）＝3m/格，20m/s 可爬升
const SLOPE_RELAX_ROUNDS := 4

func _limit_slope(wx: int, wz: int, h: int) -> int:
	var cur := h
	for _round in range(SLOPE_RELAX_ROUNDS):
		var adjust := 0
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nh := _raw_height(wx + d.x, wz + d.y)
			var diff := nh - cur
			if diff > MAX_SLOPE:
				adjust = maxi(adjust, diff - MAX_SLOPE)
			elif -diff > MAX_SLOPE:
				adjust = mini(adjust, -diff - MAX_SLOPE)
		if adjust == 0:
			break
		cur += adjust
	# 末轮仍可能残留 1~2 格超限（松弛只朝邻域拉、不反向传播），夹一次兜底。
	return clampi(cur, h - SLOPE_SLACK, h + SLOPE_SLACK)

## 松弛后允许的残差（格）。松弛把本格朝邻域拉，邻域各自独立算——约束不
## 完全传播，末轮常留 1~3 格超限。这点残差（≤1.5m）远小于飞机可承受的
## 爬升率，不是问题；断言按MAX_SLOPE + SLOPE_SLACK 判。
const SLOPE_SLACK := 3


## 未限坡的原始高度（限坡松弛的邻域采样用，避免无限递归）。
func _raw_height(wx: int, wz: int) -> int:
	var base := float(_profile.get("base_height", 28.0))
	var amplitude := float(_profile.get("amplitude", 10.0))
	var n := _noise.get_noise_2d(float(wx), float(wz))
	var h := base + n * amplitude
	h = _layered_height(wx, wz, h)
	return clampi(int(round(h)), 2, CHUNK_SIZE.y - 8)


## D-055 分层高度。返回绝对高度（格）。四段顺序即真实地貌的生成次序：
## 先有高原台地，高原边缘隆起成山脊，河流自高原切谷（只在低地切深），
## 平整保护区最后否决一切起伏。
func _layered_height(wx: int, wz: int, base_h: float) -> float:
	# ② 青藏高原地基：超低频 smoothstep 成片抬升。
	# 门限区间必须覆盖噪声实际取值范围：FastNoiseLite 的 2D simplex 输出
	# 集中在 ±0.35 附近（不是理论上的 ±1）。早期用 0.02..0.62 时，pn 越过
	# 0.2 就整片饱和到 1.0，高原边缘变成「一刀切」，山脊随之瞬时拉满——
	# 实测山脊（194格）与平原（30格）直接相邻，单步落差 164 格（82m），
	# 巡航撞上必解体。现用 0.10..0.95 覆盖实际分布，抬升连续渐变。
	var pn := _plateau_noise.get_noise_2d(float(wx), float(wz))
	var plateau := smoothstep(PLATEAU_MIN, PLATEAU_FULL, pn) * PLATEAU_H
	var plateau_n := plateau / PLATEAU_H   # 归一化 0..1，供山脊门限复用

	# ③ 山脊：ridged（1-|n|）收尖，乘高原门限——只在「够高的高原」上长山，
	# 于是喜马拉雅/昆仑沿高原边缘铺开，不会在东部平原凭空冒雪山。
	# 门限与高原同宽（0.10..0.95）：窄门限会把山脊在平原边缘切出断崖。
	var rn := 1.0 - absf(_ridge_noise.get_noise_2d(float(wx), float(wz)))
	var ridge_gate := smoothstep(RIDGE_GATE, RIDGE_GATE_FULL, plateau_n)
	var ridge := pow(rn, RIDGE_SHARP) * RIDGE_H * ridge_gate

	# ④ 长江/黄河：各向异性输入的 |rv| 越小越接近河心。下切量随高原归一化
	# 高度递减——平原段切到海面以下（成为有水的大河），高原段只切出
	# 宽谷（切太深会让高原到处是无水峡谷，反而不像江河源头）。
	var rv := _river_noise.get_noise_2d(
		float(wx) * RIVER_ANISO_X, float(wz) * RIVER_ANISO_Z)
	var river := 1.0 - smoothstep(RIVER_T0, RIVER_T1, absf(rv))
	var cut := RIVER_CUT * (1.0 - plateau_n) * river

	var layered := base_h + plateau + ridge - cut
	# ① 平整保护区：机场 / 村庄 / 降落场必须回到丘陵基底——高山会顶掉机场
	# 选址（山顶只有一格可站，上方凑不出四格空气），村庄整平区也不能变悬崖。
	# 但**必须有渐变边缘**：早期用 `if in_rect: return base_h` 硬否决，结果
	# 区外紧邻的 196 格山脊与区内 30 格平原一步相接，实测单步落差 162 格
	# （81m）——玩家在机场外就是一道空气墙，飞机撞上必解体。
	# 改为按「到保护区边界的距离」在 FLAT_FEATHER 内平滑压回基底：
	# 区内权重 0（完全平坦），边缘 FLAT_FEATHER 格内线性升到 1。
	return lerpf(base_h, layered, _flat_weight(wx, wz))


## 平整保护区权重：区内 0（纯基底），FLAT_FEATHER 格的边缘渐变带内升到 1。
## 多个保护区取最小权重（离任一区越近压得越狠）。
func _flat_weight(wx: int, wz: int) -> float:
	var w := 1.0
	for zone in _flat_zones():
		var r: Rect2i = zone
		# 到矩形的距离：区内为 0，恰好在边上也是 0，出界后按格递增。
		var dx := maxi(maxi(r.position.x - wx, wx - r.end.x), 0)
		var dz := maxi(maxi(r.position.y - wz, wz - r.end.y), 0)
		var dist := maxi(dx, dz)          # 切比雪夫距离：边缘是方形的
		if dist <= 0:
			return 0.0
		w = minf(w, clampf(float(dist) / float(FLAT_FEATHER), 0.0, 1.0))
	return w


## 当前区域的平整保护区（Rect2i 列表，格坐标）。未配置的区域返回空数组。
func _flat_zones() -> Array[Rect2i]:
	if _flat_zone_cache.size() > 0 or _flat_zone_loaded:
		return _flat_zone_cache
	_flat_zone_loaded = true
	var raw: Array = _profile.get("flat_zones", [])
	for z in raw:
		var quad: Array = z
		if quad.size() != 4:
			continue
		_flat_zone_cache.append(Rect2i(
			Vector2i(int(quad[0]), int(quad[1])),
			Vector2i(int(quad[2]), int(quad[3]))))
	return _flat_zone_cache


## 河心强度（0 = 陆地，1 = 河心）。与 _layered_height 的 ④ 用同一噪声与
## 同一各向异性缩放，保证「高度切下去的地方」与「材质换成河床的地方」
## 严格同源，不会出现切了谷却铺草、或铺了砾石却没切河的错位。
func _river_strength(wx: int, wz: int) -> float:
	if String(_profile.get("terrain", "")) != "layered":
		return 0.0
	for zone in _flat_zones():
		var r: Rect2i = zone
		var dx := maxi(maxi(r.position.x - wx, wx - r.end.x), 0)
		var dz := maxi(maxi(r.position.y - wz, wz - r.end.y), 0)
		if dx <= 0 and dz <= 0:
			return 0.0   # 保护区内不画河：机场/村庄必须踩在干地上
	var rv := _river_noise.get_noise_2d(
		float(wx) * RIVER_ANISO_X, float(wz) * RIVER_ANISO_Z)
	return 1.0 - smoothstep(RIVER_T0, RIVER_T1, absf(rv))


## 分层地表材质（D-055）：返回 Vector2i(表层, 地下三格)。
## classic 区域直接给 profile 值；layered 区域先按高度换材质
## （>SNOW_LINE 积雪 / >ROCK_LINE 裸岩），再按河心强度换河床砾石与
## 两岸草甸。_generate_chunk 与 _block_at 共用本函数，保证「战术地图上
## 看到的颜色」与「世界里踩到的方块」永远同源，不会各算一套。
func _surface_ids(wx: int, wz: int, height: int) -> Vector2i:
	var low_line := int(_profile.get("low_line", SEA_LEVEL))
	var high := height > low_line
	var surface: int = int(_profile.get("surface", BlockTypes.Block.GRASS)) if high \
		else int(_profile.get("surface_low", BlockTypes.Block.SAND))
	var sub: int = int(_profile.get("sub", BlockTypes.Block.DIRT)) if high \
		else int(_profile.get("sub_low", BlockTypes.Block.SAND))
	if String(_profile.get("terrain", "")) != "layered":
		return Vector2i(surface, sub)
	var river := _river_strength(wx, wz)
	if river > 0.78:
		# 河床：砾石比沙更"河滩"，也更容易和沙地区分
		return Vector2i(BlockTypes.Block.GRAVEL, BlockTypes.Block.GRAVEL)
	if river > 0.34:
		# 河岸草甸：冲积土
		return Vector2i(BlockTypes.Block.GRASS, BlockTypes.Block.DIRT)
	if height > SNOW_LINE:
		return Vector2i(BlockTypes.Block.SNOW, BlockTypes.Block.SNOW)
	if height > ROCK_LINE:
		# 裸岩坡：雪线以下的山体，比石头暗一度，远看有"岩层"感
		return Vector2i(BlockTypes.Block.ROCK, BlockTypes.Block.ROCK)
	return Vector2i(surface, sub)


## 地表材质由区域配置决定：高于 low_line 用 surface，低于等于则用 surface_low。
## 例如非洲低地为沙（沙漠）、高地长草；两极一律为雪。地下三格同理。
## 水体策略（D-028）：dry 沙漠洼地不留河塘；iceberg 极地海面封冻成冰、
## 噪声成团处隆起从海底长到海面之上的冰山（顶面积雪）。
## D-055：地表/地下材质改走 _surface_ids，与区块数据生成严格同源。
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
	var ids := _surface_ids(wx, wz, height)
	if wy == height:
		return ids.x
	if wy >= height - 3:
		return ids.y
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
			# D-055 树线：高于此高度不长树。雪线附近长树既不合直觉，也会让
			# 8 格树干 + 树冠戳到盘外（山脊可到 212，加树冠就 232，逼近上限）。
			var tree_line := float(_profile.get("tree_line", TREE_LINE_DEFAULT))
			if height > tree_line:
				continue
			# 河心不长树：树干泡在水里很违和（河岸 river<0.34 处长满才像样）。
			if _river_strength(wx, wz) > 0.34:
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
