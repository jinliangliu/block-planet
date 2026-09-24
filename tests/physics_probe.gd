extends Node
## 无头物理探针 v4：四象限绕向微测试（顶/底面 × 两半三角形 × 内外侧射线）
## + 游戏世界落地复检。运行：Godot_console.exe --headless --path . res://tests/physics_probe.tscn

func _ready() -> void:
	await _run()


func _run() -> void:
	var space := get_tree().root.world_3d.direct_space_state

	# 微测试体：复刻 chunk.gd 角点序。顶面块占 y 9..10（顶面 y=10），底面块同。
	# A: 顶面 + 新 +dir 绕向 (0,1,3)(0,3,2)，期望从上方两半均命中 y=10。
	var body_a := _make_quad_body(Vector3(0, 0, 0), 10.0, true, [0, 1, 3, 0, 3, 2])
	# B: 顶面 + 旧均匀绕向 (0,1,2)(0,2,3)，预期仅一半命中（对角线分割）。
	var body_b := _make_quad_body(Vector3(5, 0, 0), 10.0, true, [0, 1, 2, 0, 2, 3])
	# C: 底面 + 新 -dir 绕向 (0,2,3)(0,3,1)，期望从下方两半均命中 y=9。
	var body_c := _make_quad_body(Vector3(10, 0, 0), 9.0, false, [0, 2, 3, 0, 3, 1])
	# D: 底面 + 错误地使用 +dir 绕向，期望从下方完全不命中。
	var body_d := _make_quad_body(Vector3(15, 0, 0), 9.0, false, [0, 1, 3, 0, 3, 2])
	await get_tree().physics_frame
	await get_tree().physics_frame

	print("A_top_new_half1=", _ray(space, Vector3(0.25, 15, 0.25), Vector3.DOWN))
	print("A_top_new_half2=", _ray(space, Vector3(0.75, 15, 0.75), Vector3.DOWN))
	print("B_top_old_half1=", _ray(space, Vector3(5.25, 15, 0.25), Vector3.DOWN))
	print("B_top_old_half2=", _ray(space, Vector3(5.75, 15, 0.75), Vector3.DOWN))
	print("C_bottom_new_half1=", _ray(space, Vector3(10.25, 4, 0.25), Vector3.UP))
	print("C_bottom_new_half2=", _ray(space, Vector3(10.75, 4, 0.75), Vector3.UP))
	print("D_bottom_wrong=", _ray(space, Vector3(15.25, 4, 0.25), Vector3.UP))
	body_a.queue_free()
	body_b.queue_free()
	body_c.queue_free()
	body_d.queue_free()

	# 游戏世界复检。
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(150):
		await get_tree().physics_frame

	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")
	print("surface_height(8,8)=", world.get_surface_height(8, 8))
	print("player_pos=", player.global_position)
	print("on_floor=", player.is_on_floor())
	print("live_ray_down=", _ray(space, Vector3(8.5, 45, 8.5), Vector3.DOWN))
	print("PHYSICS_PROBE_DONE")
	get_tree().quit(0)


## 复刻 _face_corners 的角点序：axis=Y，(a,b) 依 i 为 (0,0)(0,1)(1,0)(1,1)，
## x=b、z=a；top=true 时面在 y=+1（块顶），false 时在 y=0（块底）。
func _make_quad_body(origin: Vector3, face_y: float, top: bool, indices: PackedInt32Array) -> StaticBody3D:
	var plane_y := face_y
	var verts := PackedVector3Array([
		Vector3(0, plane_y, 0), Vector3(1, plane_y, 0), Vector3(0, plane_y, 1), Vector3(1, plane_y, 1)
	])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array(indices)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var body := StaticBody3D.new()
	var shape_node := CollisionShape3D.new()
	shape_node.shape = mesh.create_trimesh_shape()
	body.add_child(shape_node)
	body.position = origin
	add_child(body)
	return body


func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, dir: Vector3) -> String:
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 60.0)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return "NONE"
	return "y=%.2f n=%s" % [hit["position"].y, hit["normal"]]
