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
## 飞行仪表 3D 视图（D-034）：座舱 3D 面板（挂飞机下）/ 世界标注（挂世界下），
## 随登机创建、下机释放；注册到屏幕仪表 HUD 以便每帧收到同一份读数。
var _cockpit_panel: CockpitPanel = null
var _flight_markers: FlightMarkers = null
## 飞行导航锚点（机场中心 / 出生点）：登机时同时注入 HSI/CDI 与 3D 标注。
var _mission_anchor := Vector3.ZERO
## 飞行重置归位点（D-039）：_flight_spawn = 本次进图的初始出生点（跑道南段），
## _craft_park = 初始停机位（出生点以北、机头朝北）。坠机/卡住时按 Y 把玩家
## 与飞机送回这两点。无机场/降落场的区域 _craft_park 为零，飞机就地摆正。
var _flight_spawn := Vector3.ZERO
var _craft_park := Vector3.ZERO


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
	var field_site := Vector3i.ZERO
	var region := GameState.current_region
	if RegionAtlas.has_airport(region):
		var center := _airport_center(region)
		var builder := AirportBuilder.new()
		airport_spawn = builder.build(_world, center)
		craft_park = builder.parking_spot()
		mission_anchor = Vector3(center)
	elif RegionAtlas.has_landing_field(region):
		var site := _find_field_site()
		field_site = site
		var builder := AirportBuilder.new()
		airport_spawn = builder.build_field(_world, site)
		craft_park = builder.parking_spot()
		mission_anchor = Vector3(site)
	# 村庄先于出生点生成：亚洲出生点锚定在村庄整平区内，扫描时读到的
	# 必须是整平后的 GRASS+空气（set_block_deferred 的数据写入是同步的）。
	_build_village()
	# 航海玩法（D-042）：四大洋在降落场所在的海岛边缘建港，默认提供一艘船。
	# 注意时序：机场/降落场与村庄都已落数据，岸点搜索读到的是成岛后的地形。
	if _is_ocean_region(region):
		_build_harbor(field_site, craft_park)
	var spawn_pos: Vector3
	if airport_spawn != Vector3.ZERO:
		spawn_pos = airport_spawn
	else:
		spawn_pos = _find_spawn_position()
	_player.global_position = spawn_pos
	_player.set_spawn_position(spawn_pos)
	# 飞行重置归位点（D-039）：记下本次进图的初始站位与停机位。
	_flight_spawn = spawn_pos
	_craft_park = craft_park
	_player.setup_world(_world)
	_hud.setup(_player)
	_hud.set_day_night(_day_night)
	_hud.set_map_name(String(profile["title"]))
	# 出生加载屏（D-064）：窗口环境下遮住世界，等高模环填满再放行——环 4 的
	# 冷启动要生成 81 块（≈3.3 s），直接把玩家丢进去会看到地形一块块蹦出来。
	# 加载屏期间 World 走 bootstrap 预算（每帧 4 块）尽快填满。
	# 无头环境不建：探针靠 await 帧数断言世界状态，遮罩既无意义也拖慢流程。
	if DisplayServer.get_name() != "headless":
		var splash := SpawnLoading.new()
		_hud.add_child(splash)
		splash.begin(_world, String(profile["title"]))
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
	# 浮动原点（D-062）：世界锚定实体整群搬迁。静态根在此登记；动态实体
	# （飞机/船/箭/浮漂/村民/飞行标注）在各自出生点调 WorldAnchor.register。
	WorldAnchor.register(_player)
	WorldAnchor.register(_mob_spawner)
	WorldAnchor.register(_flight_camera)
	Events.origin_shifted.connect(_on_origin_shifted)
	# 坠机生还自动归位（D-056）：弹射后无需玩家按 Y，自动回到初始停机坪。
	Events.aircraft_crash_survived.connect(_on_crash_survived)
	# 飞行任务航路 / 降落区锚定机场或降落场（两者皆无才锚定出生点）：
	# 形成「跑道起飞 → 单向绕场 → 落回跑道面」闭环。
	if mission_anchor == Vector3.ZERO:
		mission_anchor = Vector3(spawn_pos.x, 0.0, spawn_pos.z)
	_mission_anchor = mission_anchor
	_hud.set_mission_anchor(mission_anchor)
	# 探索模式飞行地图：开局即在跑道上摆一架可见飞机（停于出生点以北约 19 格、
	# 机头朝 +Z 北端，沿跑道进近方向的反向即起飞方向），玩家走到跟前按 F 即可
	# 登机，不必先打开背包、选中飞机右键放机——出生点已在跑道旁，落地即可起飞。
	# 仅窗口运行摆机（沿用 main._ready 既有 headless 守卫），避免干扰无头探针
	# 里的飞机相关断言。
	if GameState.is_explore() and craft_park != Vector3.ZERO \
			and DisplayServer.get_name() != "headless":
		Aircraft.spawn(self, craft_park, PI)
		# 开局让玩家正对停机飞机（+Z 正北 = 跑道起飞方向）：出生点在南段、机头朝南
		# 看不到身后北侧的飞机——把玩家 yaw 转 180°。第三人称相机的 yaw 由父节点
		# （Player）旋转自动跟随，只需转玩家，别单独动相机。仅探索模式成功摆机时设置。
		_player.rotation.y = PI
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
	# 从竞速场景返回：RaceSystem 里的一次性标记要求「回来就直接再开赛道选择器」，
	# 省得「比完 → 想换条赛道」还要先绕回地图页。标记无论是否开窗都要清掉，
	# 无头环境下只清标记不开窗（同 needs_region_pick 的守卫）。
	if RaceSystem.open_selector_on_return:
		RaceSystem.open_selector_on_return = false
		if DisplayServer.get_name() != "headless":
			_hud.open_track_selector()


## 飞行任务遥测：玩家在机上时，每物理帧把真实飞行状态喂给 HUD 任务面板
## （MissionManager 的遥测约定：altitude_agl/speed(km/h)/position/on_ground/
## vertical_speed/wrecked/block_under）。不在机上则无需喂帧——面板只在
## RUNNING 时透传。
func _physics_process(delta: float) -> void:
	# 航海玩法（D-042）：模态面板（地图选择器 / 钓具界面 / 教学浮层）打开时
	# 锁舵——船收油随波减速停住，不会在玩家看界面时自己跑掉；关闭即恢复。
	BoatSystem.input_suspended = _hud.is_any_panel_open() or _hud._any_overlay_open()
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
		# 任务遥测约定（MissionManager 文档）：position 为**世界坐标**——
		# 任务航路/降落区按世界空间锚定（missions_for_airport 用机场绝对坐标），
		# 浮动原点搬迁后渲染坐标会变、世界坐标不变，故此处经 to_world 转换
		# （origin=0 时恒等，行为与改造前一致）。屏幕仪表 HUD 不走本字典
		# （它直读 craft.snapshot() 的渲染坐标），不受影响。
		"position": _world.to_world(craft.global_position),
		"on_ground": craft.is_on_floor(),
		"vertical_speed": craft.velocity.y,
		"wrecked": craft.is_wrecked(),
		"block_under": block_under,
	}
	_hud.feed_mission(delta, telemetry)


## 登机 / 下机 → 飞行相机激活、轨迹录制起止、座舱 3D 面板与世界标注增删（D-033/D-034）。
func _on_flight_ride_changed(riding: bool) -> void:
	# 飞行流式加载窗口：登机时切到「沿机头方向的偏置矩形 + 时间预算」，
	# 下机切回徒步的 5×5 方形（D-035）。
	_world.set_flight_stream(riding)
	if riding:
		var craft := _player.aircraft()
		if craft != null and is_instance_valid(craft):
			_flight_camera.setup(craft, _player)
			# D-049：登机默认第一人称座舱（用户要求「默认登机后进入第一人称
			# 视角，界面突出座舱驾驶界面」）。须在 set_active 之前——set_active
			# 会把相机吸附到 _mode 的目标位姿，先复位才不会从追尾位飞进座舱。
			_flight_camera.reset_to_cockpit()
			_flight_camera.set_active(true)
			_recorder.start()
			# D-034：座舱 3D 面板挂飞机下（蓝图机自动隐藏）；世界标注挂世界下。
			if _cockpit_panel == null:
				_cockpit_panel = CockpitPanel.new()
				craft.add_child(_cockpit_panel)
				_cockpit_panel.setup(craft)
				# D-050：面板是「相机激活后才挂上机体」的晚到者——内视规则
				# （setup/reset_to_cockpit 时）应用时它还不存在，这里补一次，
				# 座舱视角下隐藏 3D 面板（读数交给 2D 仪表簇）。
				_flight_camera.apply_cockpit_interior()
			if _flight_markers == null:
				_flight_markers = FlightMarkers.new()
				add_child(_flight_markers)
				WorldAnchor.register(_flight_markers)  # D-062：Main 级实体，随 origin 搬迁
				_flight_markers.setup(craft, self)
			_hud.instrument_hud().register_view(_cockpit_panel)
			_hud.instrument_hud().register_view(_flight_markers)
			# 导航目标 = 任务锚点（机场/出生点）：HSI/CDI 与 3D 标注同步标出。
			# _mission_anchor 存**世界坐标**（真相）；HSI/CDI 按渲染坐标与机体
			# 位置做差、3D 标注直接摆节点，故注入前统一 to_render 转换
			# （origin=0 时恒等）。任务数据（missions_for_airport）保持世界坐标，
			# 与 _physics_process 里 to_world 后的遥测位置配套。
			var anchor_render := _world.to_render(_mission_anchor)
			_hud.set_flight_navigation(anchor_render, "机场/任务")
			_flight_markers.set_target(anchor_render, "机场/任务")
			# 进近引导：以当前机头方向为进近轴，在目标后方铺箭头 + 3° 下滑道。
			var fwd := -craft.global_transform.basis.z
			fwd.y = 0.0
			if fwd.length_squared() > 1e-4:
				fwd = fwd.normalized()
				_flight_markers.set_runway_guide(anchor_render, fwd)
	else:
		_flight_camera.set_active(false)
		_recorder.stop()
		# 释放座舱面板与世界标注，并从其屏幕 HUD 注销。
		if _cockpit_panel != null:
			_hud.instrument_hud().unregister_view(_cockpit_panel)
			_cockpit_panel.queue_free()
			_cockpit_panel = null
		if _flight_markers != null:
			_hud.instrument_hud().unregister_view(_flight_markers)
			_flight_markers.queue_free()
			_flight_markers = null
		_hud.instrument_hud().clear_navigation()


## 浮动原点搬迁（D-062）：World.request_shift_origin 已把 World 节点移到
## −new_origin（其下区块自动跟随）并重键了储物箱，这里负责 Main 级实体与
## 渲染空间锚点。delta = 旧 origin − 新 origin：世界内容整体 +delta，
## 玩家的**世界坐标**不变（render = world − origin 同步平移）。
func _on_origin_shifted(delta: Vector3) -> void:
	# ① 世界锚定实体（玩家/飞行相机/刷怪笼/飞机/船/箭/浮漂/村民/飞行标注）：
	# 全部是 Main 级叶子节点，position += delta 即整体平移（子节点随父）。
	for node in get_tree().get_nodes_in_group(WorldAnchor.GROUP):
		if node is Node3D and is_instance_valid(node):
			node.position += delta
			# 带内部坐标态的实体补钩子：飞机的 _state.position 每物理帧末才
			# 从节点回同步、船的 harbor_pos 是渲染锚点，不立即重基的话搬迁
			# 当帧的读数会带着旧坐标。
			if node is Aircraft:
				(node as Aircraft).rebase_state_after_shift(delta)
			elif node is Boat:
				(node as Boat).rebase_anchors_after_shift(delta)
	# ② 渲染空间锚点重基：这三个量以「注入时的渲染坐标」存储（传送/停机位
	# 直接当 global_position 用），随 origin 平移保持指向同一世界位置。
	_player.rebase_spawn_position(delta)
	_flight_spawn += delta
	_craft_park += delta
	# ③ 轨迹录制与回放：样本按渲染坐标采样，整体重基后回放/幽灵轨迹不错位。
	_recorder.shift(delta)
	_replay.note_origin_shifted()
	# ④ 任务锚点是世界坐标真相，不随搬迁改变；但 HSI/CDI 与 3D 标注消费
	# 渲染坐标，登机中重新注入一次（下机态无导航视图，跳过）。
	if _player.is_riding():
		var anchor_render := _world.to_render(_mission_anchor)
		_hud.set_flight_navigation(anchor_render, "机场/任务")
		if _flight_markers != null and is_instance_valid(_flight_markers):
			_flight_markers.set_target(anchor_render, "机场/任务")


## 飞行重置（D-039）：坠机 / 卡住的一键救援——玩家与飞机送回本地图初始
## 跑道，满油重新开始飞。语义：
##   1. 在机上先下机（exit_aircraft 把玩家放到机侧，随后被传送覆盖）；
##   2. 残骸立即清除（不等 4 秒消散，翻篇）；完好的飞机 place() 搬回初始
##      停机位——用 place 而非销毁重造：蓝图装配机的零件聚合会随销毁丢失；
##   3. 场上没有完好飞机时（坠毁且背包已空）补一架默认机，保证重置后一定能飞；
##   4. 玩家传送回初始出生点、朝北正对飞机（与开局摆机同一姿态）。
## D-056 起坠机弹射生还也会自动走一遍本重置（Events.aircraft_crash_survived
## → _on_crash_survived），无需玩家按 Y；卡住 / 手动重开仍走 Y 键入口。
## notice 为收尾提示文案；坠机自动归位（D-056）会带上坠机原因，空串用默认文案。
func reset_flight_experience(notice: String = "") -> void:
	if _flight_spawn == Vector3.ZERO:
		return
	# 回放中让位（同 player 的 replaying 守卫）：运镜时搬世界会打断演出。
	if _replay != null and _replay.is_playing():
		Events.notice.emit("🎬 回放中不能重置。")
		return
	if _player.is_riding():
		_player.exit_aircraft()
	var parked: Aircraft = null
	for child in get_children():
		var craft := child as Aircraft
		if craft == null or not is_instance_valid(craft):
			continue
		if craft.is_wrecked():
			# 残骸提前消散（翻篇）。先禁碰撞再 queue_free：释放发生在帧末，
			# 不清碰撞的话同位置新机出生时会被残骸的 depenetration 压下去
			# （实测下沉 2.2 m），禁碰撞后残骸只余视觉翻倒。
			craft.collision_layer = 0
			craft.collision_mask = 0
			craft.queue_free()
		elif parked == null:
			parked = craft
	if _craft_park != Vector3.ZERO:
		# 玩家在远方坠机时，初始跑道区块可能已流式卸载：先同步确保该区域
		# 区块就绪（幂等，已加载即跳过），否则飞机 place 出去无地面可停，
		# 会自由落体嵌入跑道、被 depenetration 乱推（实测浮起 1.6 m）。
		# 顺带让玩家的落点安全搜索读到真实方块。
		# _craft_park 是渲染坐标，ensure_chunks_in_region 收世界坐标（D-062）：
		# 先 to_world 再取整——搬迁后二者相差一个 origin，直接传会保证错区域。
		var pad := Vector3i(40, 0, 40)
		var park_w := _world.to_world(_craft_park)
		var park_cell := Vector3i(floori(park_w.x), 0, floori(park_w.z))
		_world.ensure_chunks_in_region(park_cell - pad, park_cell + pad)
		if parked != null:
			parked.place(_craft_park, PI)  # place() 自带状态复位与满油
		else:
			Aircraft.spawn(self, _craft_park, PI)
	else:
		# 无跑道区域：飞机就地摆正，玩家回出生点。
		if parked != null:
			parked.place(parked.global_position, PI)
	_player.teleport_to(_flight_spawn, PI)
	Events.notice.emit(notice if not notice.is_empty()
		else "✈️ 已重置：回到跑道起点，满油待发。")


## 坠机生还救援（D-056）：弹射后自动走一遍飞行重置——退出驾驶舱界面、
## 玩家与飞机回到本地图初始停机坪，满油待发。语义同 Y 手动重置（D-039），
## 坠机时免去玩家自己按一键救援（用户实测：「坠机了但人物没挂，界面停留
## 在驾驶舱画面」——期望自动退出座舱、回到初始停机坪）。
## 延迟一帧执行：事件是从 wreck() 的物理回调栈里发出来的（弹射→事件→
## 这里），当场清除残骸会与 wreck 收尾的翻倒 tween / 消散计时器抢同一个
## 节点，且 ensure_chunks_in_region 是重活，同步塞进物理帧会突然拉长帧。
func _on_crash_survived(reason: String) -> void:
	await get_tree().process_frame
	if not is_inside_tree():
		return
	# 带上坠机原因的收尾提示；原因为空（异常路径）时回落 reset 的默认文案。
	var notice := ""
	if not reason.is_empty():
		notice = "💥 %s——已回到停机坪，满油待发。" % reason
	reset_flight_experience(notice)


## Y（D-039）：飞行重置入口。守卫与 player 的飞行键一致：死亡停顿 / 回放 /
## 模态面板打开时让位——背包、地图选择器、工坊台里按 Y 不应把世界搬走。
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if not event.is_action_pressed("aircraft_reset"):
		return
	if _player == null or _player.is_dead():
		return
	if _hud != null and _hud.is_any_panel_open():
		return
	reset_flight_experience()
	get_viewport().set_input_as_handled()


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
	# get_surface_height 收**世界坐标**（D-062 创作 API），cell 是渲染坐标，
	# 先 to_world；下面的 get_block 扫描保持渲染坐标（查询 API 自带转换）。
	var at_w := _world.to_world(at)
	var surface := _world.get_surface_height(int(floorf(at_w.x)), int(floorf(at_w.z)))
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


## 四大洋（0~3）：航海玩法只属于海面区域；大洋洲（9）虽然有降落场但是
## 大陆地块，不建港。
func _is_ocean_region(region_id: int) -> bool:
	return region_id >= RegionAtlas.PACIFIC and region_id <= RegionAtlas.ARCTIC


## 建港（D-042）：海岛边缘的沙滩平台 + 木栈桥 + 灯塔 + 泊位。
## 泊位分工：栈桥向海端 = 玩家默认船（船头朝外海）；栈桥两侧 = 港湾里
## 泊着的两艘异型船（小渔船 / 快艇，纯景观，供「种类不一的船只」）。
## 找不到岸线（极小的岛）时退到停机位旁的地面上泊船，玩法仍可用。
func _build_harbor(field_site: Vector3i, craft_park: Vector3) -> void:
	var harbor := HarborBuilder.new().build(_world, field_site)
	var player_boat_id := BoatSystem.current_boat_id()
	if not bool(harbor.get("found", false)):
		var at := craft_park + Vector3(7.0, 0.0, 0.0) if craft_park != Vector3.ZERO \
			else Vector3(field_site.x + 7.0, 0.0, field_site.y)
		# get_surface_height 收世界坐标（D-062）；本函数虽只在场景就绪
		# （origin=0）时运行，仍按契约转换，避免将来在别处复用踩坑。
		var at_w := _world.to_world(at)
		var ground_y := float(_world.get_surface_height(
			int(floorf(at_w.x)), int(floorf(at_w.z)))) + 1.0
		var boat := Boat.spawn(self, Vector3(at.x, ground_y, at.z), PI, player_boat_id)
		boat.harbor_pos = Vector3.ZERO  # 无港口：距港 -1（近海带）
		boat.setup_world(_world, _day_night)
		Events.notice.emit("⛵ 岛上没有合适的岸线，你的船停在跑道旁——按 F 登船。")
		return
	var dock_dir: Vector2 = harbor["dock_dir"]
	var facing := atan2(dock_dir.x, dock_dir.y)  # rotation.y 与船头约定一致
	var player_boat := Boat.spawn(self, harbor["dock_end"], facing, player_boat_id)
	player_boat.harbor_pos = harbor["dock_end"]
	player_boat.setup_world(_world, _day_night)
	# 港湾泊船：两艘异型船面朝港内（垂直栈桥、船尾朝海）。
	var side_facing := facing + PI * 0.5
	var moorings: Array = harbor["moorings"]
	var scenery_ids := ["fishing_boat", "speedboat"]
	for i in range(mini(moorings.size(), scenery_ids.size())):
		var moored := Boat.spawn(self, moorings[i],
			side_facing if i == 0 else side_facing + PI, scenery_ids[i], false)
		moored.harbor_pos = harbor["dock_end"]
		moored.setup_world(_world, _day_night)
	Events.notice.emit("⛵ 港口泊着你的船——沿木栈桥走到头按 F 登船；开得越远，鱼种越多。")


## 生成固定村庄与掠夺塔（含村民与掠夺者，挂载于本节点，不受昼夜清空管理）。## 每个区域建 3 座村庄：出生点旁一座（亚洲出生锚定该村），东西南各远处一座。
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


## 机场中心：跑道加宽到翼展全包（RUNWAY_WID=52 格=26 m，半宽 26 格）后，
## 机场铺装/整平足迹横向达 ±(26+2)=±28 格、_probe_base_y 达 ±(26+3)=±29 格，
## 必须让「中心 x − 29 ≥ 村庄 A 整平上界 82 + 2」，即 center.x ≥ 113，否则会
## 压到亚洲村庄 A（x∈[26,82]）。故取 114：跑道 x∈[88,140]，既远离村庄 A（≤82），
## 又远离东侧远景村庄（村 B x∈[154,210]）。机场沿 +Z，z 中心保持各区原值（亚洲 96、
## 其余 8）。其余大陆原为 (8,8)：加宽后跑道会伸到负 x 且与原点村庄 A 重叠
## （x∈[26,34]），故一并东移到 114（z 仍 8，向南段跑道落位与旧版一致）。
func _airport_center(region_id: int) -> Vector3i:
	if region_id == RegionAtlas.ASIA:
		return Vector3i(114, 0, 96)
	return Vector3i(114, 0, 8)


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


## 场址列判定：自世界顶向下找首个非空气块，须为可站实体（非水），
## 其上四格空气（避开树冠与山脊积雪）。
## D-055：扫描起点原为 SEA_LEVEL+8——世界高 64 格时地形永不可能高过它。
## 高度升到 256 格后雪山可达 200+，仍从 SEA_LEVEL+8 起扫会整列扫空、
## 判定失败，导致大洋/极地区域的降落场选址永远找不到场址。改从
## CHUNK_SIZE.y-1（世界顶）起扫，与高度解耦。
func _field_column_ok(x: int, z: int) -> bool:
	var top := -1
	for y in range(World.CHUNK_SIZE.y - 1, 0, -1):
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
