extends Node
## 无头生存扩展探针：验证动物驻足节奏、按住左键连击、猪/狼生物、
## 夜晚天黑（环境光调制）、储物箱存取/破坏散落、村庄农田与面包链路，
## 以及堆叠 100、背包分类整理、铜锡矿生成、冶炼链路、生物名牌与 HUD 新增面板。
## 运行：Godot_v4.6.3-stable_win64_console.exe --headless --path . res://tests/life_probe.tscn

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
	var day_night: DayNightCycle = main_scene.get_node("DayNightCycle")
	var env: Environment = (main_scene.get_node("WorldEnvironment") as WorldEnvironment).environment

	# 关闭自动生成计时器，保证确定性；强制生存模式（收获/食用依赖生存分支）。
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	GameState.set_mode(GameState.Mode.SURVIVAL)

	var base_y := _probe_base_y(world)
	_check(base_y > 0, "村庄基准高度可探测（base_y=%d）" % base_y)

	# ── 阶段 A：生物数据与生成概率 ──────────────────────────
	_check(Mob.is_passive(Mob.MobType.PIG), "猪判定为被动生物")
	_check(not Mob.is_passive(Mob.MobType.WOLF), "狼判定为敌对生物")

	var pig := Mob.new()
	pig.setup(Mob.MobType.PIG, player, day_night)
	_check(pig.health == 8 and pig.drop_item == ItemTypes.RAW_PORK and pig.drop_count == 2,
		"猪属性：生命 8 / 掉落生猪排×2")
	var wolf := Mob.new()
	wolf.setup(Mob.MobType.WOLF, player, day_night)
	_check(wolf.health == 7 and wolf.attack_damage == 2 and wolf.drop_item == BlockTypes.Block.AIR,
		"狼属性：生命 7 / 攻击 2 / 无掉落")

	var saw_pig := false
	for i in range(200):
		if spawner._pick_passive_type() == Mob.MobType.PIG:
			saw_pig = true
	_check(saw_pig, "白天动物生成含猪（200 次抽样）")
	var saw_wolf := false
	var no_passive := true
	for i in range(200):
		var t := spawner._pick_type()
		if t == Mob.MobType.WOLF:
			saw_wolf = true
		if Mob.is_passive(t):
			no_passive = false
	_check(saw_wolf, "夜晚敌对生成含狼（200 次抽样）")
	_check(no_passive, "夜晚生成不会出现被动生物")

	# ── 阶段 B：游荡驻足节奏 ──────────────────────────
	# 把玩家传送到村庄平整区，动物脚下地形确定。
	player.global_position = Vector3(24.5, base_y + 1.1, 26.5)
	player.velocity = Vector3.ZERO
	var wanderer := _spawn_mob(main_scene, Mob.MobType.PIG, player, day_night,
		Vector3(30.5, base_y + 1.1, 21.5))
	wanderer._wander_dir = Vector3.ZERO
	wanderer._wander_timer = 99.0
	for i in range(30):
		await get_tree().physics_frame
	var idle_speed := Vector2(wanderer.velocity.x, wanderer.velocity.z).length()
	_check(idle_speed < 0.05, "驻足时水平速度为 0（%.3f）" % idle_speed)
	wanderer._start_wander()
	_check(wanderer._wander_dir != Vector3.ZERO, "_start_wander 后进入行走状态")
	for i in range(30):
		await get_tree().physics_frame
	var walk_speed := Vector2(wanderer.velocity.x, wanderer.velocity.z).length()
	_check(walk_speed > 0.1, "行走状态水平速度大于 0（%.3f）" % walk_speed)
	_check(Mob.WANDER_IDLE_MIN >= 1.0 and Mob.WANDER_WALK_MIN >= 1.0,
		"驻足/行走时长均不低于 1 秒（停一会儿节奏）")
	wanderer.queue_free()

	# ── 阶段 C：按住左键连击（打猎修复） ──────────────────────────
	var target := _spawn_mob(main_scene, Mob.MobType.WOLF, player, day_night,
		player.global_position + Vector3(0.0, 0.1, -2.0))
	target.set_physics_process(false)
	for i in range(40):
		await get_tree().physics_frame
	var hp0 := target.health
	player.start_break_or_attack()
	_check(target.health == hp0 - 1, "按下左键立即攻击一次（%d→%d）" % [hp0, target.health])
	player.break_held = true
	for i in range(90):
		await get_tree().physics_frame
	player.break_held = false
	_check(hp0 - target.health >= 3, "按住左键 1.5 秒内连续攻击多次（共命中 %d 次）" % (hp0 - target.health))
	target.queue_free()

	# ── 阶段 D：猪掉生猪排、狼夜晚追击且无掉落 ──────────────────────────
	var pig2 := _spawn_mob(main_scene, Mob.MobType.PIG, player, day_night,
		Vector3(30.5, base_y + 1.1, 21.5))
	var pig_drops := await _kill_and_collect(main_scene, pig2)
	_check(pig_drops.has(ItemTypes.RAW_PORK), "击杀猪掉落生猪排")

	day_night._time = DayNightCycle.DAY_LENGTH + DayNightCycle.NIGHT_LENGTH * 0.5
	# 出生在玩家 -x 方向 4m：该直线穿过广场圆石地面，无实心障碍
	# （+x 方向会被广场东侧酿灶台方块挡住，敌对生物无绕行逻辑）。
	var wolf2 := _spawn_mob(main_scene, Mob.MobType.WOLF, player, day_night,
		player.global_position + Vector3(-4.0, 0.1, 0.0))
	for i in range(60):
		await get_tree().physics_frame
	var dist := wolf2.global_position.distance_to(player.global_position)
	_check(dist < 3.5, "夜晚狼主动逼近玩家（剩余距离 %.2f m）" % dist)
	var wolf_drops := await _kill_and_collect(main_scene, wolf2)
	_check(wolf_drops.is_empty(), "击杀狼不掉落物品")
	day_night._time = 0.0
	day_night._apply_lighting()
	player.health = Player.MAX_HEALTH

	# ── 阶段 E：夜晚天黑 ──────────────────────────
	day_night._time = DayNightCycle.DAY_LENGTH * 0.5
	day_night._apply_lighting()
	var day_energy := env.ambient_light_energy
	_check(day_energy > 0.5, "正午环境光明亮（%.2f）" % day_energy)
	var day_bg := env.background_color
	day_night._time = DayNightCycle.DAY_LENGTH + DayNightCycle.NIGHT_LENGTH * 0.5
	day_night._apply_lighting()
	var night_energy := env.ambient_light_energy
	_check(night_energy < 0.15, "午夜环境光接近全黑（%.2f）" % night_energy)
	_check(env.background_color.v < day_bg.v, "夜晚天幕亮度低于白天（%.2f < %.2f）"
		% [env.background_color.v, day_bg.v])
	_check(env.ambient_light_color.v < 0.5, "夜晚环境光颜色为深色（%.2f）" % env.ambient_light_color.v)
	day_night._time = 0.0
	day_night._apply_lighting()

	# ── 阶段 F：储物箱存取与破坏散落 ──────────────────────────
	var chest_cell := Vector3i(30, base_y + 1, 24)
	world.set_block(chest_cell, BlockTypes.Block.CHEST)
	_check(world.get_block(chest_cell) == BlockTypes.Block.CHEST, "储物箱方块可放置读回")

	var box := world.get_box(chest_cell)
	_check(box.slots.size() == 27, "储物箱背包为 27 格（实际 %d）" % box.slots.size())
	box.add_item(BlockTypes.Block.WOOD, 10)
	_check(world.get_box(chest_cell) == box, "同一箱体重复访问返回同一背包实例")
	_check(box.count_item(BlockTypes.Block.WOOD) == 10, "箱内存入木头×10")
	_check(player.inventory.slots.size() == Inventory.SLOT_COUNT, "玩家背包保持 9 格")

	# 玩家面向储物箱右键 → 事件开面板。
	player.global_position = Vector3(30.5, base_y + 1.1, 26.5)
	player.velocity = Vector3.ZERO
	for i in range(40):
		await get_tree().physics_frame
	var opened := player._interact_village()
	_check(opened, "右键指向储物箱触发开箱（_interact_village）")
	_check(hud._box_overlay != null and hud._box_overlay.visible, "request_box_open 打开储物箱面板")
	_check(hud._box_inventory == box, "面板绑定的是该箱背包")

	# 点击箱格 0：整叠 10 木头转入背包。
	hud._on_box_slot_pressed(0)
	_check(player.inventory.count_item(BlockTypes.Block.WOOD) == 10, "点击箱格后木头×10 转入背包")
	_check(box.count_item(BlockTypes.Block.WOOD) == 0, "箱内对应格清空")
	# 点击背包格 0：整叠存回箱子。
	hud._on_box_player_slot_pressed(0)
	_check(box.count_item(BlockTypes.Block.WOOD) == 10, "点击背包格后木头×10 存回箱子")
	_check(player.inventory.count_item(BlockTypes.Block.WOOD) == 0, "背包对应格清空")
	hud.set_box_open(false)
	_check(not hud._box_overlay.visible, "储物箱面板可关闭")

	# 面板开着时箱子被破坏 → 自动关闭。
	Events.request_box_open.emit(chest_cell)
	_check(hud._box_overlay.visible, "可再次打开储物箱面板")
	Events.block_broken.emit(BlockTypes.Block.CHEST, chest_cell)
	_check(not hud._box_overlay.visible, "箱子被破坏时面板自动关闭")

	# 破坏散落：箱内 10 木头以掉落物形式出现，箱记录清空。
	world.spill_box(chest_cell, player)
	_check(not world.box_contents.has(chest_cell), "破坏散落后箱记录移除")
	var spill_count := 0
	for child in player.get_children():
		if child is DroppedItem and (child as DroppedItem).item_id == BlockTypes.Block.WOOD:
			spill_count += 1
			child.queue_free()
	_check(spill_count >= 1, "箱内物品散落为掉落物（掉落组 %d 组）" % spill_count)

	# ── 阶段 G：村庄农田与面包链路 ──────────────────────────
	var farm_o := VillageBuilder.FARM_ORIGIN
	_check(world.get_block(Vector3i(farm_o.x, base_y, farm_o.z)) == BlockTypes.Block.FARMLAND,
		"农田地块为耕地")
	_check(world.get_block(Vector3i(farm_o.x + 1, base_y + 1, farm_o.z + 1)) == BlockTypes.Block.WHEAT_CROP,
		"耕地上方种有小麦作物")
	_check(world.get_block(Vector3i(farm_o.x + 3, base_y, farm_o.z + 3)) == BlockTypes.Block.WATER,
		"农田中央一列为水")
	_check(world.get_block(Vector3i(farm_o.x + 3, base_y + 1, farm_o.z + 3)) == BlockTypes.Block.AIR,
		"水列上方不种作物")

	var crop_cell := Vector3i(farm_o.x + 1, base_y + 1, farm_o.z + 1)
	var wheat_before := player.inventory.count_item(ItemTypes.WHEAT)
	player._finish_break(crop_cell, BlockTypes.Block.WHEAT_CROP)
	_check(world.get_block(crop_cell) == BlockTypes.Block.AIR, "小麦作物可破坏")
	_check(
		player.inventory.count_item(ItemTypes.WHEAT) == wheat_before + 2,
		"收获小麦作物掉落小麦×2（drop_count_for）",
	)

	var bread_recipe := _find_recipe(ItemTypes.BREAD)
	_check(bread_recipe != null, "存在面包合成配方")
	if bread_recipe != null:
		player.inventory.add_item(ItemTypes.WHEAT, 3)
		_check(player.inventory.can_craft(bread_recipe), "小麦×3 可合成面包")
		_check(player.inventory.craft(bread_recipe), "面包合成执行成功")
		_check(player.inventory.count_item(ItemTypes.BREAD) == 1, "合成获得面包×1")

	var bread_slot := _find_slot(player.inventory, ItemTypes.BREAD)
	_check(bread_slot >= 0, "面包在玩家背包中")
	if bread_slot >= 0:
		player.selected_slot = bread_slot
		player.hunger = 5.0
		var eaten := player._eat_selected()
		_check(eaten and is_equal_approx(player.hunger, 12.0), "食用面包恢复 7 点饥饿（5→12）")
		_check(player.inventory.count_item(ItemTypes.BREAD) == 0, "食用后面包被消耗")

	_check(ItemTypes.TRADES.size() == 8, "村庄交易共 8 条（新增 3 条食物交易）")
	var has_food_trade := false
	for trade: Dictionary in ItemTypes.TRADES:
		if trade["result"] in [ItemTypes.RAW_PORK, ItemTypes.BREAD, ItemTypes.WHEAT]:
			has_food_trade = true
	_check(has_food_trade, "交易列表含食物条目（猪排/面包/小麦）")
	_check(ItemTypes.is_food(ItemTypes.RAW_PORK) and ItemTypes.is_food(ItemTypes.BREAD),
		"生猪排与面包判定为食物")

	# ── 阶段 H：杂项 ──────────────────────────
	_check(ItemTypes.is_placeable(BlockTypes.Block.CHEST), "储物箱判定为可放置物品")
	_check(BlockTypes.drop_count_for(BlockTypes.Block.WHEAT_CROP) == 2, "小麦作物掉落数量为 2")
	_check(BlockTypes.drop_count_for(BlockTypes.Block.WOOD) == 1, "普通方块掉落数量为 1")

	# ── 阶段 I：地质矿物、冶炼链路、堆叠 100、分类整理、生物名牌、HUD 新增 ──
	_check(BlockTypes.STACK_SIZE == 100, "可堆叠物品每格上限为 100")
	var stack_inv := Inventory.new(9)
	var overflow := stack_inv.add_item(BlockTypes.Block.COBBLESTONE, 150)
	_check(overflow == 0, "150 个圆石全部入包（分两栈存放）")
	_check(stack_inv.get_count(0) == 100 and stack_inv.get_count(1) == 50,
		"超量物品分栈存放（100 + 50）")

	var sort_inv := Inventory.new(9)
	sort_inv.add_item(ItemTypes.WHEAT, 60)
	sort_inv.add_item(ItemTypes.RAW_PORK, 30)
	sort_inv.add_item(ItemTypes.WHEAT, 60)
	sort_inv.add_item(BlockTypes.Block.COBBLESTONE, 20)
	sort_inv.add_item(ItemTypes.BONE, 40)
	sort_inv.sort_by_category()
	var order_ok := true
	var last_key := Vector2i(-1, -1)
	for slot: Dictionary in sort_inv.slots:
		var id := int(slot["item"])
		if id == BlockTypes.Block.AIR:
			continue
		var key := Vector2i(ItemTypes.category(id), id)
		if key < last_key:
			order_ok = false
		last_key = key
	_check(order_ok, "整理后按分类标签升序（方块→工具→食物→材料）")
	_check(sort_inv.count_item(ItemTypes.WHEAT) == 120, "同类物品合并（小麦 60+60=120）")
	var wheat_stack := -1
	for i in range(sort_inv.slots.size()):
		if int(sort_inv.slots[i]["item"]) == ItemTypes.WHEAT:
			wheat_stack = i
			break
	_check(wheat_stack >= 0 and int(sort_inv.slots[wheat_stack]["count"]) == 100,
		"合并后单格不超过上限 100（100 + 20）")
	_check(
		ItemTypes.category(BlockTypes.Block.STONE) == 0
		and ItemTypes.category(ItemTypes.BREAD) == 2
		and ItemTypes.category(ItemTypes.WHEAT) == 3
		and ItemTypes.category(ItemTypes.BONE) == 3,
		"分类标签：方块 0 / 食物 2（面包）/ 材料 3（小麦、骨头）",
	)

	world.ensure_chunks_in_region(Vector3i(0, 0, 0), Vector3i(12, 40, 14))
	var found_copper := 0
	var found_tin := 0
	for wx in range(0, 13):
		for wz in range(0, 15):
			for wy in range(8, 21):
				var block := world.get_block(Vector3i(wx, wy, wz))
				if block == BlockTypes.Block.COPPER_ORE:
					found_copper += 1
				elif block == BlockTypes.Block.TIN_ORE:
					found_tin += 1
	_check(found_copper >= 1, "石层生成铜矿石（扫描区命中 %d）" % found_copper)
	_check(found_tin >= 1, "深层生成锡矿石（扫描区命中 %d）" % found_tin)

	_check(ItemTypes.SMELT_RECIPES.size() == 3, "冶炼配方共 3 条")
	var smelt_inv := Inventory.new(9)
	smelt_inv.add_item(BlockTypes.Block.COPPER_ORE, 2)
	smelt_inv.add_item(BlockTypes.Block.TIN_ORE, 2)
	_check(smelt_inv.craft(ItemTypes.SMELT_RECIPES[0]), "铜矿×2 冶炼为铜锭")
	_check(smelt_inv.count_item(ItemTypes.COPPER_INGOT) == 1, "获得铜锭×1")
	_check(smelt_inv.craft(ItemTypes.SMELT_RECIPES[1]), "锡矿×2 冶炼为锡锭")
	_check(smelt_inv.count_item(ItemTypes.TIN_INGOT) == 1, "获得锡锭×1")
	_check(smelt_inv.craft(ItemTypes.SMELT_RECIPES[2]), "铜锭+锡锭 合成青铜锭")
	_check(smelt_inv.count_item(ItemTypes.BRONZE_INGOT) == 1, "获得青铜锭×1")
	smelt_inv.add_item(ItemTypes.BRONZE_INGOT, 3)
	smelt_inv.add_item(BlockTypes.Block.WOOD, 2)
	var pick_recipe := _find_recipe(ItemTypes.BRONZE_PICKAXE)
	_check(pick_recipe != null, "存在青铜镐合成配方")
	if pick_recipe != null:
		_check(smelt_inv.craft(pick_recipe), "青铜镐合成成功")
		var pick_slot := _find_slot(smelt_inv, ItemTypes.BRONZE_PICKAXE)
		_check(
			pick_slot >= 0 and smelt_inv.get_durability(pick_slot) == ItemTypes.tool_durability(ItemTypes.BRONZE_PICKAXE),
			"青铜镐入包且耐久正确（%d）" % ItemTypes.tool_durability(ItemTypes.BRONZE_PICKAXE),
		)
	_check(ItemTypes.is_placeable(BlockTypes.Block.SMELTER), "冶炼炉判定为可放置物品")

	var tagged := _spawn_mob(main_scene, Mob.MobType.PIG, player, day_night,
		Vector3(30.5, base_y + 1.1, 21.5))
	_check(tagged.display_name() == "猪", "猪显示名为「猪」")
	_check(tagged._nametag != null, "生物头顶名称标签已构建")
	_check(tagged._nametag.text == "猪 8/8", "名牌初始文本（猪 8/8）")
	tagged.take_damage(2)
	_check(tagged._nametag.text == "猪 6/8", "受击后名牌刷新（猪 6/8）")
	tagged.queue_free()

	Events.request_smelt.emit()
	_check(hud._smelt_overlay != null and hud._smelt_overlay.visible, "冶炼信号触发面板打开")
	hud.set_smelt_open(false)
	_check(not hud._smelt_overlay.visible, "冶炼面板可关闭")
	_check(hud._name_label != null and hud._name_label.text == "小方块", "状态面板显示姓名「小方块」")
	_check(hud._hp_bar != null and int(hud._hp_bar.max_value) == Player.MAX_HEALTH,
		"状态面板生命条范围 0-20")
	_check(hud._minimap != null, "右上角小地图已挂载")
	_check(hud._minimap._samples.size() > 0,
		"小地图已采样到顶面颜色（%d 格）" % hud._minimap._samples.size())

	if _failed == 0:
		print("LIFE_TEST_OK")
		get_tree().quit(0)
	else:
		print("LIFE_TEST_FAILED count=%d" % _failed)
		get_tree().quit(1)


## 复算村庄基准高度：与 VillageBuilder._probe_base_y 同款循环。
func _probe_base_y(world: World) -> int:
	var top := 0
	for x in range(VillageBuilder.REGION_MIN.x, VillageBuilder.REGION_MAX.x + 1):
		for z in range(VillageBuilder.REGION_MIN.z, VillageBuilder.REGION_MAX.z + 1):
			top = maxi(top, world.get_surface_height(x, z) - 1)
	return top


func _spawn_mob(parent: Node, mob_type: Mob.MobType, player: Player, dn: DayNightCycle, pos: Vector3) -> Mob:
	var mob := Mob.new()
	mob.setup(mob_type, player, dn)
	parent.add_child(mob)
	mob.global_position = pos
	return mob


## 击杀生物并收集 10 帧内其父节点下出现的掉落物 ID（去重），随后清理掉落物。
func _kill_and_collect(parent: Node, mob: Mob) -> Array[int]:
	var ids: Array[int] = []
	if mob == null:
		return ids
	var holder := mob.get_parent()
	if holder == null:
		return ids
	mob.take_damage(99)
	for i in range(10):
		await get_tree().process_frame
		for child in holder.get_children():
			if child is DroppedItem:
				var drop := child as DroppedItem
				if not ids.has(drop.item_id):
					ids.append(drop.item_id)
				drop.queue_free()
	return ids


func _find_recipe(result: int) -> Dictionary:
	for recipe in ItemTypes.RECIPES:
		if int(recipe["result"]) == result:
			return recipe
	return {}


func _find_slot(inv: Inventory, item: int) -> int:
	for i in range(inv.slots.size()):
		if int(inv.slots[i]["item"]) == item and int(inv.slots[i]["count"]) > 0:
			return i
	return -1


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
