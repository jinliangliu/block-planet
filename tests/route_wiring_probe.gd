extends Node
## 航线接线端到端探针（D-066）：绕点（CIRCUIT）任务推进到下一个航点之后，
## HSI/CDI、飞行指引十字与战术地图航线图层必须跟着切到新目标。
##
## 修的缺陷：登机时只注入一次任务锚点，绕点推进后仪表与指引仍指着老目标——
## 玩家不知道下一个点在哪。本探针起真实主场景、真实登机、真实物理帧推进，
## 断言「MissionManager 判定的当前航点」确实被 main._sync_mission_navigation()
## 同步进了仪表与地图（不是只看 RoutePlan 自己算得对）。
##
## 分段：
##   A 起真实主场景 + 登机（沿用 crash_recover_probe / flight_probe 的登机流程）
##   G 退化：未开始任务时，导航目标仍是登机注入的任务锚点（同步函数不许改坏）
##   B 开始 CIRCUIT 任务 → 仪表导航目标 = 航点 0（渲染坐标）
##   C 把机体钉到航点 0 上方 → 任务推进 → 仪表目标必须切到航点 1（修复直接证据）
##   D 战术地图航线图层：航点数一致、当前序号 = 推进后的序号
##   E 去重短路不误伤：连续多帧目标不变时导航仍正确、去重键不漂移
##   F 下机：战术地图航线清空、仪表导航清除、去重键归零
##
## 导航目标读法（本探针的关键接口）：
##   HUD.instrument_hud() → FlightInstrumentHUD.instruments_ref() → FlightInstruments
##   → 直读 _nav_target（set_navigation 写入的渲染坐标真相）。FlightInstruments
##   只暴露 nav_active/nav_name/nav_bearing_deg/nav_distance_m，没有目标 getter，
##   故取这条字段；同时用 nav_active 与 nav_name（"航点 i/n"）交叉佐证，
##   避免「只读一个字段」得出的假绿，并与战术地图状态互证。
##
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/route_wiring_probe.tscn

## 登机 / 稳定 / 推进 / 去重观察 / 下机的拍数（物理帧；世界出生预填期单帧较长，
## 留足余量，其余段落靠「条件达成即退出」的轮询而非固定拍数换算时间）。
const BOARD_FRAMES := 30
const SETTLE_FRAMES := 10
const ADVANCE_FRAMES := 60
const STEADY_FRAMES := 20
const EXIT_FRAMES := 10
## 钉位离地净空（m）：地形噪声基准之上留出树/村屋/机场设施的余量，
## 又远低于世界高度上限 256 格 = 128 m（aircraft.gd:67）。
const HOVER_ABOVE_SURFACE := 45.0

var _failed := 0
var _restored := false


func _ready() -> void:
	# 看门狗：脚本错误猝杀协程时强制退出（否则进程挂起、存档还原不执行）；
	# 存档还原另有 _exit_tree 安全网兜底（D-010）。
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		push_warning("route_wiring_probe: 看门狗超时（120 s），强制退出")
		_finish())
	await _run()


func _run() -> void:
	# 存档隔离（D-010 铁律 3）：必须在实例化 main.tscn 之前——暖机帧也会触发
	# Events（region_entered 等）写盘。
	SaveGuard.snapshot()
	var prev_pick := GameState.needs_region_pick
	GameState.needs_region_pick = false

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	await _process_frames(60)

	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")
	var hud: HUD = main_scene.get_node("UI") as HUD
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	_check(world != null and player != null and hud != null,
		"main 三件套可用（World/Player/HUD）")
	if world == null or player == null or hud == null:
		_finish()
		return

	# ── A 段：起真实主场景 + 登机 ────────────────────────
	var craft_park: Vector3 = main_scene._craft_park
	_check(craft_park != Vector3.ZERO,
		"A0 主场景记录了初始停机位（park=%s）" % str(craft_park))
	if craft_park == Vector3.ZERO:
		_finish()
		return
	var craft := Aircraft.spawn(main_scene, craft_park, PI)
	# 先给玩家一个非零 yaw：进近引导的 looking_at 在「玩家-目标」共线时告警
	#（crash_recover_probe 同款守卫，探针默认 yaw=0 会踩）。
	player.rotation.y = 0.8
	player.ride_aircraft(craft)
	await _physics_frames(BOARD_FRAMES)
	_check(player.is_riding(), "A1 玩家已登机（真实主场景 + 真实骑乘）")
	_check(is_instance_valid(craft) and not craft.is_wrecked(),
		"A2 登机后飞机完好（落位未撞玩家、未解体）")
	var ih: FlightInstrumentHUD = hud.instrument_hud()
	var fi: FlightInstruments = null
	if ih != null:
		fi = ih.instruments_ref()
	var tm: FlightTacticalMap = hud._tactical_map
	_check(ih != null and fi != null, "A3 仪表 HUD 与其数据层对象均可用")
	_check(tm != null, "A4 战术地图对象可用")
	if not is_instance_valid(craft) or ih == null or fi == null:
		_finish()
		return

	# ── G 段：退化（未开始任何任务）─────────────────────
	# 无 CIRCUIT 任务时 current_mission_waypoints() 返回空，_sync_mission_navigation
	# 只清自己的状态就返回，不许动仪表——登机注入的任务锚点必须原样留存。
	var anchor_world: Vector3 = main_scene._mission_anchor
	await _physics_frames(SETTLE_FRAMES)
	_check(fi.nav_active, "G1 无任务时仪表导航仍处于激活态（登机锚点已注入）")
	_check(fi._nav_target.distance_to(world.to_render(anchor_world)) < 0.01,
		"G2 无任务时导航目标仍是登机注入的任务锚点（目标 %s，锚点 %s）"
			% [str(fi._nav_target.round()), str(world.to_render(anchor_world).round())])
	_check(tm == null or tm._route_points.is_empty(),
		"G3 无任务时战术地图没有航线图层")
	_check(String(main_scene._nav_sync_key) == "",
		"G4 无任务时去重键为空（不残留上次任务的 key）")

	# ── B 段：开始 CIRCUIT 任务 ─────────────────────────
	var panel: MissionPanel = hud._mission_panel
	_check(panel != null, "B0 任务面板已建")
	if panel == null:
		_finish()
		return
	panel.start_mission(1)
	_check(panel.is_running(), "B1 绕点任务已开始（面板进入 RUNNING）")
	var mm: MissionManager = panel.mission_manager()
	var is_circuit := mm != null and mm.mission != null \
		and mm.mission.type == MissionData.Type.CIRCUIT
	_check(is_circuit, "B2 进行中的任务类型为 CIRCUIT")
	if not is_circuit or mm == null:
		_finish()
		return
	# 新增信号（D-066）：推进后带 index 与 pos，这里顺带验它真的发了。
	var adv_box := {"n": 0, "index": -1}
	mm.waypoint_advanced.connect(func(index: int, _pos: Vector3) -> void:
		adv_box["n"] += 1
		adv_box["index"] = index)
	var wp: Array[Vector3] = _vec3_list(hud.current_mission_waypoints())
	_check(wp.size() >= 2, "B3 绕点任务至少两个航点（实际 %d）" % wp.size())
	if wp.size() < 2:
		_finish()
		return
	await _physics_frames(SETTLE_FRAMES)
	_check(hud.current_mission_waypoint_index() == 0,
		"B4 任务起始序号为 0（实际 %d）" % hud.current_mission_waypoint_index())
	_check(fi.nav_active
			and fi._nav_target.distance_to(world.to_render(wp[0])) < 0.01,
		"B5 仪表导航目标 = 航点 0（目标 %s，航点 0 渲染坐标 %s）"
			% [str(fi._nav_target.round()), str(world.to_render(wp[0]).round())])
	_check(fi.nav_name == "航点 1/%d" % wp.size(),
		"B6 导航标签标注当前航点序号（实际「%s」）" % fi.nav_name)

	# ── C 段：飞越航点 0 → 导航目标必须切到航点 1 ──────────
	# 钉住机体：每帧 place() 回摆到航点 0 正上方（place 内部另加 GROUND_CLEARANCE）。
	# 为什么不「飞过去」：靠气动保持高度要跑几十帧，坠落/撞山会触发解体 → 任务
	# 判失败 → 航点数组清空，C/D/E 三段会被坠机连带污染，分不清是接线坏还是摔了。
	# 钉位后 main 每帧读到的水平位置恒等于航点 0，飞越判定只由 MissionManager 裁决。
	craft.use_player_input = false
	# 航点是世界坐标，钉位要落到渲染坐标（机体 global_position 的口径），
	# 与仪表侧 to_render 后的目标同一空间；origin=0 时两者恒等。
	var wp0_render: Vector3 = world.to_render(wp[0])
	var surface_y: int = world.get_surface_height(roundi(wp0_render.x), roundi(wp0_render.z))
	var pin := Vector3(wp0_render.x, float(surface_y) + HOVER_ABOVE_SURFACE, wp0_render.z)
	var idx_after := 0
	var lost := false
	for _i in range(ADVANCE_FRAMES):
		if not is_instance_valid(craft):
			lost = true
			break
		craft.place(pin, PI)
		await get_tree().physics_frame
		if not is_instance_valid(craft) or craft.is_wrecked():
			lost = true
			break
		idx_after = hud.current_mission_waypoint_index()
		if idx_after >= 1:
			break
	_check(not lost, "C0 推进期间飞机始终可用且未解体（钉位 %s）" % str(pin.round()))
	_check(idx_after >= 1,
		"C1 飞越航点 0 后任务推进到下一航点（序号 %d，判定半径 %.1f m）"
			% [idx_after, mm.mission.radius()])
	_check(int(adv_box["n"]) >= 1 and int(adv_box["index"]) == idx_after,
		"C2 waypoint_advanced 已发出且带推进后序号（n=%d index=%d）"
			% [int(adv_box["n"]), int(adv_box["index"])])
	if idx_after >= 1:
		_check(fi.nav_active, "C3 推进后仪表导航仍激活")
		_check(fi._nav_target.distance_to(world.to_render(wp[1])) < 0.01,
			"C4 推进后仪表导航目标已切成航点 1（目标 %s，航点 1 %s，航点 0 %s）"
				% [str(fi._nav_target.round()),
					str(world.to_render(wp[1]).round()),
					str(world.to_render(wp[0]).round())])
		_check(fi._nav_target.distance_to(world.to_render(wp[0])) > 1.0,
			"C5 导航目标不再是老目标航点 0（缺陷修复的直接证据）")
		_check(fi.nav_name == "航点 2/%d" % wp.size(),
			"C6 导航标签同步推进到序号 2（实际「%s」）" % fi.nav_name)

	# ── D 段：战术地图航线图层 ─────────────────────────
	if tm != null:
		_check(tm._route_points.size() == wp.size(),
			"D1 战术地图航线点数 = 任务航点数（%d vs %d）"
				% [tm._route_points.size(), wp.size()])
		_check(tm._route_current_index == idx_after,
			"D2 战术地图当前航段序号 = 任务当前序号（%d vs %d）"
				% [tm._route_current_index, idx_after])
		var first_ok := false
		if tm._route_points.size() == wp.size() and not tm._route_points.is_empty():
			first_ok = tm._route_points[0].distance_to(wp[0]) < 0.01
		_check(first_ok, "D3 航线首点即任务航点 0（图层存世界坐标，未多转一次）")

	# ── E 段：去重短路不误伤 ───────────────────────────
	# 目标不变时 _sync_mission_navigation 走 key 短路直接返回，仪表不许被清空、
	# 也不许退回旧值；同时去重键本身不许漂移（漂移说明每帧都在重算/重绘）。
	var key_before: String = main_scene._nav_sync_key
	_check(key_before != "", "E0 去重键已写入（key=%s）" % key_before)
	for _i in range(STEADY_FRAMES):
		if not is_instance_valid(craft):
			break
		craft.place(pin, PI)
		await get_tree().physics_frame
	_check(is_instance_valid(fi) and fi.nav_active,
		"E1 连续多帧目标不变时导航仍激活")
	_check(is_instance_valid(fi)
			and fi._nav_target.distance_to(world.to_render(wp[1])) < 0.01,
		"E2 连续多帧目标不变时导航目标仍为航点 1（目标 %s）"
			% str(fi._nav_target.round()))
	_check(hud.current_mission_waypoint_index() == idx_after,
		"E3 观察期内任务序号未再变动（仍 %d）" % hud.current_mission_waypoint_index())
	_check(String(main_scene._nav_sync_key) == key_before,
		"E4 去重键保持不变（短路命中，未逐帧重绘）")

	# ── F 段：下机清理 ────────────────────────────────
	# 先把飞机摆回初始停机位再下机：钉位在 45 m 高空，直接下机会让玩家从高空
	# 坠落（flight_probe J2 段同款守卫），摔伤/死亡会把 F 段的清理断言搅混。
	if is_instance_valid(craft):
		craft.place(craft_park, PI)
		await _physics_frames(EXIT_FRAMES)
	player.exit_aircraft()
	await _physics_frames(EXIT_FRAMES)
	_check(not player.is_riding(), "F1 已下机")
	_check(tm == null or tm._route_points.is_empty(),
		"F2 下机后战术地图航线已清空（剩余 %d 点）"
			% (tm._route_points.size() if tm != null else -1))
	_check(is_instance_valid(fi) and not fi.nav_active,
		"F3 下机后仪表导航已清除（nav_active=false）")
	_check(String(main_scene._nav_sync_key) == "",
		"F4 下机后去重键归零（下次登机首点不会被误判为无变化）")

	GameState.needs_region_pick = prev_pick
	_finish()


## HUD 的航点数组是 Array（元素 Variant），取成静态类型 Array[Vector3] 再用，
## 避免把 Variant 直接喂给 Vector3 形参（GDScript 会对这类调用报警告）。
func _vec3_list(src: Array) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for item: Variant in src:
		if item is Vector3:
			out.append(item as Vector3)
	return out


func _process_frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _physics_frames(n: int) -> void:
	for _i in range(n):
		await get_tree().physics_frame


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("PASS: %s" % msg)
	else:
		_failed += 1
		print("FAIL: %s" % msg)


func _finish() -> void:
	if _restored:
		return
	_restored = true
	SaveGuard.restore()
	print("ROUTE_WIRING_PROBE_%s" % ("OK" if _failed == 0 else "FAILED"))
	get_tree().quit(0 if _failed == 0 else 1)


func _exit_tree() -> void:
	# D-010 安全网：协程被脚本错误猝杀时末尾还原不执行，退出期再兜一层。
	SaveGuard.restore()
