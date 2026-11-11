extends Node
## 脱困环路回归探针（D-059）：用户实测「坠机后一直闪屏」，存档 died 计数器
## 短时间 +46——根因是 _force_unstuck 的脱困落点仍嵌在地形里时每 3 物理帧
## 重入一次，每次 died.emit() 都会重启 HUD 的 RIP 覆盖层淡入淡出（频闪），
## 并给死亡计数 +1。
##
## 场景：实例化 main.tscn（默认区域 ASIA，带机场），SaveGuard 隔离存档。
##   A 段 复现环路：在出生点列上盖 100 格实心柱（超出原 64 格搜索上限）——
##      玩家初始就站在出生点列，柱子一盖即嵌入；跑 150 帧数 died 发射次数。
##      修复后：died ≤ 2、玩家被送到柱顶非嵌入态、生命回满。
##      （改造前基线：搜索 64 格搜满 → 回退原始出生点（柱底，仍嵌入）→
##       每 3 帧重入 → died 风暴，本段 FAIL。）
##   B 段 普通死亡流不回归：take_damage 致死 → 一次 died → 墓碑停顿 →
##      回出生点重生，途中不触发脱困。
##   C 段 真实坠机链（D-056）：登机 → 机体传进山坡 → wreck 弹射 → 自动归位
##      → 玩家不嵌入、died ≤ 2、回到初始出生点。
##
## 计数铁律：died 用成员变量 + 方法连接计数。GDScript lambda 按值捕获，
## `player.died.connect(func(): n += 1)` 里的 n 恒为 0（2026-10-20 实测），
## 上一版探针因此假阴性。
##
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/stuck_rescue_probe.tscn

var _failed := 0
## died 发射计数（成员变量，避免 lambda 按值捕获）。
var _died_count := 0
## 还原幂等标记（SaveGuard.restore 只生效一次）。
var _restored := false


func _ready() -> void:
	# 看门狗：协程被脚本错误猝杀时强制退出（否则进程挂起、还原不执行）。
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		push_warning("stuck_rescue_probe: 看门狗超时，强制退出")
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


func _on_died_count() -> void:
	_died_count += 1


## 玩家是否嵌在实心方块里（与 Player._check_stuck 同一判据：脚格 + 头格均实心）。
func _embedded(player: Player, world: World) -> bool:
	var p: Vector3 = player.global_position
	var feet := BlockTypes.is_solid(world.get_block(Vector3i(p.floor())))
	var head := BlockTypes.is_solid(
		world.get_block(Vector3i((p + Vector3(0.0, 1.4, 0.0)).floor())))
	return feet and head


func _run() -> void:
	# 存档隔离（D-010 铁律 3）：必须在实例化 main.tscn 之前。
	SaveGuard.snapshot()
	var prev_pick := GameState.needs_region_pick
	GameState.needs_region_pick = false

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
	var spawn_pos: Vector3 = player.spawn_position
	var flight_spawn: Vector3 = main_scene._flight_spawn
	var craft_park: Vector3 = main_scene._craft_park
	_dbg("spawn_position=%s flight_spawn=%s craft_park=%s"
		% [str(spawn_pos), str(flight_spawn), str(craft_park)])
	player.died.connect(_on_died_count)

	# ── A 段：出生点列被 100 格实心柱堵死，复现「脱困落点仍嵌入」环路 ──
	# 玩家初始就站在出生点列上，柱子一盖脚格 + 头格即实心（嵌入前提立即成立）。
	# 计数窗口前移到盖柱前：修复后脱困发生在柱子就绪后的前几帧里。
	# 负坐标统一 floor 语义，与 _embedded() 的 Vector3i(p.floor()) 同源：
	# int(-204.5)=-204（向零），floor(-204.5)=-205；D-091 机场中心南移后出生点
	# z 变负，旧 int() 把柱子盖到相邻列，A1/A4 成对假红。拆柱(:127)复用同变量。
	var foot_cell := Vector3i(spawn_pos.floor())
	var sx := foot_cell.x
	var sz := foot_cell.z
	var base_y := foot_cell.y
	var died_a0: int = _died_count
	var rescues_a0: int = player.stuck_rescues
	for y in range(base_y, base_y + 100):
		world.set_block(Vector3i(sx, y, sz), BlockTypes.Block.DIRT)
	_dbg("A 段柱子就绪: (%d, %d..%d, %d)" % [sx, base_y, base_y + 99, sz])
	# 反向对照守卫：盖柱必须命中 _embedded() 实际读取的脚格（floor 语义）。
	# 把 floor 退回 int() 时，负 Z 下此守卫读到 AIR 立即变红，不会静默误报。
	var probe_feet := Vector3i(player.global_position.floor())
	_check(world.get_block(probe_feet) == BlockTypes.Block.DIRT,
		"A0 反向对照：盖柱命中 _embedded 脚格 floor=%s（非 int 截断列）" % str(probe_feet))
	_check(_embedded(player, world),
		"A1 柱子就绪后玩家嵌在柱底（%s）" % str(player.global_position))
	# 等脱困并观察 150 帧：修复后一次送到柱顶（died ≤2），随后不再重入。
	var last_rescue_pos := player.global_position
	for i in range(150):
		await get_tree().physics_frame
		if player.stuck_rescues > rescues_a0:
			rescues_a0 = player.stuck_rescues
			last_rescue_pos = player.global_position
			_dbg("A 段第 %d 次脱困 -> pos=%s embedded=%s health=%d died=%d"
				% [rescues_a0, str(player.global_position),
					str(_embedded(player, world)), player.health, _died_count])
	var died_a: int = _died_count - died_a0
	_check(not _embedded(player, world),
		"A2 150 帧后玩家不在嵌入态（pos=%s rescues=%d died=%d）"
			% [str(player.global_position), player.stuck_rescues, died_a])
	_check(died_a <= 2,
		"A3 脱困不循环：died 发射 ≤2（实际 %d，rescues=%d）——每次 died 都重启 RIP 频屏"
			% [died_a, player.stuck_rescues])
	_check(last_rescue_pos.y >= float(base_y + 95),
		"A4 脱困落点在柱顶附近（y=%.1f，柱顶=%d）——搜索必须覆盖到世界顶而非 64 格截断"
			% [last_rescue_pos.y, base_y + 100])
	_check(player.health == player.MAX_HEALTH,
		"A5 脱困后生命回满（%d）" % player.health)

	# 拆柱，恢复出生点列原状（世界改动不落盘，但别影响后续段）。
	for y in range(base_y, base_y + 100):
		world.set_block(Vector3i(sx, y, sz), BlockTypes.Block.AIR)
	for i in range(6):
		await get_tree().physics_frame

	# ── B 段：普通死亡流（墓碑停顿 → 回出生点）不回归、不触发脱困 ──
	var died_b0: int = _died_count
	player.take_damage(999, "探针致死")
	_check(player.is_dead(), "B1 take_damage 致死后进入死亡停顿")
	for i in range(200):  # DEATH_PAUSE 2.2s ≈ 132 帧，留余量
		await get_tree().physics_frame
		if not player.is_dead():
			break
	var died_b: int = _died_count - died_b0
	_check(not player.is_dead(), "B2 墓碑停顿后复活")
	_check(player.health == player.MAX_HEALTH, "B3 复活后生命回满（%d）" % player.health)
	_check(not _embedded(player, world),
		"B4 重生点不嵌入（pos=%s）" % str(player.global_position))
	_check(died_b <= 1,
		"B5 普通死亡只发一次 died（实际 %d）——不触发脱困、不频闪" % died_b)

	# ── C 段：真实坠机链——机体嵌山 → wreck 弹射 → 自动归位（D-056） ──
	var hill_x := 0
	var hill_z := 0
	var hill_h := -1
	for x in range(130, 190, 2):
		for z in range(60, 140, 2):
			var h: int = world.get_surface_height(x, z)
			if h > hill_h:
				hill_h = h
				hill_x = x
				hill_z = z
	_dbg("C 段山坡样本: (%d,%d) surface=%d" % [hill_x, hill_z, hill_h])
	var craft := Aircraft.spawn(main_scene, craft_park, PI)
	player.rotation.y = 0.8
	player.ride_aircraft(craft)
	for i in range(30):
		await get_tree().process_frame
	_check(player.is_riding(), "C1 玩家已登机")
	var bury := Vector3(hill_x + 0.5, float(hill_h - 1), hill_z + 0.5)
	craft.global_position = bury
	for i in range(2):
		await get_tree().physics_frame
	_dbg("C 段坠机点（机体嵌入）: craft=%s player=%s"
		% [str(craft.global_position), str(player.global_position)])
	var died_c0: int = _died_count
	craft.wreck("探针撞山坠机")
	for i in range(150):
		await get_tree().physics_frame
	_dbg("C 段结束: pos=%s embedded=%s health=%d died=%d riding=%s"
		% [str(player.global_position), str(_embedded(player, world)),
			player.health, _died_count - died_c0, str(player.is_riding())])
	var died_c: int = _died_count - died_c0
	_check(not _embedded(player, world),
		"C2 弹射+自动归位后玩家不在嵌入态（pos=%s）" % str(player.global_position))
	_check(died_c <= 2,
		"C3 撞山弹射后脱困不循环：died ≤2（实际 %d）" % died_c)
	var d_home: Vector3 = player.global_position - flight_spawn
	_check(Vector2(d_home.x, d_home.z).length() < 5.0,
		"C4 自动归位把玩家送回初始出生点（水平距 %.1f，D-056 语义）"
			% Vector2(d_home.x, d_home.z).length())

	# ── 收尾：还原并退出 ──────────────────────────────
	GameState.needs_region_pick = prev_pick
	SaveGuard.restore()
	_restored = true
	print("STUCK_RESCUE_TEST_%s" % ("OK" if _failed == 0 else "FAILED"))
	get_tree().quit(0 if _failed == 0 else 1)


func _exit_tree() -> void:
	# D-010 安全网：协程猝死时末尾还原不会执行，退出期再兜一层（幂等）。
	if not _restored:
		_restored = true
		SaveGuard.restore()
