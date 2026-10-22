extends Node3D
class_name LowTerrain
## 低模环（ADR D-064，128 km 大世界双环加载）：高模区块环之外的远景地形。
##
## 定位——**纯视觉占位**：高模方块环（World.LOAD_RADIUS = 4 区块 = 64 m）之外，
## 到 World.LOW_RADIUS（16 区块 = 256 m）由本模块的「高度图粗网格」填充。
##   · 每 World.LOW_GROUP_CHUNKS（4）个区块合并成一组 = 64×64 格
##   · 每 World.LOW_SAMPLE（4）格采样一个高度 → 17×17 顶点
##   · 顶点色取 World.surface_color_at_height（与方块地表上色同源）
##   · 没有方块数据、没有碰撞体、不投影——挖不到也撞不到
## 它存在的唯一理由：高模环只有 64 m 视野，再远就是虚空；而高模单块冷加载
## 实测 41 ms，把高模环推到 256 m 需要 4000 块（不可行）。粗网格一组实测
## 5~8 ms（平原）/ 最坏 ~16 ms（雪山组），用 4 格精度换 4 倍视野半径。
##
## 接缝：采样步长 4 且组边界落在 16 的倍数上，区块边界必然落在采样网格上，
## 故低模与高模在接缝线上高度逐点相等（两边都读 World.get_surface_height）；
## 组与组之间共享一条边（顶点重复），故组缝也无缝。
## 顶点 y 取 max(地表, SEA_LEVEL)——海底要被抬到海面，否则海是一组深坑。
##
## 坐标约定：MeshInstance3D.position = 组的世界原点，顶点是组内**局部**坐标
## （0..64），两者相加才是世界坐标。本节点自身 position 恒为 0；浮动原点搬迁
## 由父节点 World（position = −origin，D-062）负责，本模块不感知 origin。
##
## 跳过规则：高模方形内的 quad 不生成（4 m 粗网格会从精细地形里穿出来，看到
## 尖刺）。判定用 quad **中心格**是否落在高模方形内，方形外扩 1 区块作为卸载
## 滞后 pad——高模刚卸载的那一圈仍按「有高模」处理，不让低模抢先冒头。

## 非法/未初始化的中心区块（不可能出现的值：合法区块远小于它）。
const INVALID_CENTER := Vector2i(0x40000000, 0x40000000)
## 非法跳过区间（真实区间的 i0 恒在 0..quads-1）：用作「该组还没建过」的哨兵。
const INVALID_SPAN := Vector4i(0x40000000, 0, 0, 0)

## 地表高度/颜色的真相来源（纯噪声，不依赖区块是否加载）。
var _world: World
## 全组共享材质：顶点色当反照率，per-pixel 光照。
var _material: StandardMaterial3D
## 组缓存：组坐标 → MeshInstance3D。整组被高模覆盖时**不入表**（不留空节点）。
var _groups: Dictionary[Vector2i, MeshInstance3D] = {}
## 每个窗口组「已应用的跳过区间」：增量判定的唯一依据。
## 与 _groups 分开存，是为了让「整组被跳过、没有网格」的组同样能判定为已处理
## ——否则每次中心平移都会重采样这些组（白烧采样，一组约 6 ms）。
var _ranges: Dictionary[Vector2i, Vector4i] = {}
## 采样缓存：组坐标 → [PackedInt32Array 高度, PackedColorArray 顶点色]。
## 只随「组进出窗口」失效（出窗即释放，故占用恒为窗口内组数 ≈ 81 组 × 5.8 KB
## ≈ 470 KB）。存在的价值：高模方形平移时只有**索引**变了，高度与颜色完全没变，
## 有缓存就能把一次「跳过区间变化」的重建从 ~5 ms 降到 ~0.4 ms。
var _samples: Dictionary[Vector2i, Array] = {}
## 采样缓存对应的地形身份（区域 id + 种子）：World.set_region 或有人直接改
## `seed_value` 再 `_configure_noise()` 时，地形换了而组坐标没变，缓存必须作废
## （正常路径切区域会重载主场景、连带重建本节点，这里是兜底）。
var _cached_region := -1
var _cached_seed := -(1 << 30)
## 上次生效的窗口签名：中心区块 + 高模跳过半径。相同则整次调用直接返回 0。
var _last_center := INVALID_CENTER
var _last_skip := -1
## 组尺寸（setup 时从 World 常量推导）。
## 不用 const 推导：world.gd 引用 LowTerrain（var _low_terrain: LowTerrain），
## LowTerrain 再在 const 初始化期引用 World 的常量会构成解析期循环依赖，
## GDScript 会直接报错。改成运行时推导后，既没有抄来的字面量，也不会不一致。
var _blocks := 0       # 组边长（格）
var _grid := 0         # 每轴顶点数（含两侧共享边）
var _quads := 0        # 每轴 quad 数


## 存 world 引用并建材质。可重复调用（幂等）：材质只建一次；
## 仅当换了一个 World 实例才清空组缓存（高度/颜色来源变了，旧网格必然作废）。
func setup(world: World) -> void:
	if _world != null and _world != world:
		_clear_all()
	_world = world
	position = Vector3.ZERO
	_blocks = World.LOW_GROUP_CHUNKS * World.CHUNK_SIZE.x
	_grid = int(float(_blocks) / float(World.LOW_SAMPLE)) + 1
	_quads = _grid - 1
	if _material != null:
		return
	var mat := StandardMaterial3D.new()
	# 顶点色即反照率：粗网格没有 UV、没有纹理，逐顶点色是唯一的上色来源。
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1, 1, 1)
	# 顶点色在构建期已转线性（图集瓦片色是 sRGB），故这里必须保持 false，
	# 否则引擎再转一次 → 整体偏暗。
	mat.vertex_color_is_srgb = false
	# 绕向已保证正面朝上，保持默认背面剔除：省一半片元开销，且从地形下方
	# 看不到低模（玩家不会钻到地形底下）。
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	# 默认 per-pixel 光照（不开 unshaded）：远景要吃昼夜/天气的方向光与雾，
	# 否则会像一块贴在地平线上的贴图。
	_material = mat


## 按需增删/重建组，返回本次**实际重建（生成了网格）的组数**。
## center_chunk：玩家所在**世界**区块；skip_radius：该半径方形内的方块由高模
## Chunk 负责（调用方传 World.LOAD_RADIUS，飞行时传更保守的偏置窗口尺寸）。
func update_window(center_chunk: Vector2i, skip_radius: int) -> int:
	if _world == null or _grid <= 1:
		return 0
	# 地形身份变了（区域配置或种子）：采样缓存与全部网格作废，本次重来一遍。
	# 种子也要比：`seed_value` 是 @export，运行时被改后再 _configure_noise() 会让
	# 地形整个变样而区域 id 不变——只比 region 会把旧高度的缓存继续喂给新地形。
	var region := _world.get_region()
	var seed_now := _world.seed_value
	if region != _cached_region or seed_now != _cached_seed:
		_cached_region = region
		_cached_seed = seed_now
		_clear_all()
	if center_chunk == _last_center and skip_radius == _last_skip:
		return 0

	var rebuild_all := skip_radius != _last_skip
	var high := _high_rect(center_chunk, skip_radius)
	var window := _window_rect(center_chunk)

	# 1) 出窗的组连同签名与采样缓存一起释放（先收集再删，避免边遍历边改字典）。
	var stale: Array[Vector2i] = []
	for key: Vector2i in _ranges.keys():
		if not window.has_point(key):
			stale.append(key)
	for key: Vector2i in _groups.keys():
		if not window.has_point(key) and not stale.has(key):
			stale.append(key)
	for key: Vector2i in stale:
		_ranges.erase(key)
		_samples.erase(key)
		_drop_mesh(key)

	# 2) 补齐窗口内的组。只在三种情况重建：
	#    · 组还没处理过（新进入窗口）；
	#    · skip_radius 变了（全量重建，只在登机/下机时发生）；
	#    · 该组的**跳过区间**变了（高模方形随中心平移，边缘组的缺口位置会变）。
	#    只比「跳过 quad 数」是不够的：区间可能整体平移而数量不变。
	var rebuilt := 0
	for gz in range(window.position.y, window.end.y):
		for gx in range(window.position.x, window.end.x):
			var key := Vector2i(gx, gz)
			var span := _skip_span(key, high)
			var prev: Vector4i = _ranges.get(key, INVALID_SPAN)
			if not rebuild_all and prev == span:
				continue
			_ranges[key] = span
			_drop_mesh(key)
			var node := _build_group(key, span)
			if node != null:
				_groups[key] = node
				rebuilt += 1

	_last_center = center_chunk
	_last_skip = skip_radius
	return rebuilt


## 当前持有网格的组数（整组被高模覆盖的组不计）。
func group_count() -> int:
	return _groups.size()


## 当前所有组的顶点数合计（探针用口径：每组建 17×17 个顶点，被跳过 quad
## 独占的顶点不进索引、GPU 不处理，故不需要压缩）。
func total_vertices() -> int:
	var total := 0
	for node: MeshInstance3D in _groups.values():
		if is_instance_valid(node) and node.mesh != null and node.mesh.get_surface_count() > 0:
			total += node.mesh.surface_get_array_len(0)
	return total


## 该列在低模里的高度（= max(地表顶面, 海平面)）：探针与自检的比对口径。
func sample_height(wx: int, wz: int) -> int:
	if _world == null:
		return World.SEA_LEVEL
	return maxi(_world.get_surface_height(wx, wz), World.SEA_LEVEL)


# ── 窗口与跳过区间 ──────────────────────────────────────────────────────

## 组矩形（组坐标，右开区间）：覆盖「center_chunk 为心、半径 LOW_RADIUS 区块」
## 的方形窗口。组号由区块端点 floori 换算而来，故首尾组会跨出窗口一点点
## ——保留：宁可多建一组，也不在 256 m 处留一条缺口。
func _window_rect(center_chunk: Vector2i) -> Rect2i:
	var sx := World.CHUNK_SIZE.x
	var sz := World.CHUNK_SIZE.z
	var lo := (center_chunk - Vector2i(World.LOW_RADIUS, World.LOW_RADIUS)) * Vector2i(sx, sz)
	var hi := (center_chunk + Vector2i(World.LOW_RADIUS, World.LOW_RADIUS)) * Vector2i(sx, sz)
	var gx0 := floori(float(lo.x) / float(_blocks))
	var gz0 := floori(float(lo.y) / float(_blocks))
	var gx1 := floori(float(hi.x) / float(_blocks))
	var gz1 := floori(float(hi.y) / float(_blocks))
	return Rect2i(gx0, gz0, gx1 - gx0 + 1, gz1 - gz0 + 1)


## 高模方形（格坐标，右开区间）：该方形内的列由高模 Chunk 负责，低模跳过。
## 外扩 1 区块是卸载滞后 pad（与 World.UNLOAD_PAD 同思路）：高模刚卸载的那圈
## 仍算「有高模」，低模不许从那圈里冒出来。
func _high_rect(center_chunk: Vector2i, skip_radius: int) -> Rect2i:
	var pad := skip_radius + 1
	var sx := World.CHUNK_SIZE.x
	var sz := World.CHUNK_SIZE.z
	var lo := (center_chunk - Vector2i(pad, pad)) * Vector2i(sx, sz)
	var hi := (center_chunk + Vector2i(pad, pad)) * Vector2i(sx, sz)
	return Rect2i(lo.x, lo.y, hi.x - lo.x, hi.y - lo.y)


## 该组需要跳过的 quad 区间，返回 Vector4i(i0, i1, j0, j1)（闭区间）。
## i1 < i0 表示空区间（整组都要画）。
## 跳过集合在 (i, j) 空间恒为矩形：判定只依赖各自的坐标轴，两轴互不影响，
## 因此不必逐格测试 16×16 个 quad。
func _skip_span(key: Vector2i, high: Rect2i) -> Vector4i:
	if high.size.x <= 0 or high.size.y <= 0:
		return Vector4i(0, -1, 0, -1)
	var gx := key.x * _blocks
	var gz := key.y * _blocks
	var step := float(World.LOW_SAMPLE)
	var off := float(World.LOW_SAMPLE) * 0.5   # quad 中心相对左上角的偏移
	# quad 中心格 = gx + i*step + off，要求 high.position <= 中心 < high.end
	var i0 := clampi(ceili(float(high.position.x - gx) / step - off / step), 0, _quads)
	var i1 := clampi(floori(float(high.end.x - gx - 1) / step - off / step), -1, _quads - 1)
	var j0 := clampi(ceili(float(high.position.y - gz) / step - off / step), 0, _quads)
	var j1 := clampi(floori(float(high.end.y - gz - 1) / step - off / step), -1, _quads - 1)
	# 空区间必须**归一化**成同一个值（含「两轴任一为空即整组无跳过」）：
	# 否则「本组在方形左侧（i 空）」「在右侧」「在上方（j 空）」会得到数值不同
	# 但语义相同的区间，增量判定就会把它们当成「变了」而整片重建
	# （实测：归一化前每次中心平移重建 43 组/220 ms，之后 23 组/73 ms）。
	if i1 < i0 or j1 < j0:
		return Vector4i(0, -1, 0, -1)
	return Vector4i(i0, i1, j0, j1)


static func _in_span(span: Vector4i, i: int, j: int) -> bool:
	return i >= span.x and i <= span.y and j >= span.z and j <= span.w


# ── 组构建 ──────────────────────────────────────────────────────────────

## 构建一组；整组被跳过的 quad 覆盖时返回 null（不留空 MeshInstance3D）。
func _build_group(key: Vector2i, span: Vector4i) -> MeshInstance3D:
	var gx := key.x * _blocks
	var gz := key.y * _blocks
	var step := World.LOW_SAMPLE
	var n := _grid * _grid
	# 整组被覆盖：连采样都不做（这是低模环最省的一条路径）。
	if span.y >= span.x and span.w >= span.z:
		if (span.y - span.x + 1) * (span.w - span.z + 1) >= _quads * _quads:
			return null

	# ── 采样：每顶点 1 次地形高度 + 1 次取色（首次建该组时做，之后走缓存）─────
	# 取色用 surface_color_at_height 传入刚算好的地形高度：分层区域每列的地形
	# 高度要叠十几个噪声（含限坡松弛），重复算一遍会让单组从 ~5 ms 涨到 ~11 ms。
	# 传 surf-1 是因为 get_surface_height 返回的是地表**顶面** y（= 地形高度+1），
	# 而材质分档（雪线/岩线/河床）用的是地形高度本身。
	var heights: PackedInt32Array
	var colors: PackedColorArray
	var cached: Array = _samples.get(key, [])
	if cached.is_empty():
		heights = PackedInt32Array()
		heights.resize(n)
		colors = PackedColorArray()
		colors.resize(n)
		for j in _grid:
			var wz := gz + j * step
			var row := j * _grid
			for i in _grid:
				var wx := gx + i * step
				var slot := row + i
				var surf := _world.get_surface_height(wx, wz)
				# 海底抬到海面：不抬的话海面就是一组深坑（低模最常见的丑陋错误）。
				heights[slot] = maxi(surf, World.SEA_LEVEL)
				# 瓦片主色是 sRGB，而顶点色按反照率参与线性光照 → 必须转线性，
				# 否则整体偏亮泛白。
				colors[slot] = _world.surface_color_at_height(wx, wz, surf - 1).srgb_to_linear()
		_samples[key] = [heights, colors]
	else:
		heights = cached[0]
		colors = cached[1]

	# ── 顶点与法线（局部坐标 0..blocks，y 用绝对高度）────────────────────
	# 顶点全部保留（17×17），只裁索引：被跳过 quad 独占的顶点没有任何索引
	# 引用，GPU 按索引驱动顶点变换，因此不处理它们——不需要压缩顶点。
	var verts := PackedVector3Array()
	verts.resize(n)
	var normals := PackedVector3Array()
	normals.resize(n)
	var fstep := float(step)
	for j in _grid:
		var row := j * _grid
		var jl := maxi(j - 1, 0)
		var jr := mini(j + 1, _grid - 1)
		var dz := float(jr - jl) * fstep
		for i in _grid:
			var slot := row + i
			verts[slot] = Vector3(float(i * step), float(heights[slot]), float(j * step))
			# 高度图 y = h(x,z) 的法线：中心差分；边界退化为一侧差分，且跨度按
			# 实际取到的邻居数归一——否则边界法线斜率差 2 倍，组缝会出现明暗带。
			var il := maxi(i - 1, 0)
			var ir := mini(i + 1, _grid - 1)
			var dhx := float(heights[row + ir] - heights[row + il]) / (float(ir - il) * fstep)
			var dhz := float(heights[jr * _grid + i] - heights[jl * _grid + i]) / dz
			normals[slot] = Vector3(-dhx, 1.0, -dhz).normalized()

	# ── 索引：每 quad 两个三角形 ─────────────────────────────────────────
	var total_quads := _quads * _quads
	var skipped := 0
	if span.y >= span.x and span.w >= span.z:
		skipped = (span.y - span.x + 1) * (span.w - span.z + 1)
	var indices := PackedInt32Array()
	indices.resize((total_quads - skipped) * 6)
	var w := 0
	for j in _quads:
		for i in _quads:
			if _in_span(span, i, j):
				continue
			var a := j * _grid + i          # 左上
			var b := a + 1                  # 右上
			var d := a + _grid              # 左下
			var c := d + 1                  # 右下
			# Godot 正面 = 从外侧看的**顺时针**，故按「左上 → 右上 → 右下 → 左下」
			# 给角点、索引 (0,1,2, 0,2,3)。等价于 Chunk.gd 顶面的 (0,1,3, 0,3,2)
			# （同一四边形的不同枚举），两者朝向一致——绕反的话整片地形会从
			# 上方看不见（只看到背面被剔除后的虚空）。
			indices[w] = a
			indices[w + 1] = b
			indices[w + 2] = c
			indices[w + 3] = a
			indices[w + 4] = c
			indices[w + 5] = d
			w += 6
	if w == 0:
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material)

	var node := MeshInstance3D.new()
	node.name = "Low_%d_%d" % [key.x, key.y]
	node.mesh = mesh
	# 位置直接用世界坐标：父节点 LowTerrain 挂在 World 下，World 的
	# position = −origin 负责整体平移，本模块不感知 origin。
	node.position = Vector3(float(gx), 0.0, float(gz))
	# 远景投影没意义：关掉阴影投射（省一遍阴影 pass 的顶点处理）。
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


func _drop_mesh(key: Vector2i) -> void:
	var node: MeshInstance3D = _groups.get(key)
	_groups.erase(key)
	if not is_instance_valid(node):
		return
	# 先摘再加队列：同一帧内新旧网格不并存（重叠面会因 z-fighting 闪一下）。
	if node.get_parent() == self:
		remove_child(node)
	node.queue_free()


func _clear_all() -> void:
	for key: Vector2i in _groups.keys():
		_drop_mesh(key)
	_groups.clear()
	_ranges.clear()
	_samples.clear()
	_last_center = INVALID_CENTER
	_last_skip = -1
