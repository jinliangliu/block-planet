extends Node
## 无头生存扩展探针：验证动物驻足节奏、按住左键连击、猪/狼生物、
## 夜晚天黑（环境光调制）、储物箱存取/破坏散落、村庄农田与面包链路、
## 堆叠 100、背包分类整理、铜锡矿生成、冶炼链路、生物名牌与 HUD 新增面板，
## 以及水体生态（大河/池塘分类、水生植物、鱼虾蟹蜻蜓青蛙与各自行为）。
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

	# 首次进入游戏会自动弹出地图选择器并冻结玩家；探针先关闭以恢复物理与输入，
	# 后续所有移动/跳跃断言才成立。
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
	GameState.needs_region_pick = false
	_check(player.is_physics_processing(), "关闭地图选择器后玩家物理处理已恢复")

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
	_check(box.slots.size() == 36, "储物箱背包为 36 格（实际 %d）" % box.slots.size())
	box.add_item(BlockTypes.Block.WOOD, 10)
	_check(world.get_box(chest_cell) == box, "同一箱体重复访问返回同一背包实例")
	_check(box.count_item(BlockTypes.Block.WOOD) == 10, "箱内存入木头×10")
	_check(player.inventory.slots.size() == Inventory.SLOT_COUNT and Inventory.SLOT_COUNT == 18, "玩家背包扩至 18 格")

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
	_check(hud._hearts != null and hud._hearts.custom_minimum_size.x >= 100.0,
		"状态面板生命爱心条已挂载（5 颗心宽度）")
	_check(HUD.HEART_COUNT == 5 and HUD.HEARTS_PER_POINT * HUD.HEART_COUNT >= Player.MAX_HEALTH,
		"生命爱心换算（5 颗 × 4 点 ≥ 满血 20）")
	_check(hud._minimap != null, "右上角小地图已挂载")
	_check(hud._minimap._samples.size() > 0,
		"小地图已采样到顶面颜色（%d 格）" % hud._minimap._samples.size())

	# ── 阶段 J：水体生态（大河/池塘分类、水生植物、水生物与各自行为） ──
	_check(BlockTypes.is_water_plant(BlockTypes.Block.LILY_PAD), "荷叶判定为水生植物")
	_check(
		not BlockTypes.is_solid(BlockTypes.Block.DUCKWEED)
		and BlockTypes.is_transparent(BlockTypes.Block.DUCKWEED)
		and BlockTypes.is_water_plant(BlockTypes.Block.LOTUS),
		"浮萍/莲花为非固体、透明的水生植物",
	)
	_check(ItemTypes.is_placeable(BlockTypes.Block.LOTUS), "水生植物可作为方块再放置")
	_check(BlockTypes.HARDNESS[BlockTypes.Block.WATERWEED] <= 0.2, "水草徒手可快速采集")
	_check(World.WATER_FLOOD_CAP > World.LARGE_WATER_MIN_TILES, "洪泛上限大于大水体阈值")

	# 出生点列是陆地；勘察确认的池塘/大河中心附近应分类正确（种子固定）。
	_check(world.water_kind(8, 8) == World.WATER_NONE and world.water_depth(8, 8) == 0,
		"出生点列为陆地（非水体、水深 0）")
	var pond_cell := _find_kind_cell(world, Vector2i(-8, -9), World.WATER_POND, 8)
	_check(pond_cell != Vector2i.ZERO, "小池塘分类命中（%s）" % str(pond_cell))
	var large_cell := _find_kind_cell(world, Vector2i(-26, -55), World.WATER_LARGE, 8)
	_check(large_cell != Vector2i.ZERO, "大河分类命中（%s）" % str(large_cell))

	# 水生植物：大河底部为水下植物，池塘水面为浮叶植物。
	var weeds := _find_blocks_near(
		world, large_cell, 18, [BlockTypes.Block.WATERWEED, BlockTypes.Block.ALGAE]
	)
	var underwater := 0
	for cell: Vector3i in weeds:
		if cell.y < World.SEA_LEVEL:
			underwater += 1
	_check(weeds.size() >= 1 and underwater == weeds.size(),
		"大河底部生成水草/藻类（命中 %d 处，全部位于水面以下）" % weeds.size())

	var pads := _find_blocks_near(
		world, pond_cell, 18,
		[BlockTypes.Block.DUCKWEED, BlockTypes.Block.LILY_PAD, BlockTypes.Block.LOTUS]
	)
	var at_surface := 0
	for cell: Vector3i in pads:
		if cell.y == World.SEA_LEVEL:
			at_surface += 1
	_check(pads.size() >= 1 and at_surface == pads.size(),
		"池塘水面生成浮萍/荷叶/莲花（命中 %d 处，全部位于水面）" % pads.size())

	# 水生物属性：名称、生命、掉落与可食用性。
	var probe_fish := Mob.new()
	probe_fish.setup(Mob.MobType.FISH, player, day_night)
	_check(probe_fish.display_name() == "鱼" and probe_fish.health == 3
		and probe_fish.drop_item == ItemTypes.RAW_FISH and probe_fish.drop_count == 2,
		"鱼属性：显示名「鱼」/ 生命 3 / 掉落生鱼×2")
	var probe_crab := Mob.new()
	probe_crab.setup(Mob.MobType.CRAB, player, day_night)
	_check(probe_crab.display_name() == "蟹" and probe_crab.max_health == 4
		and probe_crab.drop_item == ItemTypes.CRAB_MEAT,
		"蟹属性：显示名「蟹」/ 生命 4 / 掉落蟹肉")
	var probe_shrimp := Mob.new()
	probe_shrimp.setup(Mob.MobType.SHRIMP, player, day_night)
	_check(probe_shrimp.drop_item == ItemTypes.RAW_SHRIMP, "虾掉落生虾")
	var probe_dragonfly := Mob.new()
	probe_dragonfly.setup(Mob.MobType.DRAGONFLY, player, day_night)
	_check(probe_dragonfly.display_name() == "蜻蜓" and probe_dragonfly.drop_item == BlockTypes.Block.AIR,
		"蜻蜓为环境生物（显示名「蜻蜓」/ 无掉落）")
	var probe_frog := Mob.new()
	probe_frog.setup(Mob.MobType.FROG, player, day_night)
	_check(probe_frog.display_name() == "青蛙" and probe_frog.drop_item == BlockTypes.Block.AIR,
		"青蛙为环境生物（显示名「青蛙」/ 无掉落）")

	_check(
		Mob.habitat_of(Mob.MobType.FISH) == Mob.Habitat.WATER
		and Mob.habitat_of(Mob.MobType.DRAGONFLY) == Mob.Habitat.AIR
		and Mob.habitat_of(Mob.MobType.FROG) == Mob.Habitat.LAND,
		"栖息地：鱼在水中 / 蜻蜓在空中 / 青蛙在陆地",
	)
	_check(Mob.is_aquatic(Mob.MobType.CRAB) and Mob.is_aquatic(Mob.MobType.FROG)
		and not Mob.is_aquatic(Mob.MobType.COW), "水生物判定（蟹、青蛙为正，牛为否）")
	_check(Mob.is_passive(Mob.MobType.FISH) and Mob.is_passive(Mob.MobType.FROG)
		and Mob.is_passive(Mob.MobType.CRAB), "水生物判定为被动（受击逃跑、不攻击）")
	_check(ItemTypes.is_food(ItemTypes.RAW_FISH) and ItemTypes.is_food(ItemTypes.CRAB_MEAT)
		and ItemTypes.food_value(ItemTypes.RAW_FISH) == 6, "水产可食用（生鱼恢复 6 点饥饿）")

	# 鱼在大河游动且不跃出水面。
	# 玩家需在水体旁：世界按玩家位置装卸区块，远离时鱼的行为与断言都会读到空气。
	var swim_pos := _water_spawn_position(world, large_cell, false)
	_check(swim_pos.y > 0.0, "大河中找到可用的水体格")
	player.global_position = swim_pos + Vector3(0.0, 2.5, 0.0)
	player.velocity = Vector3.ZERO
	for i in range(4):
		await get_tree().physics_frame
	var live_fish := _spawn_mob(main_scene, Mob.MobType.FISH, player, day_night, swim_pos)
	var fish_start := live_fish.global_position
	for i in range(70):
		await get_tree().physics_frame
	_check(live_fish.global_position.distance_to(fish_start) > 0.05,
		"鱼在水中游动（位移 %.2f m）" % live_fish.global_position.distance_to(fish_start))
	_check(world.get_block(Vector3i(live_fish.global_position.floor())) != BlockTypes.Block.AIR,
		"鱼未跃出水面（身体所在格仍为水）")
	live_fish.queue_free()

	# 蟹贴水底爬行（重力生效）；蜻蜓悬停不落水；青蛙在岸边起跳。
	player.global_position = Vector3(float(pond_cell.x) + 0.5, float(World.SEA_LEVEL) + 3.0, float(pond_cell.y) + 0.5)
	player.velocity = Vector3.ZERO
	for i in range(4):
		await get_tree().physics_frame
	var bed_pos := _water_spawn_position(world, pond_cell, true)
	var live_crab := _spawn_mob(main_scene, Mob.MobType.CRAB, player, day_night, bed_pos)
	for i in range(70):
		await get_tree().physics_frame
	_check(live_crab.is_on_floor(), "蟹贴在水底（is_on_floor 为真）")
	_check(live_crab.global_position.y < float(World.SEA_LEVEL) + 1.0,
		"蟹未浮出水面（y=%.2f）" % live_crab.global_position.y)
	live_crab.queue_free()

	var hover_pos := Vector3(pond_cell.x + 0.5, float(World.SEA_LEVEL) + 1.2, pond_cell.y + 0.5)
	var live_dragonfly := _spawn_mob(main_scene, Mob.MobType.DRAGONFLY, player, day_night, hover_pos)
	var bob_peak := 0.0
	for i in range(70):
		await get_tree().physics_frame
		bob_peak = maxf(bob_peak, absf(live_dragonfly.velocity.y))
	_check(live_dragonfly.global_position.y > float(World.SEA_LEVEL),
		"蜻蜓悬停在水面上方未坠落（y=%.2f）" % live_dragonfly.global_position.y)
	_check(bob_peak > 0.05, "蜻蜓上下浮动（竖直速度峰值 %.2f）" % bob_peak)
	live_dragonfly.queue_free()

	var shore_pos: Vector3 = spawner._find_pond_shore(pond_cell.x, pond_cell.y)
	_check(shore_pos != MobSpawner.INVALID_POSITION, "池塘岸边可找到可站立落点")
	var live_frog := _spawn_mob(main_scene, Mob.MobType.FROG, player, day_night, shore_pos)
	var frog_y := live_frog.global_position.y
	var frog_peak := frog_y
	for i in range(180):
		await get_tree().physics_frame
		frog_peak = maxf(frog_peak, live_frog.global_position.y)
	_check(frog_peak > frog_y + 0.15, "青蛙间歇起跳离地（峰值 +%.2f m）" % (frog_peak - frog_y))
	live_frog.queue_free()

	# 水生物生成轨道：确定性落点 + 随机搜索路径 + 清空。
	spawner._despawn_all()
	_ensure_water_chunks(world, large_cell, 8)
	_check(spawner._spawn_in_large_water(Mob.MobType.FISH, large_cell.x, large_cell.y),
		"大河水体格可放置鱼")
	_ensure_water_chunks(world, pond_cell, 8)
	_check(spawner._spawn_by_pond(Mob.MobType.FROG, pond_cell.x, pond_cell.y),
		"池塘岸边可放置青蛙")
	_check(spawner._water_mobs.size() == 2, "水生物轨道已登记 2 只（实际 %d）" % spawner._water_mobs.size())
	var track_aquatic := spawner._water_mobs.size() > 0
	for mob in spawner._water_mobs:
		if not Mob.is_aquatic(mob.type):
			track_aquatic = false
	_check(track_aquatic, "轨道登记的均为水生物")
	spawner._despawn_all()
	_check(spawner._water_mobs.is_empty() and spawner._mobs.is_empty(), "清空后陆地与水生物列表均为空")

	player.global_position = shore_pos
	player.velocity = Vector3.ZERO
	var pond_spawned := false
	var pond_tries := 0
	while pond_tries < 60 and not pond_spawned:
		pond_tries += 1
		pond_spawned = spawner._spawn_water_life()
	_check(pond_spawned, "池塘边随机搜索可生成水生物（%d 次尝试内）" % pond_tries)
	spawner._despawn_all()
	player.global_position = Vector3(24.5, base_y + 1.1, 26.5)
	player.velocity = Vector3.ZERO
	player.health = Player.MAX_HEALTH
	for i in range(20):
		await get_tree().physics_frame

	# ── 阶段 K：地图图册、3D 地球、选择器与区域化世界生成 ──
	_check(RegionAtlas.mask_is_valid(), "陆地掩码自检通过（36×72，无未知字母）")
	var titles := {}
	var seeds := {}
	var texts_ok := true
	for region_id in RegionAtlas.COUNT:
		var region: Dictionary = RegionAtlas.profile(region_id)
		titles[region["title"]] = true
		seeds[region["seed"]] = true
		for key: String in ["intro", "vegetation", "creature", "climate", "scenery"]:
			if String(region[key]).is_empty():
				texts_ok = false
	_check(titles.size() == RegionAtlas.COUNT, "11 个区域名称互不重复")
	_check(seeds.size() == RegionAtlas.COUNT, "11 个区域各有独立随机种子")
	_check(texts_ok, "每个区域的介绍与四段地理说明均非空")

	# 经纬度归属：七大洲四大洋各取一点。
	_check(RegionAtlas.region_at_lat_lon(0.0, 20.0) == RegionAtlas.AFRICA, "0°N 20°E 判为非洲")
	_check(RegionAtlas.region_at_lat_lon(50.0, 100.0) == RegionAtlas.ASIA, "50°N 100°E 判为亚洲")
	_check(RegionAtlas.region_at_lat_lon(48.0, 10.0) == RegionAtlas.EUROPE, "48°N 10°E 判为欧洲")
	_check(
		RegionAtlas.region_at_lat_lon(40.0, -100.0) == RegionAtlas.NORTH_AMERICA,
		"40°N 100°W 判为北美洲",
	)
	_check(
		RegionAtlas.region_at_lat_lon(-15.0, -60.0) == RegionAtlas.SOUTH_AMERICA,
		"15°S 60°W 判为南美洲",
	)
	_check(RegionAtlas.region_at_lat_lon(-20.0, 140.0) == RegionAtlas.OCEANIA, "20°S 140°E 判为大洋洲")
	_check(RegionAtlas.region_at_lat_lon(-85.0, 0.0) == RegionAtlas.ANTARCTICA, "85°S 判为南极洲")
	_check(RegionAtlas.region_at_lat_lon(0.0, -150.0) == RegionAtlas.PACIFIC, "0° 150°W 判为太平洋")
	_check(RegionAtlas.region_at_lat_lon(0.0, -30.0) == RegionAtlas.ATLANTIC, "0° 30°W 判为大西洋")
	_check(RegionAtlas.region_at_lat_lon(-30.0, 80.0) == RegionAtlas.INDIAN, "30°S 80°E 判为印度洋")
	_check(RegionAtlas.region_at_lat_lon(80.0, 0.0) == RegionAtlas.ARCTIC, "80°N 判为北冰洋")
	var covered := {}
	for row in RegionAtlas.ROWS:
		for col in RegionAtlas.COLS:
			covered[RegionAtlas.region_of_cell(row, col)] = true
	_check(covered.size() == RegionAtlas.COUNT, "球面覆盖全部 11 个区域（实际 %d）" % covered.size())

	# 经纬度与方向向量互逆：球面网格与拾取共用这对函数，保证点选不错位。
	var round_trip_ok := true
	for probe: Vector2 in [Vector2(0.0, 0.0), Vector2(45.0, 120.0), Vector2(-60.0, -75.0)]:
		var back := RegionAtlas.dir_to_lat_lon(RegionAtlas.lat_lon_to_dir(probe.x, probe.y))
		if absf(back.x - probe.x) > 0.001 or absf(back.y - probe.y) > 0.001:
			round_trip_ok = false
	_check(round_trip_ok, "经纬度 → 方向向量 → 经纬度 往返一致")

	# 3D 地球：球面网格生成 + 射线拾取与掩码归属一致。
	var globe := MapGlobe.new()
	add_child(globe)
	globe.build()
	globe.set_view_angles(0.0, 0.0)
	var mesh_node := globe.get_child(0) as MeshInstance3D
	_check(
		mesh_node != null and mesh_node.mesh != null and mesh_node.mesh.get_surface_count() == 1,
		"地球球面网格已生成（单表面顶点色）",
	)
	var picked := globe.region_at_world_ray(Vector3(0.0, 0.0, 3.0), Vector3(0.0, 0.0, -1.0))
	_check(
		picked == RegionAtlas.region_at_lat_lon(0.0, 0.0),
		"正面射线拾取与掩码归属一致（region=%d）" % picked,
	)
	globe.set_view_angles(180.0, 0.0)
	var picked_back := globe.region_at_world_ray(Vector3(0.0, 0.0, 3.0), Vector3(0.0, 0.0, -1.0))
	_check(picked_back != picked, "地球旋转 180° 后拾取区域随之改变")
	_check(
		globe.region_at_world_ray(Vector3(0.0, 0.0, 3.0), Vector3(1.0, 0.0, 0.0)) == -1,
		"射线未命中球体时返回 -1",
	)
	globe.queue_free()

	# 选择器三页流程：介绍页 → 加载页逐段揭示 → 按钮解锁。
	_check(
		hud._map_name_label != null and hud._map_name_label.text == GameState.region_title(),
		"屏幕顶部居中显示当前地图名（%s）" % GameState.region_title(),
	)
	hud.open_map_selector()
	_check(hud._map_selector.is_open(), "可打开地图选择器（M 键路径）")
	_check(hud._map_selector._stage.get_global_rect().size == Vector2(MapSelector.VIEW_SIZE, MapSelector.VIEW_SIZE),
		"地球视口舞台尺寸为 %d×%d" % [int(MapSelector.VIEW_SIZE), int(MapSelector.VIEW_SIZE)])
	_check(
		hud._map_selector._viewport_pos_from_global(
			hud._map_selector._stage.get_global_rect().position + Vector2(260.0, 260.0)
		) == Vector2(260.0, 260.0),
		"拾取坐标换算：全局坐标减舞台原点得视口内坐标",
	)
	hud._map_selector._show_intro(RegionAtlas.ASIA)
	_check(hud._map_selector._intro_title.text == "亚洲", "介绍页显示所选区域名称与地理介绍")
	_check(not String(hud._map_selector._intro_body.text).is_empty(), "该区域地理介绍文本非空")
	hud._map_selector._start_loading()
	_check(hud._map_selector.get_page() == MapSelector.Page.LOADING, "点「进入」后切换到加载页")
	hud._map_selector._process(MapSelector.LOAD_DURATION + 0.5)
	_check(
		not hud._map_selector._loading and not hud._map_selector._loading_enter.disabled,
		"加载进度走满后「开始探索」按钮解锁",
	)
	var steps_visible := true
	for step_label: Label in hud._map_selector._step_labels:
		if step_label.modulate.a < 1.0:
			steps_visible = false
	_check(steps_visible, "植被/生物/气候/风貌四段说明已逐条揭示")

	# 地理知识卡片：每区域 3 张、字段齐全、剪影类型受支持。
	var cards_ok := true
	var known_arts := [
		"mountain", "dune", "forest", "wave", "ice", "aurora", "storm", "rift",
		"reef", "waterfall", "rock", "trench", "sun",
		"panda", "penguin", "kangaroo", "lion", "polar_bear",
	]
	for region_id in RegionAtlas.COUNT:
		var cards := RegionAtlas.cards_of(region_id)
		if cards.size() != 3:
			cards_ok = false
		for card: Dictionary in cards:
			if String(card["title"]).is_empty() or String(card["text"]).is_empty():
				cards_ok = false
			if not known_arts.has(String(card["art"])):
				cards_ok = false
	_check(cards_ok, "11 个区域各含 3 张知识卡片且标题/正文/剪影类型齐全")
	var card_count := hud._map_selector._card_row.get_child_count()
	_check(card_count == 3, "介绍页为所选区域生成 3 张知识卡片（实际 %d）" % card_count)
	hud._map_selector._open_card_detail(1)
	_check(
		hud._map_selector._card_detail.visible and not String(hud._map_selector._detail_title.text).is_empty(),
		"点卡片弹出大图详情浮层",
	)
	hud._map_selector._close_card_detail()
	_check(not hud._map_selector._card_detail.visible, "详情浮层可关闭")
	hud.close_map_selector()
	_check(not hud._map_selector.is_open() and player.is_physics_processing(),
		"关闭选择器后玩家恢复物理处理")

	# 区域化世界生成：独立 World 实例按区域配置产出地表材质与树木密度。
	var polar := World.new()
	polar.set_region(RegionAtlas.ANTARCTICA)
	add_child(polar)
	polar.ensure_chunks_in_region(Vector3i(0, 0, 0), Vector3i(15, 0, 15))
	var all_snow := true
	var polar_tree := false
	for x in range(16):
		for z in range(16):
			var top_y := polar.get_surface_height(x, z) - 1
			if polar.get_block(Vector3i(x, top_y, z)) != BlockTypes.Block.SNOW:
				all_snow = false
			for dy in range(1, 6):
				if polar.get_block(Vector3i(x, top_y + dy, z)) == BlockTypes.Block.WOOD:
					polar_tree = true
	_check(all_snow, "南极洲区块地表一律为雪块")
	_check(not polar_tree, "南极洲树木密度 0，区块内无树木")
	_check(polar.get_region() == RegionAtlas.ANTARCTICA, "世界记录的当前区域与设置一致")
	polar.queue_free()

	var desert := World.new()
	desert.set_region(RegionAtlas.AFRICA)
	add_child(desert)
	# 单个区块内噪声几乎恒定（频率 0.012），须跨若干区块取样才能同时看到
	# 低地沙丘与高地草原两种地表。
	desert.ensure_chunks_in_region(Vector3i(0, 0, 0), Vector3i(63, 0, 63))
	var sand_tops := 0
	var grass_tops := 0
	for x in range(64):
		for z in range(64):
			var top_y2 := desert.get_surface_height(x, z) - 1
			var top_block := desert.get_block(Vector3i(x, top_y2, z))
			if top_block == BlockTypes.Block.SAND:
				sand_tops += 1
			elif top_block == BlockTypes.Block.GRASS:
				grass_tops += 1
	_check(
		sand_tops > 0 and grass_tops > 0,
		"非洲低地为沙、高地为草（沙 %d / 草 %d）" % [sand_tops, grass_tops],
	)
	_check(
		desert.seed_value == int(RegionAtlas.profile(RegionAtlas.AFRICA)["seed"]),
		"切换区域同步应用该区域随机种子",
	)
	desert.queue_free()

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


## 在中心附近找一处指定水体类型的格子；找不到返回 Vector2i.ZERO。
func _find_kind_cell(world: World, center: Vector2i, kind: int, radius: int) -> Vector2i:
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			var cell := Vector2i(center.x + dx, center.y + dz)
			if world.water_kind(cell.x, cell.y) == kind:
				return cell
	return Vector2i.ZERO


## 扫描半径内指定方块 ID 的坐标（y 覆盖水面上下四格）；先行强制加载区块。
func _find_blocks_near(world: World, center: Vector2i, radius: int, ids: Array) -> Array[Vector3i]:
	var span := radius + 2
	world.ensure_chunks_in_region(
		Vector3i(center.x - span, 0, center.y - span),
		Vector3i(center.x + span, World.SEA_LEVEL + 2, center.y + span),
	)
	var found: Array[Vector3i] = []
	for wx in range(center.x - radius, center.x + radius + 1):
		for wz in range(center.y - radius, center.y + radius + 1):
			for wy in range(World.SEA_LEVEL - 4, World.SEA_LEVEL + 1):
				if ids.has(world.get_block(Vector3i(wx, wy, wz))):
					found.append(Vector3i(wx, wy, wz))
	return found


## 强制加载以 center 为中心、半径 radius 的区块（水面上下两格覆盖）。
## 探针远离出生点时区块会被流式卸载，get_block 将一律返回空气，须先补载。
func _ensure_water_chunks(world: World, center: Vector2i, radius: int) -> void:
	world.ensure_chunks_in_region(
		Vector3i(center.x - radius, 0, center.y - radius),
		Vector3i(center.x + radius, World.SEA_LEVEL + 2, center.y + radius),
	)


## 在指定水列附近取一格可用水体作为落点；prefer_bottom 为真时取水底。
## 失败返回 Vector3(0, -1, 0)。
func _water_spawn_position(world: World, center: Vector2i, prefer_bottom: bool) -> Vector3:
	for wx in range(center.x - 2, center.x + 3):
		for wz in range(center.y - 2, center.y + 3):
			var depth := world.water_depth(wx, wz)
			if depth <= 0:
				continue
			var y := (World.SEA_LEVEL - depth + 1) if prefer_bottom else (World.SEA_LEVEL - depth / 2)
			for offset in [0, 1, -1, 2, -2]:
				var cell := Vector3i(wx, y + offset, wz)
				if world.get_block(cell) == BlockTypes.Block.WATER:
					return Vector3(wx + 0.5, float(cell.y) + 0.1, wz + 0.5)
	return Vector3(0.0, -1.0, 0.0)


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
