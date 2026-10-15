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
## 零件解锁状态（跨会话持久化 user://unlocks.json）：main 持有唯一实例，
## 注入 build_screen——任务赚的绿宝石买的零件，下次进游戏还在（D-032 Phase 4b-ii）。
var _unlocks := PartUnlocks.load_or_new()
## 飞行视角三件套（D-033）：相机 rig / 轨迹录制 / 回放。随主场景生毁；
## 登机即激活相机并开始录制（Events.aircraft_ride_changed），HUD 路由按键。
var _flight_camera: AircraftCamera
var _recorder: FlightRecorder
var _replay: FlightReplay


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
	# 机场 / 降落场先于出生点生成：带机场的区域把出生点改写到跑道南段；
	# 大洋（岛上）/ 极地（冰面）区域布一座无机库的简易降落场，同样开场在
	# 跑道旁。位置均避开村庄（机场在村庄东南角，降落场搜索半径 ≤ 10），
	# 互不重叠。
	var airport_spawn := Vector3.ZERO
	var craft_park := Vector3.ZERO
	var mission_anchor := Vector3.ZERO
	var region := GameState.current_region
	if RegionAtlas.has_airport(region):
		var center := _airport_center(region)
		var builder := AirportBuilder.new()
		airport_spawn = builder.build(_world, center)
		craft_park = builder.parking_spot()
		mission_anchor = Vector3(center)
	elif RegionAtlas.has_landing_field(region):
		var site := _find_field_site()
		var builder := AirportBuilder.new()
		airport_spawn = builder.build_field(_world, site)
		craft_park = builder.parking_spot()
		mission_anchor = Vector3(site)
	# 村庄先于出生点生成：亚洲出生点锚定在村庄整平区内，扫描时读到的
	# 必须是整平后的 GRASS+空气（set_block_deferred 的数据写入是同步的）。
	_build_village()
	var spawn_pos: Vector3
	if airport_spawn != Vector3.ZERO:
		spawn_pos = airport_spawn
	else:
		spawn_pos = _find_spawn_position()
	_player.global_position = spawn_pos
	_player.set_spawn_position(spawn_pos)
	_player.setup_world(_world)
	_hud.setup(_player)
	_hud.set_day_night(_day_night)
	_hud.set_map_name(String(profile["title"]))
	# 飞行视角 / 录制 / 回放（D-033）：相机为场景级独立节点（不挂飞机），
	# 登机时按机体位姿自驱动；录制器随驾驶起止；回放由 HUD 触发。
	_flight_camera = AircraftCamera.new()
	add_child(_flight_camera)
	_recorder = FlightRecorder.new()
	add_child(_recorder)
	_replay = FlightReplay.new()
	add_child(_replay)
	_player.flight_camera = _flight_camera
	_hud.setup_flight(_flight_camera, _recorder, _replay)
	Events.aircraft_ride_changed.connect(_on_flight_ride_changed)
	# 飞行任务航路 / 降落区锚定机场或降落场（两者皆无才锚定出生点）：
	# 形成「跑道起飞 → 单向绕场 → 落回跑道面」闭环。
	if mission_anchor == Vector3.ZERO:
		mission_anchor = Vector3(spawn_pos.x, 0.0, spawn_pos.z)
	_hud.set_mission_anchor(mission_anchor)
	# 探索模式飞行地图：开局即在跑道上摆一架可见飞机（停于出生点以北约 19 格、
	# 机头朝 +Z 北端，沿跑道进近方向的反向即起飞方向），玩家走到跟前按 F 即可
	# 登机，不必先打开背包、选中飞机右键放机——出生点已在跑道旁，落地即可起飞。
	# 仅窗口运行摆机（沿用 main._ready 既有 headless 守卫），避免干扰无头探针
	# 里的飞机相关断言。
	if GameState.is_explore() and craft_park != Vector3.ZERO \
			and DisplayServer.get_name() != "headless":
		Aircraft.spawn(self, craft_park, PI)
		Events.notice.emit("✈️ 跑道上停着你的飞机，走到跟前按 F 登机。")
	_mob_spawner.setup(_player, _world, _day_night)
	_mob_spawner.set_region(profile)
	_player.died.connect(func(): Events.player_died.emit())
	Events.region_entered.connect(_on_region_entered)

	# 工坊台建造界面（V 键，D-032 Phase 4a）：蓝图编辑 → 试飞闭环。
	_build_screen = BuildScreen.new()
	$UI.add_child(_build_screen)
	_build_screen.setup(_player)
	_build_screen.set_unlocks(_unlocks)
	_build_screen.set_hud(_hud)
	_build_screen.test_fly_requested.connect(_on_test_fly_requested)
	# 模态互斥（P2-1）：建造界面打开时 HUD 热键让位；HUD 有面板时 V 键不响应。
	_hud.set_build_screen(_build_screen)

	# 首次进入游戏先选地图；之后随时可用 M 键重新选择。
	# 无头环境（探针 / CI）不自动弹出：模态界面会冻结玩家，阻塞自动化流程。
	if GameState.needs_region_pick and DisplayServer.get_name() != "headless":
		_hud.open_map_selector()


## 飞行任务遥测：玩家在机上时，每物理帧把真实飞行状态喂给 HUD 任务面板
## （MissionManager 的遥测约定：altitude_agl/speed(km/h)/position/on_ground/
## vertical_speed/wrecked/block_under）。不在机上则无需喂帧——面板只在
## RUNNING 时透传。
func _physics_process(delta: float) -> void:
	var craft := _player.aircraft()
	if craft == null or not is_instance_valid(craft):
		return
	var snap := craft.snapshot()
	# 轨迹录制（D-033）：驾驶中按 30 Hz 采样；回放中机体正被回放系统
	# 重演，此时采样会把回放轨迹污染进缓冲区，必须跳过。
	if not (_replay != null and _replay.is_playing()):
		_recorder.sample(craft, delta)
	# 机身下方地面方块（自机身原点向下扫首个实块）：降落任务「必须停在
	# 跑道面」的判据。停机时机身原点离地约 2.5 m，扫 6 格必达地面。
	var cell := Vector3i(craft.global_position.floor())
	var block_under := BlockTypes.Block.AIR
	for i in range(6):
		var b := _world.get_block(cell - Vector3i(0, i, 0))
		if b != BlockTypes.Block.AIR:
			block_under = b
			break
	var telemetry := {
		"altitude_agl": float(snap.get("altitude_agl", 0.0)),
		"speed": float(snap.get("kmh", 0.0)),
		"position": craft.global_position,
		"on_ground": craft.is_on_floor(),
		"vertical_speed": craft.velocity.y,
		"wrecked": craft.is_wrecked(),
		"block_under": block_under,
	}
	_hud.feed_mission(delta, telemetry)


## 登机 / 下机 → 飞行相机激活与轨迹录制起止（D-033）。
func _on_flight_ride_changed(riding: bool) -> void:
	if riding:
		var craft := _player.aircraft()
		if craft != null and is_instance_valid(craft):
			_flight_camera.setup(craft, _player)
			_flight_camera.set_active(true)
			_recorder.start()
	else:
		_flight_camera.set_active(false)
		_recorder.stop()


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
	# 实心面扫描：自投放点上方往下找首个实块，取其顶面高度。
	# 不能直接用 get_surface_height——那只是噪声地形基准，看不见机场整平垫高、
	# 玩家自建平台；在垫高跑道旁试飞会把飞机嵌进跑道里再被物理弹飞
	# （与本函数遥测里 block_under 的向下扫描同思路）。
	var surface := _world.get_surface_height(cell.x, cell.z)
	var scan := Vector3i(cell.x, cell.y + 6, cell.z)
	for i in range(16):
		var b := _world.get_block(scan - Vector3i(0, i, 0))
		if BlockTypes.is_solid(b):
			surface = scan.y - i + 1
			break
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


## 机场中心：亚洲村庄在原点附近，机场放到东南角（96,96）避开村庄；
## 其余大陆区域出生点本就在 (8,8) 附近，机场即落其旁，开局即达跑道。
func _airport_center(region_id: int) -> Vector3i:
	if region_id == RegionAtlas.ASIA:
		return Vector3i(96, 0, 96)
	return Vector3i(8, 0, 8)


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


## 简易降落场场址：以 (8,8) 为圆心逐环外扩，找「地表实体可站（非水）+
## 四格空气」的列——大洋区域落到岛上草地/沙地，极地落到封冻海面的冰盖上。
## 搜索半径 ≤ 10：村庄 A 占 x∈[26,82]/z∈[32,80]，降落场含 2 格施工缘最远
## 只到 25，永不重叠。
func _find_field_site() -> Vector3i:
	_world.ensure_chunks_in_region(Vector3i(-4, 0, -4), Vector3i(20, 0, 20))
	for radius in range(11):
		for x in range(8 - radius, 8 + radius + 1):
			for z in range(8 - radius, 8 + radius + 1):
				if maxi(absi(x - 8), absi(z - 8)) != radius:
					continue
				if _field_column_ok(x, z):
					return Vector3i(x, 0, z)
	return Vector3i(8, 0, 8)


## 场址列判定：自 SEA_LEVEL+8 向下找首个非空气块，须为可站实体（非水），
## 其上四格空气（避开树冠与冰山侧壁）。
func _field_column_ok(x: int, z: int) -> bool:
	var top := -1
	for y in range(World.SEA_LEVEL + 8, 0, -1):
		if _world.get_block(Vector3i(x, y, z)) != BlockTypes.Block.AIR:
			top = y
			break
	if top < 0:
		return false
	if _world.get_block(Vector3i(x, top, z)) == BlockTypes.Block.WATER:
		return false
	for h in range(1, 5):
		if _world.get_block(Vector3i(x, top + h, z)) != BlockTypes.Block.AIR:
			return false
	return true
