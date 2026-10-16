extends Node3D
class_name Chunk
## 单个竖直区块：存储方块数据，并动态构建渲染网格与碰撞体。

const SIZE := Vector3i(16, 64, 16)

const FACE_DIRS := [
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]

var data := PackedByteArray()
## 每列最高非空气格（0..63；整列为空记 255）。pristine 区块据此把面遍历的
## y 范围收窄到「地表 + 树冠 + 水面」这一薄层：地形是无洞穴的高度图，
## 地表以下的格子六面皆实心不透明，既不产生渲染面也不产生碰撞面——平坦
## 地形下每列只需扫 2 层而不是 64 层。
var col_top := PackedByteArray()
## 每列最高的「不透明实心格」（水/冰等透明块不计，空列记 255）。列扫描的
## 下界由它决定：只有相邻列在该高度以上才有可能是空气或透明块、让本列侧向
## 暴露；再往下本格与四邻皆不透明实心，六面皆被遮住。
var col_ground := PackedByteArray()
## 未被玩家或结构改动过。一旦 set_block_local 写入（挖掘、建筑、村庄/机场
## 铺设），列结构不再由高度图决定，退回全量遍历。
var pristine := true
## 重建用的列顶扩展表（含四邻贴边那一列，255 = 未知）。由 World 在每次
## rebuild 前刷新；为空即走全量遍历。挂在区块上而非走参数，是为了让
## 「取表 + 重建」成为一个整体，调用方不必关心。
var tops_ext := PackedByteArray()
var grounds_ext := PackedByteArray()

var _mesh_instance: MeshInstance3D
var _emissive_mesh_instance: MeshInstance3D
var _collision_body: StaticBody3D
# 越界邻居查询回调，由 World 注入（get_block），用于跨界面的正确剔除。
var _neighbor_lookup := Callable()


func _init() -> void:
	data.resize(SIZE.x * SIZE.y * SIZE.z)
	data.fill(BlockTypes.Block.AIR)


# ── rebuild 热路径查表 ────────────────────────────────────────────────────
# 实测（tmp/perf_chunk，桌面 headless）：单个区块加载约 120 ms，其中数据生成
# 仅 19 ms、rebuild 高达 96 ms——流式加载「前方地形跟不上」的瓶颈全在这里。
# 96 ms 里绝大部分是「每格 6 次邻居函数调用 + 方块属性的字典查询」：GDScript
# 单次调用约 0.5 μs，16384 格 × 6 面就是 5 万次调用。故把方块属性与面几何
# 预计算成表，热循环内只做整数索引与 append。
# 表驱动化前后的几何输出逐值一致（顶点数/索引数/坐标和/UV 和/碰撞面顶点），
# 校验方式见 tmp/chunk_mesh_baseline 探针。
static var _solid_tab := PackedByteArray()
static var _transp_tab := PackedByteArray()
static var _nav_tab := PackedByteArray()
static var _tile_x_tab := PackedInt32Array()
static var _tile_y_tab := PackedInt32Array()
static var _tile_z_tab := PackedInt32Array()
static var _nav_color_tab: Array[Color] = []
## 面几何表（按 FACE_DIRS 顺序）：角点、三角化偏移、法线、方向分量。
static var _corner_tab: Array[PackedVector3Array] = []
static var _quad_tab: Array[PackedInt32Array] = []
static var _normal_tab: Array[Vector3] = []
static var _dir_x_tab := PackedInt32Array()
static var _dir_y_tab := PackedInt32Array()
static var _dir_z_tab := PackedInt32Array()
## 瓦片 UV 矩形表：同一瓦片在一块网格里被复用上百次，禁止逐面重算。
static var _uv_tab: Array[Rect2] = []
static var _tables_ready := false


static func _ensure_tables() -> void:
	if _tables_ready:
		return
	_tables_ready = true

	var n := 256
	for id in BlockTypes.NAMES:
		n = maxi(n, int(id) + 1)
	_solid_tab.resize(n)
	_transp_tab.resize(n)
	_nav_tab.resize(n)
	_tile_x_tab.resize(n)
	_tile_y_tab.resize(n)
	_tile_z_tab.resize(n)
	_nav_color_tab.resize(n)
	for id in n:
		var is_nav := BlockTypes.is_nav_light(id)
		var tiles: Vector3i = BlockTypes.TILES.get(id, Vector3i(0, 0, 0))
		_solid_tab[id] = 1 if BlockTypes.is_solid(id) else 0
		_transp_tab[id] = 1 if BlockTypes.is_transparent(id) else 0
		_nav_tab[id] = 1 if is_nav else 0
		_tile_x_tab[id] = tiles.x
		_tile_y_tab[id] = tiles.y
		_tile_z_tab[id] = tiles.z
		_nav_color_tab[id] = BlockTypes.nav_color(id) if is_nav else Color(0, 0, 0)

	for dir in FACE_DIRS:
		_corner_tab.append(_face_corners(dir))
		_normal_tab.append(Vector3(dir))
		_dir_x_tab.append(dir.x)
		_dir_y_tab.append(dir.y)
		_dir_z_tab.append(dir.z)
		# 与旧 _append_quad_indices 同式：正方向面取 (0,1,3)(0,3,2)，负方向面
		# 取 (0,2,3)(0,3,1)，绕向错则 ConcavePolygonShape3D 背面不碰撞。
		_quad_tab.append(
			PackedInt32Array([0, 1, 3, 0, 3, 2]) if dir.x + dir.y + dir.z > 0
			else PackedInt32Array([0, 2, 3, 0, 3, 1])
		)

	var tiles_n := TextureAtlas.ATLAS_TILES * TextureAtlas.ATLAS_TILES
	for id in BlockTypes.TILES:
		var t: Vector3i = BlockTypes.TILES[id]
		tiles_n = maxi(tiles_n, maxi(t.x, maxi(t.y, t.z)) + 1)
	_uv_tab.resize(tiles_n)
	for t in tiles_n:
		_uv_tab[t] = _tile_uv_rect(t)


## 列顶扩展表（见 tops_ext / grounds_ext 字段）由 World 在调用前刷新：
## pristine 区块据此把遍历收窄到「地表薄层」——下界取本列与四邻列的最高
## 不透明格，上界取本列最高非空气格（含树冠与水面）；非 pristine（被改动过）
## 或表缺失时退回全量遍历。两种路径的几何输出一致（由 tmp/chunk_mesh_baseline
## 的校验和比对保证）。
func rebuild(
	atlas_material: Material,
	emissive_material: Material,
	neighbor_lookup: Callable = Callable()
) -> void:
	_neighbor_lookup = neighbor_lookup
	_ensure_tables()
	var atlas_v := PackedVector3Array()
	var atlas_n := PackedVector3Array()
	var atlas_uv := PackedVector2Array()
	var atlas_i := PackedInt32Array()
	var ems_v := PackedVector3Array()
	var ems_n := PackedVector3Array()
	var ems_uv := PackedVector2Array()
	var ems_i := PackedInt32Array()
	var ems_c := PackedColorArray()
	var collide_v := PackedVector3Array()
	var collide_i := PackedInt32Array()

	var sx := SIZE.x
	var sy := SIZE.y
	var sz := SIZE.z
	var plane := sx * sz
	var gp := Vector3i(global_position)
	var lookup := _neighbor_lookup
	var has_lookup := not lookup.is_null()
	var air := BlockTypes.Block.AIR
	# 循环按列展开（z → x → y）：data 索引连续访问，且便于按列限定 y 范围。
	# 顶点产出顺序与旧实现不同但集合一致（几何等价，顶点和校验相同）。
	var ext_n := (sx + 2) * (sz + 2)
	var fast := pristine and tops_ext.size() == ext_n and grounds_ext.size() == ext_n
	var ext_w := sx + 2
	for z in sz:
		for x in sx:
			var lo := 0
			var hi := sy - 1
			if fast:
				var t := int(tops_ext[(z + 1) * ext_w + (x + 1)])
				if t == 255:
					continue  # 整列为空：既无渲染面也无碰撞面
				var g := int(grounds_ext[(z + 1) * ext_w + (x + 1)])
				var g1 := int(grounds_ext[(z + 1) * ext_w + x])
				var g2 := int(grounds_ext[(z + 1) * ext_w + (x + 2)])
				var g3 := int(grounds_ext[z * ext_w + (x + 1)])
				var g4 := int(grounds_ext[(z + 2) * ext_w + (x + 1)])
				if g == 255 or g1 == 255 or g2 == 255 or g3 == 255 or g4 == 255:
					lo = 0  # 邻列未知（邻块未加载或被改动）：保守全扫该列
				else:
					# 下界：本列与四邻列的最高不透明格。该高度以下，本格与四
					# 邻皆不透明实心，六面皆被遮；该高度以上才可能侧向暴露。
					lo = maxi(0, mini(g, mini(g1, mini(g2, mini(g3, g4)))) - 1)
				hi = t
			for y in range(lo, hi + 1):
				var z_base := y * plane + z * sx
				var id: int = data[z_base + x]
				if id == air:
					continue
				var id_solid := _solid_tab[id] == 1
				var is_nav := _nav_tab[id] == 1
				for d in 6:
					var nx := x + _dir_x_tab[d]
					var ny := y + _dir_y_tab[d]
					var nz := z + _dir_z_tab[d]
					var nid: int
					if nx >= 0 and nx < sx and ny >= 0 and ny < sy and nz >= 0 and nz < sz:
						nid = data[nx + nz * sx + ny * plane]
					elif has_lookup:
						nid = lookup.call(Vector3i(gp.x + nx, gp.y + ny, gp.z + nz))
					else:
						nid = air
					var render_face := nid == air or (_transp_tab[nid] == 1 and nid != id)
					var collide_face := id_solid and _solid_tab[nid] == 0
					# 世界底面（y=0 朝下）：其下是虚空，玩家与飞行器都到不了，
					# 既看不见也撞不上——过去每块白白生成 256 个面与同样多的
					# 碰撞三角形（约占总面数 15%）。统一不再生成。
					if y == 0 and _dir_y_tab[d] < 0:
						render_face = false
						collide_face = false
					if not render_face and not collide_face:
						continue

					var corners: PackedVector3Array = _corner_tab[d]
					if render_face:
						if is_nav:
							var base := ems_v.size()
							var col: Color = _nav_color_tab[id]
							for i in 4:
								ems_v.append(Vector3(x, y, z) + corners[i])
								ems_n.append(_normal_tab[d])
								ems_uv.append(Vector2.ZERO)
								ems_c.append(col)
							var q: PackedInt32Array = _quad_tab[d]
							for k in 6:
								ems_i.append(base + q[k])
						else:
							var tile := (
								_tile_x_tab[id] if _dir_y_tab[d] > 0
								else (_tile_y_tab[id] if _dir_y_tab[d] < 0 else _tile_z_tab[id])
							)
							var rect: Rect2 = _uv_tab[tile]
							var base := atlas_v.size()
							for i in 4:
								atlas_v.append(Vector3(x, y, z) + corners[i])
								atlas_n.append(_normal_tab[d])
								var u := lerpf(rect.position.x, rect.end.x, float(i / 2))
								var v := lerpf(rect.position.y, rect.end.y, float(i % 2))
								atlas_uv.append(Vector2(u, v))
							var q: PackedInt32Array = _quad_tab[d]
							for k in 6:
								atlas_i.append(base + q[k])
					if collide_face:
						var base := collide_v.size()
						for i in 4:
							collide_v.append(Vector3(x, y, z) + corners[i])
						var q: PackedInt32Array = _quad_tab[d]
						for k in 6:
							collide_i.append(base + q[k])

	_assign_mesh(atlas_v, atlas_n, atlas_uv, atlas_i, atlas_material)
	_assign_emissive_mesh(ems_v, ems_n, ems_uv, ems_i, ems_c, emissive_material)
	_assign_collision(collide_v, collide_i)


func get_block_local(pos: Vector3i) -> int:
	if not _in_bounds(pos):
		return BlockTypes.Block.AIR
	return data[_index(pos)]


func set_block_local(pos: Vector3i, id: int) -> void:
	if not _in_bounds(pos):
		return
	data[_index(pos)] = id
	# 任何外部写入都让「列范围快路径」失效：快路径的前提是列结构由高度图
	# 决定（地下无空洞），挖洞/建筑会打破它。
	pristine = false


## 重算每列的 col_top / col_ground（数据整块生成或覆写后调用）。自上而下扫描：
## 首个非空气格即 col_top，首个不透明实心格即 col_ground。
func compute_col_top() -> void:
	_ensure_tables()
	var sx := SIZE.x
	var sz := SIZE.z
	var plane := sx * sz
	col_top.resize(plane)
	col_ground.resize(plane)
	for z in sz:
		for x in sx:
			var top := 255
			var ground := 255
			for y in range(SIZE.y - 1, -1, -1):
				var id := data[x + z * sx + y * plane]
				if id == BlockTypes.Block.AIR:
					continue
				if top == 255:
					top = y
				if _solid_tab[id] == 1 and _transp_tab[id] == 0:
					ground = y
					break
			col_top[x + z * sx] = top
			col_ground[x + z * sx] = ground


static func _face_corners(dir: Vector3i) -> PackedVector3Array:
	var axis := 0
	if dir.y != 0:
		axis = 1
	elif dir.z != 0:
		axis = 2

	var sign_i := dir[axis]
	var t0 := (axis + 1) % 3
	var t1 := (axis + 2) % 3
	var base := Vector3.ZERO
	base = _set_axis(base, axis, 0.0 if sign_i < 0 else 1.0)

	var corners := PackedVector3Array()
	for a in [0, 1]:
		for b in [0, 1]:
			var p := base
			p = _set_axis(p, t0, float(a))
			p = _set_axis(p, t1, float(b))
			corners.append(p)
	return corners


static func _set_axis(v: Vector3, axis: int, value: float) -> Vector3:
	match axis:
		0:
			v.x = value
		1:
			v.y = value
		2:
			v.z = value
	return v


static func _tile_uv_rect(tile: int) -> Rect2:
	var cell := 1.0 / float(TextureAtlas.ATLAS_TILES)
	var col := tile % TextureAtlas.ATLAS_TILES
	var row := tile / TextureAtlas.ATLAS_TILES
	# 半像素内缩，避免采样到相邻瓦片造成图集渗色。
	var inset := 0.5 / float(TextureAtlas.TILE_SIZE * TextureAtlas.ATLAS_TILES)
	return Rect2(
		float(col) * cell + inset,
		float(row) * cell + inset,
		cell - inset * 2.0,
		cell - inset * 2.0
	)


func _assign_mesh(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array,
	material: Material
) -> void:
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		add_child(_mesh_instance)

	if vertices.is_empty():
		_mesh_instance.mesh = null
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# 逐 surface 指定材质（不跨面覆盖），与导航灯第二发光面解耦。
	mesh.surface_set_material(0, material)
	_mesh_instance.mesh = mesh


## 导航灯发光面：独立 MeshInstance + 共享 unshaded 顶点色材质，整片灯仅
## +1 draw call；颜色由顶点色逐块提供，主世界合批不受影响。
func _assign_emissive_mesh(
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array,
	colors: PackedColorArray,
	material: Material
) -> void:
	if _emissive_mesh_instance == null:
		_emissive_mesh_instance = MeshInstance3D.new()
		_emissive_mesh_instance.name = "NavLights"
		add_child(_emissive_mesh_instance)

	if vertices.is_empty():
		_emissive_mesh_instance.mesh = null
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	_emissive_mesh_instance.mesh = mesh


func _assign_collision(vertices: PackedVector3Array, indices: PackedInt32Array) -> void:
	if _collision_body == null:
		_collision_body = StaticBody3D.new()
		add_child(_collision_body)

	var shape_node: CollisionShape3D = _collision_body.get_node_or_null("CollisionShape3D")
	if shape_node == null:
		shape_node = CollisionShape3D.new()
		shape_node.name = "CollisionShape3D"
		_collision_body.add_child(shape_node)

	if vertices.is_empty():
		shape_node.shape = null
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	shape_node.shape = mesh.create_trimesh_shape()


func _index(pos: Vector3i) -> int:
	return pos.x + pos.z * SIZE.x + pos.y * (SIZE.x * SIZE.z)


func _in_bounds(pos: Vector3i) -> bool:
	return (
		pos.x >= 0
		and pos.x < SIZE.x
		and pos.y >= 0
		and pos.y < SIZE.y
		and pos.z >= 0
		and pos.z < SIZE.z
	)

