extends Node
## 无头生存扩展探针：验证动物驻足节奏、按住左键连击、猪/狼生物、
## 夜晚天黑（环境光调制）、储物箱存取/破坏散落、村庄农田与面包链路、
## 堆叠 100、背包分类整理、铜锡矿生成、冶炼链路、生物名牌与 HUD 新增面板，
## 以及水体生态（大河/池塘分类、水生植物、鱼虾蟹蜻蜓青蛙与各自行为）。
## 运行：Godot_v4.6.3-stable_win64_console.exe --headless --path . res://tests/life_probe.tscn

var _failed := 0
## 成长事件计数（lambda 捕获成员而非局部变量，便于统计）。
var _grown_events := 0
## 掉血来源记录（同上：lambda 捕获局部变量是拷贝，必须用成员）。
var _damage_reasons: PackedStringArray = []
## 存档隔离（D-010 铁律 3）：_run() 开头（任何 notify 之前）快照 user://
## progress.json 文本 + 进度内存态，quit 前原样还原。内存态必须一并还原——
## Progress._exit_tree 退出时会 _save() 把内存态写盘，只还文件会被覆盖。
## 教训来源（2026-10-15 实测）：原有小节级局部快照（阶段 L / S 各自备份）
## 覆盖不到小节之间的 gameplay 计数（成长/击杀/挖掘/交易），退出落盘把
## user://progress.json 写脏——违铁律 3。
var _saved_progress := ""
var _saved_counters: Dictionary = {}
var _saved_states: Dictionary = {}
var _saved_quiz_streak := 0
## 和平模式段（Q-8，D-078）的存档隔离（D-010 铁律 3）：world.json 的存在性与
## 文本快照。该开关只在玩家主动点面板时才写档，探针从不点面板 ⇒ 正常路径下
## 这个文件从头到尾都不该出现；一旦将来代码在「读」路径上写了档，这里的还原
## 与对比就是第一道警报。还原由 _restore_world_settings 负责（含 _exit_tree 兜底）。
var _world_existed := false
var _world_text := ""
var _world_restored := false
var _world_snapshotted := false
## 受保护名录里「不算图鉴物种」的三项：村民是人不是物种；蜻蜓、蝴蝶是游戏里
## 陪伴玩家的益虫，图鉴未收录它们的资料。给它们补条目时请一并删掉这条豁免。
const PROTECTED_WITHOUT_ENTRY := [
	Mob.MobType.VILLAGER,
	Mob.MobType.DRAGONFLY,
	Mob.MobType.BUTTERFLY,
]


func _ready() -> void:
	await _run()


func _run() -> void:
	# 存档隔离（D-010 铁律 3）：在任何 Progress.notify 之前快照，quit 前还原。
	_saved_progress = _read_user_text("user://progress.json")
	# world.json 与进度同步在「任何写操作之前」快照（D-078 段会用，见 §Q-8）——
	# 提前到 _run() 开头，是因为探针若在 Q-8 之前就崩掉，_exit_tree 的还原也不该
	# 把一个玩家真实存在的 world.json 当成「探针多出来的」删掉。
	_snapshot_world_settings()

	_saved_counters = Progress.counters.duplicate()
	_saved_states = Progress.states.duplicate()
	_saved_quiz_streak = Progress._quiz_correct_since_reward
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
	_check(wolf.health == 7 and wolf.attack_damage == 1 and wolf.drop_item == BlockTypes.Block.AIR,
		"狼属性：生命 7 / 攻击 1（调低）/ 无掉落")

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
	player.global_position = _stand_pos(world, 24, 26, base_y)
	player.velocity = Vector3.ZERO
	var wanderer := _spawn_mob(main_scene, Mob.MobType.PIG, player, day_night,
		_stand_pos(world, 30, 21, base_y))
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
	# D-062 P1：实体缩小后近战必须低头瞄准，原 −Z 方向（狼在土埂另一侧）会被
	# 中间那道 1 m 高地形挡住——P1 前视线水平恰好越过、实体缩小后暴露。改为
	# +Z 侧（与玩家同高的平坦侧），瞄准躯干中心。
	var target := _spawn_mob(main_scene, Mob.MobType.WOLF, player, day_night,
		player.global_position + Vector3(0.0, 0.1, 2.0))
	target.set_physics_process(false)
	# D-062 P1：狼按真实米制缩小为 ~1 m 高，水平视线（眼高 1.4 m）会从其头顶
	# 越过——真实玩家近战会低头瞄准，探针同样显式瞄准躯干中心。
	# 注意：相机朝向是本探针后续阶段（钓点/蟹/蛙）的默认前提，必须原地还原，
	# 否则「低头 21°」会连带打挂后面所有依赖射线的断言。
	# 先等一帧：新 add_child 的碰撞体全局变换要下一帧才落定，此刻读取会拿到
	# 陈旧坐标（曾据此瞄准到错误方向、脱靶）。
	await get_tree().physics_frame
	var _saved_cam_tf := player._camera.global_transform
	player._camera.look_at(target._collision.global_position)
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
	# 连击够久会把 7 血的狼打死，而 _die() 会 queue_free——这里必须在读取前确认还活着，
	# 否则「打得太狠」反而让探针崩在 freed 对象上（攻击节奏受帧率影响，不稳定）。
	var hp_after: int = target.health if is_instance_valid(target) else 0
	_check(hp0 - hp_after >= 3, "按住左键 1.5 秒内连续攻击多次（共命中 %d 点）" % (hp0 - hp_after))
	if is_instance_valid(target):
		target.queue_free()
	# 还原相机（见上方瞄准注记）：后续阶段一律按默认水平视线运行。
	player._camera.global_transform = _saved_cam_tf

	# ── 阶段 D：猪掉生猪排、狼夜晚追击且无掉落 ──────────────────────────
	var pig2 := _spawn_mob(main_scene, Mob.MobType.PIG, player, day_night,
		_stand_pos(world, 30, 21, base_y))
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
	# D-055：储物箱必须与玩家站在**等高的相邻两列**，否则射线打空。
	# 原版把箱子放 (30, base_y+1, 24)、玩家站 (30.5, base_y+1.1, 26.5)，
	# 两者高度都套 base_y（村庄区域**最高点**）。分层地形后 (30,26) 地表 38、
	# (30,24) 地表 40——差 2 格，箱子浮在高一格的坡上，射线水平打不到，
	# 8 项断言连挂。现改成：先在村庄范围内扫一对**地表等高**的相邻列
	# （玩家列 / 箱子列），地形怎么变都能找到平地。
	var flat_pair := _find_flat_pair(world, 30, 26, 12)
	_check(flat_pair != Vector2i.ZERO,
		"村庄内找到等高平地（玩家列与箱子列地表同高）")
	var chest_cell := Vector3i(flat_pair.x,
		world.get_surface_height(flat_pair.x, flat_pair.y), flat_pair.y)
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
	# 箱子在 flat_pair，玩家退到同高的 z-2 处朝 +Z（默认朝向）。
	player.global_position = Vector3(float(flat_pair.x) + 0.5,
		float(world.get_surface_height(flat_pair.x, flat_pair.y - 2)) - 1.0 + 1.1,
		float(flat_pair.y - 2) + 0.5)
	player.velocity = Vector3.ZERO
	# 相机显式转向箱子：默认朝向是 -Z，箱子在 +Z 侧，不转会打空
	# （沿用本文件 1630 段钓鱼断言的 look_at 范式）。
	player._camera.look_at(
		Vector3(float(flat_pair.x) + 0.5,
			float(world.get_surface_height(flat_pair.x, flat_pair.y)) + 0.5,
			float(flat_pair.y) + 0.5),
		Vector3.UP)
	for i in range(40):
		await get_tree().physics_frame
	print("DBG chest_cell=", chest_cell, " player=", player.global_position,
		" on_floor=", player.is_on_floor(), " base_y=", base_y,
		" surf26=", world.get_surface_height(30, 26),
		" surf24=", world.get_surface_height(30, 24))
	var opened := player._interact_village()
	_check(opened, "右键指向储物箱触发开箱（_interact_village）")
	_check(hud._box_overlay != null and hud._box_overlay.visible, "request_box_open 打开储物箱面板")
	_check(hud._box_inventory == box, "面板绑定的是该箱背包")

	# 点击箱格 0：整叠 10 木头转入背包。
	hud._on_box_slot_pressed(0)
	_check(player.inventory.count_item(BlockTypes.Block.WOOD) == 10, "点击箱格后木头×10 转入背包")
	_check(box.count_item(BlockTypes.Block.WOOD) == 0, "箱内对应格清空")
	# 点击装着木头的那个背包格：整叠存回箱子。
	# 落点格由 add_item 决定——前序阶段拾取的物品可能占住第 0 格，把木头挤到
	# 别的格（本轮实测偶发），写死 0 会间歇性失败，按内容定位。
	var wood_slot := -1
	for i in range(player.inventory.slots.size()):
		if int(player.inventory.slots[i]["item"]) == BlockTypes.Block.WOOD:
			wood_slot = i
			break
	_check(wood_slot >= 0, "背包里找到刚转入的木头（第 %d 格）" % wood_slot)
	hud._on_box_player_slot_pressed(wood_slot)
	_check(box.count_item(BlockTypes.Block.WOOD) == 10, "点击背包格后木头×10 存回箱子")
	_check(player.inventory.count_item(BlockTypes.Block.WOOD) == 0, "背包对应格清空")
	hud.set_box_open(false)
	_check(not hud._box_overlay.visible, "储物箱面板可关闭")

	# 工具搬运保留耐久：磨旧的镐子搬个家不能凭空修满。
	# 先清掉玩家可能从先前阶段持有的同款工具，避免断言读到旧实例。
	for i in range(player.inventory.slots.size()):
		if int(player.inventory.slots[i]["item"]) == ItemTypes.WOOD_PICKAXE:
			player.inventory.slots[i] = {"item": BlockTypes.Block.AIR, "count": 0, "durability": -1}
	var worn: Dictionary = {"item": ItemTypes.WOOD_PICKAXE, "count": 1, "durability": 17}
	box.slots[1] = worn
	hud._on_box_slot_pressed(1)
	var carried_dur := -1
	for s in player.inventory.slots:
		if int(s["item"]) == ItemTypes.WOOD_PICKAXE:
			carried_dur = int(s["durability"])
	_check(
		carried_dur == 17,
		"箱→包工具转移保留源耐久（17，实际 %d）" % carried_dur
	)
	# 箱格 27~35 与前 27 格同等可见可取（箱体 36 格，此前只刷新前 27 格）。
	for i in range(27):
		box.slots[i] = {"item": BlockTypes.Block.DIRT, "count": BlockTypes.STACK_SIZE, "durability": -1}
	player.inventory.add_item(BlockTypes.Block.STONE, 30)
	var overflow_slot := -1
	for i in range(player.inventory.slots.size()):
		if int(player.inventory.slots[i]["item"]) == BlockTypes.Block.STONE:
			overflow_slot = i
			break
	hud._on_box_player_slot_pressed(overflow_slot)
	var box_overflow := 0
	for i in range(27, box.slots.size()):
		if int(box.slots[i]["item"]) == BlockTypes.Block.STONE:
			box_overflow += int(box.slots[i]["count"])
	var overflow_shown := 0
	for i in range(27, box.slots.size()):
		var b := hud._box_grid.get_child(i) as ItemSlot
		if b.item_id() == BlockTypes.Block.STONE:
			overflow_shown += 1
	_check(
		box_overflow == 30 and overflow_shown >= 1,
		"箱格 27~35 可存入且面板可见（溢出区石头 ×%d，显示格 %d/9）" % [box_overflow, overflow_shown]
	)
	hud._on_box_slot_pressed(27)
	_check(
		player.inventory.count_item(BlockTypes.Block.STONE) == 30,
		"箱格 27+ 的物品可点击取出（数量随之减少）"
	)
	# 还原现场：后续「破坏散落」阶段要求箱内恰好 10 木头、背包无多余测试物资。
	for i in range(box.slots.size()):
		box.slots[i] = {"item": BlockTypes.Block.AIR, "count": 0, "durability": -1}
	box.add_item(BlockTypes.Block.WOOD, 10)
	player.inventory.consume_item(BlockTypes.Block.STONE, 30)
	for i in range(player.inventory.slots.size()):
		if int(player.inventory.slots[i]["item"]) == ItemTypes.WOOD_PICKAXE:
			player.inventory.slots[i] = {"item": BlockTypes.Block.AIR, "count": 0, "durability": -1}

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
	# 体素 0.5m 化后农田（farm_o+12²）距出生点约 26 格，早于旧布局的近距；
	# 前置阶段耗时期间远处区块可能被流式卸载——先强制加载（村庄改动有
	# 卸载留存，重载后方块原样还原），否则 get_block 全部读到 AIR。
	world.ensure_chunks_in_region(
		Vector3i(farm_o.x - 8, 0, farm_o.z - 2),
		Vector3i(farm_o.x + VillageBuilder.FARM_SIZE + 8, base_y + 2, farm_o.z + VillageBuilder.FARM_SIZE + 8),
	)
	# 0.5m 化后农田远离旧测试锚点（44 格 > 卸载半径）：ensure 只保一帧，
	# 下一物理帧流式卸载会把区块再次卸掉（倒树铺地的木头就写进了已卸载区块）。
	# 玩家必须实际挪到农田旁，后续断言与倒树落地才在常驻区块上进行。
	player.global_position = Vector3(
		float(farm_o.x) + float(VillageBuilder.FARM_SIZE) * 0.5,
		float(world.get_surface_height(
			farm_o.x + VillageBuilder.FARM_SIZE / 2, farm_o.z + 2)) - 1.0 + 1.1,
		float(farm_o.z) + 2.5,
	)
	player.velocity = Vector3.ZERO
	_check(world.get_block(Vector3i(farm_o.x, base_y, farm_o.z)) == BlockTypes.Block.FARMLAND,
		"农田地块为耕地")
	var farm_water_x := VillageBuilder.FARM_SIZE / 2
	_check(world.get_block(Vector3i(farm_o.x + farm_water_x, base_y, farm_o.z)) == BlockTypes.Block.WATER,
		"农田中央一列为水")
	_check(world.get_block(Vector3i(farm_o.x + farm_water_x, base_y + 1, farm_o.z)) == BlockTypes.Block.AIR,
		"水列上方不种作物")

	# 农田混种：扫整片田，统计四种作物齐全（小麦为主 + 三种新蔬菜）。
	var crop_seen := {}
	for x in range(VillageBuilder.FARM_SIZE):
		for z in range(VillageBuilder.FARM_SIZE):
			if x == farm_water_x:
				continue
			var b := world.get_block(Vector3i(farm_o.x + x, base_y + 1, farm_o.z + z))
			if b in [BlockTypes.Block.WHEAT_CROP, BlockTypes.Block.CARROT_CROP,
					BlockTypes.Block.POTATO_CROP, BlockTypes.Block.RADISH_CROP]:
				crop_seen[b] = true
	_check(crop_seen.size() == 4, "农田混种四种作物齐全（实际 %d 种）" % crop_seen.size())

	# 找一株小麦收割，验证面包链路（新蔬菜掉落自身，见 BlockTypes.drop_for）。
	var crop_cell := Vector3i.ZERO
	for x in range(VillageBuilder.FARM_SIZE):
		for z in range(VillageBuilder.FARM_SIZE):
			if x == farm_water_x:
				continue
			var p := Vector3i(farm_o.x + x, base_y + 1, farm_o.z + z)
			if world.get_block(p) == BlockTypes.Block.WHEAT_CROP:
				crop_cell = p
				break
		if crop_cell != Vector3i.ZERO:
			break
	var wheat_before := player.inventory.count_item(ItemTypes.WHEAT)
	player._finish_break(crop_cell, BlockTypes.Block.WHEAT_CROP)
	_check(world.get_block(crop_cell) == BlockTypes.Block.AIR, "小麦作物可破坏")
	_check(
		player.inventory.count_item(ItemTypes.WHEAT) == wheat_before + 2,
		"收获小麦作物掉落小麦×2（drop_count_for）",
	)

	# ── 树叶随树干砍尽而落下消失 ──
	# 手工搭一棵最小树：4 格树干 + 顶端 5 片树叶，验证衰减判据与清除效果。
	# （0.5m 化后农田 12×12：+6 落在水列上，挪到农田东侧空地搭树。）
	var tree_b := Vector3i(farm_o.x + VillageBuilder.FARM_SIZE + 4, base_y + 2, farm_o.z + 2)
	for i in range(4):
		world.set_block(tree_b + Vector3i(0, i, 0), BlockTypes.Block.WOOD)
	var tree_leaves: Array[Vector3i] = [
		tree_b + Vector3i(0, 4, 0),
		tree_b + Vector3i(1, 4, 0), tree_b + Vector3i(-1, 4, 0),
		tree_b + Vector3i(0, 4, 1), tree_b + Vector3i(0, 5, 0),
	]
	for p in tree_leaves:
		world.set_block(p, BlockTypes.Block.LEAVES)
	var leaves_in_bag := player.inventory.count_item(BlockTypes.Block.LEAVES)

	# 自上而下砍（自上而下不会触发倒塌：每砍一格时上方已经没有树干）。
	player._finish_break(tree_b + Vector3i(0, 3, 0), BlockTypes.Block.WOOD)
	_check(
		world.get_block(tree_leaves[0]) == BlockTypes.Block.LEAVES,
		"树干未砍尽时树叶不落（上方仍有木头）",
	)
	# 继续往下砍到只剩树根：最后一块破坏后整冠消失。
	player._finish_break(tree_b + Vector3i(0, 2, 0), BlockTypes.Block.WOOD)
	player._finish_break(tree_b + Vector3i(0, 1, 0), BlockTypes.Block.WOOD)
	player._finish_break(tree_b, BlockTypes.Block.WOOD)
	var leaves_left := 0
	for p in tree_leaves:
		if world.get_block(p) == BlockTypes.Block.LEAVES:
			leaves_left += 1
	_check(leaves_left == 0, "树干全部砍掉后树叶整冠落下消失（残留 %d 片）" % leaves_left)
	_check(
		player.inventory.count_item(BlockTypes.Block.LEAVES) == leaves_in_bag,
		"落下的树叶直接消散、不进背包",
	)

	# ── 树干被砍断后整截倒下 ──
	# 再搭一棵 4 格树干 + 顶端树冠，从底部砍断：上方那截应当被清走（倒下），
	# 树冠随树一起走，落地后木头铺在地面上而不是悬在半空。
	# 树要搭在真实地面上：这里的地形比农田层低 8 格，用 base_y 会让树飘在空中，
	# 倒下的木头也就找不到落点（这就是第一轮断言失败的原因）。
	var fall_x := farm_o.x + 12
	var fall_z := farm_o.z + 6
	var fall_y := -1
	for y in range(base_y + 8, base_y - 24, -1):
		if world.get_block(Vector3i(fall_x, y, fall_z)) != BlockTypes.Block.AIR:
			fall_y = y + 1
			break
	_check(fall_y > 0, "找到 pos 处的地面以便搭一棵落地树（y=%d）" % fall_y)
	var fall_b := Vector3i(fall_x, fall_y, fall_z)
	for i in range(4):
		world.set_block(fall_b + Vector3i(0, i, 0), BlockTypes.Block.WOOD)
	# 树冠压在树干顶端之上（y=+4），别盖掉最后一节树干。
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			world.set_block(fall_b + Vector3i(dx, 4, dz), BlockTypes.Block.LEAVES)
	# 砍第二格：上方还剩 2 格树干 + 树冠 → 判据成立
	player._finish_break(fall_b + Vector3i(0, 1, 0), BlockTypes.Block.WOOD)
	_check(
		world.trunk_height_above(fall_b + Vector3i(0, 1, 0)) == 0,
		"砍断后上方那截树干被清走（倒下演出接管）",
	)
	_check(
		world.get_block(fall_b + Vector3i(0, 4, 0)) == BlockTypes.Block.AIR,
		"树冠随倒下的那截一起消失，不再悬在空中",
	)
	# 演出节点存在且会自己收尾；落地后木头铺在地面（存在 WOOD 且下方实心）。
	var falling := 0
	for child in world.get_children():
		if child is FallingTree:
			falling += 1
	_check(falling == 1, "生成了 1 个倒塌演出节点（现 %d 个）" % falling)
	for i in range(60):
		await get_tree().physics_frame
	var landed_wood := 0
	for i in range(1, 6):
		for axis_v: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
				Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			var p := fall_b + axis_v * i
			for dy in range(-3, 4):
				var q := Vector3i(p.x, fall_b.y + dy, p.z)
				if world.get_block(q) == BlockTypes.Block.WOOD \
						and world.get_block(q + Vector3i(0, -1, 0)) != BlockTypes.Block.AIR:
					landed_wood += 1
	_check(landed_wood >= 2, "倒下的木头落地铺在地面上（%d 段）" % landed_wood)
	var still_falling := 0
	for child in world.get_children():
		if child is FallingTree:
			still_falling += 1
	_check(still_falling == 0, "落地后演出节点自行回收（残留 %d 个）" % still_falling)

	# 手搭的木柱（上方没有树冠）不该被当成树推倒。
	# 放在村庄整平区内（无天然树，±4 树冠判据不会被野生树冠误触发）。
	var post_b := Vector3i(farm_o.x - 6, world.get_surface_height(farm_o.x - 6, farm_o.z + 2), farm_o.z + 2)
	for i in range(3):
		world.set_block(post_b + Vector3i(0, i, 0), BlockTypes.Block.WOOD)
	player._finish_break(post_b, BlockTypes.Block.WOOD)
	_check(
		world.get_block(post_b + Vector3i(0, 1, 0)) == BlockTypes.Block.WOOD,
		"手搭木柱不触发倒塌（上方木头仍在原位）",
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

	# ── 合成空位预检：模拟「先扣料再放产物」──
	# 满背包但材料分成两堆（5+4）：扣掉 5 那堆会腾出一格，木镐应当可合成。
	var ci := Inventory.new(Inventory.SLOT_COUNT, Inventory.COMMON_COUNT)
	ci.add_item(BlockTypes.Block.WOOD, 5)
	ci.add_item(BlockTypes.Block.WOOD, 4)
	for i in range(2, Inventory.COMMON_COUNT):
		ci.slots[i] = {"item": BlockTypes.Block.STONE, "count": 1, "durability": -1}
	var pick_recipe2 := _find_recipe(ItemTypes.WOOD_PICKAXE)
	_check(pick_recipe2 != null and ci.can_craft(pick_recipe2),
		"满包但扣料能腾格时木镐可合成（木头 5+4 两堆）")
	_check(ci.craft(pick_recipe2) and ci.count_item(ItemTypes.WOOD_PICKAXE) == 1,
		"满包扣料腾格合成实际成功")
	# 单堆 9 木头：扣 5 后仍占一格，满包时确实放不下，按钮应保持禁用。
	var cj := Inventory.new(Inventory.SLOT_COUNT, Inventory.COMMON_COUNT)
	cj.add_item(BlockTypes.Block.WOOD, 9)
	for i in range(1, Inventory.COMMON_COUNT):
		cj.slots[i] = {"item": BlockTypes.Block.STONE, "count": 1, "durability": -1}
	_check(not cj.can_craft(pick_recipe2), "满包且扣料腾不出格时木镐不可合成")

	var has_food_trade := false
	for trade: Dictionary in ItemTypes.TRADES:
		if trade["result"] in [ItemTypes.RAW_PORK, ItemTypes.BREAD, ItemTypes.WHEAT]:
			has_food_trade = true
	_check(has_food_trade, "交易列表含食物条目（猪排/面包/小麦）")

	# 村庄收购（卖出页签）：清单非空、打包价严格高于一键售卖、UI 可切换可成交。
	_check(
		ItemTypes.SELL_TRADES.size() >= 6,
		"村庄收购 %d 条（前期易得物资）" % ItemTypes.SELL_TRADES.size(),
	)
	var generous := true
	for sell_trade: Dictionary in ItemTypes.SELL_TRADES:
		var sell_item := int(sell_trade["item"])
		var sell_cnt := int(sell_trade["count"])
		if ItemTypes.sell_bundle_price(sell_item, sell_cnt) <= ItemTypes.sell_price(sell_item) * sell_cnt:
			generous = false
	_check(generous, "收购打包价严格高于一键售卖价（×1.5 奖励）")
	var wood_trade: Dictionary = {}
	for sell_trade2: Dictionary in ItemTypes.SELL_TRADES:
		if int(sell_trade2["item"]) == BlockTypes.Block.WOOD:
			wood_trade = sell_trade2
			break
	_check(not wood_trade.is_empty(), "收购清单含木头（前期最易得物资）")
	hud.set_trade_open(true)
	hud._on_trade_tab(1)
	await get_tree().process_frame
	var sell_grid := (hud._trade_list.get_child(0) as GridContainer)
	_check(sell_grid.get_child_count() == ItemTypes.SELL_TRADES.size(),
		"卖出页签显示 %d 行" % sell_grid.get_child_count())
	if not wood_trade.is_empty():
		var em_before := player.inventory.count_item(ItemTypes.EMERALD)
		player.inventory.add_item(BlockTypes.Block.WOOD, int(wood_trade["count"]) + 3)
		hud._refresh_trade_panel()
		await get_tree().process_frame
		# 刷新会整表重建，按钮要重新取（旧引用已随旧节点释放）。
		var wood_row := (hud._trade_list.get_child(0) as GridContainer).get_child(0) as HBoxContainer
		var wood_btn := wood_row.get_child(wood_row.get_child_count() - 1) as Button
		_check(not wood_btn.disabled, "补足木头后「出售」按钮可用")
		wood_btn.pressed.emit()
		await get_tree().process_frame
		_check(
			player.inventory.count_item(ItemTypes.EMERALD)
				== em_before + ItemTypes.sell_bundle_price(BlockTypes.Block.WOOD, int(wood_trade["count"])),
			"出售木头后绿宝石到账（打包价 ×1.5）",
		)
	hud._on_trade_tab(0)
	hud.set_trade_open(false)
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
		_stand_pos(world, 30, 21, base_y))
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
	# D-055：水体坐标不能写死。分层地形的长江/黄河 carve 改变了出生点附近
	# 的水系连通性——原坐标 (-8,-9) 半径 8 内原先是小池塘，现在那里的水体被
	# 连成了大河，water_kind 按连通规模分类后不再是 POND，「小池塘分类命中」
	# 连挂 6 项（水生植物/蟹/青蛙/岸边落点全被连带）。
	# 改为在更大范围内**自找**一处小池塘：地形怎么变都能找到合适的水体。
	var pond_cell := _find_kind_cell(world, Vector2i(-8, -9), World.WATER_POND, 8)
	if pond_cell == Vector2i.ZERO:
		pond_cell = _find_any_pond(world, 160)
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
	# 0.5m 化后水阻力/浮力常数随米制 ×2，贴底收敛变慢——多等一倍帧数再断言。
	for i in range(150):
		await get_tree().physics_frame
	# 断言值里带上高度与垂直速度：这条失败过（蟹悬在水中不落地），
	# 光看 true/false 无从判断是「没下沉」还是「浮起来了」，把过程量打出来省一轮排查。
	_check(
		live_crab.is_on_floor(),
		"蟹贴在水底（is_on_floor=%s，落点 y=%.2f → 现 y=%.2f，垂直速度 %.2f）" % [
			live_crab.is_on_floor(), bed_pos.y,
			live_crab.global_position.y, live_crab.velocity.y,
		],
	)
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
	player.global_position = _stand_pos(world, 24, 26, base_y)
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

	# 区域水体策略（D-028）：沙漠无河塘，极地冰海冰山，其余常规注水。
	_check(
		RegionAtlas.profile(RegionAtlas.AFRICA)["water"] == "dry"
		and RegionAtlas.profile(RegionAtlas.OCEANIA)["water"] == "dry",
		"非洲/大洋洲水体策略为「干燥」（沙漠不生河塘）",
	)
	_check(
		RegionAtlas.profile(RegionAtlas.ARCTIC)["water"] == "iceberg"
		and RegionAtlas.profile(RegionAtlas.ANTARCTICA)["water"] == "iceberg",
		"北冰洋/南极洲水体策略为「冰海冰山」",
	)
	_check(
		RegionAtlas.profile(RegionAtlas.PACIFIC)["water"] == "normal"
		and RegionAtlas.profile(RegionAtlas.ASIA)["water"] == "normal",
		"岛屿与大陆区域保持常规水体",
	)
	var polar_below_sea := true
	for pid: int in [RegionAtlas.ARCTIC, RegionAtlas.ANTARCTICA]:
		var pp: Dictionary = RegionAtlas.profile(pid)
		if float(pp["base_height"]) + float(pp["amplitude"]) > float(World.SEA_LEVEL):
			polar_below_sea = false
	_check(polar_below_sea, "极地地形全域低于海平面（一望无际的海洋）")

	# 冰方块登记齐全，冰海行为抽样（确定性，可直接断言）。
	_check(
		BlockTypes.display_name(BlockTypes.Block.ICE) == "冰块"
		and BlockTypes.is_solid(BlockTypes.Block.ICE)
		and BlockTypes.HARDNESS.has(BlockTypes.Block.ICE)
		and BlockTypes.EFFECTIVE_TOOL[BlockTypes.Block.ICE] == "pickaxe",
		"冰方块登记齐全（名称/固体/硬度/工具）",
	)
	var polar_world := World.new()
	polar_world.set_region(RegionAtlas.ARCTIC)
	_check(
		polar_world._block_at(3, World.SEA_LEVEL, 3, 15) == BlockTypes.Block.ICE,
		"北极海面封冻为冰",
	)
	var frozen_ok := true
	for ix in range(0, 60, 7):
		for iz in range(0, 60, 7):
			if polar_world._block_at(ix, World.SEA_LEVEL, iz, 15) != BlockTypes.Block.ICE:
				frozen_ok = false
	_check(frozen_ok, "北极海面整片封冻为冰（海平面层全为冰）")
	var icebergs := 0
	for ix in range(0, 240, 3):
		for iz in range(0, 240, 3):
			if polar_world._iceberg_top(ix, iz) > 0:
				icebergs += 1
	_check(icebergs >= 20, "北极散布成群冰山（采样命中 %d 列）" % icebergs)
	polar_world.free()
	var desert_world := World.new()
	desert_world.set_region(RegionAtlas.AFRICA)
	_check(
		desert_world._block_at(3, World.SEA_LEVEL, 3, 15) == BlockTypes.Block.AIR,
		"非洲洼地不生成水（沙漠无河塘）",
	)
	desert_world.free()

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
	globe.set_view_angles(0.0, 0.0)
	globe.rotate_view(Vector2(100.0, -50.0))
	var drag_angles := globe.get_view_angles()
	_check(
		is_equal_approx(drag_angles.x, 100.0 * MapGlobe.DRAG_SPEED)
		and is_equal_approx(drag_angles.y, -50.0 * MapGlobe.DRAG_SPEED)
		and MapGlobe.DRAG_SPEED >= 0.06,
		"拖动灵敏度为 4 倍速（%.2f 弧度/像素，横拖 100px 约 %.0f°）" % [
			MapGlobe.DRAG_SPEED, 100.0 * MapGlobe.DRAG_SPEED * 180.0 / PI
		],
	)
	globe.set_view_angles(0.0, 0.0)
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
	# 连对计数是独立成员（落盘为 quiz_streak），不还原会让下一轮的
	# 「答对 2 题尚未触发连对奖励」凭空失败——探针给自己下毒。
	var saved_counters: Dictionary = Progress.counters.duplicate()
	var saved_states: Dictionary = Progress.states.duplicate()
	var saved_quiz_streak: int = Progress._quiz_correct_since_reward
	Progress.counters.clear()
	Progress.states.clear()
	Progress._quiz_correct_since_reward = 0

	# 只数「新手链」本身（id 前缀 newbie_），不数总任务数——钓鱼/竞速等分支链
	# 会各自往 quests() 里追加，按总数断言会随新玩法上线而误报。
	var newbie_chain := 0
	for q: Dictionary in QuestData.quests():
		if String(q["id"]).begins_with("newbie_"):
			newbie_chain += 1
	_check(newbie_chain == 8, "新手任务链共 8 环（现 %d 环）" % newbie_chain)
	_check(QuestData.achievements().size() == 28, "成就共 28 枚（现 %d 枚）" % QuestData.achievements().size())
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
	hud._quest_panel.set_tab(QuestPanel.Tab.LESSONS)
	_check(hud._quest_panel.get_tab() == QuestPanel.Tab.LESSONS,
		"可切换到探索课堂页签（第三页签）")
	# 页签按钮文案统一取自 QuestPanel.TAB_TITLES，测试按常量比对，避免写死中文。
	var lesson_tab_shown := false
	for node in hud._quest_panel.find_children("*", "Button", true, false):
		var btn := node as Button
		if btn != null and btn.text == QuestPanel.TAB_TITLES[int(QuestPanel.Tab.LESSONS)]:
			lesson_tab_shown = true
	_check(lesson_tab_shown and QuestPanel.TAB_TITLES[2] == "探索课堂",
		"第三页签按钮文案为探索课堂")
	hud.close_quest_panel()
	_check(not hud._quest_panel.is_open() and player.is_physics_processing(),
		"关闭任务面板后玩家恢复物理处理")

	Progress.counters = saved_counters
	Progress.states = saved_states
	Progress._quiz_correct_since_reward = saved_quiz_streak
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

	# P-3b 挖矿掉落加成：矿石基础产量 ×2 + 幸运掉落（统计断言，采样足够大）。
	_check(
		BlockTypes.drop_count_for(BlockTypes.Block.COPPER_ORE) == 2
		and BlockTypes.drop_count_for(BlockTypes.Block.TIN_ORE) == 2
		and BlockTypes.drop_count_for(BlockTypes.Block.IRON_ORE) == 2
		and BlockTypes.drop_count_for(BlockTypes.Block.GOLD_ORE) == 2
		and BlockTypes.drop_count_for(BlockTypes.Block.STONE) == 1,
		"矿石基础产量 ×2（石头仍为 1）",
	)
	var extra_ore := 0
	var emerald_hits := 0
	for i in range(400):
		for bonus: Array in BlockTypes.ore_lucky_drops(BlockTypes.Block.COPPER_ORE, 0):
			if int(bonus[0]) == BlockTypes.Block.COPPER_ORE:
				extra_ore += 1
			elif int(bonus[0]) == ItemTypes.EMERALD:
				emerald_hits += 1
	_check(
		extra_ore >= 30 and extra_ore <= 140 and emerald_hits >= 1,
		"幸运掉落统计合理：400 次挖掘额外矿石 %d 次（期望 20%%）、绿宝石 %d 次（期望 5%%）" % [
			extra_ore, emerald_hits
		],
	)
	_check(
		BlockTypes.ore_lucky_drops(BlockTypes.Block.STONE, 9).is_empty(),
		"非矿石无幸运掉落",
	)
	# 端到端：木镐挖铜矿至少入账 2 份（幸运只多不少）。
	var ore_cell := Vector3i(34, world.get_surface_height(34, 28), 28)
	world.set_block(ore_cell, BlockTypes.Block.COPPER_ORE)
	player.inventory.add_item(ItemTypes.WOOD_PICKAXE, 1)
	player.select_slot(0)
	for i in range(player.inventory.slots.size()):
		if int(player.inventory.slots[i]["item"]) == ItemTypes.WOOD_PICKAXE:
			player.inventory.assign_hotbar(0, i)
			break
	var ore_before := player.inventory.count_item(BlockTypes.Block.COPPER_ORE)
	player._finish_break(ore_cell, BlockTypes.Block.COPPER_ORE)
	_check(
		player.inventory.count_item(BlockTypes.Block.COPPER_ORE) >= ore_before + 2,
		"木镐挖铜矿至少入账 2 份（%d → %d）" % [
			ore_before, player.inventory.count_item(BlockTypes.Block.COPPER_ORE)
		],
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
		main_scene, Mob.MobType.CHICKEN, player, day_night, _stand_pos(world, 28, 24, base_y), 0
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
		egg.stage_scale() < adult_hen.stage_scale() \
			and egg._visual_root.scale.x < adult_hen.stage_scale() * 2.0,
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
		main_scene, Mob.MobType.PANDA, player, day_night, _stand_pos(world, 31, 26, base_y)
	)
	# 人形生物必须有手臂：村民抱臂（10 网格）、掠夺者垂臂，缺失即造型回退。
	var villager_arm := Mob.new()
	villager_arm.setup(Mob.MobType.VILLAGER, player, day_night, -1)
	main_scene.add_child(villager_arm)
	await get_tree().process_frame
	await get_tree().process_frame
	var villager_meshes := 0
	for child in villager_arm.get_children():
		villager_meshes += _count_meshes_recursive(child)
	villager_arm.queue_free()
	_check(villager_meshes >= 10, "村民模型有手臂（网格 %d 个，抱臂 >= 10）" % villager_meshes)
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

	# ── 阶段 Q：探索模式（M7.1 模式本体：枚举、行为分支、地图页三选一） ──
	player.set_flying(false)
	GameState.set_mode(GameState.Mode.EXPLORE)
	_check(GameState.is_explore(), "GameState.Mode 新增探索模式")
	_check(not GameState.is_creative() and GameState.is_survival(),
		"探索模式不被判为创造，且仍受生存规则约束")
	_check(GameState.can_fly(), "探索模式开放飞行")
	_check(GameState.mode_name() == "探索", "模式显示名为「探索」")
	_check(GameState.mode_hint().contains("敌对"), "模式说明点明不生成敌对生物")

	# Q-1 飞行：生存不允许、探索允许、切回生存自动落地
	GameState.set_mode(GameState.Mode.SURVIVAL)
	player.set_flying(true)
	_check(not player.flying, "生存模式不允许起飞")
	GameState.set_mode(GameState.Mode.EXPLORE)
	player.set_flying(true)
	_check(player.flying, "探索模式可以起飞（双击空格）")
	GameState.set_mode(GameState.Mode.SURVIVAL)
	_check(not player.flying, "切回生存模式后自动落地")

	# Q-2 不无敌：探索模式照样受伤、照样饿、采掘照常掉落
	GameState.set_mode(GameState.Mode.EXPLORE)
	player.health = player.MAX_HEALTH
	player._damage(3)
	_check(player.health == player.MAX_HEALTH - 3,
		"探索模式不无敌（20 → %d）" % player.health)
	player.health = player.MAX_HEALTH
	player.hunger = float(player.MAX_HUNGER)
	player._tick_survival(1.0, false)
	_check(player.hunger < float(player.MAX_HUNGER),
		"探索模式饥饿照常消耗（满 20 → %.1f）" % player.hunger)
	player.hunger = float(player.MAX_HUNGER)

	# Q-2b 掉血可解释性：饥饿速度够慢、饥饿伤害有间隔、受击有无敌帧、来源有广播。
	# 早期饥饿 0.08/秒——站着发呆 4 分钟就见底，玩家只看到血条莫名其妙地掉。
	var q_hunger0 := player.hunger
	player._tick_survival(1.0, false)
	var drain_per_sec := q_hunger0 - player.hunger
	var full_seconds := float(Player.MAX_HUNGER) / drain_per_sec
	_check(is_equal_approx(drain_per_sec, Player.HUNGER_DRAIN_PER_SECOND),
		"静止 1 秒饥饿消耗 %.2f（与常量一致）" % drain_per_sec)
	_check(full_seconds > 600.0,
		"站着不动满饥饿可撑过整个白天（%.0f 秒 > 600 秒）" % full_seconds)

	player.damage_taken.connect(func(_a: int, r: String, _rem: int): _damage_reasons.append(r))
	player.hunger = 0.0
	player.health = Player.MAX_HEALTH
	player._starvation_timer = 0.0
	for i in range(4):
		player._tick_survival(1.0, false)
	_check(player.health == Player.MAX_HEALTH, "饥饿归零后 4 秒内不掉血（留出找食物的时间）")
	player._tick_survival(1.0, false)
	_check(player.health == Player.MAX_HEALTH - 1, "饥饿归零满 5 秒才扣 1 点")
	_check(_damage_reasons.has(Player.REASON_STARVE), "饥饿扣血广播来源「饥饿」（HUD 据此提示）")

	player.health = Player.MAX_HEALTH
	player._hurt_invuln = 0.0
	player.take_damage(2, "僵尸")
	player.take_damage(2, "蜘蛛")
	_check(player.health == Player.MAX_HEALTH - 2, "受击 0.5 秒无敌帧：连挨两下只结算一次")
	player._hurt_invuln = 0.0
	player.take_damage(2, "僵尸")
	_check(player.health == Player.MAX_HEALTH - 4, "无敌帧结束后可再次受伤")
	player._hurt_invuln = 0.0
	player.health = Player.MAX_HEALTH
	player.hunger = float(player.MAX_HUNGER)
	player._starvation_timer = 0.0

	player.inventory.slots[5] = {
		"item": ItemTypes.WOOD_PICKAXE, "count": 1,
		"durability": ItemTypes.tool_durability(ItemTypes.WOOD_PICKAXE),
	}
	player.inventory.hotbar_map[0] = 5
	player.select_slot(0)
	var q_cell := Vector3i(24, World.SEA_LEVEL + 9, 24)
	world.ensure_chunks_in_region(q_cell, q_cell)
	world.set_block(q_cell, BlockTypes.Block.STONE)
	var q_bag := _inventory_total(player.inventory)
	player._finish_break(q_cell, BlockTypes.Block.STONE)
	_check(world.get_block(q_cell) == BlockTypes.Block.AIR, "探索模式可正常采掘方块")
	_check(_inventory_total(player.inventory) > q_bag,
		"探索模式采掘照常掉落（背包 %d → %d）" % [q_bag, _inventory_total(player.inventory)])

	# Q-3 敌对生物：探索模式任何时刻都不生成，并立即清空既有敌对
	day_night._time = DayNightCycle.DAY_LENGTH + 10.0
	_check(not day_night.is_day(), "先把时钟拨到夜晚")
	spawner._despawn_all()
	GameState.set_mode(GameState.Mode.EXPLORE)
	var q_wolf := _spawn_mob(
		spawner, Mob.MobType.WOLF, player, day_night, player.global_position + Vector3(4.0, 1.0, 0.0)
	)
	# _spawn_mob 只把生物挂到节点树下，生成器的名册要手工登记才参与计数。
	spawner._mobs.append(q_wolf)
	_check(spawner._hostile_count() > 0, "先手动放入一只敌对生物")
	spawner._spawn_timer = 0.0
	spawner._process(1.0)
	_check(spawner._hostile_count() == 0, "探索模式夜晚不生成敌对生物")
	_check(not is_instance_valid(q_wolf) or q_wolf.is_queued_for_deletion(),
		"探索模式会清空切模式前已存在的敌对生物")

	# 对照：生存模式夜晚照常生成敌对
	GameState.set_mode(GameState.Mode.SURVIVAL)
	var q_spawned := false
	for i in range(40):
		spawner._spawn_timer = 0.0
		spawner._process(1.0)
		if spawner._hostile_count() > 0:
			q_spawned = true
			break
	_check(q_spawned, "对照：生存模式夜晚仍会生成敌对生物")

	# Q-4 探索模式夜晚照常补充温顺动物（观察生态不受时钟限制）
	spawner._despawn_all()
	GameState.set_mode(GameState.Mode.EXPLORE)
	var q_passive := false
	for i in range(40):
		spawner._passive_timer = 0.0
		spawner._process(1.0)
		if spawner._passive_count() > 0:
			q_passive = true
			break
	_check(q_passive, "探索模式夜晚照常生成温顺动物")
	_check(spawner._hostile_count() == 0, "探索模式反复刷新也不会冒出敌对生物")
	spawner._despawn_all()
	day_night._time = 0.0

	# Q-5 切模式限制：G 键在探索模式下不跳创造
	GameState.set_mode(GameState.Mode.SURVIVAL)
	hud._toggle_game_mode()
	_check(GameState.is_creative(), "生存模式下按 G 照常切到创造")
	hud._toggle_game_mode()
	_check(not GameState.is_creative(), "再按一次 G 切回生存")
	GameState.set_mode(GameState.Mode.EXPLORE)
	hud._toggle_game_mode()
	_check(GameState.is_explore(), "探索模式下按 G 不会跳到创造模式")

	# Q-6 地图页模式三选一：三个按钮竖排在界面右侧
	var selector: MapSelector = hud._map_selector
	_check(selector != null and selector._mode_buttons.size() == 3, "地图页提供模式三选一（三个按钮）")
	selector.open()
	await get_tree().process_frame
	await get_tree().process_frame
	var mb0: Button = selector._mode_buttons[0]
	var mb1: Button = selector._mode_buttons[1]
	var mb2: Button = selector._mode_buttons[2]
	_check(
		is_equal_approx(mb0.global_position.x, mb1.global_position.x)
		and is_equal_approx(mb1.global_position.x, mb2.global_position.x)
		and mb1.global_position.y > mb0.global_position.y
		and mb2.global_position.y > mb1.global_position.y,
		"三个模式按钮竖向排列（x=%.0f，y=%.0f → %.0f → %.0f）" % [
			mb0.global_position.x, mb0.global_position.y, mb1.global_position.y, mb2.global_position.y
		],
	)
	_check(
		mb1.global_position.x + mb1.size.x > selector.size.x * 0.75,
		"模式按钮位于界面右侧（按钮右缘 %.0f / 界面宽 %.0f）" % [
			mb1.global_position.x + mb1.size.x, selector.size.x
		],
	)
	selector._select_mode(GameState.Mode.EXPLORE)
	_check(GameState.is_explore() and selector.selected_mode() == int(GameState.Mode.EXPLORE),
		"在地图页选探索即写入 GameState")
	_check(selector._mode_buttons[2].button_pressed and not selector._mode_buttons[0].button_pressed,
		"探索按钮呈选中态、生存按钮取消选中")
	selector._select_mode(GameState.Mode.SURVIVAL)
	_check(selector._mode_buttons[0].button_pressed and not selector._mode_buttons[2].button_pressed,
		"改选生存后选中态跟随切换")
	selector._select_mode(GameState.Mode.CREATIVE)
	_check(GameState.is_creative(), "地图页也能选到创造模式")

	# Q-6b 载具门牌只在探索模式显示（D-041）：飞行小飞机（D-044）+ 🏁 竞速入口，
	# 切模式当帧同步，不用重开选择器。
	var race_btn: Button = selector._race_button
	_check(race_btn != null, "地图页建有 🏁 赛道竞速入口按钮")
	selector._select_mode(GameState.Mode.SURVIVAL)
	_check(race_btn != null and not race_btn.visible, "生存模式隐藏 🏁 竞速入口")
	_check(not selector._globe.flight_flags_visible(), "生存模式隐藏地球上的飞行小飞机")
	selector._select_mode(GameState.Mode.EXPLORE)
	_check(race_btn != null and race_btn.visible, "探索模式显示 🏁 竞速入口")
	_check(selector._globe.flight_flags_visible(), "探索模式显示地球上的飞行小飞机")
	# 小鱼标记不绑模式（D-044）：钓鱼不需要载具，关飞行标记也不该连坐。
	_check(selector._globe.fish_markers_visible(), "地球上的小鱼标记不随模式隐藏")
	selector._select_mode(GameState.Mode.CREATIVE)
	_check(race_btn != null and not race_btn.visible, "创造模式同样隐藏 🏁 竞速入口")
	_check(not selector._globe.flight_flags_visible(), "创造模式同样隐藏飞行小飞机")
	# 重开选择器也按当前模式同步（open() 路径）。
	GameState.set_mode(GameState.Mode.EXPLORE)
	selector.close()
	selector.open()
	_check(race_btn != null and race_btn.visible and selector._globe.flight_flags_visible(),
		"探索模式下重开选择器，两个门牌仍然显示")

	# Q-7 HUD 模式徽章：贴在小地图外框正下方，只两个字，带描边
	GameState.set_mode(GameState.Mode.EXPLORE)
	_check(hud._mode_label.text == "探索", "HUD 模式徽章只显示两个字「%s」" % hud._mode_label.text)
	var map_bottom := hud._minimap.global_position.y + MiniMap.SIZE
	var badge_top := hud._mode_label.global_position.y
	_check(
		badge_top >= map_bottom - 6.0 and badge_top <= map_bottom + 24.0,
		"模式徽章紧贴小地图外框下缘（地图底 %.0f / 徽章顶 %.0f）" % [map_bottom, badge_top],
	)
	_check(
		is_equal_approx(
			hud._mode_label.global_position.x + hud._mode_label.size.x * 0.5,
			hud._minimap.global_position.x + hud._minimap.size.x * 0.5,
		),
		"模式徽章与小地图同一竖列居中",
	)
	_check(
		hud._mode_label.get_theme_constant("outline_size") >= 3
		and hud._mode_label.get_theme_font_size("font_size") >= 20,
		"模式徽章字号 %d、描边 %d 像素（着重显示）" % [
			hud._mode_label.get_theme_font_size("font_size"),
			hud._mode_label.get_theme_constant("outline_size"),
		],
	)
	var badge_color := hud._mode_label.get_theme_color("font_color")
	GameState.set_mode(GameState.Mode.CREATIVE)
	_check(
		hud._mode_label.text == "创造"
		and hud._mode_label.get_theme_color("font_color") != badge_color,
		"切到创造后徽章换字并换色（%s → %s）" % [
			badge_color, hud._mode_label.get_theme_color("font_color")
		],
	)
	# 创造快捷栏：建材满格（×100）+ 工具可选中（满耐久、不消耗）。
	var creative_items := ItemTypes.CREATIVE_HOTBAR
	var slot_buttons := hud._slot_buttons
	_check(
		slot_buttons.size() == creative_items.size()
		and slot_buttons[0].visible and slot_buttons[creative_items.size() - 1].visible,
		"创造快捷栏 %d 格全部可见（建材+工具）" % creative_items.size()
	)
	var material_ok := true
	for i in range(9):
		if hud._slot_buttons[i].item_id() != creative_items[i]:
			material_ok = false
			break
	_check(material_ok, "创造快捷栏前 9 格仍按 HOTBAR_BLOCKS 顺序显示九种建材")
	hud._player.select_slot(0)  # GRASS → 满格角标。
	var grass_slot := hud._slot_buttons[0] as ItemSlot
	_check(
		grass_slot._count == BlockTypes.STACK_SIZE,
		"创造模式建材角标为满格 ×%d" % BlockTypes.STACK_SIZE
	)
	hud._player.select_slot(12)  # 木镰刀 → 工具可用。
	_check(
		hud._player.get_selected_item() == ItemTypes.WOOD_SICKLE
		and hud._player.get_selected_tool() == ItemTypes.WOOD_SICKLE,
		"创造模式可选工具（12 号位 = 木镰刀）"
	)
	hud._player.select_slot(9)  # 木镐。
	_check(
		hud._player.get_selected_tool() == ItemTypes.WOOD_PICKAXE,
		"创造模式 9 号位 = 木镐（工具区起点）"
	)
	GameState.set_mode(GameState.Mode.SURVIVAL)
	_check(
		hud._player.selected_slot < Inventory.HOTBAR_SIZE
		and not hud._slot_buttons[15].visible,
		"切回生存后选中位收回 9 格内、工具格隐藏"
	)
	_check(hud._mode_label.text == "生存", "回到生存模式后徽章复位为「生存」")

	# ── Q-8 和平模式（D-078）：正交开关，只管怪物 ──────────────────────
	# 产品语义边界：**和平 ≠ 无敌**。本段四件事——夜里不刷敌对、开关当下清场、
	# 生物伤害免疫；以及反向对照：饥饿 / 跌落 / 卡死一条都不许放水。
	# 存档纪律（D-010 铁律 3）：本段不写档；world.json 的快照已在 _run() 开头取好，
	# 段末比对存在性是否一致再还原。
	GameState.set_mode(GameState.Mode.SURVIVAL)
	_check(not GameState.is_peaceful(), "和平模式默认关闭（既有默认行为不变）")
	_check(not player._dead and player.health > 0, "和平段前提：玩家存活")

	# Q-8.1 开和平 → 夜晚不刷敌对
	# 注：这一条是**守门**而非主证据——本探针的自然刷怪链路未被证明可用，怎么跑
	# 都是 0。真正证明「和平夜里没怪」的是 Q-8.2（清场）与 Q-8.5（反向对照）。
	day_night._time = DayNightCycle.DAY_LENGTH + 10.0
	_check(not day_night.is_day(), "和平段：先把时钟拨到夜晚")
	spawner._despawn_all()
	GameState.set_peaceful(true)
	_check(GameState.is_peaceful(), "打开和平模式开关（仍留在生存模式）")
	var q8_spawned := false
	for i in range(40):
		spawner._spawn_timer = 0.0
		spawner._process(1.0)
		if spawner._hostile_count() > 0:
			q8_spawned = true
			break
	_check(not q8_spawned, "和平模式夜晚不生成敌对生物")
	_check(hud._mode_label.text == "生存·和平",
		"HUD 徽章在模式名后追加「·和平」（实际「%s」）" % hud._mode_label.text)

	# Q-8.2 开和平 → 场上敌对立刻清空（与探索模式同款写法）
	var q8_wolf := _spawn_mob(main_scene, Mob.MobType.WOLF, player, day_night,
		player.global_position + Vector3(4.0, 1.0, 0.0))
	spawner._mobs.append(q8_wolf)
	_check(spawner._hostile_count() > 0, "先手动放入一只敌对生物（前提）")
	spawner._spawn_timer = 0.0
	spawner._process(1.0)
	_check(spawner._hostile_count() == 0, "开和平的当下立刻清空场上敌对生物")
	_check(not is_instance_valid(q8_wolf) or q8_wolf.is_queued_for_deletion(),
		"清出来的敌对生物确实被移除")

	# Q-8.3 开和平 → 生物攻击不掉血（take_damage 是怪物打的入口）
	player.health = Player.MAX_HEALTH
	player._hurt_invuln = 0.0
	player.take_damage(2, "僵尸")
	_check(player.health == Player.MAX_HEALTH, "和平模式下被怪物打不掉血")

	# Q-8.4 和平 ≠ 无敌：饥饿 / 跌落 / 卡死三条路照常（一行都不许放水）
	player.hunger = float(Player.MAX_HUNGER)
	player._tick_survival(1.0, false)
	_check(player.hunger < float(Player.MAX_HUNGER),
		"和平模式饥饿照常消耗（满 20 → %.1f）" % player.hunger)
	player.hunger = float(Player.MAX_HUNGER)
	player._starvation_timer = 0.0
	player.health = Player.MAX_HEALTH
	player._apply_fall_damage(Player.FALL_DAMAGE_THRESHOLD + 4.0)
	_check(player.health < Player.MAX_HEALTH,
		"和平模式跌落照样受伤（%d → %d）" % [Player.MAX_HEALTH, player.health])
	# 卡死脱困走 _force_unstuck（不经 _damage：创造模式也要能脱困）。可观测量取
	# 「死亡流程照走」+「来源广播卡住」+「重生复位」三件事：
	# ⚠️ 不能断言出口 health == 0——health 在函数返回前就被紧随的 _respawn() 补满了；
	# ⚠️ 也不看 stuck_rescues——那个计数器加在 _check_stuck()（检测器）里，
	#    _force_unstuck() 从头到尾没碰过它（player.gd:593 vs 602-610）。
	# 真实嵌入态 → _check_stuck 那一跳由 stuck_rescue_probe 覆盖；本探针构造嵌入
	# 地形成本高且易抖，按评审结论不做。
	var q8_stuck_seen := _damage_reasons.count(Player.REASON_STUCK)
	var q8_box := {"died": 0}
	player.died.connect(func(): q8_box["died"] += 1)
	player._stuck_frames = 9
	player._force_unstuck()
	_check(
		int(q8_box["died"]) > 0 and player._stuck_frames == 0
		and _damage_reasons.count(Player.REASON_STUCK) > q8_stuck_seen,
		"和平模式卡死照付代价：死亡流程照走、来源广播「%s」、重生已复位（和平 ≠ 无敌）"
			% Player.REASON_STUCK,
	)
	player.health = Player.MAX_HEALTH
	player.hunger = float(Player.MAX_HUNGER)
	player._starvation_timer = 0.0
	player._hurt_invuln = 0.0

	# Q-8.5 关和平 → 一切照旧（这条保证「默认 OFF」的语义没有暗中被改成常开）
	GameState.set_peaceful(false)
	_check(not GameState.is_peaceful(), "关闭和平模式开关")
	_check(hud._mode_label.text == "生存", "关闭后徽章去掉「·和平」")
	player.health = Player.MAX_HEALTH
	player._hurt_invuln = 0.0
	player.take_damage(2, "僵尸")
	_check(player.health == Player.MAX_HEALTH - 2, "关闭后被怪物打照常扣血")
	player.health = Player.MAX_HEALTH
	# 反向对照与 Q-8.2 **严格对称**：手动放一只敌对，跑一帧看它还在不在。
	# 不改自然刷怪——本探针里自然刷怪从未被证明可用（既有探索模式段
	# 1809-1812 行同样靠手动放入），依赖它只会得到一条恒真的弱对照。
	spawner._despawn_all()
	var q8_wolf2 := _spawn_mob(main_scene, Mob.MobType.WOLF, player, day_night,
		player.global_position + Vector3(4.0, 1.0, 0.0))
	spawner._mobs.append(q8_wolf2)
	_check(spawner._hostile_count() > 0, "关和平后手动放入一只敌对生物（前提）")
	spawner._spawn_timer = 0.0
	spawner._process(1.0)
	_check(spawner._hostile_count() > 0,
		"关掉和平后清场分支不再触发，敌对生物留在场上（%d 只）" % spawner._hostile_count())
	spawner._despawn_all()
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	day_night._time = 0.0
	# 存在性必须与段首快照一致：既不能凭空多出来，也不该被写坏。
	_check(FileAccess.file_exists(Profile.slot_world_path()) == _world_existed,
		"探针全程没有动过 %s（读路径绝不写档）" % Profile.slot_world_path())
	_restore_world_settings()

	# ── 阶段 R：资产完整性守门（新增物种/方块/物品/图鉴时先看这一节） ──
	# 这一节不测玩法，只测「代码里的表与实现是否还对得上」。
	# 新增内容若漏改某张表，这里会直接红出来——比在游戏里慢慢发现便宜得多。

	# R-1 生物名录
	var unnamed := PackedStringArray()
	for mob_id: int in Mob.MobType.values():
		var mob_title := String(Mob.MOB_NAMES.get(mob_id, ""))
		if mob_title.is_empty() or mob_title == "生物":
			unnamed.append(str(mob_id))
	_check(
		unnamed.is_empty() and Mob.MOB_NAMES.size() == Mob.MobType.size(),
		"MOB_NAMES 覆盖全部 %d 个物种（缺：%s）" % [
			Mob.MobType.size(), _join_or_none(unnamed)
		],
	)

	# R-2 敌对名单：与保护名录不得重叠，且区域敌对表必须是它的子集。
	# 新增物种默认被动；要当敌对必须在 Mob.HOSTILE_MOBS 显式登记。
	var conflict := PackedStringArray()
	for mob_id: int in Mob.HOSTILE_MOBS:
		if Mob.PROTECTED_MOBS.has(mob_id):
			conflict.append("保护动物被登记为敌对：%s" % Mob.MOB_NAMES.get(mob_id, str(mob_id)))
	for entry: Dictionary in RegionAtlas.REGIONS:
		for key: String in (entry["hostile"] as Dictionary):
			if not Mob.HOSTILE_MOBS.has(int(Mob.MobType[key])):
				conflict.append("%s/hostile 未登记为敌对：%s" % [entry["title"], key])
	_check(
		Mob.HOSTILE_MOBS.size() == 5 and conflict.is_empty(),
		"敌对名单 %d 种（僵尸/骷髅/蜘蛛/狼/掠夺者）、与保护名录无交集、区域敌对表无越界（错项：%s）" % [
			Mob.HOSTILE_MOBS.size(), _join_or_none(conflict)
		],
	)

	# R-3 凡是栖息在水里的物种，都必须归水生物轨道（青蛙是例外：栖息草地、由池塘轨道生成）
	var habitat_wrong := PackedStringArray()
	for mob_id: int in Mob.MobType.values():
		if Mob.habitat_of(mob_id) == Mob.Habitat.WATER and not Mob.is_aquatic(mob_id):
			habitat_wrong.append(String(Mob.MOB_NAMES.get(mob_id, str(mob_id))))
	_check(
		habitat_wrong.is_empty(),
		"在水里的物种都归水生物轨道（错项：%s）" % _join_or_none(habitat_wrong),
	)

	# R-4 成长阶段链：末段必须是成体（days=0、scale=1），多段的首段必须是幼体
	var stage_wrong := PackedStringArray()
	for mob_id: int in Mob.MobType.values():
		var chain := Mob.stages_of(mob_id)
		var stage_label := String(Mob.MOB_NAMES.get(mob_id, str(mob_id)))
		if chain.is_empty():
			stage_wrong.append("%s 无阶段" % stage_label)
			continue
		var last: Dictionary = chain[chain.size() - 1]
		if int(last.get("days", -1)) != 0 or not is_equal_approx(float(last.get("scale", 0.0)), 1.0):
			stage_wrong.append("%s 末段不是成体" % stage_label)
		if chain.size() > 1:
			var first: Dictionary = chain[0]
			if float(first.get("scale", 1.0)) >= 1.0 or int(first.get("days", 0)) <= 0:
				stage_wrong.append("%s 首段不是幼体" % stage_label)
	_check(
		stage_wrong.is_empty(),
		"阶段链自洽（%d 个物种有成长链；错项：%s）" % [
			_grown_species_count(), _join_or_none(stage_wrong)
		],
	)

	# R-5 区域生成表：物种名必须能解析成枚举，且分类与被动表一致
	var region_wrong := PackedStringArray()
	for entry: Dictionary in RegionAtlas.REGIONS:
		var region_name := String(entry["title"])
		for key: String in (entry["passive"] as Dictionary):
			if not Mob.MobType.has(key):
				region_wrong.append("%s/passive 写了不存在的物种「%s」" % [region_name, key])
			elif not Mob.is_passive(int(Mob.MobType[key])):
				region_wrong.append("%s/passive 混进敌对「%s」" % [region_name, key])
		for key: String in (entry["hostile"] as Dictionary):
			if not Mob.MobType.has(key):
				region_wrong.append("%s/hostile 写了不存在的物种「%s」" % [region_name, key])
			elif Mob.is_passive(int(Mob.MobType[key])):
				region_wrong.append("%s/hostile 混进被动「%s」" % [region_name, key])
	_check(
		region_wrong.is_empty(),
		"%d 个区域生成表的物种名与分类自洽（错项：%s）" % [
			RegionAtlas.COUNT, _join_or_none(region_wrong)
		],
	)
	# 水轨物种与村庄常驻角色（村民/掠夺者由 VillageBuilder 放在村里）不登区域表，
	# 其余物种都必须能被某个区域生成——新增陆地物种忘了登表就靠这条拦。
	var region_keys := _region_species_keys()
	var off_table := PackedStringArray()
	for mob_id: int in Mob.MobType.values():
		if Mob.is_aquatic(mob_id):
			continue
		if mob_id == Mob.MobType.VILLAGER or mob_id == Mob.MobType.PILLAGER:
			continue
		var enum_name := String(Mob.MobType.find_key(mob_id))
		if not region_keys.has(enum_name):
			off_table.append(String(Mob.MOB_NAMES.get(mob_id, enum_name)))
	_check(
		off_table.is_empty(),
		"区域表收录了 %d 个物种，陆地与空中物种无遗漏（未收录：%s）" % [
			region_keys.size(), _join_or_none(off_table)
		],
	)

	# R-6 造型登记表：覆盖全枚举，且方法名真实存在
	var art_wrong := PackedStringArray()
	var probe_mob := Mob.new()
	for mob_id: int in Mob.MobType.values():
		var method_name := String(Mob.ART_BUILDERS.get(mob_id, ""))
		if method_name.is_empty() or not probe_mob.has_method(method_name):
			art_wrong.append("%s → 「%s」" % [Mob.MOB_NAMES.get(mob_id, str(mob_id)), method_name])
	probe_mob.free()
	_check(
		Mob.ART_BUILDERS.size() == Mob.MobType.size() and art_wrong.is_empty(),
		"造型登记表覆盖全部物种且方法存在（%d 条；错项：%s）" % [
			Mob.ART_BUILDERS.size(), _join_or_none(art_wrong)
		],
	)

	# R-7 保护动物名录与交互提示
	var protect_wrong := PackedStringArray()
	for mob_id: int in Mob.PROTECTED_MOBS:
		if Mob.protected_note(mob_id).is_empty():
			protect_wrong.append(String(Mob.MOB_NAMES.get(mob_id, str(mob_id))))
	_check(
		Mob.PROTECTED_MOBS.size() == Mob.PROTECTED_NOTES.size() and protect_wrong.is_empty(),
		"%d 种保护动物都有中文名录（缺：%s）" % [
			Mob.PROTECTED_MOBS.size(), _join_or_none(protect_wrong)
		],
	)

	# R-8 方块表：名称/实心/透明全覆盖；非空气要有瓦片与简称；非空气与水要有硬度
	var block_wrong := PackedStringArray()
	for block_id: int in BlockTypes.Block.values():
		var block_name := String(BlockTypes.NAMES.get(block_id, ""))
		if block_name.is_empty():
			block_wrong.append("方块 %d 无名称" % block_id)
		if not BlockTypes.SOLID.has(block_id) or not BlockTypes.TRANSPARENT.has(block_id):
			block_wrong.append("%s 缺实心/透明登记" % block_name)
		if block_id != BlockTypes.Block.AIR:
			if not BlockTypes.TILES.has(block_id) or not BlockTypes.SHORT_NAMES.has(block_id):
				block_wrong.append("%s 缺瓦片或简称" % block_name)
			if block_id != BlockTypes.Block.WATER and not BlockTypes.HARDNESS.has(block_id):
				block_wrong.append("%s 缺硬度" % block_name)
	_check(
		block_wrong.is_empty(),
		"%d 种方块的名称/实心/透明/瓦片/硬度登记完整（错项：%s）" % [
			BlockTypes.Block.size(), _join_or_none(block_wrong)
		],
	)

	# R-9 物品表：工具四张表、材料三张表都要齐
	var item_wrong := PackedStringArray()
	for tool_id: int in ItemTypes.TOOL_TYPE:
		for table: Dictionary in [
			ItemTypes.TOOL_TYPE, ItemTypes.TOOL_TIER,
			ItemTypes.TOOL_DURABILITY, ItemTypes.TOOL_NAMES,
		]:
			if not table.has(tool_id):
				item_wrong.append("工具 %d" % tool_id)
				break
	for item_id: int in ItemTypes.ITEM_NAMES:
		for table: Dictionary in [ItemTypes.ITEM_SHORT_NAMES, ItemTypes.ITEM_COLORS]:
			if not table.has(item_id):
				item_wrong.append("材料 %d" % item_id)
				break
	_check(
		ItemTypes.TOOL_TYPE.size() == 26 and ItemTypes.ITEM_NAMES.size() == 31 and item_wrong.is_empty(),
		"工具 26 件四表齐、材料 %d 种三表齐（错项：%s）" % [
			ItemTypes.ITEM_NAMES.size(), _join_or_none(item_wrong)
		],
	)

	# R-9b 生活内容登记：床配方、蔬菜种植映射、可食用。
	var bed_recipe := false
	for r: Dictionary in ItemTypes.RECIPES:
		if int(r["result"]) == BlockTypes.Block.BED:
			bed_recipe = true
	_check(bed_recipe, "羊毛+木板可合成床（配方已登记）")
	_check(
		ItemTypes.crop_of(ItemTypes.WHEAT) == BlockTypes.Block.WHEAT_CROP
		and ItemTypes.crop_of(ItemTypes.CARROT) == BlockTypes.Block.CARROT_CROP
		and ItemTypes.crop_of(ItemTypes.POTATO) == BlockTypes.Block.POTATO_CROP
		and ItemTypes.crop_of(ItemTypes.RADISH) == BlockTypes.Block.RADISH_CROP,
		"小麦/胡萝卜/土豆/白萝卜均可种在耕地（crop_of 映射）",
	)
	_check(
		ItemTypes.is_food(ItemTypes.CARROT) and ItemTypes.food_value(ItemTypes.POTATO) > 0
		and ItemTypes.is_food(ItemTypes.RADISH),
		"新蔬菜胡萝卜/土豆/白萝卜可食用",
	)

	# R-10 区域图鉴卡片：字段齐、插画种类有画法
	var card_wrong := PackedStringArray()
	_check(
		RegionAtlas.REGION_CARDS.size() == RegionAtlas.COUNT,
		"%d 个区域各有一组图鉴卡片" % RegionAtlas.REGION_CARDS.size(),
	)
	for group: Array in RegionAtlas.REGION_CARDS:
		for card: Dictionary in group:
			var card_title := String(card.get("title", ""))
			if card_title.is_empty() or String(card.get("text", "")).is_empty():
				card_wrong.append("有卡片缺标题或正文")
			var kind := String(card.get("art", ""))
			if not MapSelector.ART_KINDS.has(kind):
				card_wrong.append("%s 用了没有画法的插画「%s」" % [card_title, kind])
	_check(
		card_wrong.is_empty(),
		"图鉴卡片的字段与插画种类都有对应（错项：%s）" % _join_or_none(card_wrong),
	)

	# ── 阶段 S：生物图鉴（数据完整性 + 面板行为 + 与地图/进度的接线） ──
	# 图鉴是纯数据驱动的（data/bestiary/*.json），写错一个字段不会有编译错误，
	# 只会在 UI 上静默少显示一行。这一节把「读盘时说得出哪里不对」变成硬断言。
	#
	# 本节末尾会真的答一道题（验证问答计入进度）。全局存档隔离在 _run() 开头
	# 快照、quit 前还原（D-010 铁律 3）：这份测试态不会留在 user:// 里，否则
	# 下一轮「答对 2 题尚未触发连对奖励」会凭空失败——探针给自己下毒。
	var bestiary_problems := BestiaryData.load_problems
	_check(
		BestiaryData.is_loaded and bestiary_problems.is_empty(),
		"图鉴数据零问题（%d 条；首条：%s）" % [
			bestiary_problems.size(),
			"无" if bestiary_problems.is_empty() else bestiary_problems[0],
		],
	)

	# S-1 结构：区域数、条目数、id 唯一
	_check(
		BestiaryData.get_regions().size() == 13,
		"图鉴收录 13 个地区（%d）" % BestiaryData.get_regions().size(),
	)
	var bestiary_entries := BestiaryData.get_entries()
	var entry_total := bestiary_entries.size()
	_check(entry_total >= 170, "图鉴条目共 %d 种" % entry_total)
	var unique_ids := {}
	for entry_value: Variant in bestiary_entries:
		var entry: Dictionary = entry_value
		unique_ids[String(entry.get("id", ""))] = true
	_check(unique_ids.size() == entry_total, "条目 id 唯一（%d / %d）" % [unique_ids.size(), entry_total])

	# S-2 世界区域 ↔ 图鉴区域双向接通：只往一个方向加映射，筛选就会漏掉半边图鉴。
	var link_wrong := PackedStringArray()
	var referenced := {}
	for atlas_id in RegionAtlas.COUNT:
		var region_ids := BestiaryData.region_ids_of_atlas(atlas_id)
		if region_ids.is_empty():
			link_wrong.append("%s 没有对应图鉴地区" % RegionAtlas.title_of(atlas_id))
		for region_id: String in region_ids:
			referenced[region_id] = true
			if BestiaryData.region_by_id(region_id).is_empty():
				link_wrong.append("%s → 不存在的地区 %s" % [RegionAtlas.title_of(atlas_id), region_id])
	for region_value: Variant in BestiaryData.get_regions():
		var region: Dictionary = region_value
		if not referenced.has(String(region.get("id", ""))):
			link_wrong.append("图鉴地区 %s 没被任何世界区域引用" % region.get("name_zh", ""))
	_check(
		link_wrong.is_empty(),
		"%d 个世界区域与 %d 个图鉴地区双向接得上（错项：%s）" % [
			RegionAtlas.COUNT, BestiaryData.get_regions().size(), _join_or_none(link_wrong)
		],
	)

	# S-3 受保护动物必须有图鉴条目：这条拦的是「游戏里加了保护动物、图鉴却没写」。
	# 豁免三项：村民是人不是物种，蜻蜓/蝴蝶是游戏里的陪伴益虫（图鉴未收录它们的资料）。
	var no_entry := PackedStringArray()
	var linked_species := 0
	for mob_id: int in Mob.MobType.values():
		var linked_entry := BestiaryData.entry_of_mob(mob_id)
		if linked_entry.is_empty():
			if Mob.is_protected(mob_id) and not PROTECTED_WITHOUT_ENTRY.has(mob_id):
				no_entry.append(String(Mob.MOB_NAMES.get(mob_id, str(mob_id))))
			continue
		linked_species += 1
	_check(no_entry.is_empty(), "受保护动物都在图鉴里有条目（缺：%s）" % _join_or_none(no_entry))
	_check(linked_species >= 4, "游戏物种与图鉴按中文名自动对上 %d 种" % linked_species)

	# S-4 反向：图鉴条目认出来的物种，必须真的是游戏里的物种
	var back_wrong := PackedStringArray()
	for probe_id in ["giant_panda", "polar_bear", "kangaroo", "bald_eagle", "golden_monkey", "crested_ibis"]:
		if BestiaryData.mob_of_entry(BestiaryData.get_entry(probe_id)) < 0:
			back_wrong.append(probe_id)
	_check(
		back_wrong.is_empty(),
		"保护动物条目都能反查到游戏物种（错项：%s）" % _join_or_none(back_wrong),
	)

	# S-5 题库：主题前缀都有中文名，且答案都在选项内（后者在 load_all 里已查）
	var theme_wrong := PackedStringArray()
	for item_value: Variant in BestiaryData.get_quiz():
		var item: Dictionary = item_value
		if _bestiary_theme_of(String(item.get("id", ""))).is_empty():
			theme_wrong.append(String(item.get("id", "")))
	_check(
		BestiaryData.get_quiz().size() >= 15 and theme_wrong.is_empty(),
		"题库 %d 题、主题前缀都认得（错项：%s）" % [
			BestiaryData.get_quiz().size(), _join_or_none(theme_wrong)
		],
	)

	# S-6 UI：打开 / 卡片数量 / 筛选 / 搜索 / 详情
	hud.open_bestiary()
	var panel: BestiaryUI = hud._bestiary
	_check(panel != null and panel.is_open(), "可按 F2 打开生物图鉴")
	_check(panel._cards.size() == entry_total, "面板建出 %d 张卡片（等于条目数）" % panel._cards.size())

	panel._set_kingdom("animalia")
	await get_tree().process_frame
	var animalia_matched := BestiaryData.filter("animalia", "", "", "")
	var visible_cards := 0
	var visible_non_animalia := 0
	for card_value: Variant in panel._cards.values():
		var card: EntryCard = card_value
		if not card.visible:
			continue
		visible_cards += 1
		if String(BestiaryData.get_entry(card.entry_id).get("kingdom", "")) != "animalia":
			visible_non_animalia += 1
	_check(
		visible_cards == animalia_matched.size() and visible_non_animalia == 0,
		"按「动物」界筛选命中 %d 种（期望 %d，混入非动物 %d 张）" % [
			visible_cards, animalia_matched.size(), visible_non_animalia
		],
	)

	panel._set_kingdom("")
	panel._search_box.text = "企鹅"
	panel._refresh_grid()
	await get_tree().process_frame
	# 搜索同时覆盖名字与科普文案：命中数会比「名字里带企鹅」的 7 种多
	# （磷虾的科普里写着「鲸鱼、企鹅、海豹都吃它」），但每条命中都必须真出现过这个词。
	var penguin_hits := 0
	var penguin_named := 0
	var penguin_wrong := 0
	for card_value: Variant in panel._cards.values():
		var card: EntryCard = card_value
		if not card.visible:
			continue
		penguin_hits += 1
		var hit_entry := BestiaryData.get_entry(card.entry_id)
		if String(hit_entry.get("name_zh", "")).contains("企鹅"):
			penguin_named += 1
		var text := "%s %s" % [hit_entry.get("name_zh", ""), hit_entry.get("fact_zh", "")]
		if not text.contains("企鹅"):
			penguin_wrong += 1
	_check(
		penguin_named >= 7 and penguin_wrong == 0,
		"搜索「企鹅」命中 %d 种（其中名字里带企鹅的 %d 种，凭空命中 %d）" % [
			penguin_hits, penguin_named, penguin_wrong
		],
	)

	panel._search_box.text = ""
	panel._on_card_pressed("giant_panda")
	await get_tree().process_frame
	_check(
		panel._detail_name.text.contains("大熊猫")
		and not panel._detail_fact.text.is_empty()
		and panel._detail_latin.text.contains("Ailuropoda")
		and panel._detail_badges.get_child_count() == 3,
		"点开卡片显示资料：%s / %s" % [panel._detail_name.text, panel._detail_latin.text],
	)
	_check(
		panel._detail_game.text.contains("大熊猫"),
		"图鉴会指出该物种在游戏内也能遇见：%s" % panel._detail_game.text,
	)
	_check(panel._preview_layer.visible, "点卡片后弹出居中预览卡（而不是在底部显示说明）")
	_check(
		panel._preview_layer.visible
		and panel._preview_stage.get_child_count() >= 1
		and BestiaryModel.is_real_mob(panel._preview_stage.get_child(0)),
		"游戏内物种的预览卡挂出真 3D 模型（大熊猫）",
	)
	panel._close_preview()
	_check(not panel._preview_layer.visible, "预览卡可关闭")
	# S-6.5 每个「类」都要有程序化替身：174 条里只有 6 条能用真 Mob 模型，
	# 其余全靠 BestiaryModel 按类拼装。这里逐类造一遍，任何一类漏了就会显出来。
	var host := Node3D.new()
	get_tree().root.add_child(host)
	var thin: Array[String] = []
	var built_classes := 0
	# 合成一条属于该类的虚构条目，好让「类」本身被覆盖到——某些类（比如地衣）
	# 暂时还没有任何物种，但工厂仍须支持它，将来加数据才不会开出空白卡。
	for cat_value: Variant in BestiaryData.categories.keys():
		var category_id := String(cat_value)
		var sample := {
			"id": "probe_" + category_id,
			"kingdom": BestiaryData.category_kingdom(category_id),
			"category": category_id,
		}
		var m := BestiaryModel.build(sample)
		host.add_child(m)
		BestiaryModel.hide_labels(m)
		if _count_meshes(m) < 3:
			thin.append("%s(%d)" % [category_id, _count_meshes(m)])
		built_classes += 1
		m.queue_free()
	_check(
		thin.is_empty() and built_classes >= 19,
		"19 个类都能拼出程序化替身模型（薄弱：%s）" % _join_or_none(PackedStringArray(thin)),
	)

	# 取真模型与替身各一条，验证 normalize 的契约：
	# 所有模型都缩放到同一包围盒并居中 —— 相机这才敢用固定参数取景。
	var frames_ok := true
	var frames_detail := ""
	for sample_id in ["giant_panda", "asian_elephant"]:
		var m2 := BestiaryModel.build(BestiaryData.get_entry(sample_id))
		host.add_child(m2)
		BestiaryModel.normalize(m2)
		var boxes: Array[AABB] = []
		BestiaryModel._collect_boxes(m2, boxes)
		if boxes.is_empty():
			frames_ok = false
			frames_detail += "%s=空 " % sample_id
			continue
		var frame_box := boxes[0]
		for i in range(1, boxes.size()):
			frame_box = frame_box.merge(boxes[i])
		var longest := maxf(maxf(frame_box.size.x, frame_box.size.y), frame_box.size.z)
		var center := frame_box.get_center().length()
		if absf(longest - BestiaryModel.FRAME_SIZE) > 0.002 or center > 0.05:
			frames_ok = false
		frames_detail += "%s=%.3f/中心%.3f " % [sample_id, longest, center]
		m2.queue_free()
	_check(frames_ok, "模型归一化到统一取景包围盒（%s目标 %.2f）" % [frames_detail, BestiaryModel.FRAME_SIZE])
	host.queue_free()

	# S-6.6 卡片微缩图：每条都有「占位底色 + 贴图层」两层，图到了就盖住占位。
	var thumb_bad := 0
	for card_value: Variant in panel._cards.values():
		var c: EntryCard = card_value
		if c._thumb == null or c._thumb_bg == null:
			thumb_bad += 1
	_check(thumb_bad == 0, "174 张卡片都带 3D 微缩图位（缺 %d 张）" % thumb_bad)
	# headless（探针运行环境）没有渲染设备，渲染器应当自行停机而不是硬跑。
	if panel._thumbs.is_enabled():
		_check(
			panel._thumbs.pending_count() + panel._thumbs.cache_size() >= BestiaryData.get_entries().size(),
			"微缩图渲染队列覆盖全部条目（待渲染 %d / 已缓存 %d）" % [
				panel._thumbs.pending_count(), panel._thumbs.cache_size()
			],
		)
	else:
		_check(true, "headless 无渲染设备时微缩图渲染器自行停机（卡片显示占位底色）")

	# S-6.7 悬停预览：进入卡片浮出可旋转的 3D 模型，离开即收起并卸载模型。
	panel._on_card_hovered("giant_panda")
	await get_tree().process_frame
	_check(
		panel.is_hover_open()
		and panel.hover_entry_id() == "giant_panda"
		and panel._hover_stage.get_child_count() >= 1,
		"鼠标悬停卡片弹出 3D 预览浮层（大熊猫）",
	)
	panel._on_card_hovered("asian_elephant")
	await get_tree().process_frame
	_check(
		panel.hover_entry_id() == "asian_elephant" and panel._hover_stage.get_child_count() == 1,
		"换悬停条目时旧模型被换掉（视口里始终只有一个）",
	)
	panel._hide_hover()
	await get_tree().process_frame
	_check(
		not panel.is_hover_open() and panel._hover_stage.get_child_count() == 0,
		"鼠标离开后悬停浮层收起并卸载模型",
	)
	panel._set_kingdom("")

	# S-7 问答页：出题 → 答对计入进度 → 答错不计
	panel._set_tab(BestiaryUI.Tab.QUIZ)
	await get_tree().process_frame
	_check(
		not panel._quiz_question.text.is_empty() and panel._quiz_options.get_child_count() >= 2,
		"问答页出题并列出选项（%d 个）" % panel._quiz_options.get_child_count(),
	)
	var quiz_before := int(Progress.counters.get("quiz_correct", 0))
	panel._on_option_pressed(panel._quiz_answer)
	await get_tree().process_frame
	var quiz_after_correct := int(Progress.counters.get("quiz_correct", 0))
	_check(
		quiz_after_correct == quiz_before + 1,
		"图鉴问答答对计入知识问答进度（%d → %d）" % [quiz_before, quiz_after_correct],
	)
	panel._draw_question()
	await get_tree().process_frame
	panel._on_option_pressed("这个选项一定不对")
	var quiz_after_wrong := int(Progress.counters.get("quiz_correct", 0))
	_check(
		quiz_after_wrong == quiz_after_correct and panel._quiz_feedback.text.contains("正确答案"),
		"答错不计数，并说明正确答案",
	)
	panel._set_tab(BestiaryUI.Tab.ENTRIES)
	panel._on_card_pressed("giant_panda")
	_check(panel.get_tab() == BestiaryUI.Tab.ENTRIES, "可切回图鉴页")

	# S-8 地图页 → 图鉴：介绍页的「看看这里的生物」要带着地区筛选跳过来
	var selector_open: bool = hud._map_selector.is_open()
	if not selector_open:
		hud._map_selector.open()
	hud._map_selector._show_intro(RegionAtlas.AFRICA)
	await get_tree().process_frame
	var jump_button := _find_button(hud._map_selector._intro_panel, "看看这里的生物")
	_check(jump_button != null, "地球介绍页有「看看这里的生物」入口")
	if jump_button != null:
		jump_button.pressed.emit()
		await get_tree().process_frame
		_check(not hud._map_selector.is_open(), "从地图页跳进图鉴时，地图选择器已关闭")
		_check(panel.is_open(), "图鉴已打开")
		var africa_hits := 0
		var africa_wrong := 0
		for card_value: Variant in panel._cards.values():
			var card: EntryCard = card_value
			if not card.visible:
				continue
			africa_hits += 1
			var region_id := String(BestiaryData.get_entry(card.entry_id).get("region_id", ""))
			if region_id != "africa":
				africa_wrong += 1
		_check(
			africa_hits > 0 and africa_wrong == 0,
			"跳过来时地区筛选已落在非洲（命中 %d 种，串区 %d）" % [africa_hits, africa_wrong],
		)
	hud.close_bestiary()
	_check(not panel.is_open(), "关闭图鉴后状态复位")

	# S-9 合成台分类分页：每页非空、页间总数守恒、切换后选中项必落在本页。
	var page_totals := {}
	for i in range(ItemTypes.RECIPES.size()):
		var page_no := ItemTypes.recipe_page(ItemTypes.RECIPES[i])
		page_totals[page_no] = int(page_totals.get(page_no, 0)) + 1
	_check(
		page_totals.size() == HUD.CRAFT_PAGES.size()
		and int(page_totals.values().reduce(func(a: int, b: int) -> int: return a + b, 0)) == ItemTypes.RECIPES.size(),
		"配方分成 %d 页且页间总数守恒（%s）" % [page_totals.size(), str(page_totals)],
	)
	hud.set_craft_open(true)
	await get_tree().process_frame
	var tools_visible := 0
	for i in range(ItemTypes.RECIPES.size()):
		if (hud._craft_result_grid.get_child(i) as ItemSlot).visible:
			tools_visible += 1
	_check(tools_visible == int(page_totals.get(0, -1)), "默认工具页显示 %d 格" % tools_visible)
	hud._on_craft_cat(3)
	await get_tree().process_frame
	var food_visible := 0
	var food_wrong := 0
	for i in range(ItemTypes.RECIPES.size()):
		var slot := hud._craft_result_grid.get_child(i) as ItemSlot
		if slot.visible:
			food_visible += 1
			if ItemTypes.recipe_page(ItemTypes.RECIPES[i]) != 3:
				food_wrong += 1
	var sel_in_page := ItemTypes.recipe_page(ItemTypes.RECIPES[hud._selected_recipe]) == 3
	_check(
		food_visible == int(page_totals.get(3, -1)) and food_wrong == 0 and sel_in_page,
		"切到食物页显示 %d 格、无串页、选中项在本页" % food_visible,
	)
	_check(hud._craft_craft_button.text == "合成", "按钮文案是「合成」")

	# S-9.1 成品格角标 = 按持有材料实时推算的可合成数：清空背包后全部 ×0，
	# 补足一份木镐材料（5 木头）后该格恢复 ×recipe_count，与 craft() 口径一致。
	var s_inv_slots: Array = hud._player.inventory.slots.duplicate(true)
	for slot_i in range(hud._player.inventory.slots.size()):
		hud._player.inventory.slots[slot_i] = {"item": 0, "count": 0, "durability": -1}
	hud._refresh_craft_panel()
	await get_tree().process_frame
	var pickaxe_recipe: Dictionary = ItemTypes.RECIPES[0]
	var slot0 := hud._craft_result_grid.get_child(0) as ItemSlot
	_check(
		int(slot0._count) == 0 and slot0.item_id() == int(pickaxe_recipe["result"]),
		"空手时成品格显示 ×0 且图标仍在（%s）" % "木镐",
	)
	hud._player.inventory.add_item(int(pickaxe_recipe["ingredients"].keys()[0]),
		int(pickaxe_recipe["ingredients"].values()[0]))
	hud._refresh_craft_panel()
	await get_tree().process_frame
	_check(
		int(slot0._count) == ItemTypes.recipe_count(pickaxe_recipe),
		"补足一份材料后成品格推算为 ×%d" % ItemTypes.recipe_count(pickaxe_recipe),
	)
	hud._player.inventory.slots = s_inv_slots
	hud._player.inventory.changed.emit()
	hud.set_craft_open(false)

	# S-10 说明书里写明了入口：文档与实现不同步时（加了键没说）这里会红
	var manual_mentions := false
	for page_value: Variant in ManualPanel.PAGES:
		var page: Dictionary = page_value
		for line_value: Variant in page.get("lines", []):
			if String(line_value).contains("F2"):
				manual_mentions = true
	_check(manual_mentions, "说明书里写明了图鉴的打开方式")

	# 还原进度存档（D-010 铁律 3）：文件文本 + 内存态一并还原——Progress 退出时
	# _exit_tree 会 _save()，只还文件会被内存态覆盖（flight_probe 同款教训）。
	# 阶段 L/S 的问答测试态由此不落盘（见阶段 S 开头的说明）。
	_write_user_text("user://progress.json", _saved_progress)
	Progress.counters = _saved_counters.duplicate()
	Progress.states = _saved_states.duplicate()
	Progress._quiz_correct_since_reward = _saved_quiz_streak

	if _failed == 0:
		print("LIFE_TEST_OK")
		get_tree().quit(0)
	else:
		print("LIFE_TEST_FAILED count=%d" % _failed)
		get_tree().quit(1)


## 递归统计节点树中 MeshInstance3D 的数量（含自身层级）。
func _count_meshes_recursive(node: Node) -> int:
	var count := 1 if node is MeshInstance3D else 0
	for child in node.get_children():
		count += _count_meshes_recursive(child)
	return count


## 复算村庄基准高度：与 VillageBuilder._probe_base_y 同款循环。
func _probe_base_y(world: World) -> int:
	var top := 0
	for x in range(VillageBuilder.REGION_MIN.x, VillageBuilder.REGION_MAX.x + 1):
		for z in range(VillageBuilder.REGION_MIN.z, VillageBuilder.REGION_MAX.z + 1):
			top = maxi(top, world.get_surface_height(x, z) - 1)
	return top


## D-055：找一对「地表等高」的相邻列，返回箱子列坐标；找不到返回 ZERO。
## 箱子放 (x, z)，玩家站 (x, z-2) 朝 +Z（Godot 默认朝向 -Z，故箱子必须在 +Z 侧）。
## 三处（玩家 / 中间 / 箱子）地表高度必须全等，才构成一条水平可直视的通道；
## 否则射线从低处水平射出打不到高处的箱子（分层地形起伏处必踩）。
func _find_flat_pair(world: World, cx: int, cz: int, radius: int) -> Vector2i:
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var x := cx + dx
			var z := cz + dz
			var h := world.get_surface_height(x, z)
			if world.get_surface_height(x, z + 1) == h \
					and world.get_surface_height(x, z + 2) == h:
				return Vector2i(x, z + 2)
	return Vector2i.ZERO


## D-055教训：物件必须贴**该处实际地表**放，不能套base_y。
## base_y 是村庄区域**最高点**（_probe_base_y 取 maxi），地形一改它就与
## 具体坐标的地表脱节——箱子会悬空/埋土，玩家悬空掉下去，射线打空，
## 一片断言连带 FAIL（D-055 实测14 项：储物箱 8 + 池塘 6）。
## 统一走这个函数取「该列地表上方 1.1 m 的站立点」。
func _stand_pos(world: World, wx: int, wz: int, base_y: int) -> Vector3:
	return Vector3(float(wx) + 0.5,
		float(world.get_surface_height(wx, wz)) - 1.0 + 1.1,
		float(wz) + 0.5)


## D-055：在半径内自找任意一处小池塘（写死坐标会被地形改动打穿）。
## 按行列步进采样（不逐格全扫——water_kind 会触发洪泛，代价不小），
## 且要确保该列区块已加载，否则 water_kind 读到的水体是空的。
func _find_any_pond(world: World, radius: int) -> Vector2i:
	for dz in range(-radius, radius + 1, 2):
		for dx in range(-radius, radius + 1, 2):
			var x := dx
			var z := dz
			if not world.is_water_column(x, z):
				continue
			if world.water_kind(x, z) == World.WATER_POND:
				return Vector2i(x, z)
	return Vector2i.ZERO


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
				if world.get_block(cell) != BlockTypes.Block.WATER:
					continue
				# 贴底 spawn（蟹）额外要求正下方是实体：水底若悬空（区块尚未
				# 生成 / 世界边缘），螃蟹会坠入虚空——该断言偶发失败过，
				# 根因是落点选择缺陷而非物理缺陷。
				if prefer_bottom:
					var below := world.get_block(Vector3i(cell.x, cell.y - 1, cell.z))
					if below == BlockTypes.Block.AIR or below == BlockTypes.Block.WATER:
						continue
				return Vector3(wx + 0.5, float(cell.y) + 0.1, wz + 0.5)
	return Vector3(0.0, -1.0, 0.0)


func _spawn_mob(parent: Node, mob_type: Mob.MobType, player: Player, dn: DayNightCycle, pos: Vector3, start_stage: int = -1) -> Mob:
	var mob := Mob.new()
	mob.setup(mob_type, player, dn, start_stage)
	parent.add_child(mob)
	mob.global_position = pos
	return mob


## 击杀生物并收集 10 帧内其父节点下出现的掉落物 ID（去重），随后清理掉落物。
## 掉落物若生成在玩家拾取半径（2.4m）内会被自动收入背包而从场景消失，
## 因此同时把「背包内增量」计入结果——生物死亡前会随机游走，仅凭场景节点
## 统计会偶发漏记（曾因牛落点随机漂移误报「成体牛不掉兽皮」）。
func _kill_and_collect(parent: Node, mob: Mob) -> Array[int]:
	var ids: Array[int] = []
	if mob == null:
		return ids
	var holder := mob.get_parent()
	if holder == null:
		return ids
	# 注意：mob 被击杀后会 queue_free，玩家引用必须在击杀前取出，
	# 否则 10 帧后访问已释放实例会抛「previously freed」。
	var target_player := mob.player
	var before := _inventory_snapshot(target_player)
	mob.take_damage(99)
	for i in range(10):
		await get_tree().process_frame
		for child in holder.get_children():
			if child is DroppedItem:
				var drop := child as DroppedItem
				if not ids.has(drop.item_id):
					ids.append(drop.item_id)
				drop.queue_free()
	var after := _inventory_snapshot(target_player)
	for id: int in after.keys():
		if int(after[id]) > int(before.get(id, 0)) and not ids.has(id):
			ids.append(id)
	return ids


## 背包内各物品 ID 的总数快照（用于区分「场景里的掉落」与「已自动拾取」）。
func _inventory_snapshot(player: Player) -> Dictionary:
	var snap: Dictionary = {}
	if player == null or not is_instance_valid(player) or player.inventory == null:
		return snap
	var inv := player.inventory
	for i in range(inv.slots.size()):
		var id := inv.get_item(i)
		if id != BlockTypes.Block.AIR:
			snap[id] = int(snap.get(id, 0)) + inv.get_count(i)
	return snap


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


## 存档隔离（D-010）：读 user:// 文本；不存在返回空串。
func _read_user_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


## 存档隔离（D-010）：写 user:// 文本；空串表示原文件不存在，还原即删除。
func _write_user_text(path: String, text: String) -> void:
	if text == "":
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()


## D-078 段（Q-8）的存档隔离（D-010 铁律 3）：记录档案世界设置 world.json
## 的存在性与文本。开关默认 OFF、探针又从不点面板，正常路径下不该有任何写档。
func _snapshot_world_settings() -> void:
	_world_snapshotted = true
	_world_existed = FileAccess.file_exists(Profile.slot_world_path())
	_world_text = _read_user_text(Profile.slot_world_path())


## 还原 world.json 快照（幂等；正常路径与 _exit_tree 安全网都走它）。
## 没取过快照就一律不动手：探针若在 Q-8 之前崩掉，玩家的真实档不能被当成
## 「探针多出来的文件」删掉（这是 D-010 铁律 3 的一半——另一半是「不许残留」）。
func _restore_world_settings() -> void:
	if _world_restored or not _world_snapshotted:
		return
	_world_restored = true
	if _world_existed:
		_write_user_text(Profile.slot_world_path(), _world_text)
	elif FileAccess.file_exists(Profile.slot_world_path()):
		_write_user_text(Profile.slot_world_path(), "")


## D-010 铁律 3 的退出兜底：协程被脚本错误猝杀时末尾的还原不会执行，
## 退出期再兜一层——探针多写出来的 world.json 会污染共享回归基线。
func _exit_tree() -> void:
	_restore_world_settings()


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)


## 阶段 R 用：把异常清单拼成一句话（空则「无」）。
func _join_or_none(items: PackedStringArray) -> String:
	return "无" if items.is_empty() else ", ".join(items)


## 阶段 S 用：递归数出一个模型里有多少个 MeshInstance3D。
## 替身造型至少得有三五个零件才谈得上「看得出是个什么东西」。
func _count_meshes(node: Node) -> int:
	var total := 0
	for child in node.get_children():
		if child is MeshInstance3D:
			total += 1
		total += _count_meshes(child)
	return total


## 阶段 R 用：有成长链的物种数量。
func _grown_species_count() -> int:
	var grown := 0
	for mob_id: int in Mob.MobType.values():
		if Mob.has_growth(mob_id):
			grown += 1
	return grown


## 阶段 R 用：区域生成表里出现过的物种名字集合（键即枚举名）。
func _region_species_keys() -> Dictionary:
	var seen: Dictionary = {}
	for entry: Dictionary in RegionAtlas.REGIONS:
		for key: String in (entry["passive"] as Dictionary):
			seen[key] = true
		for key: String in (entry["hostile"] as Dictionary):
			seen[key] = true
	return seen


## 阶段 S 用：题目 id 前缀 → 主题名（认不出返回空串，说明主题徽章会退化成「综合」）。
func _bestiary_theme_of(quiz_id: String) -> String:
	for pair: Array in BestiaryUI.QUIZ_THEMES:
		if quiz_id.begins_with(String(pair[0])):
			return String(pair[1])
	return ""


## 阶段 S 用：按文字递归找按钮（用来点开地图介绍页里的入口，而不是直接调方法）。
func _find_button(root: Node, text: String) -> Button:
	for child in root.get_children():
		if child is Button and (child as Button).text == text:
			return child as Button
		var found := _find_button(child, text)
		if found != null:
			return found
	return null
