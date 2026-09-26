extends Node
## 无头生物探针：验证牛/羊/鸡被动行为、骷髅远程射箭、昼夜双轨生成与掉落闭环。
## 运行：Godot_console.exe --headless --path . res://tests/mob_probe.tscn

const TIMEOUT_FRAMES := 600

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
	var day_night: DayNightCycle = main_scene.get_node("DayNightCycle")
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")

	# 关闭自动生成计时器，全部由探针手动驱动，保证确定性。
	# 注意：上方等待帧期间被动生成器可能已自动刷入动物，先清场。
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()

	# ── 阶段 A：白天被动动物 ──────────────────────────────
	_check(day_night.is_day(), "初始为白天")

	spawner._spawn_one(Mob.MobType.COW)
	spawner._spawn_one(Mob.MobType.SHEEP)
	spawner._spawn_one(Mob.MobType.CHICKEN)
	_check(spawner._mobs.size() == 3, "手动生成牛/羊/鸡各一只")
	_check(spawner._passive_count() == 3, "三只均为被动类型")
	_check(spawner._hostile_count() == 0, "无敌对生物")

	var cow := _find_mob(spawner, Mob.MobType.COW)
	var sheep := _find_mob(spawner, Mob.MobType.SHEEP)
	var chicken := _find_mob(spawner, Mob.MobType.CHICKEN)
	_check(cow != null and sheep != null and chicken != null, "三类动物均在场景中")

	# 生成器会随机抽中幼体阶段（12%/阶段），掉落断言要求成体：统一强制拉到末段。
	for specimen: Mob in [cow, sheep, chicken]:
		if specimen != null and not specimen.is_adult():
			specimen.stage = Mob.stage_count_of(specimen.type) - 1
			specimen._rebuild_visual()
			specimen._apply_stage_stats()

	# 白天推进若干帧：动物不被清除。
	for i in range(30):
		await get_tree().process_frame
	_check(spawner._passive_count() == 3, "白天推进后动物仍存在")

	# 被动不攻击：把牛传送到玩家旁 1 米，贴近站立 1 秒（玩家保持原地不动）。
	if cow != null:
		var hp_before := player.health
		cow.global_position = player.global_position + Vector3(1.0, 0.2, 0.0)
		cow.velocity = Vector3.ZERO
		cow._flee_timer = 0.0
		cow._wander_dir = Vector3.ZERO
		for i in range(60):
			await get_tree().physics_frame
		_check(player.health == hp_before, "贴近动物 1 秒玩家未受伤（被动不攻击）")

	# 受击逃跑。
	if cow != null:
		cow.take_damage(1)
		_check(cow._flee_timer > 0.0, "牛受击后进入逃跑状态")
		cow._flee_timer = 0.0

	# 击杀掉落闭环：牛→生牛排、羊→羊毛、鸡→生鸡肉。
	var beef_found := await _kill_and_find_drop(cow, ItemTypes.RAW_BEEF)
	_check(beef_found, "击杀牛掉落生牛排")
	var wool_found := await _kill_and_find_drop(sheep, BlockTypes.Block.WOOL)
	_check(wool_found, "击杀羊掉落羊毛（可放置方块）")
	var chicken_found := await _kill_and_find_drop(chicken, ItemTypes.RAW_CHICKEN)
	_check(chicken_found, "击杀鸡掉落生鸡肉")

	# 羊毛可放置：作为方块可读回且在硬度表中。
	# （0.5m 化后出生点锚定村庄，硬编码 (12,37,12) 远离玩家会被流式卸载——
	# 改用玩家头顶旁的格子，保证区块常驻。）
	var wool_cell := Vector3i(
		int(player.global_position.x) + 2,
		int(player.global_position.y) + 3,
		int(player.global_position.z))
	world.set_block(wool_cell, BlockTypes.Block.WOOL)
	_check(world.get_block(wool_cell) == BlockTypes.Block.WOOL, "羊毛方块可放置并读回")
	_check(BlockTypes.HARDNESS.has(BlockTypes.Block.WOOL), "羊毛在硬度表中（可徒手破坏）")
	_check(ItemTypes.is_placeable(BlockTypes.Block.WOOL), "羊毛判定为可放置物品")
	_check(not ItemTypes.is_placeable(ItemTypes.RAW_BEEF), "生牛排不可放置")

	# 进食：饥饿 10 + 生牛排(8) → 18，消耗 1 个。
	# （击杀牛掉落的牛排可能已被玩家拾取，故按"吃前数量-1"断言。）
	player.inventory.add_item(ItemTypes.RAW_BEEF, 1)
	var beef_slot := _find_slot(player, ItemTypes.RAW_BEEF)
	_check(beef_slot >= 0, "生牛排已进入背包")
	if beef_slot >= 0:
		player.select_slot(beef_slot)
		player.hunger = 10.0
		var count_before: int = player.inventory.get_count(beef_slot)
		var eaten := player._eat_selected()
		var count_after: int = player.inventory.get_count(beef_slot)
		_check(eaten and absf(player.hunger - 18.0) < 0.01, "食用生牛排饥饿 10→18")
		_check(count_after == count_before - 1, "食用后消耗 1 个生牛排")
	player.hunger = 20.0

	# ── 阶段 B：夜晚敌对生物 ──────────────────────────────
	day_night._time = DayNightCycle.DAY_LENGTH + 5.0
	_check(not day_night.is_day(), "已切至夜晚")

	# 骷髅远程：放在玩家正前 6m，清空视线走廊。
	var skel := _spawn_at(spawner, Mob.MobType.SKELETON, player.global_position + Vector3(0.0, 0.2, 6.0))
	_check(skel != null, "夜晚生成骷髅")
	for z in range(9, 15):
		world.set_block(Vector3i(8, 37, z), BlockTypes.Block.AIR)
		world.set_block(Vector3i(8, 38, z), BlockTypes.Block.AIR)
	var hp_before_skel := player.health
	var arrow_seen := false
	if skel != null:
		skel._attack_timer = 0.0
		for i in range(60):
			await get_tree().physics_frame
			if _find_arrow(spawner):
				arrow_seen = true
				break
	_check(arrow_seen, "骷髅在射程内射出箭矢")
	var player_hit := false
	for i in range(90):
		await get_tree().physics_frame
		if player.health < hp_before_skel:
			player_hit = true
			break
	_check(player_hit, "箭矢命中玩家造成伤害")

	# 蜘蛛/骷髅掉落：击杀断言掉落物 ID。
	var spider := _spawn_at(spawner, Mob.MobType.SPIDER, player.global_position + Vector3(6.0, 0.2, 6.0))
	var spider_drop_ok := await _kill_and_find_drop(spider, ItemTypes.STRING)
	_check(spider_drop_ok, "击杀蜘蛛掉落线")
	var skel_drop_ok := await _kill_and_find_drop(skel, ItemTypes.BONE)
	_check(skel_drop_ok, "击杀骷髅掉落骨头")

	# 夜晚自动刷新：类型必须为三类敌对之一。
	spawner._spawn_timer = 0.0
	await get_tree().process_frame
	await get_tree().process_frame
	var auto_ok := false
	for mob in spawner._mobs:
		if is_instance_valid(mob) and not Mob.is_passive(mob.type):
			auto_ok = true
			break
	_check(auto_ok, "夜晚自动生成敌对生物")

	# ── 阶段 C：白天清敌对、保留动物 ──────────────────────
	spawner._spawn_one(Mob.MobType.COW)
	day_night._time = 1.0
	await get_tree().process_frame
	await get_tree().process_frame
	_check(spawner._hostile_count() == 0, "白天敌对生物被清空")
	_check(spawner._passive_count() > 0, "白天动物被保留")

	if _failed == 0:
		print("MOB_TEST_OK")
		get_tree().quit(0)
	else:
		print("MOB_TEST_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _find_mob(spawner: MobSpawner, type: Mob.MobType) -> Mob:
	for mob in spawner._mobs:
		if is_instance_valid(mob) and mob.type == type and not mob.is_queued_for_deletion():
			return mob
	return null


func _spawn_at(spawner: MobSpawner, type: Mob.MobType, pos: Vector3) -> Mob:
	var before := spawner._mobs.size()
	spawner._spawn_one(type)
	if spawner._mobs.size() == before:
		return null
	var mob: Mob = spawner._mobs[spawner._mobs.size() - 1]
	mob.global_position = pos
	return mob


func _find_arrow(spawner: MobSpawner) -> ArrowProjectile:
	for child in spawner.get_children():
		if child is ArrowProjectile:
			return child
	return null


## 击杀生物并在其父节点下寻找指定 ID 的掉落物。
## 注意：击杀后 mob 会被 queue_free，父节点引用需在击杀前获取。
func _kill_and_find_drop(mob: Mob, expected_id: int) -> bool:
	if mob == null:
		return false
	var parent := mob.get_parent()
	if parent == null:
		return false
	mob.take_damage(99)
	for i in range(10):
		await get_tree().process_frame
		for child in parent.get_children():
			if child is DroppedItem and child.item_id == expected_id:
				return true
	return false


func _find_slot(player: Player, item: int) -> int:
	for s in range(Inventory.SLOT_COUNT):
		if player.inventory.get_item(s) == item and player.inventory.get_count(s) > 0:
			return s
	return -1


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
