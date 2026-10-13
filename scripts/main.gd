extends Node3D
## 主场景装配：按 GameState 选定的区域生成世界，并驱动地图选择器。
##
## 区域切换走「重载主场景」这一条路径：GameState（Autoload）存活并把区域 ID
## 带给新场景实例，区块、村庄、生物、HUD 全部随场景重建，无需手工清理世界
## 状态，也就不会残留旧区域的方块改动与储物箱内容。

@onready var _player: Player = $Player
@onready var _hud: HUD = $UI
@onready var _light: DirectionalLight3D = $DirectionalLight3D
@onready var _world: World = $World
@onready var _day_night: DayNightCycle = $DayNightCycle
@onready var _mob_spawner: MobSpawner = $MobSpawner
@onready var _env: Environment = ($WorldEnvironment as WorldEnvironment).environment
var _build_screen: BuildScreen


func _ready() -> void:
	InputActions.register()

	# 区域参数必须先于世界生成落地：World._ready 用默认区域初始化了噪声，
	# 这里按 GameState 的当前区域覆盖种子、地形起伏与地表材质。
	var profile := RegionAtlas.profile(GameState.current_region)
	_world.set_region(GameState.current_region)
	_day_night.setup(_light)
	_day_night.setup_environment(_env)
	_day_night.set_sky_tint(profile["sky"])

	# 切换区域时随身携带背包，避免换图丢光家当。
	if GameState.carried_inventory != null:
		_player.inventory = GameState.carried_inventory
		GameState.carried_inventory = null

	# 探索模式开局送一架飞机：该模式的主题就是「自由观察世界」，
	# 飞行是第一玩法而非要先凑齐铁锭的附属品。每局只送一次
	# （GameState 里的一次性标记），换图/重载不重复发。
	if GameState.is_explore() and GameState.claim_explore_aircraft():
		_player.inventory.add_item(ItemTypes.AIRCRAFT, 1)

	_world.set_player(_player)
	_player.day_night_ref = _day_night
	# 村庄先于出生点生成：亚洲出生点锚定在村庄整平区内，扫描时读到的
	# 必须是整平后的 GRASS+空气（set_block_deferred 的数据写入是同步的）。
	_build_village()
	var spawn_pos := _find_spawn_position()
	_player.global_position = spawn_pos
	_player.set_spawn_position(spawn_pos)
	_player.setup_world(_world)
	_hud.setup(_player)
	_hud.set_day_night(_day_night)
	_hud.set_map_name(String(profile["title"]))
	_mob_spawner.setup(_player, _world, _day_night)
	_mob_spawner.set_region(profile)
	_player.died.connect(func(): Events.player_died.emit())
	Events.region_entered.connect(_on_region_entered)

	# 工坊台建造界面（V 键，D-032 Phase 4a）：蓝图编辑 → 试飞闭环。
	_build_screen = BuildScreen.new()
	$UI.add_child(_build_screen)
	_build_screen.setup(_player)
	_build_screen.test_fly_requested.connect(_on_test_fly_requested)

	# 首次进入游戏先选地图；之后随时可用 M 键重新选择。
	# 无头环境（探针 / CI）不自动弹出：模态界面会冻结玩家，阻塞自动化流程。
	if GameState.needs_region_pick and DisplayServer.get_name() != "headless":
		_hud.open_map_selector()


## 选图确认：记录区域并重载场景，由新实例按该区域重新生成世界。
func _on_region_entered(region_id: int) -> void:
	GameState.carried_inventory = _player.inventory
	GameState.set_region(region_id)
	get_tree().reload_current_scene()


## 试飞请求（工坊台 F）：把蓝图飞机放到玩家身前实心面上，直接登机——
## 「造飞机 → 试飞」闭环的最后一跳。机身/气动框由蓝图零件聚合决定。
func _on_test_fly_requested(bp: Blueprint) -> void:
	var forward := -_player.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3(1.0, 0.0, 0.0)
	var at := _player.global_position + forward.normalized() * 10.0
	var cell := Vector3i(at.floor())
	var surface := _world.get_surface_height(cell.x, cell.z)
	var craft := Aircraft.from_loadout(
		self,
		Vector3(float(cell.x) + 0.5, float(surface) + 0.1, float(cell.z) + 0.5),
		_player.rotation.y,
		bp,
	)
	_player.ride_aircraft(craft)
	Events.notice.emit("🔧 蓝图飞机已放出，起飞！")


## 生成固定村庄与掠夺塔（含村民与掠夺者，挂载于本节点，不受昼夜清空管理）。
## 每个区域建 3 座村庄：出生点旁一座（亚洲出生锚定该村），东西南各远处一座。
## 村庄格数布局体素 0.5m 化后占地（格）×2，村庄间距同步 ×2。
func _build_village() -> void:
	if GameState.current_region in [RegionAtlas.ARCTIC, RegionAtlas.ANTARCTICA]:
		return
	for offset: Vector3i in [
		Vector3i.ZERO,
		Vector3i(128, 0, 16),
		Vector3i(16, 0, 128),
	]:
		var builder := VillageBuilder.new()
		builder.build(_world, _player, _day_night, self, offset)


## 出生点：在出生列按真实方块向上扫描"两格空气 + 实心底"，双脚精确落在
## 实心底块顶面——胶囊高 1.8 m 恰占已验证的两格空气；任何悬空偏移都会
## 让身体上部嵌进头顶方块（如邻树树冠）。高度取样必须用出生列本身。
##
## 亚洲出生点锚定村庄整平区内的空地（广场西北侧空场），保证落地即见村庄；
## 原默认出生 (8,8) 离村庄十余格且常被树木丘陵遮挡。锚点依次尝试，
## 全部失败退回通用扫描 (8,8)。
func _find_spawn_position() -> Vector3:
	var anchors: Array[Vector2i] = [Vector2i(8, 8)]
	if GameState.current_region == RegionAtlas.ASIA:
		# 村庄布局格数 ×2（体素 0.5m 化）：锚点同步 ×2。
		anchors = [
			Vector2i(42, 50),  # 民居①与广场之间的空场
			Vector2i(44, 40),  # 广场北侧空地
			Vector2i(42, 42),
			Vector2i(28, 52),  # 村庄西缘
		]
	for anchor: Vector2i in anchors:
		var pos := _scan_spawn_column(anchor.x, anchor.y)
		if pos != Vector3.ZERO:
			return pos
	return Vector3(8.5, float(_world.get_surface_height(8, 8)), 8.5)


func _scan_spawn_column(x: int, z: int) -> Vector3:
	var base_y := _world.get_surface_height(x, z)
	for i in range(32):
		var cell := Vector3i(x, base_y + i, z)
		# 玩家 3.6 格高：需要连续四格空气 + 实心底。
		var clear := true
		for h in range(4):
			if _world.get_block(cell + Vector3i(0, h, 0)) != BlockTypes.Block.AIR:
				clear = false
				break
		if clear and _world.get_block(cell + Vector3i(0, -1, 0)) != BlockTypes.Block.AIR:
			return Vector3(x + 0.5, float(base_y + i), z + 0.5)
	return Vector3.ZERO
