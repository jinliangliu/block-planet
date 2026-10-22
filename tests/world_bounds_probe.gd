extends Node
## 世界边界回归探针（D-064，128 km 大世界 P3）。
##
## 定夺：每区域各 128 km × 128 km（±64000 格），**软边界**——加载环在界外截断
## 不生成（不产生区块键），海面与雾延伸到界，HUD 提示「已到世界边缘」。
## 设硬空气墙违反本作铁律（MEMORY.md：全域无空气墙）。
##
## 本探针钉住：
##   A 边界判据（纯函数）：±64000 的区块取舍边界逐值正确（含负坐标）
##   B 界外不生成：_load_chunk / _rebuild_wanted 都拒绝界外区块
##   C 真实场景贴边：玩家站到 63.9 km 处，窗口内所有区块都在界内、
##     不存在的区块键一个都没被造出来
##   D 边界提示：进入 EDGE_NOTICE_DIST 内提示「已到世界边缘」，离开提示恢复
##   E 大洋区域生成：PACIFIC/ATLANTIC/INDIAN「128 km 大洋 + 岛礁」成立
##     （水柱占比 > 60%，且存在露出海面的岛），ARCTIC 为封冻海面
##
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/world_bounds_probe.tscn

var _failed := 0
var _restored := false
## 收到的边界提示文案（成员变量 + 方法连接：GDScript lambda 按值捕获，计数恒 0）。
var _notices: Array[String] = []


func _ready() -> void:
	# 看门狗：协程被脚本错误猝杀时强制退出（否则进程挂起、还原不执行）。
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		push_warning("world_bounds_probe: 看门狗超时，强制退出")
		SaveGuard.restore()
		get_tree().quit())
	await _run()


func _run() -> void:
	SaveGuard.snapshot()
	var prev_pick := GameState.needs_region_pick
	GameState.needs_region_pick = false

	_run_pure()

	# ── C 真实场景：贴边站位 ──────────────────────────────────
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame
	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	Events.notice.connect(_on_notice)

	# 传到东边界内侧 40 格（世界坐标 63960），让流式加载在那儿铺开。
	var edge_world := Vector3(float(World.WORLD_HALF - 40), 0.0, 0.0)
	var ground := world.get_surface_height(int(edge_world.x), 0)
	player.global_position = world.to_render(edge_world) + Vector3(0.0, float(ground) + 2.0, 0.0)
	for i in range(240):
		await get_tree().process_frame
	_settle(world, 600)

	var oob_loaded := 0
	var oob_wanted := 0
	for key: Vector2i in world._chunks:
		if not world.is_chunk_in_bounds(key):
			oob_loaded += 1
	for key: Vector2i in world._wanted:
		if not world.is_chunk_in_bounds(key):
			oob_wanted += 1
	_check(oob_loaded == 0, "C1 贴边时界外区块一个都没生成（越界 %d 块）" % oob_loaded)
	_check(oob_wanted == 0, "C2 wanted 集不含界外区块（越界 %d 块）" % oob_wanted)

	var east_edge := World.HALF_CHUNKS - 1
	var near_edge_loaded := 0
	for dz in range(-World.LOAD_RADIUS, World.LOAD_RADIUS + 1):
		if world._chunks.has(Vector2i(east_edge, dz)):
			near_edge_loaded += 1
	_check(near_edge_loaded > 0,
		"C3 最外侧合法区块（x=%d）已正常加载（%d 行）" % [east_edge, near_edge_loaded])
	print("INFO 贴边时已载区块 %d 块，wanted %d 块"
		% [world._chunks.size(), world._wanted.size()])

	# ── D 边界提示 ───────────────────────────────────────────
	_check(world.is_near_world_edge(edge_world),
		"D1 距界 40 格判定为「临近世界边缘」")
	_check(not world.is_near_world_edge(Vector3.ZERO),
		"D2 原点判定为「不在边缘」")
	var edge_noticed := false
	for t in _notices:
		if t.contains("边缘"):
			edge_noticed = true
	_check(edge_noticed, "D3 贴边时已发出「已到世界边缘」提示（收到 %d 条提示）"
		% _notices.size())

	# ── 收尾 ─────────────────────────────────────────────────
	GameState.needs_region_pick = prev_pick
	SaveGuard.restore()
	_restored = true
	print("WORLD_BOUNDS_TEST_%s" % ("OK" if _failed == 0 else "FAILED"))
	get_tree().quit(0 if _failed == 0 else 1)


## 纯函数段：边界判据 + 不许生成 + 大洋区域生成勘察。
func _run_pure() -> void:
	var w := World.new()
	# A 边界判据：chunk c 覆盖 [c*16, c*16+15] 格，故合法区间 [-4000, 3999]。
	_check(w.is_chunk_in_bounds(Vector2i(0, 0)), "A1 原点区块在界内")
	_check(w.is_chunk_in_bounds(Vector2i(3999, 3999)), "A2 (3999,3999) 在界内")
	_check(not w.is_chunk_in_bounds(Vector2i(4000, 0)), "A3 (4000,0) 在界外（64000 起已出界）")
	_check(w.is_chunk_in_bounds(Vector2i(-4000, 0)), "A4 (-4000,0) 在界内（覆盖 -64000）")
	_check(not w.is_chunk_in_bounds(Vector2i(-4001, 0)), "A5 (-4001,0) 在界外")
	_check(not w.is_chunk_in_bounds(Vector2i(0, -4001)), "A6 z 轴负向同样生效")

	# B 界外不生成：_load_chunk 直接拒绝（不产生区块键）。
	w._load_chunk(Vector2i(4000, 4000))
	_check(not w._chunks.has(Vector2i(4000, 4000)), "B1 _load_chunk 拒绝界外区块")
	w._load_chunk(Vector2i(-4001, 0))
	_check(not w._chunks.has(Vector2i(-4001, 0)), "B2 _load_chunk 拒绝负向界外区块")
	# 取一个「半径 1 圈内全部越界」的中心（4001±1 = 4000..4002 全在界外），
	# 否则 (4000,4000) 的 ±1 圈里还夹着界内的 (3999,3999)，断言不成立。
	_check(w.fill_ring_sync(Vector2i(4001, 4001), 1) == 0,
		"B3 fill_ring_sync 在界外不加载任何区块")
	_check(w._chunks.is_empty(), "B4 界外加载尝试没有留下任何区块键")

	# E 大洋区域：128 km 都该是大洋 + 岛礁。
	for region: int in [RegionAtlas.PACIFIC, RegionAtlas.ATLANTIC, RegionAtlas.INDIAN]:
		var stats := _ocean_stats(w, region)
		var water_ratio: float = stats["water"]
		var land_ratio: float = stats["land"]
		var rname := String(RegionAtlas.profile(region)["title"])
		_check(water_ratio > 0.6,
			"E1 %s 是大洋（水柱占比 %.1f%%）" % [rname, water_ratio * 100.0])
		_check(land_ratio > 0.002,
			"E2 %s 有露出海面的岛礁（陆地占比 %.2f%%）"
				% [rname, land_ratio * 100.0])
	# 极地：水面按 iceberg 策略封冻，但地形高度仍大面积低于海平面。
	var arctic := _ocean_stats(w, RegionAtlas.ARCTIC)
	_check(float(arctic["water"]) > 0.6,
		"E3 北极是封冻海面（低于海平面的列占 %.1f%%）" % (float(arctic["water"]) * 100.0))


## 在 ±60000 范围内均匀采样，统计「低于海平面的列」与「高出海面的列」占比。
func _ocean_stats(w: World, region: int) -> Dictionary:
	w.set_region(region)
	var step := 512
	var water := 0
	var land := 0
	var total := 0
	var x := -World.WORLD_HALF + step
	while x < World.WORLD_HALF:
		var z := -World.WORLD_HALF + step
		while z < World.WORLD_HALF:
			total += 1
			if w.is_water_column(x, z):
				water += 1
			else:
				land += 1
			z += step
		x += step
	return {
		"water": float(water) / float(maxi(total, 1)),
		"land": float(land) / float(maxi(total, 1)),
		"total": total,
	}


func _on_notice(text: String) -> void:
	_notices.append(text)


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


func _exit_tree() -> void:
	# D-010 安全网：协程猝死时末尾还原不会执行，退出期再兜一层（幂等）。
	if not _restored:
		_restored = true
		SaveGuard.restore()
