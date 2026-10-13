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
const STRIP_WIDTH := 10
## 跑道长度 64 格：满油门滑跑到抬轮速度约 21 格，余量充足。
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
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
	GameState.needs_region_pick = false

	_run_flight_model_checks()
	_run_parts_checks()

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
	# 机身放大后碰撞盒长 15.6 格、宽 6.6 格，故横向取跑道中线、
	# 纵向留出机尾到跑道起点的余量，保证整机都在铺面上。
	var start := Vector3(float(origin.x) + 5.0, surface + 0.1,
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
	_check(roll_distance > 2.0 and roll_distance < float(STRIP_LENGTH),
		"滑跑距离落在跑道内（%.1f m）" % roll_distance)
	var liftoff := craft.snapshot()
	_check(liftoff["airspeed"] >= liftoff["stall_speed"] * 0.95,
		"离地空速不低于失速速度（%.1f / %.1f m/s）"
			% [liftoff["airspeed"], liftoff["stall_speed"]])

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
	_check(cruise["kmh"] > 95.0 and cruise["kmh"] < 155.0,
		"半油门平飞速度收敛在巡航带（%.0f km/h）" % cruise["kmh"])
	_check(not cruise["stalled"], "巡航状态未失速")
	_check(not cruiser.is_wrecked(), "巡航过程未解体")

	# ── E 段：爬升 → 持续拉杆失速 → 推杆改出 ─────────────
	var climb_start_y: float = cruiser.global_position.y
	cruiser.controls.throttle = 1.0
	cruiser.controls.pitch = 0.6
	for i in range(360):
		await get_tree().physics_frame
	var climbed: float = cruiser.global_position.y - climb_start_y
	_check(climbed > 5.0, "满油门拉杆可以爬升（+%.1f m）" % climbed)

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


func _finish() -> void:
	if _failed == 0:
		print("FLIGHT_PROBE_OK")
		get_tree().quit(0)
	else:
		print("FLIGHT_PROBE_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
