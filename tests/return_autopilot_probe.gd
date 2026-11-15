extends Node
## 返航自动驾驶探针（D-098）：构造式喂帧 + 反向对照。
##
## A 段（纯逻辑，不进场景树）：直接 new 一份 ReturnAutopilot，逐档喂 step() 的
##   航向偏差/高度/速度/距离，断言四档输出方向与限幅、arrived 阈值、takeover()
##   边界、VNE/失速油门方向与纵向配平方向。控制器是纯 RefCounted，不碰 Autoload。
## B 段（真实 main.tscn）：起主场景、登机、开 CIRCUIT 任务，验证 _return_active
##   为 true 时导航同步段整段挂起、一次性设的机场目标不被任务航点覆写；反向
##   对照（_return_active=false）证明「不挂起时目标确实会被覆写」，闸非空。
## C 段（复用 B 段 main.tscn）：构造式喂帧摆出 1000 m 起距 / |nav_dev|≈170°
##   掉头工况，调 return_to_airport() 断言全链路置位，喂 ≥120 物理帧断言
##   |nav_dev| 朝目标收敛；反向对照（仅置 _return_active、不激活 autopilot）
##   偏差不收敛 ⇒ 证明收敛确由自动驾驶带来。静态落码，引擎验证待放行。
##
## 隔离：B/C 段实例化 main.tscn 前 SaveGuard.snapshot()、退出前 restore()（D-010）。
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/return_autopilot_probe.tscn

const AP = preload("res://scripts/flight/return_autopilot.gd")

const BOARD_FRAMES := 30
const SETTLE_FRAMES := 10
const STEADY_FRAMES := 20
const WARM_FRAMES := 60
# C 段：≥120 物理帧（取 180 ≈ 3 s；55 m/s × 3 s = 165 m < 1000 m 不误触发 arrived）。
const TURN_FRAMES := 180
const TURN_START_DIST_M := 1000.0
const C_DEV_DEG := 170.0
const CONVERGE_MIN_DEG := 3.0
const CRUISE_MPS := 30.0

var _failed := 0
var _restored := false
var _prev_pick := true


func _ready() -> void:
	# 看门狗：协程被脚本错误猝杀时强制收尾（否则存档还原不执行）。
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		push_warning("return_autopilot_probe: 看门狗超时（120 s），强制退出")
		_finish())
	await _run()


func _run() -> void:
	SaveGuard.snapshot()
	_run_controller_checks()
	await _run_suspension_checks()
	GameState.needs_region_pick = _prev_pick
	_finish()


## ── A 段：控制器纯逻辑断言 ───────────────────────────────────
func _run_controller_checks() -> void:
	var ap = AP.new()
	# 常量守卫：增益/边界取值被引程钉住，防止误改后断言跟着漂。
	_check(is_equal_approx(AP.VNE, 55.0), "A0 VNE==55.0（与 AircraftFlight.VNE 一致）")
	_check(is_equal_approx(AP.STALL_SPEED, 13.1), "A0b STALL_SPEED==13.1")
	_check(is_equal_approx(AP.ARRIVE_DIST_M, 150.0), "A0c ARRIVE_DIST_M==150.0")
	_check(AP.MAX_BANK_RAD > 0.0 and AP.MAX_BANK_RAD < PI * 0.5,
		"A0d MAX_BANK_RAD 在 (0, 90°) 内（温和坡度）")
	# 四档方向：dev>0 → roll>0（右转），dev<0 → roll<0（左转），dev=0 → 0。
	var r0 := _step(ap, 0.0)
	_check(absf(float(r0["roll"])) < 1e-6, "A1 dev=0 → roll≈0")
	var rp10 := _step(ap, 10.0)
	_check(float(rp10["roll"]) > 0.0, "A2 dev=+10 → roll>0（右转）")
	var rn10 := _step(ap, -10.0)
	_check(float(rn10["roll"]) < 0.0, "A3 dev=-10 → roll<0（左转）")
	var rp90 := _step(ap, 90.0)
	_check(float(rp90["roll"]) > 0.0 and float(rp90["roll"]) <= 1.0,
		"A4 dev=+90 → roll>0 且 ≤1（限幅）")
	var rp180 := _step(ap, 180.0)
	_check(float(rp180["roll"]) > 0.0 and float(rp180["roll"]) <= 1.0,
		"A5 dev=+180 → roll>0 且 ≤1（掉头不飙杆）")
	# A5 已把掉头方向锁定为 +1；A6 测的是「另起一次掉头」的对称性，
	# 不 reset 就会沿用旧方向，测到的将是锁定而非对称。
	ap.reset()
	var rn180 := _step(ap, -180.0)
	_check(float(rn180["roll"]) < 0.0 and float(rn180["roll"]) >= -1.0,
		"A6 dev=-180 → roll<0 且 ≥-1（掉头对称）")
	# 全部输出限幅：roll/pitch/yaw ∈ [-1,1]，throttle ∈ [0,1]。
	for dev: float in [0.0, 10.0, -10.0, 90.0, -90.0, 180.0, -180.0]:
		var res := _step(ap, dev)
		_check(float(res["roll"]) >= -1.0 and float(res["roll"]) <= 1.0,
			"A7 roll∈[-1,1] dev=%.0f" % dev)
		_check(float(res["pitch"]) >= -1.0 and float(res["pitch"]) <= 1.0,
			"A8 pitch∈[-1,1] dev=%.0f" % dev)
		_check(float(res["yaw"]) >= -1.0 and float(res["yaw"]) <= 1.0,
			"A9 yaw∈[-1,1] dev=%.0f" % dev)
		_check(float(res["throttle"]) >= 0.0 and float(res["throttle"]) <= 1.0,
			"A10 throttle∈[0,1] dev=%.0f" % dev)
	# arrived 阈值（闭区间）。
	_check(bool(_step(ap, 0.0, 0.0, 0.0, 60.0, 60.0, 35.0,
		AP.ARRIVE_DIST_M)["arrived"]), "A11 dist=阈值 → arrived=true")
	_check(not bool(_step(ap, 0.0, 0.0, 0.0, 60.0, 60.0, 35.0,
		AP.ARRIVE_DIST_M + 1.0)["arrived"]), "A12 dist=阈值+1 → arrived=false")
	_check(bool(_step(ap, 0.0, 0.0, 0.0, 60.0, 60.0, 35.0, 10.0)["arrived"]),
		"A13 dist=10 → arrived=true")
	# takeover 边界（严格 >）。
	var t := AP.TAKEOVER_STICK
	_check(not AP.takeover([0.0, 0.0, 0.0]), "A14 全零杆 → 不接管")
	_check(not AP.takeover([t, 0.0, 0.0]), "A15 |杆|=阈值 → 不接管（严格大于）")
	_check(AP.takeover([t + 0.01, 0.0, 0.0]), "A16 超阈值 → 接管")
	_check(AP.takeover([0.0, -(t + 0.01), 0.0]), "A17 负向超阈值 → 接管")
	_check(AP.takeover([0.0, 0.0, t + 0.01]), "A18 yaw 超阈值 → 接管")
	_check(not AP.takeover([]), "A19 空数组 → 不接管")
	# 油门方向：巡航基准、VNE 收油、失速加油，且单调。
	var cruise := AP.THROTTLE_CRUISE
	var c_norm := _step(ap, 0.0, 0.0, 0.0, 60.0, 60.0, 35.0, 500.0)
	_check(is_equal_approx(float(c_norm["throttle"]), cruise),
		"A20 巡航速度油门 = THROTTLE_CRUISE")
	var vne := _step(ap, 0.0, 0.0, 0.0, 60.0, 60.0, AP.VNE, 500.0)
	_check(float(vne["throttle"]) < cruise,
		"A21 速度=VNE → 收油（throttle < cruise）")
	var over := _step(ap, 0.0, 0.0, 0.0, 60.0, 60.0, AP.VNE + 10.0, 500.0)
	_check(float(over["throttle"]) <= float(vne["throttle"]) + 1e-6,
		"A22 超 VNE → 油门不回升（单调收油）")
	var stall := _step(ap, 0.0, 0.0, 0.0, 60.0, 60.0, AP.STALL_SPEED, 500.0)
	_check(float(stall["throttle"]) > cruise,
		"A23 速度=STALL_SPEED → 加油（throttle > cruise）")
	var slow := _step(ap, 0.0, 0.0, 0.0, 60.0, 60.0, 5.0, 500.0)
	_check(float(slow["throttle"]) >= float(stall["throttle"]) - 1e-6,
		"A24 更低速 → 油门不低于失速点（单调加油）")
	# 纵向方向：低于目标高度拉杆、高于目标高度推杆。
	var climb := _step(ap, 0.0, 0.0, 0.0, 20.0, 60.0, 35.0, 500.0)
	_check(float(climb["pitch"]) > 0.0, "A25 低于目标高度 → 拉杆(pitch>0)")
	var descend := _step(ap, 0.0, 0.0, 0.0, 100.0, 60.0, 35.0, 500.0)
	_check(float(descend["pitch"]) < 0.0, "A26 高于目标高度 → 推杆(pitch<0)")
	# 阻尼参与：偏航率阻尼收杆、已有坡度超目标反向回平。
	var plain := _step(ap, 10.0, 0.0, 0.0, 60.0, 60.0, 35.0, 500.0)
	var damped := _step(ap, 10.0, 0.0, 0.5, 60.0, 60.0, 35.0, 500.0)
	_check(float(damped["roll"]) < float(plain["roll"]),
		"A27 偏航率阻尼使 roll 减小（防过冲）")
	var banked := _step(ap, 0.0, 0.2, 0.0, 60.0, 60.0, 35.0, 500.0)
	_check(float(banked["roll"]) < 0.0,
		"A28 当前坡度>目标坡度 → 反向压杆回平")
	# ── 掉头方向锁定（2026-11-16 引擎实测证伪后补，WF15 判据）──
	# 构造 wrapf 反屈序列：+170 → -173 → -155 → +100 → -10，
	# 锁定期间杆量方向必须保持不变，解锁后才交回常规比例控制。
	var lap = AP.new()
	var l0 := _step(lap, 170.0)
	_check(float(l0["roll"]) > 0.0, "A29 dev=+170 → 锁定右转（roll>0）")
	_check(float(_step(lap, -173.0)["roll"]) > 0.0,
		"A30 wrapf 反屈到 -173 → 杆量仍为右转（方向锁定生效）")
	_check(float(_step(lap, -155.0)["roll"]) > 0.0,
		"A31 仍在锁定区 |dev|>150 → 方向不翻转")
	_check(float(_step(lap, 100.0)["roll"]) > 0.0,
		"A32 |dev|<110 解锁后 dev=+100 → 常规右转")
	_check(float(_step(lap, -10.0)["roll"]) < 0.0,
		"A33 解锁后 dev=-10 → 左转（常规比例控制恢复）")
	var rap = AP.new()
	var r0b := _step(rap, -170.0)
	_check(float(r0b["roll"]) < 0.0, "A34 dev=-170 → 锁定左转（roll<0）")
	_check(float(_step(rap, 173.0)["roll"]) < 0.0,
		"A35 反向 wrapf 翻到 +173 → 仍为左转（对称）")
	rap.reset()
	_check(float(_step(rap, 170.0)["roll"]) > 0.0,
		"A36 reset() 后可重新选向右转（跨次激活不污染）")
	_check(AP.TURN_LATCH_DEG > AP.TURN_RELEASE_DEG,
		"A37 锁定阈值 > 解锁阈值（迟滞区间非空）")


## 构造一帧中性飞行态，调 step() 取杆量字典（构造式喂帧）。
func _step(ap, dev: float, bank: float = 0.0, yaw_rate: float = 0.0,
		alt: float = 60.0, tgt_alt: float = 60.0, spd: float = 35.0,
		dist: float = 500.0) -> Dictionary:
	var out: Dictionary = ap.step(dev, bank, yaw_rate, alt, tgt_alt, spd, dist, 0.016)
	return out


## ── B 段：_return_active 挂起导航同步（真实主场景 + 反向对照）──
func _run_suspension_checks() -> void:
	_prev_pick = GameState.needs_region_pick
	GameState.needs_region_pick = false
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	await _process_frames(WARM_FRAMES)
	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")
	var hud: HUD = main_scene.get_node("UI") as HUD
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	_check(world != null and player != null and hud != null,
		"B0 main 三件套可用（World/Player/HUD）")
	if world == null or player == null or hud == null:
		return
	var craft_park: Vector3 = main_scene._craft_park
	_check(craft_park != Vector3.ZERO, "B0b 主场景记录了初始停机位")
	if craft_park == Vector3.ZERO:
		return
	var craft := Aircraft.spawn(main_scene, craft_park, PI)
	player.rotation.y = 0.8
	player.ride_aircraft(craft)
	await _physics_frames(BOARD_FRAMES)
	_check(player.is_riding(), "B1 玩家已登机（真实主场景 + 真实骑乘）")
	var ih: FlightInstrumentHUD = hud.instrument_hud()
	var fi: FlightInstruments = null
	if ih != null:
		fi = ih.instruments_ref()
	_check(ih != null and fi != null, "B2 仪表 HUD 与数据层可用")
	if fi == null:
		return
	# 开 CIRCUIT 任务，让 _sync_mission_navigation 有航点可注入。
	var panel: MissionPanel = hud._mission_panel
	_check(panel != null, "B2b 任务面板已建")
	if panel == null:
		return
	panel.start_mission(1)
	_check(panel.is_running(), "B3 CIRCUIT 任务已运行")
	var wp: Array = hud.current_mission_waypoints()
	_check(not wp.is_empty(), "B3b 任务返回至少一个航点")
	if wp.is_empty() or not (wp[0] is Vector3):
		return
	var wp0: Vector3 = wp[0] as Vector3
	var wp0_render: Vector3 = world.to_render(wp0)
	var anchor_render: Vector3 = world.to_render(main_scene._mission_anchor)
	# 飞机停在地面不飞：任务航点不推进，wp0 始终是当前目标。
	craft.use_player_input = false

	# ① 反向对照（不挂起）：一次性设机场目标 + 清去重键，喂帧后任务同步
	#    必须把它覆写成航点 0——先证明「会被覆写」这条因果真实存在（非空闸）。
	main_scene._return_active = false
	main_scene._nav_sync_key = ""
	hud.set_flight_navigation(anchor_render, "机场/任务")
	await _physics_frames(SETTLE_FRAMES)
	_check(fi.nav_active and fi._nav_target.distance_to(wp0_render) < 0.01,
		"B4 反向对照：不挂起时任务同步把机场目标覆写成航点 0")

	# ② 挂起：_return_active=true，一次性设机场目标 + 清去重键，喂多帧。
	#    守卫整段跳过 _sync_mission_navigation，目标必须锁定机场不被覆写。
	main_scene._return_active = true
	main_scene._nav_sync_key = ""
	hud.set_flight_navigation(anchor_render, "机场/任务")
	await _physics_frames(STEADY_FRAMES)
	_check(fi.nav_active and fi._nav_target.distance_to(anchor_render) < 0.01,
		"B5 挂起期间目标仍是机场锚点（任务同步未覆写）")
	_check(fi._nav_target.distance_to(wp0_render) > 0.01,
		"B5b 挂起期间目标未被改成航点 0")

	# ③ 取消挂起（恢复同步）：目标再次被任务覆写成航点 0。
	main_scene._return_active = false
	main_scene._nav_sync_key = ""
	await _physics_frames(SETTLE_FRAMES)
	_check(fi._nav_target.distance_to(wp0_render) < 0.01,
		"B6 取消挂起后同步恢复，目标重新被覆写成航点 0")

	# ── C 段：return_to_airport() 端到端全链路 + 收敛 / 反向对照（WF15 判据）──
	# 2026-11-16 首次引擎实测证伪：nav_dev 在 ±180° 反屈点跳符号，控制器把
	# 目标坡度从 +25° 翻成 -25°，飞机左右摇摆，自动驾驶组仅比对照组多转
	# 1.13° ⇒ ReturnAutopilot 补「掉头方向锁定」后才谈得上自动飞回。
	# trace 为 D-010 取证闸：断言失败先打印实测值证伪推断，禁止盲改代码。
	var c_anchor := world.to_render(main_scene._mission_anchor)
	_setup_turn_state(craft, c_anchor)
	var c_dev_start := _nav_dev_deg(craft, c_anchor)
	var c_h0 := _heading_vec(craft)
	_check(absf(absf(c_dev_start) - C_DEV_DEG) < 10.0,
		"C0 构造态：|nav_dev|≈170°（背对机场的掉头工况）")
	var flat_start := Vector3(craft.global_position.x - c_anchor.x, 0.0,
		craft.global_position.z - c_anchor.z).length()
	_check(flat_start >= TURN_START_DIST_M,
		"C0b 起距≥1000 m（避开 ARRIVE_DIST_M=150 近场立即解除）")

	main_scene.return_to_airport()
	_check(main_scene._return_active, "C1 return_to_airport() → _return_active==true")
	_check(craft.is_autopilot_active(), "C2 飞机 autopilot 已激活（全链路接通）")
	var ih2: FlightInstrumentHUD = hud.instrument_hud()
	var fd2 = ih2._fd if ih2 != null else null
	_check(fd2 != null and is_instance_valid(fd2) and fd2.return_active,
		"C3 HUD 转发 → FlightDirector.return_active 已置位（引导/按钮文案唯一驱动）")
	_check(fi.nav_active and fi._nav_target.distance_to(c_anchor) < 0.01,
		"C4 一次性设定的导航目标 == 机场渲染坐标")

	# D-010 取证闸：断言失败先打印实测值证伪推断，禁止盲改代码。
	_trace("C-start", craft, c_anchor)
	await _physics_frames(TURN_FRAMES / 2)
	_trace("C-mid", craft, c_anchor)
	await _physics_frames(TURN_FRAMES - TURN_FRAMES / 2)
	var c_dev_end := _nav_dev_deg(craft, c_anchor)
	var c_turned := rad_to_deg(c_h0.angle_to(_heading_vec(craft)))
	_trace("C-end", craft, c_anchor)
	print("[C calc] dev_start=%.2f dev_end=%.2f turned=%.2f" % [
		c_dev_start, c_dev_end, c_turned])
	_check(absf(c_dev_start) - absf(c_dev_end) >= CONVERGE_MIN_DEG,
		"C5 |nav_dev| 朝目标收敛（按 N 后飞机真的开始转向）")
	_check(c_turned >= CONVERGE_MIN_DEG,
		"C5b 机头水平朝向确实改变（排除纯平移造成的偏差变化）")
	_check(craft.is_autopilot_active(),
		"C6 喂帧期间 autopilot 未提前解除（未误触发 arrived/失速/接管）")

	# 反向对照：仅置 _return_active（不激活 autopilot），同样 170° 偏航、喂同样帧数。
	main_scene._cancel_return()
	_setup_turn_state(craft, c_anchor)
	main_scene._return_active = true
	_check(not craft.is_autopilot_active(),
		"C7 反向对照：_return_active 已置但飞机 autopilot 未激活")
	var r_dev_start := _nav_dev_deg(craft, c_anchor)
	var r_h0 := _heading_vec(craft)
	_trace("R-start", craft, c_anchor)
	await _physics_frames(TURN_FRAMES / 2)
	_trace("R-mid", craft, c_anchor)
	await _physics_frames(TURN_FRAMES - TURN_FRAMES / 2)
	var r_dev_end := _nav_dev_deg(craft, c_anchor)
	var r_turned := rad_to_deg(r_h0.angle_to(_heading_vec(craft)))
	_trace("R-end", craft, c_anchor)
	print("[R calc] dev_start=%.2f dev_end=%.2f turned=%.2f" % [
		r_dev_start, r_dev_end, r_turned])
	_check(absf(r_dev_start) - absf(r_dev_end) < CONVERGE_MIN_DEG,
		"C8 反向对照：不激活 autopilot 时 |nav_dev| 不收敛")
	# 引擎实测证伪「无自动驾驶机头不动」：自然飘转（风向标/辅助稳定）实测
	# 12.34°，故改用相对判据，才真正证伪「收敛只是物理漂移」。
	_check(c_turned > r_turned + CONVERGE_MIN_DEG,
		"C8b 自动驾驶组机头转向幅度显著大于无自动驾驶组（≥+3°）")
	_check(absf(c_dev_end) < absf(r_dev_end) - CONVERGE_MIN_DEG,
		"C9 收敛确由自动驾驶带来（终点偏差显著小于无自动驾驶组）")
	main_scene._cancel_return()


func _process_frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _physics_frames(n: int) -> void:
	for _i in range(n):
		await get_tree().physics_frame


## ── C 段辅助：把飞机摆成「离机场 ≥1000 m、|nav_dev|≈170°」的掉头工况 ──
## 复用 B 段既有的 use_player_input=false（脚本直写路径）：_prepare_input 早退
## 不碰 controls，_apply_autopilot 的 live 判据恒假 ⇒ 从根上跳过 takeover 判定
## （headless 下 Input/杆量残留都不会误解除自动驾驶），而物理积分照常运行。
func _setup_turn_state(craft, anchor: Vector3) -> void:
	craft.clear_autopilot()
	craft.use_player_input = false
	var start := anchor + Vector3(0.0, AP.CRUISE_ALT_M, TURN_START_DIST_M)
	craft.global_position = start
	craft._state.position = start
	# 目标在 -Z 方向（bearing=180°）；令 heading=bearing-C_DEV_DEG=10°，机头
	# 几乎背对机场。Basis.from_euler(Y,θ) 下 heading=θ+180，故 θ=heading+180。
	var to_h := Vector3(anchor.x - start.x, 0.0, anchor.z - start.z)
	var nav_bearing := rad_to_deg(atan2(to_h.x, to_h.z))
	var heading0 := nav_bearing - C_DEV_DEG
	craft._state.basis = Basis.from_euler(
		Vector3(0.0, deg_to_rad(heading0 + 180.0), 0.0))
	var fwd: Vector3 = -craft._state.basis.z
	craft._state.velocity = fwd * CRUISE_MPS
	craft.velocity = craft._state.velocity
	craft._state.roll_rate = 0.0
	craft._state.pitch_rate = 0.0
	craft._state.yaw_rate = 0.0
	craft._state.stalled = false
	craft._state.stall_warning = false
	craft.controls.roll = 0.0
	craft.controls.pitch = 0.0
	craft.controls.yaw = 0.0
	craft.controls.brake = false
	craft.controls.throttle = AP.THROTTLE_CRUISE


## 复算 HSI 口径 nav_dev_deg：与 aircraft.gd:_apply_autopilot 及
## flight_instruments.gd:267-268 的 bearing/heading/dev 公式逐字一致。
func _nav_dev_deg(craft, target: Vector3) -> float:
	# craft 是无类型 Variant（Aircraft.spawn 返回值），其属性访问在编译期无类型；
	# 右侧减法 / 取 basis 列若用 := 推断会触发 Parse Error
	# 「Cannot infer the type ... because the value doesn't have a set type」，
	# 故三处一律显式标注 Vector3（坑 #33 同族，见 _setup_turn_state:302）。
	var to_target: Vector3 = target - craft.global_position
	to_target.y = 0.0
	var nav_bearing := fposmod(
		rad_to_deg(atan2(to_target.x, to_target.z)), 360.0)
	var fwd: Vector3 = -craft._state.basis.z
	var heading := fposmod(rad_to_deg(atan2(fwd.x, fwd.z)), 360.0)
	return wrapf(nav_bearing - heading, -180.0, 180.0)


## 机头水平朝向单位向量：angle_to 只反映姿态旋转，排除平移造成的 bearing 变化。
func _heading_vec(craft) -> Vector3:
	var n: Vector3 = -craft._state.basis.z
	return Vector3(n.x, 0.0, n.z).normalized()


## D-010 取证闸：C 段断言失败时打印真实物理状态，先证伪推断再改代码。
## 只读，不改任何 controls / state，也不计入 PASS。
func _trace(tag: String, craft, target: Vector3) -> void:
	var bank_rad: float = -asin(clampf(
		float(craft._state.basis.x.y), -1.0, 1.0))
	var dist_m: float = Vector3(
		float(craft.global_position.x) - target.x, 0.0,
		float(craft.global_position.z) - target.z).length()
	print("[%s] dev=%.2f bank=%.2f roll=%.3f yaw_rate=%.3f pitch=%.3f thr=%.2f" % [
		tag, _nav_dev_deg(craft, target), rad_to_deg(bank_rad),
		float(craft.controls.roll), float(craft._state.yaw_rate),
		float(craft.controls.pitch), float(craft.controls.throttle)])
	print("[%s] spd=%.1f alt=%.1f dist=%.1f ground=%s ap=%s pos=%s" % [
		tag, float(craft._state.airspeed), float(craft.global_position.y), dist_m,
		str(craft.is_on_floor()), str(craft.is_autopilot_active()),
		str(craft.global_position)])


func _finish() -> void:
	if _restored:
		return
	_restored = true
	SaveGuard.restore()
	print("RETURN_AUTOPILOT_PROBE_%s" % ("OK" if _failed == 0 else "FAILED"))
	get_tree().quit(0 if _failed == 0 else 1)


func _exit_tree() -> void:
	# D-010 安全网：协程被脚本错误猝杀时末尾还原不执行，退出期再兜一层。
	SaveGuard.restore()


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
