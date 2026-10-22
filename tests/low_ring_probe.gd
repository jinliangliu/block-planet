extends Node
## 双环加载回归探针（D-064，128 km 大世界 P2）。
##
## 背景：高模方块环（半径 World.LOAD_RADIUS = 4 区块 = 64 m）之外到
## World.LOW_RADIUS（16 区块 = 256 m）由 LowTerrain 的「高度图粗网格」填充——
## 每 4×4 区块合并成一组、每 4 格采样一个高度、顶点色上色、无方块数据、无碰撞。
##
## 本探针钉住：
##   A 高模环填满（9×9）+ 低模环组数落在预期区间 + 组数 < 全窗口组数
##     （证明「高模方形内的低模被跳过」，否则粗网格会从精细地形里穿出来）
##   B 低模顶点高度与噪声地形**逐点严格相等**（接缝无缝的前提），
##     格内插值误差在平原地带 ≤ 4 m（D-064 验收口径）
##   C 低模无碰撞体、不投影、挂在 World 下（浮动原点随动）
##   D 低模只在中心跨组/高模半径变化时重建（增量：一次只重建少量组）
##   E 走远后低模组数不膨胀（窗口外的组被释放）
##
## 约定：LowTerrain 的顶点是**组内局部坐标**（0..64），MeshInstance3D.position
## 是组的世界原点，故「position + 顶点」= 世界坐标。
##
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/low_ring_probe.tscn

var _failed := 0
var _restored := false
## 组内顶点数（4×4 区块 / 4 格步长 + 1 两侧共享边 = 17×17）。
const N := 17


func _ready() -> void:
	# 看门狗：协程被脚本错误猝杀时强制退出（否则进程挂起、还原不执行）。
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		push_warning("low_ring_probe: 看门狗超时，强制退出")
		SaveGuard.restore()
		get_tree().quit())
	await _run()


func _run() -> void:
	# 存档隔离（D-010 铁律 3）：必须在实例化 main.tscn 之前。
	SaveGuard.snapshot()
	var prev_pick := GameState.needs_region_pick
	GameState.needs_region_pick = false

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(120):
		await get_tree().process_frame
	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()

	var low: LowTerrain = world.get_node_or_null("LowTerrain")
	if low == null:
		_check(false, "A0 World 下存在 LowTerrain 节点")
		_finish(prev_pick)
		return

	# ── A 双环：高模环填满、低模环组数合理 ─────────────────────
	_settle(world, 600)
	var center := world.world_to_chunk(player.global_position)
	var hi_missing := 0
	for dx in range(-World.LOAD_RADIUS, World.LOAD_RADIUS + 1):
		for dz in range(-World.LOAD_RADIUS, World.LOAD_RADIUS + 1):
			if not world._chunks.has(center + Vector2i(dx, dz)):
				hi_missing += 1
	_check(hi_missing == 0,
		"A1 高模环 %d×%d 区块全部加载（缺 %d 块）"
			% [World.LOAD_RADIUS * 2 + 1, World.LOAD_RADIUS * 2 + 1, hi_missing])

	# 窗口内的组数：组 = 4 区块 = 64 格，窗口 ±16 区块 = ±256 格 = ±4 组，
	# 故每轴 9~10 组（中心未对齐组边界时多一圈），上限 100。
	var group_span := World.LOW_RADIUS / World.LOW_GROUP_CHUNKS
	var full_groups := (group_span * 2 + 2) * (group_span * 2 + 2)
	var got := low.group_count()
	_check(got > 0, "A2 低模环已生成组（%d 组）" % got)
	_check(got <= full_groups,
		"A2 低模组数不超过窗口上限（%d ≤ %d）" % [got, full_groups])
	# 高模方形（±(LOAD_RADIUS+UNLOAD_PAD) 区块 = ±80 格）覆盖的组必须整组不出
	# 网格：中心组整组落在里面，必须被跳过——否则 4 m 粗网格会从精细地形里
	# 穿出来（看到尖刺）。用「中心组原点有没有 MeshInstance3D」直接验。
	var cg := Vector2i(floori(float(center.x) / float(World.LOW_GROUP_CHUNKS)),
		floori(float(center.y) / float(World.LOW_GROUP_CHUNKS)))
	var cg_origin := Vector3(float(cg.x * World.LOW_GROUP_CHUNKS * 16), 0.0,
		float(cg.y * World.LOW_GROUP_CHUNKS * 16))
	var center_group_built := false
	for mi: MeshInstance3D in _low_meshes(low):
		if absf(mi.position.x - cg_origin.x) < 0.5 and absf(mi.position.z - cg_origin.z) < 0.5:
			center_group_built = true
	_check(not center_group_built,
		"A3 中心组（被高模环完全覆盖）没有低模网格")
	_check(low.total_vertices() > 0,
		"A4 低模顶点数 > 0（%d）" % low.total_vertices())
	print("INFO 网格数：高模 %d 块 + 低模 %d 组 ≈ %d 次绘制（未含发光面/碰撞体）"
		% [world._chunks.size(), low.group_count(), world._chunks.size() + low.group_count()])

	# ── B 低模几何：顶点高度与噪声地形逐点相等 ─────────────────
	var meshes := _low_meshes(low)
	_check(meshes.size() == got, "B0 低模 MeshInstance3D 数 = 组数（%d/%d）"
		% [meshes.size(), got])
	var mismatch := 0
	var checked_verts := 0
	var scanned := 0
	for mi: MeshInstance3D in meshes:
		if scanned >= 8:
			break
		var verts := _verts(mi)
		if verts.is_empty():
			continue
		scanned += 1
		for v in verts:
			var wx := roundi(mi.position.x + v.x)
			var wz := roundi(mi.position.z + v.z)
			var want := maxi(world.get_surface_height(wx, wz), World.SEA_LEVEL)
			checked_verts += 1
			if want != roundi(v.y):
				mismatch += 1
	_check(checked_verts > 0 and mismatch == 0,
		"B1 低模顶点高度与噪声地形逐点相等（%d 个顶点，误差 0 m）" % checked_verts)

	# 格内插值误差：4 m 采样 → 用格心双线性插值 vs 真值。平原地带（出生点
	# 附近、坡度 ≤1 格/格）应 ≤ 4 m——D-064 的「低模高度误差 ≤4 m」口径。
	var plains := _pick_mesh_near(low, world, center + Vector2i(World.LOAD_RADIUS + 3, 0))
	var plains_err := _cell_error(world, plains)
	_check(plains_err <= 4.0,
		"B2 平原地带格内插值最大误差 %.2f m ≤ 4 m" % plains_err)
	var worst := 0.0
	for mi: MeshInstance3D in meshes:
		worst = maxf(worst, _cell_error(world, mi))
	print("INFO 窗口内全部低模组格内插值最大误差 %.2f m（含山区陡坡，只作记录）" % worst)

	# ── C 低模不是碰撞体、不投影、挂在 World 下 ────────────────
	var bodies := 0
	var shadow_on := 0
	for mi: MeshInstance3D in meshes:
		if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			shadow_on += 1
		for child in mi.get_children():
			if child is CollisionObject3D:
				bodies += 1
	_check(bodies == 0, "C1 低模无任何碰撞体（撞不到、飞不撞）")
	_check(shadow_on == 0, "C2 低模全部关闭阴影投影（%d 个仍开着）" % shadow_on)
	_check(low.get_parent() == world,
		"C3 LowTerrain 挂在 World 下（浮动原点搬迁随动，无需单独注册）")

	# ── D 增量：中心跨一组只重建少量组 ────────────────────────
	# 注意：这里**不能**先 await 帧——World._process 每帧都会调 _update_low_ring，
	# 签名一旦被它抢先更新，本段显式调用就恒返回 0（假阴性）。
	var built := world._update_low_ring(center)
	_check(built == 0, "D1 中心未变时无重建（重建 %d 组）" % built)
	player.global_position += Vector3(float(World.LOW_GROUP_CHUNKS * 16), 0.0, 0.0)
	var center2 := world.world_to_chunk(player.global_position)
	var t_d := Time.get_ticks_usec()
	built = world._update_low_ring(center2)
	var ms_d := float(Time.get_ticks_usec() - t_d) / 1000.0
	_check(built > 0 and built <= 40,
		"D2 跨一组后只重建增量（%d 组，%.1f ms，上限 40；全窗口约 81~100 组）"
			% [built, ms_d])
	if built > 0:
		print("INFO 低模单组增量成本 %.2f ms/组（目标 ≤10 ms）" % (ms_d / float(built)))

	# ── E 窗口外组被释放，组数不膨胀 ──────────────────────────
	player.global_position += Vector3(0.0, 0.0, 640.0)
	await get_tree().process_frame
	_settle(world, 400)
	_check(low.group_count() <= full_groups,
		"E1 远行后低模组数仍不超过窗口上限（%d ≤ %d）"
			% [low.group_count(), full_groups])
	var reach_blocks := float((World.LOW_RADIUS + World.LOW_GROUP_CHUNKS) * 16)
	var here := world.world_to_chunk(player.global_position)
	var outside := 0
	for mi: MeshInstance3D in _low_meshes(low):
		var c := world.world_to_chunk(mi.position)
		var off := c - here
		if absf(float(off.x)) * 16.0 > reach_blocks or absf(float(off.y)) * 16.0 > reach_blocks:
			outside += 1
	_check(outside == 0, "E2 窗口外的低模组已释放（残留 %d 组）" % outside)

	_finish(prev_pick)


func _verts(mi: MeshInstance3D) -> PackedVector3Array:
	if mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return PackedVector3Array()
	var arr := mi.mesh.surface_get_arrays(0)
	var out: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	return out


## 该组网格的「格内插值最大误差」：每 4×4 格取中心点，用四角高度双线性插值，
## 与真实地形高度比。低模自身不插值——引擎按三角面线性插值，其误差不超过
## 双线性（双线性是三角面误差的上界近似），故这里用双线性作保守估计。
## 顶点被部分跳过（组内 quad 被高模方形裁掉）时返回 0，避免误判。
func _cell_error(world: World, mi: MeshInstance3D) -> float:
	if mi == null:
		return 0.0
	var verts := _verts(mi)
	if verts.size() != N * N:
		return 0.0
	var worst := 0.0
	for j in range(N - 1):
		for i in range(N - 1):
			var x0 := roundi(mi.position.x + verts[j * N + i].x)
			var z0 := roundi(mi.position.z + verts[j * N + i].z)
			var x1 := roundi(mi.position.x + verts[j * N + i + 1].x)
			var h00 := verts[j * N + i].y
			var h10 := verts[j * N + i + 1].y
			var h01 := verts[(j + 1) * N + i].y
			var h11 := verts[(j + 1) * N + i + 1].y
			var cx := (x0 + x1) / 2
			var cz := (z0 + roundi(mi.position.z + verts[(j + 1) * N + i].z)) / 2
			var interp := (h00 + h10 + h01 + h11) * 0.25
			var truth := float(maxi(world.get_surface_height(cx, cz), World.SEA_LEVEL))
			worst = maxf(worst, absf(interp - truth))
	return worst


func _low_meshes(low: LowTerrain) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for c in low.get_children():
		if c is MeshInstance3D:
			out.append(c)
	return out


## 取最接近指定世界区块的组网格。
func _pick_mesh_near(low: LowTerrain, world: World, chunk: Vector2i) -> MeshInstance3D:
	var best: MeshInstance3D = null
	var best_d := INF
	var want := world.chunk_to_world(chunk)
	for mi: MeshInstance3D in _low_meshes(low):
		var d := mi.position.distance_to(want)
		if d < best_d:
			best_d = d
			best = mi
	return best


## 反复推进流式加载直至队列清空（或达到帧数上限）。
func _settle(world: World, frames: int) -> void:
	for _i in frames:
		world._update_chunks()
		if world._pending_load.is_empty():
			break


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("PASS: %s" % msg)
	else:
		_failed += 1
		print("FAIL: %s" % msg)


func _finish(prev_pick: bool) -> void:
	GameState.needs_region_pick = prev_pick
	SaveGuard.restore()
	_restored = true
	print("LOW_RING_TEST_%s" % ("OK" if _failed == 0 else "FAILED"))
	get_tree().quit(0 if _failed == 0 else 1)


func _exit_tree() -> void:
	# D-010 安全网：协程猝死时末尾还原不会执行，退出期再兜一层（幂等）。
	if not _restored:
		_restored = true
		SaveGuard.restore()
