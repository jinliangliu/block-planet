extends Node
## 飞行器探针：验证「简化真实气动」的关键行为。
## A 段为纯气动标定（无场景依赖，直接驱动 AircraftFlight）；
## B~E 段在世界里开一条高架测试跑道，用真实节点物理跑完停放/起飞/巡航/
## 失速/硬着陆解体全链路——飞行手感的核心断言都在这里。
## 运行：Godot_v4.6.3-stable_win64_console.exe --headless --path . res://tests/flight_probe.tscn

## 测试跑道：远离三座村庄（原点村 x26~82/z32~80；+x 村 x154~210；+z 村 z160~208），
## 选在世界东南角，并挑「地表最高点最低」的候选点，尽量留出净空。
const STRIP_CANDIDATES := [
	Vector2i(300, 300),
	Vector2i(300, 600),
	Vector2i(600, 300),
	Vector2i(600, 600),
]
## 跑道横向 16 格 = 8 m：宽于机身碰撞盒（6.6 m），整机含翼尖全由铺面支撑，
## 不再仅靠跑道中线吃重量（核对记录：10 格窄跑道时机身横向各悬空约 0.8 m）。
const STRIP_WIDTH := 16
## 跑道长度 64 格：满油门滑跑到抬轮约 35 格（17.6 m），余量充足。
## 上限受世界流式加载半径约束（LOAD_RADIUS = 2 区块 = 80 格）。
const STRIP_LENGTH := 64
## 玩家站位：跑到中段，保证整条跑道所在区块常驻（区块跟随玩家位置流式加载）。
const STAND_MARGIN := 6
## 机身朝 +Z 起飞（Godot 里机头朝 −Z，故朝向取 π）。
## 跑道沿 +Z 铺设，机头必须顺着跑道——否则一抬轮就冲出跑道上到原始地形里卡住。
const RUNWAY_HEADING := PI

var _failed := 0
var _stall_event := false
var _crash_reasons: Array[String] = []
## 存档隔离快照（D-010 铁律 3）：跑前存档文本 + 进度内存态，_finish() 前原样还原。
## 空串表示原文件不存在（还原即删除），避免「探针凭空建了个新存档」的污染。
## 内存态也必须还原：Progress._exit_tree 退出时会 _save() 把内存态写盘——
## 只还原文件会被它覆盖（实测：只写文件后 flew 107→119，还原失效）。
var _saved_progress := ""
var _saved_settings := ""
var _saved_counters: Dictionary = {}
var _saved_states: Dictionary = {}
var _saved_quiz_streak := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	# 输入动作注册（幂等）：H 段键盘/鼠标驾驶通路断言依赖 InputMap 里已有动作。
	InputActions.register()
	# 存档隔离（D-010 铁律 3）：本探针会真实推进飞行成就计数并读写飞行设置，
	# 跑前快照 user:// 两个存档文件，_finish() 前原样还原（life_probe 阶段 S 同款教训）。
	_saved_progress = _read_user_text("user://progress.json")
	_saved_settings = _read_user_text("user://settings.json")
	_saved_counters = Progress.counters.duplicate()
	_saved_states = Progress.states.duplicate()
	_saved_quiz_streak = Progress._quiz_correct_since_reward
	# 飞行设置钉死「标准/半开」：探针逐帧行为不再依赖开发者磁盘设置档
	# （硬核档无辅助稳定，逐帧行为不同——违反探针可复现原则）。set_current 只改内存。
	FlightSettings.set_current(FlightSettings.for_difficulty(FlightSettings.Difficulty.NORMAL))
	# 领机一次性标记：同进程首次领取为真、再领为假（探索赠机不刷屏）。
	var prev_mode: GameState.Mode = GameState.mode
	GameState.mode = GameState.Mode.EXPLORE
	_check(GameState.claim_explore_aircraft(), "探索模式首次领取飞机为真")
	_check(not GameState.claim_explore_aircraft(), "同进程内二次领取为假（赠机不刷屏）")
	GameState.mode = prev_mode

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame

	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")
	var hud: HUD = main_scene.get_node("UI")
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
	GameState.needs_region_pick = false

	_run_flight_model_checks()
	_run_parts_checks()
	_run_attitude_sign_checks()

	# ── 准备：高架测试跑道 ──────────────────────────────
	var origin := _pick_strip_origin(world)
	var strip_y := _build_strip(world, origin)
	_check(strip_y > 0 and strip_y < 60,
		"测试跑道建在区块高度范围内（y=%d，起点 %s）" % [strip_y, origin])
	# 玩家物理停掉后位置固定，区块常驻；否则下一帧跑道就被流式卸载。
	player.set_physics_process(false)
	player.global_position = Vector3(
		float(origin.x) + STRIP_WIDTH + STAND_MARGIN,
		float(strip_y) + 3.0,
		float(origin.y) + STRIP_LENGTH * 0.5)
	for i in range(30):
		await get_tree().physics_frame

	var surface := float(strip_y + 1)
	# 起飞点（地面点）：place() 内部会再加 GROUND_CLEARANCE，这里只给地表高度。
	# 碰撞盒 15.6 m × 6.6 m（米制，非格）：横向取跑道中线，整机都在铺面上。
	var start := Vector3(float(origin.x) + STRIP_WIDTH * 0.5, surface + 0.1,
		float(origin.y) + 10.0)

	# ── B 段：停放 ───────────────────────────────────────
	var craft := Aircraft.spawn(main_scene, start, RUNWAY_HEADING)
	craft.drive_remotely()
	craft.stall_changed.connect(_on_stall_changed)
	craft.crashed.connect(_on_crashed)
	await _frames(40)
	_check(not craft.is_wrecked(), "停放 40 帧未解体")
	var parked_y := craft.global_position.y
	_check(absf(parked_y - (surface + Aircraft.GROUND_CLEARANCE))
			< Aircraft.GROUND_CLEARANCE * 0.5,
		"机轮贴地停放（离地高度 %.2f，期望 %.2f）"
			% [parked_y - surface, Aircraft.GROUND_CLEARANCE])
	_check(craft.snapshot()["airspeed"] < 0.5, "无油门时保持静止")

	# ── C 段：满油门滑跑 → 到抬轮速度拉杆离地 ─────────────
	# 地面姿态被机轮限在 12°，静止时机翼攻角近零、升力为零——必须像真飞行员
	# 那样「先加速、到抬轮速度再拉杆」，飞机才会离地。这一步同时验证升降舵在地面有效。
	craft.controls.throttle = 1.0
	var lifted_frame := -1
	var rotate_frame := -1
	for i in range(1200):
		await get_tree().physics_frame
		var roll := craft.snapshot()
		if rotate_frame < 0 and float(roll["airspeed"]) >= float(roll["stall_speed"]) * 0.9:
			craft.controls.pitch = 0.8
			rotate_frame = i
		if not craft.is_on_floor():
			lifted_frame = i
			break
	_check(rotate_frame > 0, "到抬轮速度前保持三点滑跑（第 %d 帧拉杆）" % rotate_frame)
	_check(lifted_frame > 0, "满油门滑跑 + 拉杆后离地（第 %d 帧）" % lifted_frame)
	_check(not craft.is_wrecked(), "起飞过程未解体")
	craft.controls.pitch = 0.0
	var roll_distance := craft.global_position.z - start.z
	_check(roll_distance > 12.0 and roll_distance < 24.0,
		"起飞滑跑钉死 ≈18 m（实际 %.1f m，D-031）" % roll_distance)
	var liftoff := craft.snapshot()
	_check(liftoff["airspeed"] >= liftoff["stall_speed"] * 0.95,
		"离地空速不低于失速速度（%.1f / %.1f m/s）"
			% [liftoff["airspeed"], liftoff["stall_speed"]])
	_check(liftoff["airspeed"] >= 13.5 and liftoff["airspeed"] <= 18.0,
		"抬轮离地空速落在 14~18 m/s（实际 %.1f m/s）" % liftoff["airspeed"])

	# ── D 段：半油门平飞速度收敛 ─────────────────────────
	# 另起一架飞机投到**区块高度上限（64 格）之上**：那里全图无方块，
	# 巡航与失速段可以放心长时间飞，不必担心撞山打断断言。
	# 配一个简易高度保持（模拟玩家的目视修正），这样速度才有稳定的收敛值。
	var cruiser := Aircraft.spawn(main_scene, start + Vector3(-6.0, 46.0, 24.0), RUNWAY_HEADING)
	cruiser.drive_remotely()
	cruiser.launch(30.0)
	cruiser.stall_changed.connect(_on_stall_changed)
	cruiser.crashed.connect(_on_crashed)
	cruiser.controls.throttle = 0.5
	var hold_y := cruiser.global_position.y
	for i in range(1200):
		await get_tree().physics_frame
		var drift: float = cruiser.global_position.y - hold_y
		cruiser.controls.pitch = clampf(-drift * 0.05, -0.35, 0.35)
	var cruise := cruiser.snapshot()
	_check(cruise["kmh"] > 120.0 and cruise["kmh"] < 150.0,
		"半油门平飞收敛钉死在巡航带（%.0f km/h，D-031 目标 127~137）" % cruise["kmh"])
	_check(not cruise["stalled"], "巡航状态未失速")
	_check(not cruiser.is_wrecked(), "巡航过程未解体")
	# D-048：节点位姿必须跟随纯逻辑姿态——相机/座舱仪表/座位/录制全读
	# global_transform，修复前节点 basis 只在 place() 写过一次，飞机「会转弯
	# 但不转身」（模型坡度 45° 时仪表恒 0°）。此处把节点 basis == 模型 basis 钉死。
	_check(cruiser.global_transform.basis.is_equal_approx(cruiser._state.basis),
		"巡航中节点位姿跟随飞行模型（basis 逐列一致）")

	# ── E 段：爬升 → 持续拉杆失速 → 推杆改出 ─────────────
	var climb_start_y: float = cruiser.global_position.y
	cruiser.controls.throttle = 1.0
	cruiser.controls.pitch = 0.6
	for i in range(360):
		await get_tree().physics_frame
	var climbed: float = cruiser.global_position.y - climb_start_y
	_check(climbed > 30.0 and climbed < 110.0,
		"满油门爬升率落在 5~18 m/s 量级（6 s 爬升 +%.1f m，D-031 目标 ≈10 m/s）" % climbed)

	cruiser.controls.pitch = 1.0
	var stalled := false
	for i in range(1500):
		await get_tree().physics_frame
		if cruiser.snapshot()["stalled"]:
			stalled = true
			break
	_check(stalled, "持续拉杆后进入失速")
	_check(_stall_event, "失速翻转广播了 stall_changed")
	var stalled_speed: float = cruiser.snapshot()["airspeed"]
	_check(stalled_speed < cruise["airspeed"],
		"失速时空速低于巡航（%.1f < %.1f m/s）" % [stalled_speed, cruise["airspeed"]])
	# 改出：推杆减小攻角 + 保持油门。
	cruiser.controls.pitch = -0.6
	var recovered := false
	for i in range(1200):
		await get_tree().physics_frame
		if not cruiser.snapshot()["stalled"]:
			recovered = true
			break
	_check(recovered, "推杆后改出失速")
	cruiser.queue_free()

	# ── D2 段：满油门平飞收敛（D-031：最大平飞 ≈50 m/s，必须低于 VNE 55）──
	# 自起一架投到区块高度上限之上（全图无方块，可放心飞）。高度保持带阻尼项
	# （-垂直速度）把富波阻尼掉，速度干净收敛到平衡值；50 m/s 初发贴近平衡点，
	# 不激发大振幅摆动。默认机 1650 N / 240 kg：海平面平衡解 50.4 m/s。
	var full_craft := Aircraft.spawn(
		main_scene, start + Vector3(6.0, 46.0, 24.0), RUNWAY_HEADING)
	full_craft.drive_remotely()
	full_craft.launch(50.0)
	full_craft.controls.throttle = 1.0
	var full_hold_y := full_craft.global_position.y
	for i in range(1200):
		await get_tree().physics_frame
		var fdrift: float = full_craft.global_position.y - full_hold_y
		full_craft.controls.pitch = clampf(
			-fdrift * 0.05 - full_craft.velocity.y * 0.04, -0.35, 0.35)
	var full := full_craft.snapshot()
	_check(full["airspeed"] < AircraftFlight.VNE - 1.0,
		"满油门平飞低于结构极限（%.1f < %.0f m/s）"
			% [full["airspeed"], AircraftFlight.VNE])
	_check(full["airspeed"] > 46.0 and full["airspeed"] < 53.0,
		"满油门平飞收敛钉死 ≈50 m/s（实际 %.1f m/s，D-031）" % full["airspeed"])
	_check(not full["overspeed"], "满油门平飞未标超速")
	full_craft.queue_free()

	# ── F 段：俯冲撞地 → 解体 ────────────────────────────
	# ── F 段：俯冲撞地 → 解体（机头朝 −Z，确保俯冲路径落在常驻区块内）──
	var diver := Aircraft.spawn(main_scene, start + Vector3(20.0, 26.0, 14.0), 0.0)
	diver.drive_remotely()
	diver.launch(12.0)
	diver.crashed.connect(_on_crashed)
	diver.controls.throttle = 1.0
	diver.controls.pitch = -1.0
	for i in range(1800):
		await get_tree().physics_frame
		if diver.is_wrecked():
			break
	_check(diver.is_wrecked(), "俯冲撞地后解体")
	_check(_crash_reasons.size() >= 1, "解体广播了 crashed（原因：%s）"
		% (_crash_reasons[0] if _crash_reasons.size() > 0 else "无"))

	# ── G 段：蓝图驱动飞机（试飞闭环验证）──────────────────
	# 用默认套件蓝图经 from_loadout 造机：体素外观应被构建，且能像默认机一样离地。
	var loadout_bp := Blueprint.new()
	loadout_bp.parts = PartRegistry.default_loadout()
	var loadout := Aircraft.from_loadout(
		main_scene, start, RUNWAY_HEADING, loadout_bp)
	loadout.drive_remotely()
	loadout.crashed.connect(_on_crashed)
	var pm := loadout.get_node_or_null("PartMeshes")
	_check(pm != null and pm.get_child_count() == loadout_bp.parts.size(),
		"蓝图飞机生成体素外观（%d 块 / 零件 %d）"
		% [pm.get_child_count() if pm else 0, loadout_bp.parts.size()])
	# 先落稳在跑道上（spawn 当帧 is_on_floor 尚未被 move_and_slide 置真）。
	await _frames(30)
	_check(loadout.is_on_floor(), "蓝图飞机初始停在跑道上")
	loadout.controls.throttle = 1.0
	var lo_lifted := -1
	for i in range(600):
		await get_tree().physics_frame
		if not loadout.is_on_floor():
			lo_lifted = i
			break
	_check(lo_lifted > 0, "蓝图飞机满油门可离地（第 %d 帧）" % lo_lifted)
	_check(not loadout.is_wrecked(), "蓝图飞机起飞未解体")
	loadout.queue_free()

	# ── G2 段：涡轮发动机套件满油门不解体（P1-1 修复守护）────────────
	# 原 2600 N 涡轮满油门平飞平衡解 63.5 m/s > VNE 55，最贵解锁件必然超速解体。
	# 修复（两者结合）：推力降到 1750 N + Airframe.aggregate 按零件 vne_limit 取下限
	# （后者留给未来更脆零件；涡轮本身不弱于基准 55）。套件 = 默认零件拆下默认
	# 发动机、原位换装涡轮（聚合只求和，位置不影响气动；双发并装仍会超速，属自找）。
	var turbo_parts: Array[PlacedPart] = []
	var engine_cell := Vector3i.ZERO
	for p in PartRegistry.default_loadout():
		if p.data.category == PartData.Category.ENGINE:
			engine_cell = p.cell
		else:
			turbo_parts.append(p)
	turbo_parts.append(PlacedPart.make(PartRegistry.by_id("turbine"), engine_cell))
	var turbo_af := AircraftFlight.Airframe.aggregate(turbo_parts)
	_check(absf(turbo_af.thrust_max - 1750.0) < 0.01,
		"涡轮套件聚合推力 = 1750 N（实际 %.0f N）" % turbo_af.thrust_max)
	_check(absf(turbo_af.mass - 250.0) < 0.01,
		"涡轮套件聚合质量 = 250 kg（实际 %.1f kg）" % turbo_af.mass)
	_check(turbo_af.vne == AircraftFlight.VNE,
		"涡轮件不弱于基准结构限速（整机 VNE 仍 %.0f）" % turbo_af.vne)
	# 满油门平飞 60 s：高度保持带阻尼，逐帧记录峰值空速。「不解体」即蕴含
	# 「全程未触 VNE」——超速 flag 下一帧就触发解体（_check_failure）。
	var turbo_bp := Blueprint.new()
	turbo_bp.parts = turbo_parts
	var turbo := Aircraft.from_loadout(
		main_scene, start + Vector3(-6.0, 46.0, 24.0), RUNWAY_HEADING, turbo_bp)
	turbo.drive_remotely()
	turbo.crashed.connect(_on_crashed)
	var turbo_crashes_before := _crash_reasons.size()
	turbo.launch(50.0)
	turbo.controls.throttle = 1.0
	var turbo_hold_y := turbo.global_position.y
	var turbo_max_v := 0.0
	for i in range(3600):
		await get_tree().physics_frame
		turbo_max_v = maxf(turbo_max_v, float(turbo.snapshot()["airspeed"]))
		var tdrift: float = turbo.global_position.y - turbo_hold_y
		turbo.controls.pitch = clampf(
			-tdrift * 0.05 - turbo.velocity.y * 0.04, -0.35, 0.35)
	var turbo_reason := "无"
	if _crash_reasons.size() > turbo_crashes_before:
		turbo_reason = _crash_reasons[_crash_reasons.size() - 1]
	_check(not turbo.is_wrecked(),
		"涡轮套件满油门 60 s 不解体（峰值空速 %.1f m/s，坠机原因：%s）"
			% [turbo_max_v, turbo_reason])
	_check(turbo_max_v < AircraftFlight.VNE,
		"涡轮全程峰值空速低于 VNE（%.1f < %.0f m/s）" % [turbo_max_v, AircraftFlight.VNE])
	_check(turbo.snapshot()["airspeed"] > 48.0,
		"涡轮满油门收敛在预期带（末速 %.1f m/s，平衡解 ≈52）"
			% turbo.snapshot()["airspeed"])
	turbo.queue_free()

	# ── H 段：键盘 / 鼠标驾驶通路（此前探针全程远程驾驶，键鼠通路零覆盖）──
	# 真实驾驶形态：piloted=true 且 use_player_input=true（不调 drive_remotely），
	# _prepare_input 走 Input.get_axis 读动作；触屏分支在桌面端恒不激活。
	var kb := Aircraft.spawn(main_scene, start + Vector3(6.0, 0.0, 6.0), RUNWAY_HEADING)
	kb.set_piloted(true, player)
	kb.set_engine(true)
	# place() 把机轮放在地面点上方 GROUND_CLEARANCE + 0.05——只等 2 帧机体
	# 仍在空中，空格刹车（controls.brake = jump and on_floor）不成立；且熄火
	# 门控把 W/S 油门锁 0（aircraft._prepare_input 提前 return）。等沉降 + 点火。
	await _frames(14)
	Input.action_press("aircraft_pitch_up")
	await get_tree().physics_frame
	_check(kb.controls.pitch > 0.5, "键盘 ↑ 拉杆产生正俯仰杆量（%.2f）" % kb.controls.pitch)
	Input.action_release("aircraft_pitch_up")
	await get_tree().physics_frame
	_check(kb.controls.pitch < 0.05, "松杆后俯仰回中（%.2f）" % kb.controls.pitch)
	Input.action_press("aircraft_roll_right")
	await get_tree().physics_frame
	_check(kb.controls.roll > 0.5, "键盘 → 产生右滚杆量（%.2f）" % kb.controls.roll)
	Input.action_release("aircraft_roll_right")
	Input.action_press("move_right")
	await get_tree().physics_frame
	_check(kb.controls.yaw > 0.5, "键盘 D 产生右偏航杆量（%.2f）" % kb.controls.yaw)
	Input.action_release("move_right")
	Input.action_press("jump")
	await get_tree().physics_frame
	_check(kb.controls.brake, "空格键触发机轮刹车")
	Input.action_release("jump")
	var thr0 := kb.controls.throttle
	Input.action_press("move_forward")
	await _frames(20)
	_check(kb.controls.throttle > thr0 + 0.05,
		"W 推升油门（%.2f → %.2f）" % [thr0, kb.controls.throttle])
	Input.action_release("move_forward")
	var thr1 := kb.controls.throttle
	Input.action_press("move_back")
	await _frames(20)
	_check(kb.controls.throttle < thr1 - 0.05,
		"S 收低油门（%.2f → %.2f）" % [thr1, kb.controls.throttle])
	Input.action_release("move_back")
	# 鼠标操纵杆：右移 → 右滚、上移 → 抬头（Godot 鼠标 motion 的 y 正方向向下）。
	kb.add_mouse_motion(Vector2(200.0, -200.0))
	await get_tree().physics_frame
	_check(kb.controls.roll > 0.3, "鼠标右移产生右滚杆量（%.2f）" % kb.controls.roll)
	_check(kb.controls.pitch > 0.3, "鼠标上移产生抬头杆量（%.2f）" % kb.controls.pitch)
	kb.set_piloted(false)
	kb.queue_free()

	# ── I 段：试飞闭环端到端（build_screen_probe 只验到信号层，这里验 main 接线）──
	# main._on_test_fly_requested：蓝图 → 放到玩家身前实心面 → 直接登机。
	# 玩家先站到跑道中段（面朝 −Z，沿跑道），试飞机才会落在铺面上。
	player.global_position = Vector3(
		float(origin.x) + STRIP_WIDTH * 0.5,
		float(strip_y) + 3.0,
		float(origin.y) + STRIP_LENGTH * 0.5)
	player.rotation = Vector3.ZERO
	var player_pos_before: Vector3 = player.global_position
	var e2e_bp := Blueprint.new()
	e2e_bp.parts = PartRegistry.default_loadout()
	main_scene.call("_on_test_fly_requested", e2e_bp)
	var fly_craft: Aircraft = player.aircraft()
	_check(fly_craft != null, "试飞请求后玩家直接登机（player.aircraft() 非空）")
	if fly_craft != null:
		_check(fly_craft.get_parent() == main_scene, "试飞机作为 main 子节点生成")
		var to_craft: Vector3 = fly_craft.global_position - player_pos_before
		to_craft.y = 0.0
		_check(to_craft.length() > 8.0 and to_craft.length() < 12.0,
			"飞机生成在玩家身前约 10 m（实际 %.1f m）" % to_craft.length())
		await _frames(30)
		_check(fly_craft.is_on_floor(), "试飞机停在实心面上")
		var cell_u := Vector3i(fly_craft.global_position.floor())
		var block_u := BlockTypes.Block.AIR
		for i in range(6):
			var bb = world.get_block(cell_u - Vector3i(0, i, 0))
			if bb != BlockTypes.Block.AIR:
				block_u = bb
				break
		_check(block_u == BlockTypes.Block.COBBLESTONE,
			"试飞机下方是跑道铺面（block=%d）" % block_u)
		_check(absf(fly_craft._state.airframe.mass - 240.0) < 0.01,
			"试飞气动框 = 蓝图聚合（质量 %.1f kg）" % fly_craft._state.airframe.mass)
		# P2-3：试飞机收回不刷道具。双击 F 的完整链路是「单按先下机 → 窗口期内
		# 再按回收」；试飞机由蓝图拼装、从未消耗库存物品，回收时背包 AIRCRAFT
		# 必须不变（修复前生存模式每轮净 +1，「工坊台试飞→收回」可无限刷）。
		var ac_before := player.inventory.count_item(ItemTypes.AIRCRAFT)
		# 归零上次按 F 时间：保证「单按 → 窗口期内再按」的确定序列，
		# 不依赖探针前文是否碰过 F 键。
		player._last_aircraft_f_ms = 0
		player._handle_aircraft_key()
		_check(player.aircraft() == null, "单按 F 从试飞机下机")
		player._handle_aircraft_key()
		# queue_free 的删除刷新晚于当前帧（踩坑记录）：等一帧物理帧再验存活。
		await get_tree().physics_frame
		_check(not is_instance_valid(fly_craft), "双击 F 收回试飞机（移出世界）")
		_check(player.inventory.count_item(ItemTypes.AIRCRAFT) == ac_before,
			"P2-3：试飞机收回不退物品（背包 %d → %d，防刷道具）"
				% [ac_before, player.inventory.count_item(ItemTypes.AIRCRAFT)])
		# 踩坑记录：queue_free 的删除刷新晚于当前物理帧，同帧同位置再 spawn
		# 会被 depenetration 顶飞——释放后至少等一帧物理帧。
		await get_tree().physics_frame

	# ── J 段：任务遥测接线端到端 + 下机中止（P1-2 修复守护）────────────
	# mission_panel_probe 用合成遥测直喂面板；这里验 main._physics_process 的
	# 真实接线：骑乘 → 组遥测 → hud.feed_mission → 面板 → MissionManager.step。
	hud.set_mission_anchor(Vector3(
		float(origin.x) + STRIP_WIDTH * 0.5, 0.0,
		float(origin.y) + STRIP_LENGTH * 0.5))
	hud.open_mission_panel()
	var panel: MissionPanel = hud._mission_panel
	_check(panel != null and panel.is_open(), "任务面板可打开")
	panel.start_mission(0)
	_check(panel.is_running(), "任务 0（起飞）已开始")
	var mm_before: float = panel._mm.elapsed()
	var tel_craft := Aircraft.spawn(
		main_scene, start + Vector3(-6.0, 0.0, 6.0), RUNWAY_HEADING)
	player.ride_aircraft(tel_craft)
	await _frames(30)
	# 状态块在驾驶中隐藏（D-046，用户要求「登机后1区不显示」）：容器 visible=false，
	# 三个读数随容器一起不可见。显隐断言一律用 is_visible_in_tree()：子节点自己的
	# visible 标记仍为 true，只有「自身 + 祖先链」全可见才算真显示，逐节点断言会假绿。
	_check(not hud._hotbar_bar.is_visible_in_tree(),
		"登机后底部物品栏隐藏（飞行中不放置方块，底部让给飞行 UI）")
	_check(not hud._stats_box.is_visible_in_tree(),
		"登机后左上角状态块隐藏（姓名 + 生命 + 饥饿，飞行中玩家就是飞机本身）")
	_check(not hud._name_label.is_visible_in_tree(), "驾驶中姓名随状态块一起隐藏")
	_check(not hud._hearts.is_visible_in_tree(), "驾驶中生命爱心随状态块一起隐藏")
	_check(not hud._hunger_label.is_visible_in_tree(), "驾驶中饥饿读数随状态块一起隐藏")
	_check(not hud._map_name_label.is_visible_in_tree(),
		"登机后顶部居中世界名隐藏（不贴住飞行面板标题右侧）")
	_check(not hud._minimap.is_visible_in_tree(),
		"登机后右上角小地图（指南针）隐藏（方位交给战术地图与仪表小地图）")
	_check(not hud._mode_label.is_visible_in_tree(), "登机后右上角模式徽章隐藏")
	_check(hud._time_label.is_visible_in_tree(),
		"驾驶中右上角天数/时钟/天气行保留（飞行仍要看得见昼夜与天气）")
	_check(not hud._minimap.is_processing(),
		"驾驶中停掉小地图 _process（不再每 0.6 s 扫一遍地形圆域）")
	var mm_riding: float = panel._mm.elapsed()
	_check(mm_riding > mm_before + 0.2,
		"骑乘时真实遥测喂进任务管理器（elapsed %.2f → %.2f s）"
			% [mm_before, mm_riding])
	# 下机：遥测停喂 + P1-2 修复——任务被 abandon，不再永久卡 RUNNING。
	player.exit_aircraft()
	await _frames(10)
	_check(hud._hotbar_bar.is_visible_in_tree(), "下机后底部物品栏恢复显示")
	_check(hud._stats_box.is_visible_in_tree(), "下机后左上角状态块恢复显示")
	_check(hud._map_name_label.is_visible_in_tree(), "下机后顶部居中世界名恢复显示")
	_check(hud._hunger_label.is_visible_in_tree(), "下机后饥饿读数仍在状态块内可见")
	_check(hud._minimap.is_visible_in_tree(), "下机后右上角小地图（指南针）恢复显示")
	_check(hud._mode_label.is_visible_in_tree(), "下机后右上角模式徽章恢复显示")
	_check(hud._minimap.is_processing(), "下机后小地图 _process 恢复（下机即重采样）")
	_check(absf(panel._mm.elapsed() - mm_riding) < 0.001,
		"下机后遥测停喂，elapsed 定格（%.2f s）" % panel._mm.elapsed())
	_check(not panel.is_running(),
		"下机后任务被中止（P1-2：可再开新任务，不再卡死）")
	hud.close_mission_panel()
	tel_craft.queue_free()
	# 踩坑：queue_free 的删除刷新晚于当前物理帧——同帧在同位置再 spawn 一架，
	# 两具同尺寸碰撞盒会重叠一帧并被 depenetration 顶飞（本段实测被顶起一个
	# 盒高 4.65 m，支撑消失后坠落触发 7.0 解体阈值）。释放后至少等一帧。
	await get_tree().physics_frame

	# ── J2 段：任务奖励端到端 + 防刷（P2-9）────────────────────
	# J 段验「下机中止」；这里验奖励链末端。起飞任务判定「离地 ≥30 m 且空速
	# ≥40 km/h」：照 D2 段惯例把飞机投到全图无方块的净空高度再满油门平飞，
	# 由 main 真实遥测链（骑乘 → snapshot → feed_mission → 面板 → Manager）
	# 判成功——低空滑跑起飞与爬升由 C 段覆盖，这里不重复验气动。
	# 奖励经 mission_reward → HUD 绿宝石入包；再次开始同一任务——仍在空中，
	# 数帧内二次成功，但奖励归零、不再入包（P2-9 守护）。
	var emeralds_before: int = player.inventory.count_item(ItemTypes.EMERALD)
	var rw_craft := Aircraft.spawn(
		main_scene, start + Vector3(-6.0, 46.0, 24.0), RUNWAY_HEADING)
	player.ride_aircraft(rw_craft)
	await _frames(10)
	# 探针写杆位（C/D 段惯例）：只摘输入通路、不动骑乘状态——rider 保留，
	# 万一坠机仍会正常弹射玩家；main 遥测链只认 player.aircraft()，照常透传。
	rw_craft.use_player_input = false
	rw_craft.launch(50.0)
	rw_craft.controls.throttle = 1.0
	hud.open_mission_panel()
	var panel2: MissionPanel = hud._mission_panel
	panel2.start_mission(0)
	_check(panel2.is_running(), "J2：起飞任务已开始")
	var reward_box := {"count": 0, "reward": -1, "repeat": true}
	panel2.mission_reward.connect(func(emeralds: int, _s: bool, r: Dictionary):
		reward_box["count"] += 1
		reward_box["reward"] = emeralds
		reward_box["repeat"] = bool(r.get("repeat", false)))
	# 高度带阻尼保持（D 段写法）：等真实遥测把任务喂成功即止。
	var j2_hold_y := rw_craft.global_position.y
	for i in range(600):
		await get_tree().physics_frame
		if panel2._mm.status != MissionManager.Status.RUNNING:
			break
		var drift: float = rw_craft.global_position.y - j2_hold_y
		rw_craft.controls.pitch = clampf(
			-drift * 0.05 - rw_craft.velocity.y * 0.04, -0.35, 0.35)
	_check(panel2._mm.status == MissionManager.Status.SUCCEEDED,
		"J2：起飞任务经真实遥测判成功（净空 + 满油门）")
	_check(player.inventory.count_item(ItemTypes.EMERALD) == emeralds_before + 5,
		"J2：首次完成 5 绿宝石入包（%d → %d）" % [
			emeralds_before, player.inventory.count_item(ItemTypes.EMERALD)])
	_check(reward_box["count"] == 1 and reward_box["reward"] == 5
		and not reward_box["repeat"], "J2：mission_reward 首次发放且无 repeat 标记")
	var toast_text := hud._toast_label.text if hud._toast_label != null else ""
	_check(toast_text.contains("任务奖励：绿宝石 ×5"),
		"J2：Toast 提示奖励（「%s」）" % toast_text)

	# 防刷：再次开始同一任务——仍在空中，数帧即二次成功，但零发放。
	panel2.start_mission(0)
	_check(panel2.is_running(), "J2：已完成的任务可再次开始")
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(panel2._mm.status == MissionManager.Status.SUCCEEDED,
		"J2：二次完成仍判成功（可反复挑战）")
	_check(player.inventory.count_item(ItemTypes.EMERALD) == emeralds_before + 5,
		"J2（P2-9）：二次完成奖励归零，绿宝石不再入包（仍 %d）" %
			player.inventory.count_item(ItemTypes.EMERALD))
	_check(reward_box["count"] == 2 and reward_box["reward"] == 0
		and reward_box["repeat"],
		"J2（P2-9）：mission_reward 二次发放奖励 0 且带 repeat 标记")
	toast_text = hud._toast_label.text if hud._toast_label != null else ""
	_check(toast_text.contains("不再发放"),
		"J2（P2-9）：Toast 注明本次不再发放（「%s」）" % toast_text)
	# 收尾：传送回跑道面并双清零速度（_state.velocity 每帧覆盖 velocity，只清
	# 节点侧停不住）；空中下机会让玩家从 45 m 坠落，后续段落还要用玩家。
	rw_craft.global_position = start + Vector3(-6.0, 0.0, 2.0)
	rw_craft._state.velocity = Vector3.ZERO
	rw_craft.velocity = Vector3.ZERO
	rw_craft.controls.throttle = 0.0
	rw_craft.controls.pitch = 0.0
	await _frames(30)
	player.exit_aircraft()
	hud.close_mission_panel()
	rw_craft.queue_free()

	# ── K 段：涂装每帧同步（settings_panel_probe 只验面板落盘，这里验在飞飞机）──
	var livery_craft := Aircraft.spawn(
		main_scene, start + Vector3(6.0, 0.0, -6.0), RUNWAY_HEADING)
	livery_craft.drive_remotely()
	await _frames(2)
	_check(livery_craft._model != null, "默认（非蓝图）飞机带程序化机模")
	FlightSettings.current().set_livery(2)
	await get_tree().physics_frame
	_check(livery_craft._model != null and livery_craft._model.livery_index() == 2,
		"改设置后下一帧机身改色（涂装索引 %d）" % livery_craft._model.livery_index())
	var livery_body_mats: Array = livery_craft._model._role_materials.get("body", [])
	var livery_ok := livery_body_mats.size() > 0
	for mat: StandardMaterial3D in livery_body_mats:
		if mat.albedo_color != AircraftLivery.body_of(2):
			livery_ok = false
	_check(livery_ok, "机身材质 albedo 同步为丛林绿")
	FlightSettings.current().set_livery(0)
	livery_craft.queue_free()

	# ── L 段：模态互斥 + 面板期间飞行输入门控（P2-1 / P2-2）────────────
	# P2-1：工坊台与 HUD 面板互斥——两个方向各自带「对照」断言：先证明合成键
	# 事件确实能驱动目标（排除「事件根本不匹配动作」的假阳性），再证互斥。
	# 方向一：HUD 面板打开时，V 键不唤出工坊台。
	hud.set_craft_open(true)
	_check(hud.is_any_panel_open(), "合成台打开时 is_any_panel_open() 为真")
	main_scene._build_screen._unhandled_input(_key(KEY_V))
	_check(not main_scene._build_screen.visible,
		"P2-1：合成台开着按 V 不唤出工坊台（模态栈只允许一层）")
	hud.set_craft_open(false)
	main_scene._build_screen._unhandled_input(_key(KEY_V))
	_check(main_scene._build_screen.visible, "对照：无遮挡时 V 键可唤出工坊台")
	# 方向二：工坊台打开时，HUD 热键（E 合成台）一律让位。
	hud._unhandled_input(_key(KEY_E))
	_check(not (hud._craft_overlay != null and hud._craft_overlay.visible),
		"P2-1：工坊台打开时按 E 不开合成台（HUD 热键让位）")
	main_scene._build_screen.close()
	_check(not main_scene._build_screen.visible, "工坊台可正常关闭")
	# 关面板后恢复：E 键重新能开合成台（证明让位只发生在工坊台打开期间）。
	hud._unhandled_input(_key(KEY_E))
	_check(hud._craft_overlay != null and hud._craft_overlay.visible,
		"对照：工坊台关闭后 E 键恢复打开合成台")
	hud.set_craft_open(false)

	# P2-2：模态面板冻结期间，W/S/A/D/空格不再遥控飞机（修复前骑着飞机开
	# K/O 面板时油门/方向舵/刹车仍实时响应—— aircraft._prepare_input 直接
	# 轮询 Input，看不到面板状态）。
	var gate_craft := Aircraft.spawn(
		main_scene, start + Vector3(6.0, 0.0, 6.0), RUNWAY_HEADING)
	gate_craft.set_piloted(true, player)
	gate_craft.set_engine(true)
	await get_tree().physics_frame
	hud.open_mission_panel()
	_check(player.input_locked, "模态面板打开时玩家被冻结（input_locked）")
	var gate_thr := gate_craft.controls.throttle
	Input.action_press("move_forward")
	Input.action_press("move_right")
	Input.action_press("jump")
	await _frames(10)
	_check(gate_craft.controls.throttle == gate_thr,
		"P2-2：面板打开时 W 推不进油门（%.2f 保持不变）" % gate_thr)
	_check(gate_craft.controls.yaw == 0.0, "P2-2：面板打开时 D 不产生方向舵杆量")
	_check(not gate_craft.controls.brake, "P2-2：面板打开时空格不触发刹车")
	Input.action_release("move_forward")
	Input.action_release("move_right")
	Input.action_release("jump")
	hud.close_mission_panel()
	_check(not player.input_locked, "关闭面板后解除冻结")
	await get_tree().physics_frame
	Input.action_press("move_forward")
	await _frames(10)
	_check(gate_craft.controls.throttle > gate_thr + 0.05,
		"P2-2：关闭面板后 W 恢复加油门（%.2f → %.2f）"
			% [gate_thr, gate_craft.controls.throttle])
	Input.action_release("move_forward")
	gate_craft.set_piloted(false)
	gate_craft.queue_free()
	# 踩坑记录：queue_free 删除刷新晚于当前物理帧——同帧同位置再 spawn 会被
	# depenetration 顶飞。M 段出生点选在跑道另一处（0,+10），错开更保险。
	await get_tree().physics_frame

	# ── M 段：蓝图机外观三项合并修 + 坠机原因播报（P2-6/P2-17/P2-5）────
	# P2-6+P2-17 同文件同函数一次改动修完：零件组悬空 0.85 m（_build_part_
	# visuals 按重心居中、未对齐碰撞盒底）、桨不转/舵不摆（产出未登记进动画
	# 字段）、换涂装无效果（_sync_livery 对 _model==null 早退）。
	# P2-5：坠机只有病句「被坠机打中了」，看不到具体原因。
	var bp := Blueprint.new()
	bp.parts = PartRegistry.default_loadout()
	var bp_craft := Aircraft.from_loadout(
		main_scene, start + Vector3(0.0, 0.0, 10.0), RUNWAY_HEADING, bp)
	await _frames(5)
	_check(bp_craft._model == null and bp_craft._bp_props.size() >= 1,
		"蓝图机走零件外观路径（螺旋桨中继 %d 个）" % bp_craft._bp_props.size())
	# 悬空修复：零件组位移应把最低零件底面锚到碰撞盒底（−GROUND_CLEARANCE）。
	var com: Vector3 = bp.center_of_gravity()
	var min_y := INF
	for p: PlacedPart in bp.parts:
		var c: Vector3 = p.local_pos() - com
		min_y = minf(min_y, c.y - float(p.data.size.y) * 0.5 * PartData.GRID_METERS)
	var mesh_root: Node3D = bp_craft.get_node("PartMeshes")
	var expect_shift: float = -Aircraft.GROUND_CLEARANCE - min_y
	_check(absf(mesh_root.position.y - expect_shift) < 0.001,
		"P2-17：零件组底面锚到碰撞盒底（位移 %.2f，期望 %.2f）"
			% [mesh_root.position.y, expect_shift])
	var bp_bottom: float = bp_craft.global_position.y + mesh_root.position.y + min_y
	var collider_bottom: float = bp_craft.global_position.y \
		+ Aircraft.COLLIDER_CENTER.y - Aircraft.COLLIDER_SIZE.y * 0.5
	_check(absf(bp_bottom - collider_bottom) < 0.01,
		"P2-17：零件组底与碰撞盒底同高（世界差 %.3f m）"
			% absf(bp_bottom - collider_bottom))
	# 螺旋桨动画：满油门数帧，中继绕机头轴累计转角应显著（修复前桨不转）。
	bp_craft.drive_remotely()
	bp_craft.controls.throttle = 1.0
	var prop_before: float = bp_craft._bp_props[0].rotation.z
	await _frames(10)
	var prop_after: float = bp_craft._bp_props[0].rotation.z
	_check(absf(prop_after - prop_before) > 0.5,
		"P2-6：蓝图机螺旋桨随油门旋转（%.2f → %.2f rad）"
			% [prop_before, prop_after])
	# 升降舵动画：拉杆杆量 → 升降舵网格偏转（修复前舵不摆）。
	bp_craft.controls.throttle = 0.0
	bp_craft.controls.brake = true
	bp_craft.controls.pitch = 0.8
	await _frames(3)
	var elevator: MeshInstance3D = bp_craft._bp_elevators[0]
	_check(absf(elevator.rotation.x + 0.4) < 0.01,
		"P2-6：蓝图机升降舵随拉杆偏转（rotation.x = %.2f）" % elevator.rotation.x)
	bp_craft.controls.pitch = 0.0
	bp_craft.controls.brake = false
	# 涂装同步：改设置后下一帧，机身（FUSELAGE）材质 albedo 变涂装 body 色。
	FlightSettings.current().set_livery(2)
	await get_tree().physics_frame
	var body_ok := false
	for i in bp_craft._bp_mats.size():
		if bp_craft._bp_cats[i] != PartData.Category.FUSELAGE:
			continue
		var mat: StandardMaterial3D = bp_craft._bp_mats[i].material_override
		if mat != null and mat.albedo_color == AircraftLivery.body_of(2):
			body_ok = true
	_check(body_ok, "P2-6：蓝图机机身随涂装改色（丛林绿 body）")
	FlightSettings.current().set_livery(0)
	# P2-5：坠机原因播报。骑乘即连接 crashed；wreck 先广播原因再弹射
	# （弹射触发下机 → 连接断开），掉血播报把具体原因合并进去。
	_check(not bp_craft.crashed.is_connected(hud._on_aircraft_crashed),
		"未骑乘时 HUD 不监听该机 crashed（只连自己驾驶的那架）")
	player.ride_aircraft(bp_craft)
	await get_tree().physics_frame
	_check(bp_craft.crashed.is_connected(hud._on_aircraft_crashed),
		"P2-5：骑乘后 HUD 连接该机 crashed")
	hud._last_crash_reason = ""
	bp_craft.wreck("摔得太狠，机身解体")
	await _frames(2)
	var crash_toast := hud._toast_label.text if hud._toast_label != null else ""
	_check(crash_toast.contains("飞机坠毁了") and crash_toast.contains("摔得太狠"),
		"P2-5：坠机播报带具体原因（「%s」）" % crash_toast)
	_check(not bp_craft.crashed.is_connected(hud._on_aircraft_crashed),
		"P2-5：弹射下机后 HUD 断开连接（连接不泄漏）")
	bp_craft.queue_free()
	await get_tree().physics_frame

	# ── N 段：残骸坠落 + 鼠标杆单位圆（P2-10 / P2-11）────────────
	# P2-10：wreck 原来把 velocity 置零后 _physics_process 直接 return——
	# 空中解体的残骸悬停 4 秒等消散。现在残骸继续受重力坠落。
	var wreck_craft := Aircraft.spawn(
		main_scene, start + Vector3(6.0, 46.0, 24.0), RUNWAY_HEADING)
	wreck_craft.drive_remotely()
	await get_tree().physics_frame
	var wreck_y0: float = wreck_craft.global_position.y
	wreck_craft.wreck("测试解体")
	await _frames(60)
	var wreck_y1: float = wreck_craft.global_position.y
	_check(wreck_y1 < wreck_y0 - 3.0,
		"P2-10：空中解体后残骸受重力坠落（%.1f → %.1f m，1 s 下落 %.1f）"
			% [wreck_y0, wreck_y1, wreck_y0 - wreck_y1])
	wreck_craft.queue_free()
	await get_tree().physics_frame
	# P2-11：鼠标杆分别钳 x/y 时，对角推满总杆量达 √2 ≈ 1.41（滚转与俯仰
	# 同时超订）。改按模长归一到单位圆。
	var stick_craft := Aircraft.spawn(main_scene, start, RUNWAY_HEADING)
	stick_craft.drive_remotely()
	for i in range(20):
		stick_craft.add_mouse_motion(Vector2(200.0, 200.0))
	_check(stick_craft._stick.length() <= 1.001,
		"P2-11：对角推满杆量限幅在单位圆（|%.3f| ≤ 1）" % stick_craft._stick.length())
	_check(absf(stick_craft._stick.x - stick_craft._stick.y) < 0.01
		and stick_craft._stick.x > 0.0,
		"P2-11：归一化保持对角方向（x=y=%.3f）" % stick_craft._stick.x)
	stick_craft.queue_free()
	await get_tree().physics_frame

	_finish()


## A 段：纯气动标定。不建场景、不跑物理，直接验算模型本身。
func _run_flight_model_checks() -> void:
	var af := AircraftFlight.default_airframe()
	var vs := AircraftFlight.stall_speed(AircraftFlight.SEA_LEVEL_DENSITY, af)
	_check(vs > 12.0 and vs < 18.0, "海平面失速速度 12~18 m/s（实际 %.1f，合 %.0f km/h）"
		% [vs, vs * AircraftFlight.MPS_TO_KMH])
	_check(AircraftFlight.lift_coefficient(0.0) == 0.0, "零攻角不产生升力")
	var slope := AircraftFlight.lift_coefficient(0.1) / 0.1
	_check(absf(slope - AircraftFlight.CL_ALPHA) < 0.05, "线性段升力斜率 = CLα（%.2f）" % slope)
	_check(absf(AircraftFlight.lift_coefficient(AircraftFlight.STALL_ALPHA)
		- AircraftFlight.CL_MAX) < 0.02, "临界攻角处恰好达到 CLmax")
	var post := AircraftFlight.lift_coefficient(AircraftFlight.STALL_ALPHA + 0.30)
	_check(post < AircraftFlight.CL_MAX * 0.6,
		"越过临界攻角升力骤降（%.2f < %.2f）" % [post, AircraftFlight.CL_MAX * 0.6])
	_check(AircraftFlight.lift_coefficient(-0.1) < 0.0, "负攻角升力为负（可倒飞）")
	var sea := AircraftFlight.air_density(0.0)
	var high := AircraftFlight.air_density(5000.0)
	_check(sea > high and absf(sea - AircraftFlight.SEA_LEVEL_DENSITY) < 0.001,
		"海平面密度为标准值且随高度衰减（5000 m 处 %.3f）" % high)
	_check(absf(AircraftFlight.air_density(AircraftFlight.DENSITY_SCALE_HEIGHT)
		/ AircraftFlight.SEA_LEVEL_DENSITY - 0.3679) < 0.01, "8500 m 标高密度约为海平面 37%")

	# 超速标志：把状态直接拉到 VNE 之上（平飞够不到，只有俯冲能到）。
	var fast := AircraftFlight.make_state(Vector3(0.0, 3000.0, 0.0))
	fast.velocity = -fast.basis.z * (AircraftFlight.VNE + 5.0)
	AircraftFlight.integrate(fast, AircraftFlight.Controls.new(), 1.0 / 60.0, false)
	_check(fast.overspeed, "超过 VNE 标出结构失效")

	# 配平平飞的载荷系数：攻角取 CL_trim = mg/(q·S) 对应的值，此时升力恰等于重力。
	# （两个坑：① 直接给零攻角会得到 0.05 的读数——平飞不是「零攻角」；
	#   ② 必须放在海平面，3000 m 处空气密度只剩 70%，升力自然只有 0.72 个 g。）
	var level := AircraftFlight.make_state(Vector3.ZERO)
	var trim_speed := 30.0
	level.velocity = Vector3(0.0, 0.0, -trim_speed)
	var q_dyn := 0.5 * AircraftFlight.SEA_LEVEL_DENSITY * trim_speed * trim_speed
	var cl_trim := (af.mass * AircraftFlight.GRAVITY) \
		/ (q_dyn * af.wing_area)
	var alpha_trim := cl_trim / AircraftFlight.CL_ALPHA
	level.basis = Basis.from_euler(Vector3(alpha_trim, 0.0, 0.0))
	AircraftFlight.integrate(level, AircraftFlight.Controls.new(), 1.0 / 60.0, false)
	_check(absf(level.load_factor - 1.0) < 0.1,
		"配平平飞时载荷系数 ≈ 1g（%.2f，配平攻角 %.1f°）"
			% [level.load_factor, rad_to_deg(alpha_trim)])

	# ── D-031 标定值钉死（核对报告：此前为宽区间/弱不等式，改坏数值不一定被抓）──
	_check(AircraftFlight.VNE == 55.0, "结构极限速度 VNE = 55 m/s（D-031 钉死）")
	# 巡航 35 m/s 平飞阻力 ≈815 N：直接用模型 acceleration() 反推——攻角配平后
	# 升力与重力相消、零油门，合加速度即阻力/质量，故 |a|·m 就是阻力（N）。
	var cruise_state := AircraftFlight.make_state(Vector3.ZERO)
	cruise_state.velocity = Vector3(0.0, 0.0, -35.0)
	var q35 := 0.5 * AircraftFlight.SEA_LEVEL_DENSITY * 35.0 * 35.0
	var cl35 := (af.mass * AircraftFlight.GRAVITY) / (q35 * af.wing_area)
	cruise_state.basis = Basis.from_euler(Vector3(cl35 / AircraftFlight.CL_ALPHA, 0.0, 0.0))
	var drag35 := AircraftFlight.acceleration(
		cruise_state, AircraftFlight.Controls.new()).length() * af.mass
	_check(absf(drag35 - 815.0) < 82.0,
		"巡航 35 m/s 平飞阻力 ≈815 N（模型反推 %.0f N，D-031 半油门巡航点）" % drag35)
	# 最大升阻比扫描：L/Dmax = 1/(2·√(cd0·k)) ≈ 8（D-031）。
	var best_ld := 0.0
	for i in range(65):
		var a_ld := float(i) / 64.0 * AircraftFlight.STALL_ALPHA
		var cl_ld := AircraftFlight.lift_coefficient(a_ld)
		best_ld = maxf(best_ld, cl_ld / (af.cd0 + af.induced_k * cl_ld * cl_ld))
	_check(best_ld > 7.0 and best_ld < 9.0,
		"最大升阻比 L/Dmax ≈8（扫描峰值 %.2f，D-031）" % best_ld)
	# 失速速度钉死 13.1 m/s（D-031 目标，容差 0.3）。
	_check(absf(vs - 13.1) < 0.3,
		"海平面失速速度钉死 13.1 m/s（实际 %.2f m/s，合 %.1f km/h）"
			% [vs, vs * AircraftFlight.MPS_TO_KMH])

	# ── P2-8：地面偏航门控 ─────────────────────────────────────
	# 地面满杆偏航只由节点层前轮转向（_apply_ground_forces 的 STEER_RATE）
	# 负责，气动层不再叠杆量偏航——修复前双重叠加 ≈77°/s（YAW_RATE_MAX
	# 31.5°/s + 前轮 45°/s），滑跑里轻点方向舵就冲出跑道。
	var gy := AircraftFlight.make_state(Vector3.ZERO)
	var gc := AircraftFlight.Controls.new()
	gc.yaw = 1.0
	for i in range(30):
		AircraftFlight.integrate(gy, gc, 1.0 / 60.0, true)
	_check(rad_to_deg(gy.yaw_rate) < 5.0,
		"P2-8：地面满杆偏航角速度受气动层门控（30 帧后 %.1f°/s，修复前 ≈31.5）"
			% rad_to_deg(gy.yaw_rate))
	# 空中对照：同样杆量应拿到气动舵效（证明门控只发生在地面）。
	var ay := AircraftFlight.make_state(Vector3(0.0, 200.0, 0.0))
	ay.velocity = -ay.basis.z * 40.0
	var ac := AircraftFlight.Controls.new()
	ac.yaw = 1.0
	for i in range(30):
		AircraftFlight.integrate(ay, ac, 1.0 / 60.0, false)
	_check(rad_to_deg(ay.yaw_rate) > 20.0,
		"P2-8：空中满杆偏航保留气动舵效（30 帧后 %.1f°/s）" % rad_to_deg(ay.yaw_rate))


## 姿态积分三轴符号回归：正滚转杆量 → 右翼下沉、正俯仰杆量 → 机头上仰、
## 正偏航杆量 → 机头右偏。D-031 曾把 pitch 符号写反（拉杆变成压机头），
## 此处把「杆量方向 → 机体响应」钉死，将来改坏 _integrate_attitude 符号立刻被抓。
func _run_attitude_sign_checks() -> void:
	var dt := 1.0 / 60.0
	var rs := AircraftFlight.make_state(Vector3.ZERO)
	rs.velocity = -rs.basis.z * 40.0
	var rc := AircraftFlight.Controls.new()
	rc.roll = 1.0
	for i in range(30):
		AircraftFlight.integrate(rs, rc, dt, false)
	_check(rs.basis.x.y < -0.2,
		"正滚转杆量把右翼压下沉（basis.x.y = %.2f）" % rs.basis.x.y)
	var ps := AircraftFlight.make_state(Vector3.ZERO)
	ps.velocity = -ps.basis.z * 40.0
	var pc := AircraftFlight.Controls.new()
	pc.pitch = 1.0
	for i in range(30):
		AircraftFlight.integrate(ps, pc, dt, false)
	_check((-ps.basis.z).y > 0.2,
		"拉杆（正俯仰杆量）抬机头（仰角 %.1f°）"
			% rad_to_deg(asin(clampf((-ps.basis.z).y, -1.0, 1.0))))
	var ys := AircraftFlight.make_state(Vector3.ZERO)
	ys.velocity = -ys.basis.z * 40.0
	var yc := AircraftFlight.Controls.new()
	yc.yaw = 1.0
	for i in range(30):
		AircraftFlight.integrate(ys, yc, dt, false)
	_check(-ys.basis.z.x > 0.1,
		"右舵（正偏航杆量）把机头转向右（机头 x 分量 %.2f）" % -ys.basis.z.x)


## Phase 1 聚合断言（D-032）：整机特性必须等于零件的求和，数据驱动不失真。
func _run_parts_checks() -> void:
	var parts := PartRegistry.default_loadout()
	var agg := AircraftFlight.Airframe.aggregate(parts)
	_check(absf(agg.mass - 240.0) < 0.01,
		"聚合质量 = Σ零件质量（%.1f kg）" % agg.mass)
	_check(absf(agg.wing_area - 14.0) < 0.01,
		"聚合翼面积 = Σ升力面（%.1f m²）" % agg.wing_area)
	_check(absf(agg.thrust_max - 1650.0) < 0.01,
		"聚合推力 = Σ发动机（%.0f N）" % agg.thrust_max)
	_check(absf(agg.cd0 - 0.075) < 0.001,
		"聚合零升阻力 = 基值 + Σ寄生（%.3f）" % agg.cd0)

	# 重心 = 各零件位置 × 质量的加权平均。
	var com_expected := Vector3.ZERO
	for p in parts:
		com_expected += p.local_pos() * p.data.mass
	com_expected /= agg.mass
	_check(agg.com.distance_to(com_expected) < 0.001,
		"重心 = 质量加权平均（%v）" % agg.com)

	# 升力中心只由升力面决定：应异于重心（机翼在重心前上方、尾翼在后）。
	_check(agg.lift_center.distance_to(agg.com) > 0.01,
		"升力中心异于重心（升力中心 %v，重心 %v）" % [agg.lift_center, agg.com])

	# 拆掉机翼：升力面减少 → 失速速度升高（翅膀越小越「飞不起来」）。
	var no_wing: Array[PlacedPart] = []
	for p in parts:
		if p.data.category != PartData.Category.WING:
			no_wing.append(p)
	var no_wing_af := AircraftFlight.Airframe.aggregate(no_wing)
	_check(no_wing_af.wing_area < agg.wing_area,
		"拆掉机翼后升力面减少（%.1f < %.1f）" % [no_wing_af.wing_area, agg.wing_area])
	var vs_full := AircraftFlight.stall_speed(AircraftFlight.SEA_LEVEL_DENSITY, agg)
	var vs_no_wing := AircraftFlight.stall_speed(AircraftFlight.SEA_LEVEL_DENSITY, no_wing_af)
	_check(vs_no_wing > vs_full,
		"升力面越小失速速度越高（%.1f > %.1f m/s）" % [vs_no_wing, vs_full])

	# 加装一只前机身油箱：总质量上升、重心向油箱（−Z 机头）偏移。
	var heavier: Array[PlacedPart] = []
	heavier.assign(parts)
	heavier.append(PlacedPart.make(PartRegistry.by_id("fuel_tank"), Vector3i(-1, 0, -8)))
	var heavy_af := AircraftFlight.Airframe.aggregate(heavier)
	_check(heavy_af.mass > agg.mass,
		"加装油箱后总质量上升（%.1f > %.1f）" % [heavy_af.mass, agg.mass])
	_check(heavy_af.com.z < agg.com.z,
		"前置油箱把重心拉向机头（%.3f < %.3f）" % [heavy_af.com.z, agg.com.z])

	# 空零件不崩：无升力面时失速速度定义为 0（飞不起来但不除零）。
	var none: Array[PlacedPart] = []
	var empty := AircraftFlight.Airframe.aggregate(none)
	_check(empty.mass == 0.0 and empty.wing_area == 0.0, "空零件聚合为零且不崩")
	_check(AircraftFlight.stall_speed(AircraftFlight.SEA_LEVEL_DENSITY, empty) == 0.0,
		"无升力面时失速速度定义为 0")

	# 闭环一致性：默认套件聚合 = 默认气动框（from_loadout 据此飞得与默认机一致）。
	var bp := Blueprint.new()
	bp.parts = parts
	var af2 := bp.aggregate()
	var def := AircraftFlight.default_airframe()
	_check(absf(af2.mass - def.mass) < 0.01
		and absf(af2.wing_area - def.wing_area) < 0.01
		and absf(af2.thrust_max - def.thrust_max) < 0.01,
		"default_loadout 聚合 = 默认气动框（蓝图闭环一致性）")


## 挑地表最高点最低的候选区，留出尽可能多的净空高度（区块高度上限 64）。
func _pick_strip_origin(world: World) -> Vector2i:
	var best := STRIP_CANDIDATES[0]
	var best_top := 1 << 30
	for candidate: Vector2i in STRIP_CANDIDATES:
		world.ensure_chunks_in_region(
			Vector3i(candidate.x, 0, candidate.y),
			Vector3i(candidate.x + STRIP_WIDTH, 0, candidate.y + STRIP_LENGTH))
		var top := 0
		for x in range(candidate.x, candidate.x + STRIP_WIDTH + 1, 2):
			for z in range(candidate.y, candidate.y + STRIP_LENGTH + 1, 2):
				top = maxi(top, world.get_surface_height(x, z))
		if top < best_top:
			best_top = top
			best = candidate
	return best


## 在候选区铺一条石板跑道，并清掉上方挡住净空的方块。返回跑道顶面所在格。
func _build_strip(world: World, origin: Vector2i) -> int:
	var max_cell := Vector3i(origin.x + STRIP_WIDTH, 0, origin.y + STRIP_LENGTH)
	world.ensure_chunks_in_region(Vector3i(origin.x, 0, origin.y), max_cell)
	var top := 0
	for x in range(origin.x, origin.x + STRIP_WIDTH + 1):
		for z in range(origin.y, origin.y + STRIP_LENGTH + 1):
			top = maxi(top, world.get_surface_height(x, z))
	var y := top + 1
	if y > 58:
		y = 58
	for x in range(origin.x, origin.x + STRIP_WIDTH + 1):
		for z in range(origin.y, origin.y + STRIP_LENGTH + 1):
			world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.COBBLESTONE)
			# 净空 9 格：垂尾顶在跑道面上 6.8 格，须整体清出。
			for h in range(1, 10):
				world.set_block_deferred(Vector3i(x, y + h, z), BlockTypes.Block.AIR)
	world.rebuild_chunks_in_region(Vector3i(origin.x, 0, origin.y), max_cell)
	return y


func _on_stall_changed(stalled: bool) -> void:
	if stalled:
		_stall_event = true


func _on_crashed(reason: String) -> void:
	_crash_reasons.append(reason)


func _frames(count: int) -> void:
	for i in range(count):
		await get_tree().physics_frame


## 合成按键事件（L 段模态互斥用）：keycode 与 physical_keycode 同时置位，
## 覆盖 InputMap 动作事件两种登记方式（InputActions.register 只登记 physical）。
func _key(kc: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = kc
	ev.physical_keycode = kc
	ev.pressed = true
	ev.echo = false
	return ev


func _finish() -> void:
	# 存档还原（D-010 铁律 3）：把探针期间被推进的成就计数/设置写回快照原样，
	# 用户真实进度零污染（life_probe 阶段 S 同款范式）。
	_restore_user_saves()
	if _failed == 0:
		print("FLIGHT_PROBE_OK")
		get_tree().quit(0)
	else:
		print("FLIGHT_PROBE_FAILED count=%d" % _failed)
		get_tree().quit(1)


## 存档隔离（D-010）：快照 / 还原 user:// 文本文件。空串 = 原文件不存在，还原即删除。
func _read_user_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


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


func _restore_user_saves() -> void:
	_write_user_text("user://progress.json", _saved_progress)
	_write_user_text("user://settings.json", _saved_settings)
	# 内存态一并还原：否则 Progress._exit_tree 的 _save() 会把探针推进过的
	# 计数再写一遍盘，文件还原被覆盖（D-010 铁律 3 的实测教训）。
	Progress.counters = _saved_counters.duplicate()
	Progress.states = _saved_states.duplicate()
	Progress._quiz_correct_since_reward = _saved_quiz_streak


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
