extends Node
## 坐标地基回归探针（D-062，128 km 大世界 P0：Vector2i 区块键 + 浮动原点）。
##
## 背景：世界扩到 ±64000 格后 float32 在远处量化丢精度（64 km 处约 8 mm），
## 区块节点错位、相机抖动。故逻辑坐标一律整数（世界空间，真相），渲染坐标 =
## 世界坐标 − origin；玩家越过 ORIGIN_SHIFT_THRESHOLD（4096）即 recenter。
## 本探针钉住这套契约的不变式：
##   A 纯函数恒等式（无场景）：world_to_chunk/chunk_to_world 互逆（含负坐标）、
##     to_world/to_render 往返、chunk_at = to_world + world_to_chunk。
##   B request_shift_origin 行为（独立 World 实例）：origin()/position=−origin/
##     box_contents 重键/信号 delta/同值幂等不重复发信号。
##   C 真实 main 场景：传送玩家 6000 格 → origin 搬迁 → 玩家**世界坐标**不变
##     （x/z 逐值一致）→ 回传后曾标记的方块仍在同一世界格（卸载/重载/重键往返）。
##   D 实体不变式：船/飞机出生即登记进搬迁组；手动 shift 后节点 +delta、
##     世界坐标不变、内部锚点（harbor_pos/_state.position/spawn_position/
##     _flight_spawn/_craft_park）同步重基。
##
## 计数铁律：信号计数用成员变量 + 方法连接（GDScript lambda 按值捕获，
## `connect(func(): n += 1)` 里的 n 恒 0——2026-10-20 实测）。
##
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/world_coord_probe.tscn

var _failed := 0
## origin_shifted 信号计数（成员变量，避免 lambda 按值捕获）。
var _shift_count := 0
var _last_delta := Vector3.ZERO
## 还原幂等标记（SaveGuard.restore 只生效一次）。
var _restored := false


func _ready() -> void:
	# 看门狗：协程被脚本错误猝杀时强制退出（否则进程挂起、还原不执行）。
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		push_warning("world_coord_probe: 看门狗超时，强制退出")
		SaveGuard.restore()
		get_tree().quit())
	await _run()


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("PASS: %s" % msg)
	else:
		_failed += 1
		print("FAIL: %s" % msg)


func _dbg(msg: String) -> void:
	print("DBG %s" % msg)


func _on_shifted(delta: Vector3) -> void:
	_shift_count += 1
	_last_delta = delta


## 纯函数段（A）+ 搬迁行为段（B）：独立 World 实例，不入树、不生成区块。
func _run_pure() -> void:
	var w := World.new()

	# ── A1 区块接口互逆（含负坐标：floori 向下取整，-1 格属 -1 区块）──
	var cases: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1),
		Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(-2, 3),
	]
	var ok_roundtrip := true
	for c: Vector2i in cases:
		if w.world_to_chunk(w.chunk_to_world(c)) != c:
			ok_roundtrip = false
			_dbg("A1 逆失败 c=%s -> %s" % [str(c),
				str(w.world_to_chunk(w.chunk_to_world(c)))])
	_check(ok_roundtrip, "A1 world_to_chunk(chunk_to_world(c)) == c（含负区块）")

	# 边界格：15.9 属 0 区块、-0.1 属 -1 区块、-16 整好是 -1 区块原点。
	var ok_boundary := (
		w.world_to_chunk(Vector3(15.9, 0.0, 15.9)) == Vector2i(0, 0)
		and w.world_to_chunk(Vector3(-0.1, 0.0, -0.1)) == Vector2i(-1, -1)
		and w.world_to_chunk(Vector3(-16.0, 0.0, -16.0)) == Vector2i(-1, -1)
		and w.world_to_chunk(Vector3(-16.1, 0.0, 0.0)) == Vector2i(-2, 0)
		and w.world_to_chunk(Vector3(16.0, 0.0, 0.0)) == Vector2i(1, 0)
	)
	_check(ok_boundary, "A2 区块边界取整（15.9→0、-0.1→-1、-16→-1、-16.1→-2、16→1）")

	# ── A3 to_world/to_render 往返（origin=0 时恒等）──
	var ok_ident := (
		w.to_world(Vector3(3.5, 7.0, -2.25)).is_equal_approx(Vector3(3.5, 7.0, -2.25))
		and w.to_render(Vector3(3.5, 7.0, -2.25)).is_equal_approx(Vector3(3.5, 7.0, -2.25))
	)
	_check(ok_ident, "A3 origin=0 时 to_world/to_render 恒等")

	# ── B 段：request_shift_origin 行为 ──
	Events.origin_shifted.connect(_on_shifted)
	_check(w.origin() == Vector2i.ZERO and w.position.is_equal_approx(Vector3.ZERO),
		"B1 新 World origin=(0,0)、节点位置为零")
	var inv := Inventory.new(36)
	w.box_contents[Vector3i(5, 30, 7)] = inv
	w.request_shift_origin(Vector2i(4096, -8192))
	_check(w.origin() == Vector2i(4096, -8192),
		"B2 request_shift_origin 后 origin()==请求值（%s）" % str(w.origin()))
	_check(w.position.is_equal_approx(Vector3(-4096.0, 0.0, 8192.0)),
		"B3 World 节点位置 = −origin（%s）——其下子节点自动跟随" % str(w.position))
	_check(_shift_count == 1 and _last_delta.is_equal_approx(Vector3(-4096.0, 0.0, 8192.0)),
		"B4 origin_shifted 发一次且 delta = 旧−新 origin（%s，count=%d）"
			% [str(_last_delta), _shift_count])
	# delta = 旧−新 origin = (0−4096, 0, 0−(−8192)) = (−4096, 0, +8192)，
	# 键随之 (5,30,7) → (−4091,30,8199)。
	_check(w.box_contents.has(Vector3i(-4091, 30, 8199))
		and not w.box_contents.has(Vector3i(5, 30, 7)),
		"B5 储物箱按渲染格为键，随 origin 重键（+delta）")

	# 同值幂等：再请求同一 origin 不发信号、不挪节点。
	w.request_shift_origin(Vector2i(4096, -8192))
	_check(_shift_count == 1 and w.position.is_equal_approx(Vector3(-4096.0, 0.0, 8192.0)),
		"B6 同 origin 重复请求幂等（信号仍 %d 次、节点不动）" % _shift_count)

	# ── A4 非零 origin 下的往返 ──
	var probe := Vector3(-123.5, 44.0, 678.25)
	var ok_rt := w.to_render(w.to_world(probe)).is_equal_approx(probe)
	ok_rt = ok_rt and w.to_world(probe).is_equal_approx(
		probe + Vector3(4096.0, 0.0, -8192.0))
	_check(ok_rt, "A4 非零 origin 下 to_world/to_render 互逆且偏移量正确")
	var ok_chunk_at := w.chunk_at(probe) == w.world_to_chunk(w.to_world(probe))
	_check(ok_chunk_at, "A5 chunk_at(渲染坐标) == world_to_chunk(to_world(...))")
	Events.origin_shifted.disconnect(_on_shifted)


func _run() -> void:
	# 存档隔离（D-010 铁律 3）：必须在实例化 main.tscn 之前。
	SaveGuard.snapshot()
	var prev_pick := GameState.needs_region_pick
	GameState.needs_region_pick = false

	await _run_pure()

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(90):
		await get_tree().process_frame

	var player: Player = main_scene.get_node("Player")
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()

	var world: World = player.world_ref()
	_check(world.origin() == Vector2i.ZERO,
		"C0 场景就绪时 origin 为零（搬迁只发生在越过阈值后）")

	# ── C1 标记方块：出生点旁一格，记录其世界坐标（origin=0，渲染=世界）──
	var p0: Vector3 = player.global_position
	var mark_w := Vector3i(int(floorf(p0.x)) + 3, int(floorf(p0.y)) + 1, int(floorf(p0.z)) + 3)
	world.set_block(mark_w, BlockTypes.Block.DIRT)
	_check(world.get_block(mark_w) == BlockTypes.Block.DIRT,
		"C1 标记方块可读回（world cell=%s，origin=0 渲染=世界）" % str(mark_w))
	var spawn_pos0: Vector3 = player.spawn_position
	var flight_spawn0: Vector3 = main_scene._flight_spawn
	var craft_park0: Vector3 = main_scene._craft_park

	# ── C2 传送 6000 格：越过 ORIGIN_SHIFT_THRESHOLD(4096) 即自动搬迁 ──
	# y 取 220：世界高 256、地形最高约 188，保证落点在任何山脊之上，
	# 不会一落地就嵌进方块触发脱困流程干扰断言。
	var dest_w := Vector3(6200.0, 220.0, 40.0)
	player.teleport_to(world.to_render(dest_w), 0.0)
	var pre_world := world.to_world(player.global_position)
	_dbg("C2 传送后: render=%s world=%s origin=%s"
		% [str(player.global_position), str(pre_world), str(world.origin())])
	var shifted := false
	for i in range(30):
		await get_tree().process_frame
		if world.origin() != Vector2i.ZERO:
			shifted = true
			break
	_check(shifted, "C2a 越过阈值后 origin 自动搬迁（30 帧内）")
	_check(world.origin() == Vector2i(4096, 0),
		"C2b 新 origin 对齐 ORIGIN_SHIFT_GRID 网格（%s，期望 (4096,0)）"
			% str(world.origin()))
	var post_world := world.to_world(player.global_position)
	var dxz := Vector2(post_world.x - pre_world.x, post_world.z - pre_world.z).length()
	_check(dxz < 0.5,
		"C2c 搬迁不改变玩家世界坐标（x/z 漂移 %.3f 格；render=%s→%s）"
			% [dxz, str(world.to_render(pre_world)), str(player.global_position)])
	_check(absf(post_world.y - pre_world.y) < 5.0,
		"C2d 搬迁不改变玩家世界高度（Δy=%.2f，仅允许几帧自由落）"
			% absf(post_world.y - pre_world.y))

	# ── C3 渲染空间锚点重基：spawn_position/_flight_spawn/_craft_park ──
	var ok_anchor := (
		world.to_world(player.spawn_position).distance_to(spawn_pos0) < 1.0
		and world.to_world(main_scene._flight_spawn).distance_to(flight_spawn0) < 1.0
		and world.to_world(main_scene._craft_park).distance_to(craft_park0) < 1.0
	)
	_check(ok_anchor,
		"C3 渲染锚点随 origin 重基（spawn/flight_spawn/craft_park 世界坐标不变）")

	# ── D 实体不变式：船 / 飞机出生即进组，手动 shift 后世界坐标不变 ──
	# 时序要点：D 必须在「回传出生区」之前做——C2 后 origin=(4096,0)、玩家
	# 世界坐标 ≈(6200,40)，与 origin 相距 2104 格，手动再搬 2048/1024 仍在
	# 阈值内，不会被 _maybe_shift_origin 立刻改回去（若回出生区后再搬，
	# |60−6144|>4096 会触发自动回搬，双重搬迁会让断言全部失配）。
	var boat_at := player.global_position + Vector3(6.0, 0.0, 0.0)
	var boat := Boat.spawn(main_scene, boat_at, PI, "raft")
	# 落点锚定「出生后的实际节点位置」：Boat.spawn 原样落位，而
	# Aircraft.place() 会抬 GROUND_CLEARANCE+0.05，直接用传入点比会差一段 y。
	var boat_pos0 := boat.global_position
	var boat_world0 := world.to_world(boat.global_position)
	boat.harbor_pos = boat_at
	var craft_at := player.global_position + Vector3(-8.0, 0.0, 2.0)
	var craft := Aircraft.spawn(main_scene, craft_at, PI)
	var craft_pos0 := craft.global_position
	var craft_world0 := world.to_world(craft.global_position)
	var craft_state0: Vector3 = craft._state.position
	_dbg("D 段出生: boat_world=%s craft_world=%s origin=%s"
		% [str(boat_world0), str(craft_world0), str(world.origin())])

	# 手动搬迁（2048/1024，不超阈值、不会被 _maybe_shift_origin 立刻改掉）：
	var origin_before := world.origin()
	world.request_shift_origin(origin_before + Vector2i(2048, 1024))
	var expect_delta := Vector3(
		float(origin_before.x) - float(origin_before.x + 2048), 0.0,
		float(origin_before.y) - float(origin_before.y + 1024))
	_check(boat.global_position.is_equal_approx(boat_pos0 + expect_delta),
		"D1 船节点随搬迁 +delta（%s → %s）"
			% [str(boat_pos0), str(boat.global_position)])
	_check(world.to_world(boat.global_position).distance_to(boat_world0) < 0.01,
		"D2 船世界坐标不变（距原点 %.3f）"
			% world.to_world(boat.global_position).distance_to(boat_world0))
	_check(world.to_world(boat.harbor_pos).distance_to(boat_world0) < 0.01,
		"D3 船 harbor_pos 锚点同步重基（世界坐标不变）")
	_check(craft.global_position.is_equal_approx(craft_pos0 + expect_delta),
		"D4 飞机节点随搬迁 +delta")
	_check(world.to_world(craft.global_position).distance_to(craft_world0) < 0.01,
		"D5 飞机世界坐标不变")
	_check(craft._state.position.distance_to(craft_state0 + expect_delta) < 0.01,
		"D6 飞机 _state.position 同步重基（遥测/快照不读旧坐标）")
	_check(world.position.is_equal_approx(
			Vector3(-float(world.origin().x), 0.0, -float(world.origin().y))),
		"D7 World 节点位置 = −origin（%s）" % str(world.position))

	# ── C4 回传出生区：区块经历卸载→重载，标记方块须还在同一世界格 ──
	# 注意：回传后玩家世界坐标 ≈(60,40)，与 D 段后的 origin 相距 >4096，
	# 会触发一次自动回搬（origin 对齐到 (0,1024)）——这正是「往返各搬一次」
	# 的完整链路；C4a 的期望值按回传后的实时 origin 现算，不受其影响。
	player.teleport_to(world.to_render(p0), 0.0)
	for i in range(150):
		await get_tree().process_frame
	var mark_render := world.to_render(Vector3(mark_w))
	_check(world.get_block(Vector3i(mark_render)) == BlockTypes.Block.DIRT,
		"C4a 卸载/重载/搬迁往返后标记方块仍在同一世界格（render %s→%s, origin=%s）"
			% [str(mark_w), str(Vector3i(mark_render)), str(world.origin())])
	_check(Vector3i(mark_render) != mark_w,
		"C4b 同一世界格的渲染坐标确已随 origin 改变（证明搬迁真的发生了）")

	# ── 收尾：还原并退出 ──────────────────────────────
	GameState.needs_region_pick = prev_pick
	SaveGuard.restore()
	_restored = true
	print("WORLD_COORD_TEST_%s" % ("OK" if _failed == 0 else "FAILED"))
	get_tree().quit(0 if _failed == 0 else 1)


func _exit_tree() -> void:
	# D-010 安全网：协程猝死时末尾还原不会执行，退出期再兜一层（幂等）。
	if not _restored:
		_restored = true
		SaveGuard.restore()
