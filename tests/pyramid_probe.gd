extends Node
## 金字塔堆叠搭建验证探针。
## 用真实放置链路（Player._place_target 的射线命中 → hit+normal 规则）逐块搭建三层金字塔，
## 断言结构完整、无空洞、可站立（碰撞正确）、区块卸载重载后留存。
##
## 运行：Godot_console.exe --headless --path . res://tests/pyramid_probe.tscn
##
## 搭建策略（与真人建造一致）：自底向上逐层铺满，每次只从"已落下方块/地面的顶面"放置，
## 即始终命中 +Y 面、目标格 = hit + 0.5*Y，与游戏放置规则完全同构。
##
## 关键约束（经 tests/place_diag*.gd 九项隔离诊断实证）：
##   1. _raycast_target() 读 _camera.global_position；
##   2. 相机若继承 Player 变换，teleport Player 会牵动区块流式与物理，导致射线随机脱靶
##      → 相机临时挂到根节点，仅设自身 global_transform；
##   3. looking_at() 正下方视线会与 UP 共线产生非法基 → 手工构造 basis；
##   4. 相机必须位于空气格内，否则射线从实心体内出发必然脱靶。

const LAYERS := 3
const BASE_HALF := 2  # 底层 x/z 各 span 5 格

var _failed := 0
var _diag_count := 0
var _skip_count := 0
var _world: World
var _player: Player
var _camera: Camera3D
var _original_parent: Node = null
var _original_transform := Transform3D()


func _ready() -> void:
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(90):
		await get_tree().process_frame

	_world = main_scene.get_node("World")
	_player = main_scene.get_node("Player")
	_camera = _player.get_node("Camera3D")

	GameState.set_mode(GameState.Mode.CREATIVE)
	_player.select_slot(2)  # HOTBAR_BLOCKS[2] = STONE
	_check(_player.get_selected_placeable() == BlockTypes.Block.STONE, "当前选中可放置方块为石头")

	var base := _find_base()
	_check(base != Vector3i(0, 0, 0), "找到金字塔基座层")
	if base == Vector3i.ZERO:
		_restore_camera()
		_finish(0)
		return

	# 冻结玩家物理：逐块瞄准期间身体不得被重力/移动拉扯。
	# 同时把玩家挪离基座所在列——玩家胶囊会挡住自上而下的放置射线（诊断 7 实证）。
	_player.set_physics_process(false)
	_player.velocity = Vector3.ZERO
	_player.global_position = Vector3(
		float(base.x - BASE_HALF - 3) + 0.5, float(base.y + LAYERS) + 0.2, float(base.z) + 0.5
	)
	await get_tree().physics_frame

	var expected := 0
	for layer in range(LAYERS):
		var side := 2 * (BASE_HALF - layer) + 1
		expected += side * side

	# 自底向上、逐层由外向内：总是从上一位已落方块（或地面）的顶面放置。
	var placed := 0
	for layer in range(LAYERS):
		var half := BASE_HALF - layer
		for dx in range(-half, half + 1):
			for dz in range(-half, half + 1):
				var cell := Vector3i(base.x + dx, base.y + layer, base.z + dz)
				if await _place_on_top(cell):
					placed += 1
	_check(placed == expected, "金字塔逐块放置成功（%d/%d）" % [placed, expected])

	# --- 结构断言 ---
	var holes := 0
	for layer in range(LAYERS):
		var half := BASE_HALF - layer
		for dx in range(-half, half + 1):
			for dz in range(-half, half + 1):
				if _world.get_block(Vector3i(base.x + dx, base.y + layer, base.z + dz)) != BlockTypes.Block.STONE:
					holes += 1
	_check(holes == 0, "金字塔无空洞（收缩立方堆叠完整）")

	var overhang_ok := true
	for layer in range(LAYERS):
		var half := BASE_HALF - layer
		var ring := half + 1
		if ring > BASE_HALF:
			continue
		for dx in range(-ring, ring + 1):
			for dz in range(-ring, ring + 1):
				if absi(dx) != ring and absi(dz) != ring:
					continue
				if _world.get_block(Vector3i(base.x + dx, base.y + layer, base.z + dz)) == BlockTypes.Block.STONE:
					overhang_ok = false
	_check(overhang_ok, "上层未越界（阶梯收缩正确，无悬空多余方块）")

	var above_ok := true
	for dx in range(-BASE_HALF - 1, BASE_HALF + 2):
		for dz in range(-BASE_HALF - 1, BASE_HALF + 2):
			if _world.get_block(Vector3i(base.x + dx, base.y + LAYERS, base.z + dz)) == BlockTypes.Block.STONE:
				above_ok = false
	_check(above_ok, "金字塔顶端之上无多余方块（层数精确为 %d）" % LAYERS)

	# --- 碰撞断言 ---
	_restore_camera()
	_player.set_physics_process(true)
	await get_tree().physics_frame

	var top_cell := Vector3i(base.x, base.y + LAYERS - 1, base.z)
	var top_probe := Vector3(top_cell) + Vector3(0.5, 0.5, 0.5)
	var hit := _ray_down(top_probe + Vector3(0.0, 5.0, 0.0), top_probe - Vector3(0.0, 5.0, 0.0))
	_check(not hit.is_empty(), "塔顶方块有碰撞体（射线命中）")
	if not hit.is_empty():
		var hit_pos: Vector3 = hit["position"]
		_check(absf(hit_pos.y - float(top_cell.y + 1)) < 0.05, "塔顶碰撞面高度等于方块顶面 y=%d" % (top_cell.y + 1))

	# 阶梯外侧（基座环外一格）自地表起应无金字塔方块：垂直射线应命中"原始地面顶面"，
	# 而不是更高处——更高处意味着塔外多出方块。地形在此处本身必然实心。
	var side_x := base.x + BASE_HALF + 1
	var side_z := base.z
	var ground_y := _find_ground_y(side_x, side_z)
	var side_probe := Vector3(float(side_x) + 0.5, float(base.y) + 1.0, float(side_z) + 0.5)
	var side_hit := _ray_down(side_probe + Vector3(0.0, 6.0, 0.0), side_probe - Vector3(0.0, 6.0, 0.0))
	_check(not side_hit.is_empty(), "塔外列仍为地形地面（射线命中）")
	if not side_hit.is_empty():
		var side_pos: Vector3 = side_hit["position"]
		_check(
			absf(side_pos.y - float(ground_y + 1)) < 0.05,
			"塔外列无多余方块（命中高度=原始地面顶面 y=%d，实测 %.2f）" % [ground_y + 1, side_pos.y]
		)

	# --- 留存断言 ---
	var coord := _world.world_to_chunk(Vector3(base) + Vector3(0.5, 0.5, 0.5))
	_check(_force_unload(coord), "金字塔所在区块已卸载")
	for i in range(45):
		await get_tree().process_frame
	var survive := 0
	for layer in range(LAYERS):
		var half := BASE_HALF - layer
		for dx in range(-half, half + 1):
			for dz in range(-half, half + 1):
				if _world.get_block(Vector3i(base.x + dx, base.y + layer, base.z + dz)) == BlockTypes.Block.STONE:
					survive += 1
	_check(survive == expected, "区块卸载重载后金字塔完整留存（%d/%d）" % [survive, expected])

	print("PYRAMID_STATS base=%s expected=%d placed=%d holes=%d survive=%d" % [base, expected, placed, holes, survive])
	_finish(placed)


func _finish(placed: int) -> void:
	if _failed == 0:
		print("PYRAMID_TEST_OK placed=%d" % placed)
		get_tree().quit(0)
	else:
		print("PYRAMID_TEST_FAILED count=%d" % _failed)
		get_tree().quit(1)


## 基座层：玩家前方近处找一块"基座 5x5 footprint 下方同高实心 + 上方净空"的位置。
## 地形起伏时部分列无支撑，放置会被游戏正确拒绝（不可悬空贴块）。
## 同时排除玩家自身所在列——其胶囊会遮挡自上而下的放置射线。
func _find_base() -> Vector3i:
	var from := _player.global_position
	var player_cell := Vector3i(from.floor())
	var ranges: Array[Vector2i] = [
		Vector2i(3, 6), Vector2i(6, 10), Vector2i(10, 16), Vector2i(16, 24), Vector2i(-10, -3), Vector2i(-16, -10)
	]
	for r: Vector2i in ranges:
		for radius in range(r.x, r.y + 1):
			for dx in range(-12, 13):
				for dz in range(-6, 7):
					var x := player_cell.x + dx
					var z := player_cell.z + radius + dz
					if x == player_cell.x and z == player_cell.z:
						continue
					var ground := _find_ground_y(x, z)
					if ground < -20:
						continue
					if not _footprint_usable(x, z, ground):
						continue
					return Vector3i(x, ground + 1, z)
	return Vector3i.ZERO


## 基座 5x5 下方同高实心，且基座层及以上 LAYERS 层全为空气。
func _footprint_usable(cx: int, cz: int, ground: int) -> bool:
	for ex in range(-BASE_HALF, BASE_HALF + 1):
		for ez in range(-BASE_HALF, BASE_HALF + 1):
			var x := cx + ex
			var z := cz + ez
			if not BlockTypes.is_solid(_world.get_block(Vector3i(x, ground, z))):
				return false
			for layer in range(LAYERS + 1):
				if _world.get_block(Vector3i(x, ground + 1 + layer, z)) != BlockTypes.Block.AIR:
					return false
	return true


func _find_ground_y(x: int, z: int) -> int:
	var surface := _world.get_surface_height(x, z)
	for y in range(surface, surface - 24, -1):
		if BlockTypes.is_solid(_world.get_block(Vector3i(x, y, z))):
			return y
	return -1


## 在目标格放置方块：镜头置于目标格正上方 3 格（REACH 内）空气处，垂直俯视支撑块顶面。
## 命中 +Y 面 → 游戏规则 cell = hit + 0.5*Y = 目标格，与真人"往下叠方块"完全一致。
## 前置条件：目标列上方 3 格内必须全为空气，否则射线会先命中途中方块而偏移。
func _place_on_top(cell: Vector3i) -> bool:
	if _world.get_block(cell) != BlockTypes.Block.AIR:
		_skip_reason("cell_not_air(%d)" % _world.get_block(cell))
		return false
	var support := cell + Vector3i(0, -1, 0)
	var support_id := _world.get_block(support)
	if not BlockTypes.is_solid(support_id):
		_skip_reason("support_not_solid(id=%d at %s)" % [support_id, support])
		return false

	# 镜头放在目标格上方固定 3 格（在 REACH 内），并确保该格与沿途均为空气，
	# 否则射线会先命中途中的方块而非支撑顶面。
	var cam_dy := 3
	var cam_cell := Vector3i(cell.x, cell.y + cam_dy, cell.z)
	if _world.get_block(cam_cell) != BlockTypes.Block.AIR:
		_skip_reason("cam_cell_blocked(id=%d at %s)" % [_world.get_block(cam_cell), cam_cell])
		return false
	for y in range(cell.y + 1, cell.y + cam_dy):
		if _world.get_block(Vector3i(cell.x, y, cell.z)) != BlockTypes.Block.AIR:
			_skip_reason("column_blocked_at_y%d" % y)
			return false

	var center := Vector3(cell) + Vector3(0.5, 0.0, 0.5)
	var cam := Vector3(cell) + Vector3(0.5, float(cam_dy), 0.5)

	_aim_camera(cam, center)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var ray := _player._raycast_target()
	_player._place_target()
	var ok := _world.get_block(cell) == BlockTypes.Block.STONE
	if not ok and _diag_count < 8:
		_diag_count += 1
		var reason := "ray_empty"
		if not ray.is_empty():
			var hp: Vector3 = ray["position"]
			var hn: Vector3 = ray["normal"]
			reason = "hit=%s n=%s cell_from_ray=%s" % [hp, hn, Vector3i((hp + hn * 0.5).floor())]
		print("DIAGFAIL cell=%s support_id=%d cam=%s cam_id=%d %s" % [
			cell,
			_world.get_block(support),
			_camera.global_position,
			_world.get_block(Vector3i(cam.floor())),
			reason,
		])
	return ok


## 把相机精确摆到指定世界位置并朝向目标（手工构造 basis，避免 looking_at 共线退化）。
func _aim_camera(camera_pos: Vector3, target: Vector3) -> void:
	if _camera.get_parent() != _player.get_parent():
		_original_parent = _camera.get_parent()
		_original_transform = _camera.transform
		_original_parent.remove_child(_camera)
		_player.get_parent().add_child(_camera)

	var fwd := (target - camera_pos).normalized()
	var up := Vector3.UP
	if absf(fwd.dot(up)) > 0.999:
		up = Vector3.FORWARD
	var right := fwd.cross(up).normalized()
	up = right.cross(fwd).normalized()
	_camera.global_transform = Transform3D(Basis(right, up, -fwd), camera_pos)


## 恢复相机为 Player 的子节点。
func _restore_camera() -> void:
	if _original_parent == null:
		return
	if _camera.get_parent() != null:
		_camera.get_parent().remove_child(_camera)
	_original_parent.add_child(_camera)
	_camera.transform = _original_transform
	_original_parent = null


func _ray_down(from: Vector3, to: Vector3) -> Dictionary:
	var space := _player.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return space.intersect_ray(query)


## 强制卸载指定区块（模拟玩家走远），用于验证修改留存。
func _force_unload(coord: Vector3i) -> bool:
	if not _world._chunks.has(coord):
		return false
	_world._unload_chunk(coord)
	return true


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)


func _skip_reason(why: String) -> void:
	if _skip_count < 10:
		_skip_count += 1
		print("SKIP: " + why)
