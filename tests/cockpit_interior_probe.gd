extends Node
## 3D 座舱内装纯逻辑探针（D-065，无头）：L1 环绕框 + L2 仪表台底板 + L3 杆手。
##
## 为什么只用无头逻辑断言：几何观感（视差、遮挡关系、比例）无头查不出来，那部分
## 交给窗口截图目检（tests/cockpit_interior_shot.gd）。本探针锁的是**不看画面
## 就会悄悄坏掉**的契约，每一条都对应一次真实踩坑或一次设计决策：
##   A 装配与预算：内装必须挂在 Aircraft 的**直接子节点**（相机只遍历一层），
##     盒体 39 个（几何预算闸，超了就是有人偷偷加件）、材质共享 9 个（逐盒新建
##     材质会把 draw call 打成 39 份 distinct）、全部不投影。
##   B 可见性状态机：内装极性**与面板相反**（内视=true 时显示）。追尾/后视/地图
##     必须隐藏，自由观察（座舱底）必须显示——L1/L3 的价值只在环顾低头时兑现。
##   C 蓝图机：按契约不建任何几何（节点在树上但零子节点，三条件同时成立）。
##   D L3 方向符号：拉杆朝飞行员、右滚杆顶朝 +X、右舵右脚前——符号反了观感全错，
##     而且不会报错。
##   E 微颤幅度：有颤但幅度受控（引擎关掉必须归零，否则杆会永远抖）。
##   F 杆不挡面板：低头看仪表台时握把不能压住读数。
##   G 相机贴在眼位上（R1 闸）：座舱相机的指数阻尼对匀速目标有稳态滞后 v/rate，
##     修前 50 m/s 巡航时相机落在眼位后方 12.09 m——3D 面板距眼只有 0.85 m，
##     滞后十几米会把面板缩到 1/14，「与 2D 簇重合」在数学上就不可能。这条闸
##     不修必 FAIL。
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/cockpit_interior_probe.tscn

const PROBE_PAD := preload("res://tests/probe_pad.gd")
## 盒体预算（L1 22 + L2 12 + L3 5）。分层不写进断言：分层是文档口径，改分层
## 不该红；总数才是预算闸。
const BOX_BUDGET := 39
const MATERIAL_BUDGET := 9
## 相机-眼位容差（m）。D-097 起座舱内视位置抖动收敛为 0（COCKPIT_SHAKE_SCALE=0.0）：
## 单轴峰值 SHAKE_AMP×1.5×COCKPIT_SHAKE_SCALE 由 D-075 的 0.030 m 降为 0，三轴
## 合成抖动偏移亦为 0，探针容差对该分量只松不紧，仍 PASS。
## 容差仍取 0.15——比真实偏移大 3 倍、比修前的 12 m 小 240 倍，回归拦得住。
## 吸附判据容差（m）：取 2.0，因为无头环境 process(20~30 Hz) 与 physics(60 Hz) 错拍，
## 采样点必然落在两次相机更新之间，误差 ≈「若干物理步的位移」，实测 0.1~0.6 m 毛刺，
## 且随帧调度波动。判据的真正目标是拦「座舱仍走位移阻尼」这个 **39 m** 量级的回归——
## 2.0 m 仍有 20 倍余量，而把容差压到 0.05 只会得到一条随机红绿的 flaky 闸。
const CAM_SNAP_TOL := 2.0

var _fails := 0
var _craft: Aircraft = null
var _interior: CockpitInterior = null
var _player: Player = null
var _cam: AircraftCamera = null
var _restored := false


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		_fails += 1
		print("FAIL: ", msg)


func _wait(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


func _wait_physics(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


func _ready() -> void:
	await _run()


func _run() -> void:
	SaveGuard.snapshot()
	GameState.needs_region_pick = false
	GameState.current_region = RegionAtlas.ASIA
	FlightSettings.set_current(FlightSettings.for_difficulty(FlightSettings.Difficulty.NORMAL))

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	await _wait(120)

	var hud: HUD = main_scene.get_node("UI")
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	await _wait(20)

	_player = main_scene.get_node("Player")
	var world: World = main_scene.get_node("World")
	var pad := PROBE_PAD.prepare(world, _player)
	await _wait_physics(12)
	var spawn_pos: Vector3 = pad["spawn"]
	_craft = Aircraft.spawn(main_scene, spawn_pos, PI)
	await _wait_physics(2)
	_player.ride_aircraft(_craft)
	_craft.drive_remotely()
	for i in range(300):
		await get_tree().physics_frame
		if not is_instance_valid(_craft):
			break
		if _craft.is_on_floor() and _craft.velocity.length() < 0.5:
			break
	await _wait_physics(6)
	if not is_instance_valid(_craft) or _craft.is_wrecked():
		_fail_and_quit("就位阶段机体解体（落位/平台问题，先查 probe_pad）")
		return
	_cam = _player.flight_camera

	_check_assembly()
	if _interior == null:
		_fail_and_quit("内装未装配，后续断言无意义")
		return
	await _check_state_machine()
	_check_stick()
	_check_tremor()
	_check_clearance()
	await _check_camera_eye()
	await _check_blueprint(main_scene, spawn_pos)

	GameState.needs_region_pick = true
	SaveGuard.restore()
	_restored = true
	print("COCKPIT_INTERIOR_TEST_%s" % ("OK" if _fails == 0 else "FAILED"))
	get_tree().quit(0 if _fails == 0 else 1)


## ── A 装配与预算 ────────────────────────────────────────────
func _check_assembly() -> void:
	# 只查一层子节点：相机的 _set_exterior_hidden 只遍历 _craft.get_children()，
	# 挂深层则状态机不驱动它（不报错，只是永远不亮/不灭）。
	# 按**类型**找而不是按节点名：脚本类 new() 出来的节点名由引擎决定，按名字
	# find_child 会在改名/加前缀时静默 false（探针假红）。
	for child: Node in _craft.get_children():
		if child is CockpitInterior:
			_interior = child as CockpitInterior
			break
	var names := []
	for child: Node in _craft.get_children():
		names.append(child.name)
	_check(_interior != null,
		"A1 内装挂在 Aircraft 的直接子节点上（实测子节点：%s）" % str(names))
	if _interior == null:
		return
	var boxes: Array[Node] = _interior.find_children("*", "MeshInstance3D", true, false)
	_check(boxes.size() == BOX_BUDGET,
		"A2 盒体数 = %d（实测 %d，超了是有人偷偷加件）" % [BOX_BUDGET, boxes.size()])
	var mats := {}
	var shadow_on := 0
	for node: Node in boxes:
		var mi := node as MeshInstance3D
		if mi.material_override != null:
			mats[mi.material_override] = true
		if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			shadow_on += 1
	_check(mats.size() == MATERIAL_BUDGET,
		"A3 共享材质 %d 个（实测 %d，逐盒新建会把 draw call 打成散材质）"
			% [MATERIAL_BUDGET, mats.size()])
	_check(shadow_on == 0, "A4 全部不投影（座舱内无投影收益，省一遍 shadow pass）")
	_check(_interior.position.is_equal_approx(AircraftCamera.COCKPIT_OFFSET),
		"A5 内装原点 = 相机眼位 %s（眼位一改内装整体跟着走）"
			% str(AircraftCamera.COCKPIT_OFFSET))
	# L2 派生关系：仪表台枢轴必须等于面板中心，倾角必须与面板同源。
	var dash := _interior.find_child("Dash", true, false) as Node3D
	_check(dash != null
			and dash.position.is_equal_approx(CockpitPanel.PANEL_POS - AircraftCamera.COCKPIT_OFFSET),
		"A6 仪表台枢轴 = 面板中心（眼位相对），搬面板自动跟随")
	_check(dash != null
			and absf(dash.rotation.x - deg_to_rad(CockpitPanel.PANEL_TILT_DEG)) < 1e-4,
		"A7 仪表台与面板同倾角 %.1f°（不同源会看见两块板错开）"
			% CockpitPanel.PANEL_TILT_DEG)
	var plate := _interior.find_child("Plate", true, false) as MeshInstance3D
	var plate_box: BoxMesh = plate.mesh as BoxMesh if plate != null else null
	# 边宽读内装自己的派生常量，不写 0.18 这个魔数——否则调 RIM 探针会假红。
	_check(plate_box != null
			and absf(plate_box.size.x
				- (CockpitPanel.PANEL_W + CockpitInterior.DASH_RIM * 2.0)) < 1e-3,
		"A8 承托板宽 = 面板宽 + 两侧边（RIM %.2f m，板必须包住面板）"
			% CockpitInterior.DASH_RIM)
	_check(_interior.is_base_visible(), "A9 普通机 is_base_visible = true")


## ── B 可见性状态机（极性：内视=true 显示，与面板相反）──────
func _check_state_machine() -> void:
	var cases := [
		["登机默认第一人称", true],
		["切追尾", false],
		["回第一人称", true],
		["自由观察（座舱底）", true],
		["退出自由观察", true],
		["后视", false],
		["战术地图", false],
	]
	# 顺序执行：set_mode 会同步调 apply_cockpit_interior，帧末再看结果。
	_cam.set_mode(AircraftCamera.ViewMode.FIRST_PERSON)
	await _wait(2)
	_check(_interior.visible == true and _cam.is_cockpit_view(),
		"B1 %s → 内装显示" % cases[0][0])
	_cam.set_mode(AircraftCamera.ViewMode.CHASE)
	await _wait(2)
	_check(not _interior.visible and not _cam.is_cockpit_view(), "B2 %s → 内装隐藏" % cases[1][0])
	_cam.set_mode(AircraftCamera.ViewMode.FIRST_PERSON)
	await _wait(2)
	_check(_interior.visible, "B3 %s → 内装显示" % cases[2][0])
	_cam.set_free_look(true)
	await _wait(2)
	_check(_interior.visible and _cam.is_cockpit_view(),
		"B4 %s → 内装显示（2D 簇此刻自动隐藏，内装是唯一座舱层）" % cases[3][0])
	_cam.set_free_look(false)
	await _wait(2)
	_check(_interior.visible, "B5 %s → 内装显示" % cases[4][0])
	_cam.set_mode(AircraftCamera.ViewMode.REAR)
	await _wait(2)
	_check(not _interior.visible, "B6 %s → 内装隐藏" % cases[5][0])
	_cam.set_map_view(true)
	await _wait(2)
	_check(not _interior.visible, "B7 %s → 内装隐藏" % cases[6][0])
	_cam.set_map_view(false)
	_cam.set_mode(AircraftCamera.ViewMode.FIRST_PERSON)
	await _wait(2)


## ── D L3 方向符号（反向即观感全错，且不会报错）──────────────
func _check_stick() -> void:
	var dt := 1.0 / 60.0
	_interior.update_stick_input(1.0, 0.0, 0.0, 0.0, false, false, 0.0, dt)
	var sa := _interior.stick_angles()
	_check(sa.x > 0.15, "D1 pitch=+1（拉杆）→ 杆绕 +X 正转 %.2f rad（朝飞行员）" % sa.x)
	_interior.update_stick_input(0.0, 1.0, 0.0, 0.0, false, false, 0.0, dt)
	sa = _interior.stick_angles()
	_check(sa.y < -0.15, "D2 roll=+1（右滚）→ 杆绕 +Z 负转 %.2f rad（杆顶朝右）" % sa.y)
	_interior.update_stick_input(0.0, 0.0, 1.0, 0.0, false, false, 0.0, dt)
	var po := _interior.pedal_offsets()
	_check(po.x > 0.03 and po.y < -0.03,
		"D3 yaw=+1（右舵）→ 左踏后 %.3f m / 右踏前 %.3f m" % [po.x, po.y])


## ── E 微颤幅度 ──────────────────────────────────────────────
func _check_tremor() -> void:
	var dt := 1.0 / 60.0
	var lo := INF
	var hi := -INF
	for i in range(60):
		_interior.update_stick_input(0.0, 0.0, 0.0, 0.5, false, true, 0.0, dt)
		var v := _interior.stick_angles().x
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var span := hi - lo
	_check(span > 1e-4 and span <= 0.03,
		"E1 引擎运转 + 50% 油门 → 杆有颤动但幅度受控（极差 %.4f rad ≤ 0.03）" % span)
	lo = INF
	hi = -INF
	for i in range(60):
		_interior.update_stick_input(0.0, 0.0, 0.0, 0.5, false, false, 0.0, dt)
		var v := _interior.stick_angles().x
		lo = minf(lo, v)
		hi = maxf(hi, v)
	_check(hi - lo < 1e-4, "E2 引擎熄火 → 颤动归零（极差 %.6f）" % (hi - lo))


## ── F 杆不挡面板（低头读表时握把不能压读数）──────────────
func _check_clearance() -> void:
	var grip := _interior.find_child("StickGrip", true, false) as MeshInstance3D
	if grip == null:
		_check(false, "F0 找不到 StickGrip 节点（命名契约变了）")
		return
	var grip_box: BoxMesh = grip.mesh as BoxMesh
	# 用机体局部坐标做算术：内装原点=眼位，机体局部才是「机头 −Z」的直观系。
	var inv := _craft.global_transform.affine_inverse()
	var grip_top: Vector3 = inv * (grip.global_transform * Vector3(0.0, grip_box.size.y * 0.5, 0.0))
	# 眼 → 面板下沿的视线，在握把所在 z 处的高度。
	var tilt := Basis(Vector3.RIGHT, deg_to_rad(CockpitPanel.PANEL_TILT_DEG))
	var panel_low: Vector3 = CockpitPanel.PANEL_POS \
		+ tilt * Vector3(0.0, -CockpitPanel.PANEL_H * 0.5, 0.0)
	var eye := AircraftCamera.COCKPIT_OFFSET
	var t := (eye.z - grip_top.z) / (eye.z - panel_low.z)
	var sight_y := eye.y + (panel_low.y - eye.y) * t
	_check(sight_y - grip_top.y >= 0.15,
		"F1 低头视线在杆处高 %.3f m、握把顶 %.3f m → 净空 %.3f m（≥0.15）"
			% [sight_y, grip_top.y, sight_y - grip_top.y])


## ── G 相机贴在眼位上（R1 闸）────────────────────────────────
## 只做**瞬移吸附**这一种判据，因为它是确定性的、与帧率无关：
##   把机体瞬移到一个新位置，两个 process 帧内相机必须贴回眼位。
## 旧实现走指数阻尼（rate=4，alpha≈0.065/帧），瞬移 45 m 后两个帧只走掉 ~6 m，
## 还剩 ~39 m —— 一测就红，且不会像「巡航 steady-state」那样被采样口径干扰。
##
## 为什么不用「巡航中相机-眼位距离」当判据：`get_tree().process_frame` 在节点
## `_process` **之前**发出，采样必然读到上一帧的相机，而机体已走完若干物理步；
## 无头环境 process 只有 20~30 Hz 而物理固定 60 Hz，误差会集中在「n 个物理步的
## 位移」上（46 m/s 时每步 0.77 m，实测中位数可到 5 m），那是指标口径问题，
## 不是相机缺陷。同一事实在窗口运行（process=physics=60）下恒为 ≈0。
func _check_camera_eye() -> void:
	_check(_cam.is_cockpit_view(), "G0 座舱段 is_cockpit_view 为真（吸附只对座舱两模式生效）")
	# 三个方向各瞬移一次：只测「吸附」，不受速度/采样影响。
	var probes := [
		["水平前跳 45 m", Vector3(0.0, 0.0, 45.0)],
		["垂直爬升 45 m", Vector3(0.0, 45.0, 0.0)],
		["横向侧跳 45 m", Vector3(45.0, 0.0, 0.0)],
	]
	for item: Array in probes:
		_craft.place(_craft.global_position + (item[1] as Vector3), PI)
		# 4 帧不是 2 帧：place() 之后机体已开始受重力/推力积分，两帧内相机虽已
		# 吸附到眼位，但采样点落在两次更新之间会带上一帧的位移（实测 0.16 m）。
		# 判据本身仍是「吸附」——旧阻尼在同样帧数下还剩 ~39 m。
		await _wait(4)
		var eye: Vector3 = _craft.global_transform * AircraftCamera.COCKPIT_OFFSET
		var err := _cam.global_position.distance_to(eye)
		_check(err <= CAM_SNAP_TOL,
			"G %s 后相机贴回眼位（偏差 %.3f m ≤ %.2f；旧阻尼此时 ≈39 m）"
				% [item[0], err, CAM_SNAP_TOL])


## ── C 蓝图机不建内装几何 ─────────────────────────────────────
func _check_blueprint(main_scene: Node, spawn_pos: Vector3) -> void:
	# 横向错开 10 m 落位：不能落在当前这架飞机身上（碰撞盒 15.6 m 长，重叠会被
	# 物理首帧分离顶起来解体）。
	var bp := Blueprint.new()
	bp.parts = PartRegistry.default_loadout()
	var at := Vector3(spawn_pos.x + 10.0, spawn_pos.y, spawn_pos.z + 10.0)
	var bp_craft := Aircraft.from_loadout(main_scene, at, PI, bp)
	await _wait_physics(2)
	_player.ride_aircraft(bp_craft)
	bp_craft.drive_remotely()
	await _wait_physics(6)
	var bp_interior: CockpitInterior = null
	for child: Node in bp_craft.get_children():
		if child is CockpitInterior:
			bp_interior = child as CockpitInterior
			break
	# 三条同时成立才算契约成立：节点在树上（装配逻辑没漏）、零子节点（不建几何）、
	# 不可见（永不对玩家显形）。
	_check(bp_interior != null
			and bp_interior.interior_box_count() == 0
			and not bp_interior.is_base_visible()
			and not bp_interior.visible,
		"C1 蓝图机：节点在树上但零几何、永不可见（三条件同时成立）")
	var bp_panel: CockpitPanel = null
	for child: Node in bp_craft.get_children():
		if child is CockpitPanel:
			bp_panel = child as CockpitPanel
			break
	_check(bp_panel != null and not bp_panel.visible,
		"C2 蓝图机 3D 面板仍隐藏（反转只对有机模的机生效）")


func _fail_and_quit(reason: String) -> void:
	_check(false, reason)
	SaveGuard.restore()
	_restored = true
	print("COCKPIT_INTERIOR_TEST_FAILED")
	get_tree().quit(1)


func _exit_tree() -> void:
	# D-010 安全网：协程猝死时末尾还原不会执行，退出期再兜一层（幂等）。
	if not _restored:
		_restored = true
		SaveGuard.restore()
