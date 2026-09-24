extends Node
## 无头生存扩展探针：验证动物驻足节奏、按住左键连击、猪/狼生物、
## 夜晚天黑（环境光调制）、储物箱存取/破坏散落、村庄农田与面包链路、
## 堆叠 100、背包分类整理、铜锡矿生成、冶炼链路、生物名牌与 HUD 新增面板，
## 以及水体生态（大河/池塘分类、水生植物、鱼虾蟹蜻蜓青蛙与各自行为）。
## 运行：Godot_v4.6.3-stable_win64_console.exe --headless --path . res://tests/life_probe.tscn

var _failed := 0
## 成长事件计数（lambda 捕获成员而非局部变量，便于统计）。
var _grown_events := 0


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
	# 徒手对狼：规则伤害 4、工具不匹配折半 → 2 点（HuntRules.BARE/wrong-tool 口径）。
	_check(target.health == hp0 - 2, "按下左键立即攻击一次（%d→%d，折半规则 4/2）" % [hp0, target.health])
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
	_check(wolf_drops.has(ItemTypes.FANG), "击杀狼掉落獠牙")
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
	_check(player.inventory.slots.size() == Inventory.SLOT_COUNT and Inventory.SLOT_COUNT == 36,
		"玩家背包扩至 36 格")

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

	_check(ItemTypes.TRADES.size() == 13, "村庄交易共 13 条（新增食物与材料交易，现 %d 条）" % ItemTypes.TRADES.size())
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

	_check(ItemTypes.SMELT_RECIPES.size() == 6, "冶炼配方共 6 条（含铁锭/金锭/合金锭）")
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

	# 游戏说明书：F1 唤出，分页展示，关闭后状态复位。
	var manual: ManualPanel = hud._manual
	_check(manual != null and not manual.is_open(), "HUD 持有说明书且初始关闭")
	hud.open_manual()
	_check(manual.is_open(), "可打开游戏说明书（F1 键路径）")
	_check(manual.get_page() == 0, "说明书初始停在第 1 页")
	manual.select_page(3)
	_check(manual.get_page() == 3, "可切换到指定页签")
	manual.select_page(-2)
	_check(manual.get_page() == 0, "越界页码被钳制到第 1 页")
	manual.select_page(99)
	_check(manual.get_page() == ManualPanel.PAGES.size() - 1, "越界页码被钳制到末页")
	hud.close_manual()
	_check(not manual.is_open(), "关闭说明书后状态复位")

	# 阶段 L：任务与成就系统。先备份真实进度再清空，保证断言确定性。
	var saved_counters: Dictionary = Progress.counters.duplicate()
	var saved_states: Dictionary = Progress.states.duplicate()
	Progress.counters.clear()
	Progress.states.clear()

	_check(QuestData.quests().size() == 8, "新手任务链共 8 环")
	_check(QuestData.achievements().size() == 25, "成就共 25 枚（现 %d 枚）" % QuestData.achievements().size())
	var first_q := QuestData.quests()[0]
	var second_q := QuestData.quests()[1]
	_check(Progress.is_visible(first_q) and not Progress.is_visible(second_q),
		"任务链首环可见、次环锁定")
	_check(Progress.state_of(String(first_q["id"])) == Progress.State.ACTIVE,
		"首环初始为进行中")
	Progress.notify(String(first_q["goal"]["key"]), int(first_q["goal"]["count"]) + 1)
	_check(Progress.state_of(String(first_q["id"])) == Progress.State.DONE,
		"达成目标后任务进入可领奖")
	_check(Progress.goal_progress(first_q["goal"]).x == int(first_q["goal"]["count"]),
		"进度值被钳制在目标值内")
	var reward: Dictionary = Progress.claim(String(first_q["id"]))
	_check(not reward.is_empty()
		and Progress.state_of(String(first_q["id"])) == Progress.State.CLAIMED,
		"领奖后任务标记为已领取并返回奖励")
	_check(Progress.is_visible(second_q), "前序领奖后下一环解锁")
	_check(Progress.goal_progress({"type": "regions", "count": 5}).y == 5,
		"区域型目标可计算进度")

	var quiz_hits: Array[Dictionary] = []
	Progress.quiz_reward_earned.connect(func(item: int, count: int):
		quiz_hits.append({"item": item, "count": count}))
	Progress.answer_quiz(true)
	Progress.answer_quiz(true)
	_check(quiz_hits.is_empty(), "答对 2 题尚未触发连对奖励")
	Progress.answer_quiz(true)
	_check(quiz_hits.size() == 1 and int(quiz_hits[0]["count"]) == 2,
		"答对 3 题触发一次连对奖励（面包 ×2）")
	_check(int(Progress.counters.get("quiz_correct", 0)) == 3,
		"答对题数计入计数器")

	_check(FileAccess.file_exists("user://progress.json"), "进度已持久化到 user://")

	hud.open_quest_panel()
	_check(hud._quest_panel.is_open() and not player.is_physics_processing(),
		"可打开任务面板且玩家被冻结（J 键路径）")
	hud._quest_panel.set_tab(1)
	_check(hud._quest_panel.get_tab() == 1, "可切换到成就页签")
	hud.close_quest_panel()
	_check(not hud._quest_panel.is_open() and player.is_physics_processing(),
		"关闭任务面板后玩家恢复物理处理")

	Progress.counters = saved_counters
	Progress.states = saved_states
	Progress._save()

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

	# ── 阶段 O：背包分区、快捷栏指派与待售区一键售卖 ──
	var bag := Inventory.new(Inventory.SLOT_COUNT, Inventory.COMMON_COUNT)
	_check(bag.slots.size() == 36 and Inventory.COMMON_COUNT == 27 and Inventory.SELL_COUNT == 9,
		"背包 36 格 = 常用区 27 + 待售区 9")
	_check(not bag.is_sell_slot(0) and not bag.is_sell_slot(26) and bag.is_sell_slot(27)
		and bag.is_sell_slot(35) and not bag.is_sell_slot(36), "待售区槽位判定覆盖 27~35")
	_check(InventoryPanel.COMMON_COLUMNS == 9, "背包面板常用区每行 9 格")
	_check(bag.hotbar_map.size() == 9 and bag.hotbar_slot(0) == 0 and bag.hotbar_slot(8) == 8,
		"快捷栏默认映射背包前 9 格")

	# 自动入包只落常用区：填满后剩余量原样返回，待售区保持空。
	for i in range(Inventory.COMMON_COUNT):
		bag.slots[i] = {"item": BlockTypes.Block.STONE, "count": BlockTypes.STACK_SIZE, "durability": -1}
	var leftover := bag.add_item(BlockTypes.Block.DIRT, 3)
	_check(leftover == 3 and bag.get_item(Inventory.COMMON_COUNT) == BlockTypes.Block.AIR,
		"常用区满时拾取不再落入待售区")

	# 快捷栏指派：新槽位直接指派，占用中的槽位互换（顺带覆盖待售区槽位可指派）。
	var assign_bag := Inventory.new(Inventory.SLOT_COUNT, Inventory.COMMON_COUNT)
	assign_bag.slots[31] = {"item": ItemTypes.EMERALD, "count": 5, "durability": -1}
	_check(assign_bag.assign_hotbar(0, 31) and assign_bag.hotbar_item(0) == ItemTypes.EMERALD,
		"可把背包第 32 格（待售区）指派到快捷栏 1 号位")
	_check(assign_bag.assign_hotbar(1, 31) and assign_bag.hotbar_item(1) == ItemTypes.EMERALD
		and assign_bag.hotbar_item(0) == BlockTypes.Block.AIR,
		"重复指派同一背包槽时与原快捷位互换")
	_check(assign_bag.swap_hotbar(1, 3) and assign_bag.hotbar_item(3) == ItemTypes.EMERALD,
		"快捷栏两位可互换")

	# 搬运：同物按数量合并，异格整栈互换。
	var move_bag := Inventory.new(Inventory.SLOT_COUNT, Inventory.COMMON_COUNT)
	move_bag.slots[0] = {"item": BlockTypes.Block.WOOD, "count": 16, "durability": -1}
	move_bag.slots[1] = {"item": BlockTypes.Block.WOOD, "count": 8, "durability": -1}
	_check(move_bag.move_between(0, 1, 4) and move_bag.get_count(1) == 12
		and move_bag.get_count(0) == 12, "同物搬运按数量合并（16+8 → 12+12）")
	move_bag.slots[2] = {"item": BlockTypes.Block.SAND, "count": 3, "durability": -1}
	_check(move_bag.move_between(0, 2, move_bag.get_count(0))
		and move_bag.get_item(0) == BlockTypes.Block.SAND, "异格整栈搬运为互换")

	# 售价与可售判定。
	_check(ItemTypes.sell_price(BlockTypes.Block.STONE) == 1
		and ItemTypes.sell_price(ItemTypes.WOOD_AXE) == 4
		and ItemTypes.sell_price(ItemTypes.BREAD) == 2
		and ItemTypes.sell_price(ItemTypes.BONE) == 3, "售价按分类定价（方块1/工具4/食物2/材料3）")
	_check(not ItemTypes.is_sellable(ItemTypes.EMERALD)
		and ItemTypes.is_sellable(BlockTypes.Block.STONE), "绿宝石不可售、方块可售")

	# 待售区一键售卖：结算为绿宝石且待售区清空。
	var sell_bag := Inventory.new(Inventory.SLOT_COUNT, Inventory.COMMON_COUNT)
	sell_bag.slots[Inventory.COMMON_COUNT] = {"item": BlockTypes.Block.WOOD, "count": 10, "durability": -1}
	sell_bag.slots[Inventory.COMMON_COUNT + 1] = {"item": ItemTypes.BONE, "count": 2, "durability": -1}
	var sale := sell_bag.sell_all()
	_check(int(sale["emeralds"]) == 16 and int(sale["sold"]) == 12,
		"一键售卖按售价结算（木头×10 + 骨头×2 = 16 绿宝石）")
	_check(sell_bag.get_item(Inventory.COMMON_COUNT) == BlockTypes.Block.AIR
		and sell_bag.count_item(ItemTypes.EMERALD) == 16, "售出后待售区清空、绿宝石入包")

	# 整理背包不触动待售区。
	var sort_bag := Inventory.new(Inventory.SLOT_COUNT, Inventory.COMMON_COUNT)
	sort_bag.slots[0] = {"item": BlockTypes.Block.STONE, "count": 2, "durability": -1}
	sort_bag.slots[Inventory.COMMON_COUNT] = {"item": BlockTypes.Block.SAND, "count": 7, "durability": -1}
	sort_bag.sort_by_category()
	_check(sort_bag.get_item(Inventory.COMMON_COUNT) == BlockTypes.Block.SAND
		and sort_bag.get_count(Inventory.COMMON_COUNT) == 7, "整理背包不影响待售区")

	# 面板：开关、选区、数量钳制、快捷栏视图联动。
	player.inventory.slots[0] = {"item": BlockTypes.Block.STONE, "count": 5, "durability": -1}
	hud.open_inventory()
	_check(hud._inventory_panel.is_open(), "可按 B 打开背包窗口（B 键路径）")
	hud._inventory_panel._on_cell_pressed("common", 0)
	var sel := hud._inventory_panel.selection()
	_check(String(sel["zone"]) == "common" and int(sel["index"]) == 0, "点选背包格后可读取选区")
	hud._inventory_panel.set_amount(99999)
	_check(int(hud._inventory_panel.selection()["amount"]) == 5, "搬运数量被钳制在该格数量内")
	player.select_slot(0)
	_check(player.active_inventory_slot() == 0
		and player.inventory.get_item(player.active_inventory_slot()) == BlockTypes.Block.STONE,
		"快捷栏 1 号位手持物品来自映射的背包槽")
	hud.close_inventory()
	_check(not hud._inventory_panel.is_open(), "关闭背包窗口后状态复位")


	# ── 阶段 P：工具分级、矿石门槛、生物生长、狩猎规则、弓箭与垂钓（M8） ──
	# P-1 工具分级 1~4 级
	_check(
		ItemTypes.tool_tier(ItemTypes.WOOD_PICKAXE) == 1
		and ItemTypes.tool_tier(ItemTypes.STONE_PICKAXE) == 2
		and ItemTypes.tool_tier(ItemTypes.BRONZE_PICKAXE) == 3
		and ItemTypes.tool_tier(ItemTypes.IRON_PICKAXE) == 4,
		"工具分级为 1 木 / 2 石 / 3 青铜 / 4 铁",
	)
	_check(
		ItemTypes.tool_speed(ItemTypes.WOOD_PICKAXE) < ItemTypes.tool_speed(ItemTypes.STONE_PICKAXE)
		and ItemTypes.tool_speed(ItemTypes.STONE_PICKAXE) < ItemTypes.tool_speed(ItemTypes.BRONZE_PICKAXE)
		and ItemTypes.tool_speed(ItemTypes.BRONZE_PICKAXE) < ItemTypes.tool_speed(ItemTypes.IRON_PICKAXE),
		"采集速度随等级递增（%.0f < %.0f < %.0f < %.0f）" % [
			ItemTypes.tool_speed(ItemTypes.WOOD_PICKAXE),
			ItemTypes.tool_speed(ItemTypes.STONE_PICKAXE),
			ItemTypes.tool_speed(ItemTypes.BRONZE_PICKAXE),
			ItemTypes.tool_speed(ItemTypes.IRON_PICKAXE),
		],
	)
	_check(
		ItemTypes.tool_speed(ItemTypes.GOLD_PICKAXE) > ItemTypes.tool_speed(ItemTypes.IRON_PICKAXE)
		and ItemTypes.tool_durability(ItemTypes.SILVER_PICKAXE) > ItemTypes.tool_durability(ItemTypes.IRON_PICKAXE)
		and ItemTypes.tool_durability(ItemTypes.GOLD_PICKAXE) < ItemTypes.tool_durability(ItemTypes.IRON_PICKAXE),
		"银/金为同级珍稀变体：金最快但最脆、银最耐用",
	)
	var ladder_ok := true
	for tier in [1, 2, 3, 4]:
		var kinds := {}
		for id: int in ItemTypes.TOOL_TYPE:
			var kind := ItemTypes.tool_type(id)
			if ItemTypes.tool_tier(id) == tier and kind != "bow" and kind != "rod":
				kinds[kind] = true
		if kinds.size() < 4:
			ladder_ok = false
	_check(ladder_ok, "每级都备齐镐/斧/锹/镰刀四类采集工具")
	_check(
		ItemTypes.is_bow(ItemTypes.WOOD_BOW) and ItemTypes.is_rod(ItemTypes.WOOD_FISHING_ROD)
		and ItemTypes.tool_type(ItemTypes.IRON_SICKLE) == "sickle",
		"镰刀/鱼竿/弓已纳入工具类别",
	)
	_check(ItemTypes.TOOL_TYPE.size() == 26, "工具总数 26 件（4 级×4 类 + 银金 6 + 渔具 4）")
	_check(
		ItemTypes.tool_type_name(ItemTypes.WOOD_AXE) == "斧头"
		and ItemTypes.tool_type_name(ItemTypes.WOOD_SICKLE) == "镰刀",
		"工具类别有中文名（斧头/镰刀），供狩猎提示使用",
	)

	# P-2 矿石等级门槛与深层生成
	_check(
		BlockTypes.required_tier(BlockTypes.Block.TIN_ORE) == 2
		and BlockTypes.required_tier(BlockTypes.Block.IRON_ORE) == 3
		and BlockTypes.required_tier(BlockTypes.Block.GOLD_ORE) == 4,
		"锡/铁/金矿石分别要求 2/3/4 级工具",
	)
	_check(
		not BlockTypes.tier_allows(BlockTypes.Block.TIN_ORE, 1)
		and BlockTypes.tier_allows(BlockTypes.Block.TIN_ORE, 2)
		and BlockTypes.tier_allows(BlockTypes.Block.STONE, 0),
		"木镐采不下锡矿、石镐可以；普通石头无门槛",
	)
	_check(BlockTypes.tier_hint(BlockTypes.Block.IRON_ORE) == "青铜镐", "铁矿的提示名为「青铜镐」")
	_check(
		BlockTypes.HARDNESS.has(BlockTypes.Block.IRON_ORE)
		and BlockTypes.EFFECTIVE_TOOL.get(BlockTypes.Block.GOLD_ORE, "") == "pickaxe"
		and ItemTypes.is_placeable(BlockTypes.Block.IRON_ORE),
		"铁/金矿石已接入硬度表、有效工具与可放置判定",
	)

	var scan_min := Vector3i(8, 1, 8)
	var scan_max := Vector3i(40, World.SEA_LEVEL - 6, 40)
	world.ensure_chunks_in_region(scan_min, scan_max)
	var iron_found := 0
	var gold_found := 0
	for wx in range(scan_min.x, scan_max.x + 1):
		for wz in range(scan_min.z, scan_max.z + 1):
			for wy in range(1, World.SEA_LEVEL - 5):
				var ore := world.get_block(Vector3i(wx, wy, wz))
				if ore == BlockTypes.Block.IRON_ORE:
					iron_found += 1
				elif ore == BlockTypes.Block.GOLD_ORE:
					gold_found += 1
	_check(iron_found > 0, "地层中生成铁矿石（命中 %d 格）" % iron_found)
	_check(gold_found > 0, "更深处生成金矿石（命中 %d 格）" % gold_found)

	# P-3 新材料合成与冶炼链路
	var iron_recipe := ItemTypes.SMELT_RECIPES[3]
	_check(int(iron_recipe["result"]) == ItemTypes.IRON_INGOT, "冶炼配方含铁矿 → 铁锭")
	var chain_inv := Inventory.new(Inventory.SLOT_COUNT, Inventory.COMMON_COUNT)
	chain_inv.add_item(BlockTypes.Block.IRON_ORE, 2)
	_check(
		chain_inv.craft(iron_recipe) and chain_inv.count_item(ItemTypes.IRON_INGOT) == 1,
		"铁矿×2 冶炼为铁锭",
	)
	chain_inv.add_item(ItemTypes.IRON_INGOT, 3)
	chain_inv.add_item(BlockTypes.Block.WOOD, 2)
	var iron_pick_recipe := _find_recipe(ItemTypes.IRON_PICKAXE)
	_check(
		not iron_pick_recipe.is_empty() and chain_inv.craft(iron_pick_recipe)
		and chain_inv.count_item(ItemTypes.IRON_PICKAXE) == 1,
		"铁锭×3 + 木×2 合成铁镐",
	)
	_check(
		int(ItemTypes.TOOL_DURABILITY[ItemTypes.IRON_PICKAXE]) > int(ItemTypes.TOOL_DURABILITY[ItemTypes.BRONZE_PICKAXE]),
		"铁镐耐久高于青铜镐",
	)
	var arrow_inv := Inventory.new(Inventory.SLOT_COUNT, Inventory.COMMON_COUNT)
	arrow_inv.add_item(BlockTypes.Block.WOOD, 1)
	arrow_inv.add_item(BlockTypes.Block.COBBLESTONE, 1)
	arrow_inv.add_item(ItemTypes.FEATHER, 1)
	var arrow_recipe := _find_recipe(ItemTypes.ARROW)
	_check(
		not arrow_recipe.is_empty() and arrow_inv.craft(arrow_recipe)
		and arrow_inv.count_item(ItemTypes.ARROW) == ItemTypes.recipe_count(arrow_recipe),
		"木+圆石+羽毛 一次合成 4 支箭",
	)
	_check(
		BlockTypes.drop_count_for(BlockTypes.Block.WHEAT_CROP) == 2
		and BlockTypes.drop_count_for(BlockTypes.Block.WHEAT_CROP, "sickle") == 4,
		"镰刀收割小麦收成翻倍（2 → 4）",
	)

	# P-4 生物生长阶段
	_check(
		Mob.stage_count_of(Mob.MobType.CHICKEN) == 3
		and Mob.stage_count_of(Mob.MobType.BUTTERFLY) == 4
		and Mob.stage_count_of(Mob.MobType.COW) == 2
		and Mob.stage_count_of(Mob.MobType.ZOMBIE) == 1,
		"成长链：鸡 3 段 / 蝴蝶 4 段 / 牛 2 段 / 僵尸无成长",
	)
	var adult_hen := Mob.new()
	adult_hen.setup(Mob.MobType.CHICKEN, player, day_night)
	_check(
		adult_hen.is_adult() and adult_hen.stage_name() == "鸡" and adult_hen.max_health == 3,
		"默认以成体出现（「鸡」/ 生命 3），与旧行为一致",
	)
	var egg := _spawn_mob(
		main_scene, Mob.MobType.CHICKEN, player, day_night, Vector3(28.5, base_y + 1.1, 24.5), 0
	)
	_check(
		not egg.is_adult() and egg.stage_name() == "鸡蛋" and not egg.is_huntable()
		and egg.max_health < adult_hen.max_health and egg.is_still(),
		"卵阶段：名「鸡蛋」/ 生命更低 / 原地不动 / 不可狩猎",
	)
	Events.mob_grown.connect(_on_probe_grown)
	_grown_events = 0
	day_night.advance_days(1)
	await get_tree().process_frame
	_check(egg.stage == 1 and egg.stage_name() == "小鸡", "跨过一个游戏日后鸡蛋孵出小鸡")
	_check(_grown_events == 1, "成长事件已广播一次（供成就计数）")
	_check(
		egg.stage_scale() < adult_hen.stage_scale() and egg._visual_root.scale.x < 0.99,
		"幼体外观按阶段缩放（%.2f）" % egg.stage_scale(),
	)
	_check(egg._visual_root.get_child_count() > 0, "阶段切换后外观已重建")
	_check(egg.advance_stage() and egg.stage == 2 and egg.is_adult(), "再推进一阶段即成年为鸡")
	_check(not egg.advance_stage(), "成体阶段不再推进")
	Events.mob_grown.disconnect(_on_probe_grown)
	var frog_chain := Mob.stages_of(Mob.MobType.FROG)
	_check(
		String(frog_chain[0]["name"]) == "蛙卵" and String(frog_chain[1]["name"]) == "蝌蚪"
		and String(frog_chain[2]["name"]) == "青蛙",
		"青蛙成长链为 蛙卵 → 蝌蚪 → 青蛙",
	)
	var butterfly_chain := Mob.stages_of(Mob.MobType.BUTTERFLY)
	_check(
		String(butterfly_chain[2]["name"]) == "茧" and String(butterfly_chain[1]["name"]) == "毛毛虫",
		"蝴蝶成长链含 毛毛虫 → 茧 → 蝴蝶",
	)
	_check(day_night.day_count() > 1, "昼夜循环已累计游戏天数（第 %d 天）" % day_night.day_count())

	# P-5 保护动物
	_check(
		Mob.is_protected(Mob.MobType.PANDA) and Mob.is_protected(Mob.MobType.CRESTED_IBIS)
		and Mob.is_protected(Mob.MobType.BUTTERFLY) and Mob.is_protected(Mob.MobType.VILLAGER)
		and not Mob.is_protected(Mob.MobType.COW),
		"保护名录：大熊猫/朱鹮/蝴蝶/村民受保护，牛不受保护",
	)
	var panda := _spawn_mob(
		main_scene, Mob.MobType.PANDA, player, day_night, Vector3(31.5, base_y + 1.1, 26.5)
	)
	_check(
		panda.display_name() == "大熊猫" and Mob.is_passive(Mob.MobType.PANDA)
		and panda.max_health == 14 and not panda.is_huntable(),
		"大熊猫：被动词条 / 生命 14 / 不可狩猎",
	)
	_check(
		panda._nametag.modulate.g > panda._nametag.modulate.r,
		"保护动物名牌为绿色（r=%.2f g=%.2f）" % [panda._nametag.modulate.r, panda._nametag.modulate.g],
	)
	var panda_hit := HuntRules.evaluate(panda, ItemTypes.IRON_AXE)
	_check(
		not bool(panda_hit["ok"]) and bool(panda_hit["protection"])
		and String(panda_hit["toast"]).find("保护") >= 0,
		"攻击大熊猫被拦下并给出保护提示（「%s」）" % String(panda_hit["toast"]),
	)
	_check(
		int(RegionAtlas.profile(RegionAtlas.ASIA)["passive"].get("PANDA", 0)) > 0
		and int(RegionAtlas.profile(RegionAtlas.ASIA)["passive"].get("GOLDEN_MONKEY", 0)) > 0
		and int(RegionAtlas.profile(RegionAtlas.ARCTIC)["passive"].get("POLAR_BEAR", 0)) > 0
		and int(RegionAtlas.profile(RegionAtlas.OCEANIA)["passive"].get("KANGAROO", 0)) > 0
		and int(RegionAtlas.profile(RegionAtlas.NORTH_AMERICA)["passive"].get("BALD_EAGLE", 0)) > 0,
		"各区域生成表已含本地代表保护动物（熊猫/金丝猴/北极熊/袋鼠/白头海雕）",
	)
	var new_mob_visuals_ok := true
	for mob_type: int in [
		Mob.MobType.BUTTERFLY, Mob.MobType.PANDA, Mob.MobType.GOLDEN_MONKEY,
		Mob.MobType.CRESTED_IBIS, Mob.MobType.BALD_EAGLE, Mob.MobType.POLAR_BEAR, Mob.MobType.KANGAROO,
	]:
		var specimen := Mob.new()
		specimen.setup(mob_type, player, day_night)
		main_scene.add_child(specimen)
		specimen.global_position = Vector3(30.5, base_y + 1.1, 30.5)
		if specimen._visual_root.get_child_count() == 0:
			new_mob_visuals_ok = false
		specimen.queue_free()
	_check(new_mob_visuals_ok, "7 种新增生物（蝴蝶与 6 种保护动物）外观均可构建")

	# P-6 狩猎规则引擎
	var cow := _spawn_mob(
		main_scene, Mob.MobType.COW, player, day_night, Vector3(26.5, base_y + 1.1, 28.5)
	)
	var bare_hit := HuntRules.evaluate(cow, -1)
	var axe_hit := HuntRules.evaluate(cow, ItemTypes.WOOD_AXE)
	var wrong_hit := HuntRules.evaluate(cow, ItemTypes.WOOD_SHOVEL)
	_check(
		bool(axe_hit["ok"]) and int(axe_hit["damage"]) == 4 and not HuntRules.rule_for(Mob.MobType.COW).is_empty(),
		"木斧狩猎牛造成 4 点伤害",
	)
	_check(
		int(bare_hit["damage"]) < int(axe_hit["damage"]),
		"徒手伤害低于斧头（%d < %d）" % [int(bare_hit["damage"]), int(axe_hit["damage"])],
	)
	_check(
		int(wrong_hit["damage"]) == int(bare_hit["damage"]) and not String(wrong_hit["toast"]).is_empty(),
		"用错工具伤害减半并提示正确工具（「%s」）" % String(wrong_hit["toast"]),
	)
	_check(
		HuntRules.wears_tool(cow, ItemTypes.WOOD_AXE) and not HuntRules.wears_tool(cow, ItemTypes.WOOD_SHOVEL),
		"只有用对的工具才会磨损耐久",
	)
	var hunter_fish := Mob.new()
	hunter_fish.setup(Mob.MobType.FISH, player, day_night)
	_check(
		int(HuntRules.evaluate(hunter_fish, ItemTypes.WOOD_FISHING_ROD)["damage"]) == 5
		and int(HuntRules.evaluate(hunter_fish, ItemTypes.IRON_AXE)["damage"]) == 2,
		"鱼：鱼竿伤害 5、斧头只有 2",
	)
	var calf := _spawn_mob(
		main_scene, Mob.MobType.COW, player, day_night, Vector3(24.5, base_y + 1.1, 30.5), 0
	)
	var calf_hit := HuntRules.evaluate(calf, ItemTypes.IRON_AXE)
	_check(
		not bool(calf_hit["ok"]) and bool(calf_hit["stage_blocked"]) and not calf.is_huntable(),
		"幼体不可狩猎（提示：「%s」）" % String(calf_hit["toast"]),
	)
	var calf_drops := await _kill_and_collect(main_scene, calf)
	_check(
		calf_drops.has(ItemTypes.RAW_BEEF) and not calf_drops.has(ItemTypes.HIDE),
		"幼体掉落更少（只有生牛排，没有兽皮）",
	)
	var adult_drops := await _kill_and_collect(main_scene, cow)
	_check(adult_drops.has(ItemTypes.HIDE), "成体牛额外掉落兽皮")
	var bear := _spawn_mob(
		main_scene, Mob.MobType.POLAR_BEAR, player, day_night, Vector3(33.5, base_y + 1.1, 28.5)
	)
	_check(bear.counters_back() and not Mob.COUNTER_MOBS.has(Mob.MobType.COW), "北极熊会反击，牛只会逃跑")
	bear.take_damage(1)
	_check(
		bear.is_countering()
		and bear._nametag.modulate.r > bear._nametag.modulate.g
		and bear._nametag.modulate.g > bear._nametag.modulate.b,
		"受击后进入反击状态且名牌转红",
	)
	bear.queue_free()
	panda.queue_free()

	# P-7 弓箭
	_check(
		HuntRules.bow_damage(0.0) == HuntRules.BOW_DAMAGE_MIN
		and HuntRules.bow_damage(1.0) == HuntRules.BOW_DAMAGE_MAX
		and HuntRules.bow_damage(0.5) < HuntRules.bow_damage(1.0),
		"弓伤害随蓄力提升（%d → %d）" % [HuntRules.BOW_DAMAGE_MIN, HuntRules.BOW_DAMAGE_MAX],
	)
	var calf_ref := Mob.new()
	calf_ref.setup(Mob.MobType.COW, player, day_night, 0)
	var panda_ref := Mob.new()
	panda_ref.setup(Mob.MobType.PANDA, player, day_night)
	var cow_ref := Mob.new()
	cow_ref.setup(Mob.MobType.COW, player, day_night)
	_check(
		HuntRules.arrow_damage(cow_ref, 6) == 6 and HuntRules.arrow_damage(panda_ref, 6) == 0
		and HuntRules.arrow_damage(calf_ref, 6) == 0,
		"箭对保护动物与幼体免伤",
	)
	player.inventory.slots[0] = {
		"item": ItemTypes.WOOD_BOW, "count": 1,
		"durability": ItemTypes.tool_durability(ItemTypes.WOOD_BOW),
	}
	player.inventory.slots[1] = {"item": ItemTypes.ARROW, "count": 5, "durability": -1}
	player.inventory.hotbar_map[0] = 0
	player.inventory.hotbar_map[1] = 1
	player.select_slot(0)
	_check(player.get_selected_item() == ItemTypes.WOOD_BOW, "快捷栏 1 号位手持木弓")
	player._begin_use()
	_check(player.is_charging_bow(), "按住右键开始拉弓蓄力")
	player._update_bow(1.0)
	_check(
		player.bow_charge_ratio() > 0.5,
		"蓄力进度可读取（%.2f）" % player.bow_charge_ratio(),
	)
	var arrows_before := player.inventory.count_item(ItemTypes.ARROW)
	player._end_use()
	await get_tree().process_frame
	var arrows_shot := 0
	for child in main_scene.get_children():
		if child is ArrowProjectile:
			arrows_shot += 1
			child.queue_free()
	_check(arrows_shot == 1 and not player.is_charging_bow(), "松手射出一支箭且蓄力归零")
	_check(
		player.inventory.count_item(ItemTypes.ARROW) == arrows_before - 1,
		"射击消耗一支箭（%d → %d）" % [arrows_before, player.inventory.count_item(ItemTypes.ARROW)],
	)

	# P-8 垂钓：抛竿 → 咬钩 → 收竿
	var fish_spot := _find_kind_cell(
		world, Vector2i(int(player.global_position.x), int(player.global_position.z)), World.WATER_LARGE, 60
	)
	if fish_spot == Vector2i.ZERO:
		fish_spot = _find_kind_cell(
			world, Vector2i(int(player.global_position.x), int(player.global_position.z)), World.WATER_POND, 60
		)
	_check(fish_spot != Vector2i.ZERO, "玩家附近可找到水体用于垂钓")
	_ensure_water_chunks(world, fish_spot, 8)
	player.set_physics_process(false)
	player.global_position = Vector3(
		float(fish_spot.x) + 4.5, float(World.SEA_LEVEL) + 2.0, float(fish_spot.y) + 0.5
	)
	player._camera.look_at(
		Vector3(float(fish_spot.x) + 0.5, float(World.SEA_LEVEL) - 1.0, float(fish_spot.y) + 0.5), Vector3.UP
	)
	player.inventory.slots[2] = {
		"item": ItemTypes.WOOD_FISHING_ROD, "count": 1,
		"durability": ItemTypes.tool_durability(ItemTypes.WOOD_FISHING_ROD),
	}
	player.inventory.hotbar_map[0] = 2
	player.select_slot(0)
	_check(player.get_selected_item() == ItemTypes.WOOD_FISHING_ROD, "快捷栏 1 号位手持木鱼竿")
	var casted := player._cast_fishing()
	_check(
		casted and player.fishing_state() == Player.FISH_WAITING and player._bobber != null,
		"抛竿后浮标落在水面并进入等待咬钩",
	)
	player._fish_timer = 0.001
	await get_tree().process_frame
	_check(
		player.fishing_state() == Player.FISH_BITING and player._bobber.is_biting(),
		"等待结束后浮标下沉、提示可以收竿",
	)
	var bag_before := _inventory_total(player.inventory)
	player._reel_fishing()
	_check(
		player.fishing_state() == Player.FISH_IDLE and player._bobber == null,
		"收竿后回到待机状态并回收浮标",
	)
	_check(
		_inventory_total(player.inventory) > bag_before,
		"咬钩时收竿有收获（背包物品 %d → %d）" % [bag_before, _inventory_total(player.inventory)],
	)
	player._cast_fishing()
	player._reel_fishing()
	_check(player.fishing_state() == Player.FISH_IDLE, "提前收竿（未咬钩）也能安全回到待机")
	player.set_physics_process(true)

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


func _spawn_mob(parent: Node, mob_type: Mob.MobType, player: Player, dn: DayNightCycle, pos: Vector3, start_stage: int = -1) -> Mob:
	var mob := Mob.new()
	mob.setup(mob_type, player, dn, start_stage)
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


## 背包内所有槽位的数量之和（垂钓收益断言用）。
func _inventory_total(inv: Inventory) -> int:
	var total := 0
	for slot: Dictionary in inv.slots:
		total += int(slot["count"])
	return total


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


## 阶段 P 的成长事件统计回调（成员变量，供 lambda/connect 使用）。
func _on_probe_grown(_mob_type: int, _stage: int) -> void:
	_grown_events += 1


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
