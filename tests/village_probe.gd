extends Node
## 无头村庄探针：验证村庄生成（民居/广场/酿灶台/掠夺塔）、村民与掠夺者、
## 交易面板与交易执行、不死图腾拯救、玩家头发。
## 运行：Godot_v4.6.3-stable_win64_console.exe --headless --path . res://tests/village_probe.tscn

var _failed := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame

	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")
	var hud: HUD = main_scene.get_node("UI")
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")

	# 关闭自动生成计时器，保证确定性（村庄 NPC 挂在 main 下，不受其管理）。
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()

	# 探针独立复算村庄基准高度（get_surface_height 为纯噪声，与生成时一致）。
	var base_y := _probe_base_y(world)
	_check(base_y > 0, "村庄基准高度可探测（base_y=%d）" % base_y)
	# 0.5m 化后村庄占地 ×2，四角距出生锚点 40+ 格超出卸载半径：
	# 结构断言前先强制加载整个村庄区域（村庄改动有卸载留存，原样还原）。
	world.ensure_chunks_in_region(
		Vector3i(VillageBuilder.REGION_MIN.x, 0, VillageBuilder.REGION_MIN.z),
		Vector3i(VillageBuilder.REGION_MAX.x, base_y + 2, VillageBuilder.REGION_MAX.z),
	)

	# ── 阶段 A：村庄结构 ──────────────────────────────
	# 坐标全部对应 0.5m 化后的布局（VillageBuilder 常量 ×2）。
	_check(
		world.get_block(Vector3i(54, base_y + 1, 52)) == BlockTypes.Block.BREWING,
		"酿灶台方块存在于广场东侧 (54,%d,52)" % (base_y + 1),
	)

	# 出生点位置随区域而异：
	# - 带机场的区域（如亚洲）出生点改写到跑道旁（main.gd _airport_center +
	#   AirportBuilder），落地即站在跑道上、可立即起飞；
	# - 其余区域仍锚定村庄广场。故按 has_airport 分流断言。
	var spawn_xz := Vector2(player.global_position.x, player.global_position.z)
	if RegionAtlas.has_airport(GameState.current_region):
		# 验证出生点落在跑道上：出生列周围（脚下）存在跑道方块 COBBLESTONE/SAND。
		var on_runway := false
		var feet_y := int(player.global_position.y) - 1
		for dx in range(-3, 4):
			for dz in range(-3, 4):
				var b := world.get_block(Vector3i(int(spawn_xz.x) + dx, feet_y, int(spawn_xz.y) + dz))
				if b == BlockTypes.Block.COBBLESTONE or b == BlockTypes.Block.SAND:
					on_runway = true
					break
			if on_runway:
				break
		_check(on_runway, "带机场区域出生点落在跑道旁（出生列 %s）" % Vector3i(player.global_position.floor()))
	else:
		var plaza_xz := Vector2(49.0, 53.0)
		_check(
			spawn_xz.distance_to(plaza_xz) < 20.0,
			"出生点锚定村庄旁（距广场 %.1f 格）" % spawn_xz.distance_to(plaza_xz),
		)

	# 民居玻璃窗：位置由 VillageBuilder._build_house 决定（x=0/11 两侧墙 y+3）。
	_check(
		world.get_block(Vector3i(30, base_y + 3, 39)) == BlockTypes.Block.GLASS
			and world.get_block(Vector3i(41, base_y + 3, 39)) == BlockTypes.Block.GLASS,
		"民居墙体嵌有玻璃窗方块",
	)
	_check(BlockTypes.is_transparent(BlockTypes.Block.GLASS), "玻璃在方块表中标记为透明")

	var grass_ok := true
	for cell: Vector3i in [
		Vector3i(26, base_y, 32), Vector3i(82, base_y, 80),
		Vector3i(82, base_y, 32), Vector3i(26, base_y, 80),
		Vector3i(54, base_y, 52),
	]:
		if world.get_block(cell) != BlockTypes.Block.GRASS:
			grass_ok = false
	_check(grass_ok, "村庄地基抽查均为 GRASS（四角与中部，整平生效）")

	_check(
		world.get_block(Vector3i(30, base_y + 1, 36)) == BlockTypes.Block.COBBLESTONE,
		"民居圆石墙体",
	)
	_check(world.get_block(Vector3i(30, base_y + 5, 36)) == BlockTypes.Block.WOOD, "民居木质屋顶")
	_check(
		world.get_block(Vector3i(74, base_y + 5, 44)) == BlockTypes.Block.COBBLESTONE,
		"掠夺塔塔体为圆石",
	)
	_check(
		world.get_block(Vector3i(74, base_y + 17, 44)) == BlockTypes.Block.WOOD,
		"掠夺塔顶为木质平台",
	)
	_check(world.get_block(Vector3i(74, base_y + 1, 42)) == BlockTypes.Block.AIR, "掠夺塔南门门洞")
	_check(ItemTypes.is_placeable(BlockTypes.Block.BREWING), "酿灶台判定为可放置物品")
	_check(BlockTypes.HARDNESS.has(BlockTypes.Block.BREWING), "酿灶台在硬度表中（可破坏）")

	# ── 阶段 B：村民与掠夺者 ──────────────────────────────
	var villagers: Array[Mob] = []
	var pillagers: Array[Mob] = []
	for child in main_scene.get_children():
		var mob := child as Mob
		if mob == null or mob.is_queued_for_deletion():
			continue
		if mob.type == Mob.MobType.VILLAGER:
			villagers.append(mob)
		elif mob.type == Mob.MobType.PILLAGER:
			pillagers.append(mob)
	_check(villagers.size() >= 4, "村民至少 4 名（实际 %d，含新增村庄）" % villagers.size())
	_check(pillagers.size() >= 2, "掠夺者至少 2 名（三座村庄共 %d）" % pillagers.size())
	_check(Mob.is_passive(Mob.MobType.VILLAGER), "村民判定为被动（不被昼夜清空）")
	_check(not Mob.is_passive(Mob.MobType.PILLAGER), "掠夺者判定为敌对")

	# 村民被击杀不掉落任何物品（drop_item=AIR、无掉落表）。
	if not villagers.is_empty():
		var ids := await _kill_and_collect(villagers[0])
		_check(ids.is_empty(), "村民被击杀不掉落物品（实际掉落 %s）" % [ids])

	# ── 阶段 C：掠夺者白天驻守与掉落 ──────────────────────
	# 把玩家与一名掠夺者传送到村庄平整区中央，保证脚下地形确定。
	player.global_position = Vector3(49.5, base_y + 1.1, 53.5)
	player.velocity = Vector3.ZERO
	if not pillagers.is_empty():
		var guard := pillagers[0]
		var hp_before := player.health
		var origin := player.global_position + Vector3(6.0, 0.1, 0.0)
		guard.global_position = origin
		guard.velocity = Vector3.ZERO
		for i in range(60):
			await get_tree().physics_frame
		var moved := guard.global_position.distance_to(origin)
		_check(player.health == hp_before, "白天掠夺者贴近玩家 6m 不攻击（驻守）")
		_check(moved < 2.0, "白天掠夺者原地驻守不追击（位移 %.2f m）" % moved)
		# 送回塔门位置再击杀，掉落物远离玩家，避免被拾取干扰断言。
		guard.global_position = Vector3(75.5, base_y + 1.0, 40.5)
		var drops := await _kill_and_collect(guard)
		_check(drops.has(ItemTypes.TOTEM), "击杀掠夺者掉落不死图腾")
		_check(drops.has(ItemTypes.EMERALD), "击杀掠夺者掉落绿宝石×2")

	# ── 阶段 D：不死图腾拯救 ──────────────────────────────
	player.inventory.add_item(ItemTypes.TOTEM, 1)
	player.health = 2
	player._damage(5)
	_check(player.health == Player.MAX_HEALTH / 2, "致命伤触发图腾拯救（血量恢复半血 10）")
	_check(player.inventory.count_item(ItemTypes.TOTEM) == 0, "图腾拯救后自动消耗")

	# ── 阶段 E：玩家头发 ──────────────────────────────
	_check(player._model.has_hair(), "玩家模型已生成头发（HairTop/HairBack/HairFringe）")

	# ── 阶段 E2：床睡觉跳过夜晚 ──────────────────────────
	var dn: DayNightCycle = main_scene.get_node("DayNightCycle")
	dn._time = DayNightCycle.DAY_LENGTH + 30.0
	_check(not dn.is_day() and dn.sleep_to_morning(), "夜晚睡床直接跳到次日清晨")
	_check(not dn.sleep_to_morning(), "白天睡床无效（sleep_to_morning 返回假）")

	# ── 阶段 F：交易面板与交易执行 ──────────────────────────
	_check(hud._trade_overlay != null, "交易面板已构建")
	Events.request_trade.emit()
	_check(hud._trade_overlay.visible, "request_trade 信号打开交易面板（B 键/触屏/右键共用）")
	hud.set_trade_open(false)
	_check(not hud._trade_overlay.visible, "交易面板可关闭")

	# 右键指向村民：村民瞬移到玩家正前方的广场地面并禁用游走。
	# 必须等待物理帧让瞬移后的碰撞体同步（同帧射线查的是旧物理位置）。
	var trader := _find_villager(main_scene)
	if trader != null:
		trader.global_position = Vector3(49.5, base_y + 1.0, 51.0)
		trader.velocity = Vector3.ZERO
		trader._wander_dir = Vector3.ZERO
		trader._wander_timer = 99.0
		for i in range(40):
			await get_tree().physics_frame
		var opened := player._interact_village()
		_check(opened, "右键指向村民触发交易（_interact_village）")
		_check(hud._trade_overlay.visible, "右键村民后交易面板处于打开状态")
		hud.set_trade_open(false)

	# 交易执行：2 绿宝石 → 生牛排×3。
	player.inventory.add_item(ItemTypes.EMERALD, 4)
	var beef_before := player.inventory.count_item(ItemTypes.RAW_BEEF)
	hud._on_trade_pressed(ItemTypes.TRADES[0])
	_check(player.inventory.count_item(ItemTypes.EMERALD) == 2, "交易扣除 2 绿宝石（4→2）")
	_check(
		player.inventory.count_item(ItemTypes.RAW_BEEF) == beef_before + 3,
		"交易获得生牛排×3",
	)
	_check(ItemTypes.item_name(ItemTypes.TRADES[0]["result"]) != "", "交易条目指向有效物品（%s）" % ItemTypes.item_name(ItemTypes.TRADES[0]["result"]))

	var poor := {"cost": 99, "result": ItemTypes.RAW_BEEF, "count": 1}
	_check(not hud._can_trade(poor), "绿宝石不足时交易不可用")
	_check(hud._can_trade(ItemTypes.TRADES[0]), "绿宝石充足时交易可用")

	# 酿灶台方块可放置并读回（用玩家旁的格子，远离玩家会被流式卸载）。
	var brew_cell := Vector3i(
		int(player.global_position.x) + 2,
		int(player.global_position.y) + 3,
		int(player.global_position.z))
	world.set_block(brew_cell, BlockTypes.Block.BREWING)
	_check(
		world.get_block(brew_cell) == BlockTypes.Block.BREWING,
		"酿灶台方块可放置读回",
	)

	if _failed == 0:
		print("VILLAGE_TEST_OK")
		get_tree().quit(0)
	else:
		print("VILLAGE_TEST_FAILED count=%d" % _failed)
		get_tree().quit(1)


## 复算村庄基准高度：与 VillageBuilder._probe_base_y 同款循环。
func _probe_base_y(world: World) -> int:
	var top := 0
	for x in range(VillageBuilder.REGION_MIN.x, VillageBuilder.REGION_MAX.x + 1):
		for z in range(VillageBuilder.REGION_MIN.z, VillageBuilder.REGION_MAX.z + 1):
			top = maxi(top, world.get_surface_height(x, z) - 1)
	return top


func _find_villager(main_scene: Node) -> Mob:
	for child in main_scene.get_children():
		var mob := child as Mob
		if mob != null and mob.type == Mob.MobType.VILLAGER and not mob.is_queued_for_deletion():
			return mob
	return null


## 击杀生物并收集 10 帧内其父节点下出现的掉落物 ID（去重）。
## 击杀后 mob 会被 queue_free，父节点引用需在击杀前获取。
func _kill_and_collect(mob: Mob) -> Array[int]:
	var ids: Array[int] = []
	if mob == null:
		return ids
	var parent := mob.get_parent()
	if parent == null:
		return ids
	mob.take_damage(99)
	for i in range(10):
		await get_tree().process_frame
		for child in parent.get_children():
			if child is DroppedItem:
				var id := (child as DroppedItem).item_id
				if not ids.has(id):
					ids.append(id)
	return ids


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
