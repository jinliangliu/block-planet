extends Node3D
class_name LowTerrain
## 低模环（D-064，128 km 大世界 P2 双环加载）。
##
## 高模方块环（半径 World.LOAD_RADIUS = 4 区块 = 64 m）之外，到
## World.LOW_RADIUS（16 区块 = 256 m）由本模块的「高度图粗网格」填充：
##   · 每 World.LOW_GROUP_CHUNKS（4）个区块合并成一组 = 64×64 格 = 64 m
##   · 每 World.LOW_SAMPLE（4）格采样一个高度 → 17×17 顶点
##   · 顶点色取自 World.surface_color_at（与方块地表同源）
##   · 无方块数据、无碰撞体、不投影——纯视觉占位
## 它存在的唯一理由：高模环只有 64 m 视野，再远就是虚空；而高模单块冷加载
## 实测 41 ms，把高模环推到 256 m 需要 4000 块（不可行）。粗网格一组只花
## 几毫秒，用 4 m 精度换 4 倍视野半径。
##
## 接缝：采样步长 4 且组边界落在 16 的倍数上，区块边界必然在采样网格上，
## 故低模与高模在接缝线上高度逐点相等（两边都读 World.get_surface_height）。
## 顶点 y 取 max(地表, SEA_LEVEL)——海底地形要被抬到海面，否则海是一个个深坑。
##
## 坐标约定：MeshInstance3D.position = 组的世界原点，顶点是组内局部坐标
## （0..64），两者相加才是世界坐标。节点自身 position 恒为 0，浮动原点搬迁
## 由父节点 World（position = −origin）负责。

## 组边长（格）= World.LOW_GROUP_CHUNKS × World.CHUNK_SIZE.x。用字面量而非
## 跨类 const：world.gd 引用 LowTerrain、LowTerrain 再引用 World 的 const
## 会构成循环依赖（GDScript 解析期报错），故此处写字面量并在 setup() 里断言
## 与 World 常量一致。
const GROUP_BLOCKS := 64
const SAMPLE := 4
const N := GROUP_BLOCKS / SAMPLE + 1   # 17：顶点每轴个数（含两侧共享边）

var _world: World
var _material: StandardMaterial3D
var _groups: Dictionary[Vector2i, MeshInstance3D] = {}
## 整组落在高模方形内、因此不出网格的组（每次跳过高模半径变化即清空）。
## 单独记一份：否则这些组每帧都被判成「缺失 → 重建」，白烧采样。
var _empty: Dictionary[Vector2i, bool] = {}
## 上次生效的签名：中心区块 + 高模跳过半径。相同则整次调用直接返回 0。
var _sig_center := Vector2i(1 << 30, 1 << 30)
var _sig_skip := -1


func setup(world: World) -> void:
	_world = world
	position = Vector3.ZERO
	if GROUP_BLOCKS != World.LOW_GROUP_CHUNKS * World.CHUNK_SIZE.x:
		push_error("LowTerrain: GROUP_BLOCKS 与 World.LOW_GROUP_CHUNKS/CHUNK_SIZE 不一致")
	if SAMPLE != World.LOW_SAMPLE:
		push_error("LowTerrain: SAMPLE 与 World.LOW_SAMPLE 不一致")
	if _material != null:
		return
	# 顶点色当反照率：颜色已在采样时转线性（瓦片色是 sRGB），故此处 albedo
	# 保持白色不再着色。默认 per-pixel 光照——低模要吃昼夜光照与雾，才不像
	# 一块贴在地平线上的贴图。
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.albedo_color = Color(1.0, 1.0, 1.0)
	_material.roughness = 1.0
	_material.metallic = 0.0
	_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED


## 按需增删/重建组，返回本次实际重建的组数。
## center_chunk：玩家所在**世界**区块；skip_radius：该半径方形内的方块由高模
## Chunk 负责，低模必须跳过这些 quad——否则 4 m 粗网格会从精细地形里穿出来。
func update_window(center_chunk: Vector2i, skip_radius: int) -> int:
	if _world == null:
		return 0
	if center_chunk == _sig_center and skip_radius == _sig_skip:
		return 0
	var old_center := _sig_center
	var skip_changed := skip_radius != _sig_skip
	_sig_center = center_chunk
	_sig_skip = skip_radius

	var span := World.LOW_RADIUS / World.LOW_GROUP_CHUNKS
	var gc := _group_of_chunk(center_chunk)
	var want := {}
	for gx in range(gc.x - span - 1, gc.x + span + 2):
		for gz in range(gc.y - span - 1, gc.y + span + 2):
			var g := Vector2i(gx, gz)
			if _group_in_window(g, center_chunk):
				want[g] = true

	# 出窗组释放
	var drop: Array[Vector2i] = []
	for key: Vector2i in _groups:
		if not want.has(key):
			drop.append(key)
	for key in drop:
		var old: MeshInstance3D = _groups[key]
		_groups.erase(key)
		old.queue_free()
	for key: Vector2i in _empty.keys():
		if not want.has(key):
			_empty.erase(key)

	# 建/重建：新入窗的组 + 跳过集合受影响的组（新旧中心各判一次——旧中心
	# 那边被裁掉的 quad 要补回来，否则走一步就永久缺一块）。
	var built := 0
	# 跳过高模半径变化（登机/下机）会让「整组被覆盖」的判定整体作废，先清账
	# 再建，否则陈旧记录会让本该出网格的组一直空着。
	if skip_changed:
		_empty.clear()
	var skip_block := float((skip_radius + 1) * World.CHUNK_SIZE.x)
	for key: Vector2i in want:
		var known := _groups.has(key) or _empty.has(key)
		if known and not skip_changed:
			var origin := _group_origin(key)
			var near_new := _rect_touch(origin, skip_block, center_chunk)
			var near_old := _rect_touch(origin, skip_block, old_center)
			if not near_new and not near_old:
				continue
		var mi: MeshInstance3D = _build_group(key, center_chunk, skip_radius)
		if _groups.has(key):
			var old_mi: MeshInstance3D = _groups[key]
			_groups.erase(key)
			old_mi.queue_free()
		if mi == null:
			_empty[key] = true
		else:
			_empty.erase(key)
			_groups[key] = mi
		built += 1
	return built


func group_count() -> int:
	return _groups.size()


func total_vertices() -> int:
	var n := 0
	for mi: MeshInstance3D in _groups.values():
		if mi.mesh != null and mi.mesh.get_surface_count() > 0:
			n += mi.mesh.surface_get_array_len(0)
	return n


## 该列在低模里的高度（= max(地表顶面, 海平面)）——探针与自检的比对口径。
func sample_height(wx: int, wz: int) -> int:
	if _world == null:
		return 0
	return maxi(_world.get_surface_height(wx, wz), World.SEA_LEVEL)


# ── 内部 ────────────────────────────────────────────────────────────────

func _group_of_chunk(chunk: Vector2i) -> Vector2i:
	var per := World.LOW_GROUP_CHUNKS
	return Vector2i(floori(float(chunk.x) / float(per)), floori(float(chunk.y) / float(per)))


func _group_origin(g: Vector2i) -> Vector3:
	return Vector3(float(g.x * GROUP_BLOCKS), 0.0, float(g.y * GROUP_BLOCKS))


## 组矩形是否与「中心 ±LOW_RADIUS 区块」的窗口方形相交。
func _group_in_window(g: Vector2i, center: Vector2i) -> bool:
	var reach := float(World.LOW_RADIUS * World.CHUNK_SIZE.x)
	var cx := float(center.x * World.CHUNK_SIZE.x)
	var cz := float(center.y * World.CHUNK_SIZE.x)
	var origin := _group_origin(g)
	return origin.x <= cx + reach and origin.x + float(GROUP_BLOCKS) >= cx - reach \
		and origin.z <= cz + reach and origin.z + float(GROUP_BLOCKS) >= cz - reach


## 组矩形是否贴到「以 center 为心、半径 skip_block 格」的高模方形。
func _rect_touch(origin: Vector3, skip_block: float, center: Vector2i) -> bool:
	var cx := float(center.x * World.CHUNK_SIZE.x)
	var cz := float(center.y * World.CHUNK_SIZE.x)
	return origin.x <= cx + skip_block and origin.x + float(GROUP_BLOCKS) >= cx - skip_block \
		and origin.z <= cz + skip_block and origin.z + float(GROUP_BLOCKS) >= cz - skip_block


func _build_group(g: Vector2i, center: Vector2i, skip_radius: int) -> MeshInstance3D:
	var gx := g.x * GROUP_BLOCKS
	var gz := g.y * GROUP_BLOCKS
	# 高模方形（右开区间）：中心格落在里面就跳过该 quad。
	var skip_block := float((skip_radius + 1) * World.CHUNK_SIZE.x)
	var cx := float(center.x * World.CHUNK_SIZE.x)
	var cz := float(center.y * World.CHUNK_SIZE.x)
	var hi_min_x := cx - skip_block
	var hi_max_x := cx + skip_block
	var hi_min_z := cz - skip_block
	var hi_max_z := cz + skip_block

	var heights := PackedFloat32Array()
	heights.resize(N * N)
	var colors := PackedColorArray()
	colors.resize(N * N)
	for j in N:
		for i in N:
			var wx := gx + i * SAMPLE
			var wz := gz + j * SAMPLE
			var slot := j * N + i
			# 地表顶面（真值）与低模高度（海底抬到海面，否则海是深坑）分开算：
			# 取色要用**真**地形高度（地表材质有雪线/岩线/河床分档），不能
			# 用被 SEA_LEVEL 抬升过的那个。
			var surf := _world.get_surface_height(wx, wz)
			heights[slot] = float(maxi(surf, World.SEA_LEVEL))
			# 直接复用刚算出的高度：地形高度在分层区域每列约 13 μs，重复算
			# 一遍会让单组成本从 ~7 ms 涨到 ~11 ms。
			colors[slot] = _world.surface_color_at_height(wx, wz, surf - 1).srgb_to_linear()

	var verts := PackedVector3Array()
	verts.resize(N * N)
	var normals := PackedVector3Array()
	normals.resize(N * N)
	var idx := PackedInt32Array()
	for j in N:
		for i in N:
			var slot := j * N + i
			verts[slot] = Vector3(float(i * SAMPLE), heights[slot], float(j * SAMPLE))
			# 顶点法线由邻格高度差算（中心差分，边界退化为单侧）：比全朝上
			# 更能体现丘陵起伏，也让低模在侧光下有明暗层次。
			var hl := heights[j * N + maxi(i - 1, 0)]
			var hr := heights[j * N + mini(i + 1, N - 1)]
			var hu := heights[maxi(j - 1, 0) * N + i]
			var hd := heights[mini(j + 1, N - 1) * N + i]
			normals[slot] = Vector3(hl - hr, 2.0 * float(SAMPLE), hu - hd).normalized()
	# 索引：每格两个三角形，绕向沿用 Chunk 的约定（正方向面 (0,1,3)(0,3,2)）：
	# 角点顺序 [p00, p10, p01, p11] 时三角形为 (p00,p10,p11) 与 (p00,p11,p01)。
	for j in range(N - 1):
		for i in range(N - 1):
			var mid_x := float(gx + i * SAMPLE + SAMPLE / 2)
			var mid_z := float(gz + j * SAMPLE + SAMPLE / 2)
			if mid_x >= hi_min_x and mid_x < hi_max_x and mid_z >= hi_min_z and mid_z < hi_max_z:
				continue
			var a := j * N + i
			var b := j * N + i + 1
			var c := (j + 1) * N + i + 1
			var d := (j + 1) * N + i
			idx.append(a)
			idx.append(b)
			idx.append(c)
			idx.append(a)
			idx.append(c)
			idx.append(d)

	if idx.is_empty():
		# 整组被高模环覆盖：不建网格（调用方记入 _empty，不留空节点）。
		return null
	var mi := MeshInstance3D.new()
	mi.position = _group_origin(g)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _material)
	mi.mesh = mesh
	add_child(mi)
	return mi
