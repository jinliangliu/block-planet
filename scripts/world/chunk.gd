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

var _mesh_instance: MeshInstance3D
var _emissive_mesh_instance: MeshInstance3D
var _collision_body: StaticBody3D
# 越界邻居查询回调，由 World 注入（get_block），用于跨界面的正确剔除。
var _neighbor_lookup := Callable()


func _init() -> void:
	data.resize(SIZE.x * SIZE.y * SIZE.z)
	data.fill(BlockTypes.Block.AIR)


func rebuild(atlas_material: Material, emissive_material: Material, neighbor_lookup: Callable = Callable()) -> void:
	_neighbor_lookup = neighbor_lookup
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

	for x in SIZE.x:
		for y in SIZE.y:
			for z in SIZE.z:
				_collect_block(
					Vector3i(x, y, z),
					atlas_v, atlas_n, atlas_uv, atlas_i,
					ems_v, ems_n, ems_uv, ems_i, ems_c,
					collide_v, collide_i
				)

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


func _collect_block(
	pos: Vector3i,
	atlas_v: PackedVector3Array, atlas_n: PackedVector3Array, atlas_uv: PackedVector2Array, atlas_i: PackedInt32Array,
	ems_v: PackedVector3Array, ems_n: PackedVector3Array, ems_uv: PackedVector2Array, ems_i: PackedInt32Array, ems_c: PackedColorArray,
	collide_v: PackedVector3Array, collide_i: PackedInt32Array
) -> void:
	var id := data[_index(pos)]
	if id == BlockTypes.Block.AIR:
		return

	var tiles: Vector3i = BlockTypes.TILES.get(id, Vector3i(0, 0, 0))
	var is_nav := BlockTypes.is_nav_light(id)

	for dir in FACE_DIRS:
		var nid := _neighbor_id(pos + dir)

		var render_face := nid == BlockTypes.Block.AIR or (BlockTypes.is_transparent(nid) and nid != id)
		var collide_face := BlockTypes.is_solid(id) and not BlockTypes.is_solid(nid)

		if not render_face and not collide_face:
			continue

		if render_face:
			if is_nav:
				_emit_nav_face(pos, dir, BlockTypes.nav_color(id), ems_v, ems_n, ems_uv, ems_i, ems_c)
			else:
				_emit_render_face(pos, dir, _face_tile(dir, tiles), atlas_v, atlas_n, atlas_uv, atlas_i)
		if collide_face:
			_emit_collide_face(pos, dir, collide_v, collide_i)


func _emit_render_face(
	pos: Vector3i,
	dir: Vector3i,
	tile: int,
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array
) -> void:
	var base := vertices.size()
	var normal := Vector3(dir)
	var uv_rect := _tile_uv_rect(tile)
	var corners := _face_corners(dir)

	for i in range(4):
		vertices.append(Vector3(pos) + corners[i])
		normals.append(normal)
		# 角点顺序为 (0,0) (0,1) (1,0) (1,1)：a=i/2 映射 U，b=i%2 映射 V。
		var u := lerpf(uv_rect.position.x, uv_rect.end.x, float(i / 2))
		var v := lerpf(uv_rect.position.y, uv_rect.end.y, float(i % 2))
		uvs.append(Vector2(u, v))

	_append_quad_indices(indices, base, dir)


func _emit_nav_face(
	pos: Vector3i,
	dir: Vector3i,
	color: Color,
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array,
	colors: PackedColorArray
) -> void:
	var base := vertices.size()
	var normal := Vector3(dir)
	var corners := _face_corners(dir)
	for i in range(4):
		vertices.append(Vector3(pos) + corners[i])
		normals.append(normal)
		uvs.append(Vector2(0.0, 0.0))
		colors.append(color)
	_append_quad_indices(indices, base, dir)


func _emit_collide_face(
	pos: Vector3i,
	dir: Vector3i,
	vertices: PackedVector3Array,
	indices: PackedInt32Array
) -> void:
	var base := vertices.size()
	var corners := _face_corners(dir)

	for i in range(4):
		vertices.append(Vector3(pos) + corners[i])

	# 碰撞面与渲染面使用相同绕向：ConcavePolygonShape3D 默认背面不碰撞，
	# 绕向错误会让玩家从"背面三角形"漏出地面。
	_append_quad_indices(indices, base, dir)


## 按面方向选择三角化绕向，保证四边形正面朝外（经微测试实证：Godot 的
## 正面判定与叉积直觉相反——对角点序 (0,0)(0,1)(1,0)(1,1)，
## 正方向面取 (0,1,3)(0,3,2)，负方向面取 (0,2,3)(0,3,1)，均沿对角线 c0-c3 拆分。
## 若绕向写反，ConcavePolygonShape3D 默认背面不碰撞，玩家会从地表坠落。
func _append_quad_indices(indices: PackedInt32Array, base: int, dir: Vector3i) -> void:
	if dir.x + dir.y + dir.z > 0:
		indices.append(base)
		indices.append(base + 1)
		indices.append(base + 3)
		indices.append(base)
		indices.append(base + 3)
		indices.append(base + 2)
	else:
		indices.append(base)
		indices.append(base + 2)
		indices.append(base + 3)
		indices.append(base)
		indices.append(base + 3)
		indices.append(base + 1)


func _face_corners(dir: Vector3i) -> PackedVector3Array:
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


func _set_axis(v: Vector3, axis: int, value: float) -> Vector3:
	match axis:
		0:
			v.x = value
		1:
			v.y = value
		2:
			v.z = value
	return v


func _tile_uv_rect(tile: int) -> Rect2:
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


func _face_tile(dir: Vector3i, tiles: Vector3i) -> int:
	if dir.y > 0:
		return tiles.x
	if dir.y < 0:
		return tiles.y
	return tiles.z


func _neighbor_id(pos: Vector3i) -> int:
	if _in_bounds(pos):
		return data[_index(pos)]
	if not _neighbor_lookup.is_null():
		return _neighbor_lookup.call(Vector3i(global_position) + pos)
	return BlockTypes.Block.AIR


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

