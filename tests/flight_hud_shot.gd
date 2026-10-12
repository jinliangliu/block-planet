extends Node
## 飞行仪表盘取证：驾驶飞机经「地面滑跑 → 空中巡航 → 失速告警」三个状态，
## 每个状态截一张图（HUD 飞行面板入镜），并把面板文案与 Aircraft.snapshot()
## 逐项比对——仪表与物理必须同源，不能各算一套。
## 另核对面板显隐：未登机 / 已下机时应当隐藏。
## 需窗口运行，勿加 --headless。
## 运行：Godot_v4.6.3-stable_win64_console.exe --path . res://tests/flight_hud_shot.tscn

const SHOT_DIR := "res://tmp"
const STRIP_CANDIDATES := [
	Vector2i(300, 300),
	Vector2i(300, 600),
	Vector2i(600, 300),
	Vector2i(600, 600),
]
const STRIP_WIDTH := 10
const STRIP_LENGTH := 64
## 巡航目标离地高度（m）。
const CRUISE_ALT := 40.0
## 单阶段等待上限（秒），超时即失败，避免探针卡死。
const PHASE_TIMEOUT := 12.0

var _craft: Aircraft
var _player: Player
var _hud: HUD
var _world: World
var _fails := 0


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS ", message)
	else:
		_fails += 1
		print("FAIL ", message)


func _ready() -> void:
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(90):
		await get_tree().process_frame
	_world = main_scene.get_node("World")
	_player = main_scene.get_node("Player")
	_hud = main_scene.get_node("UI")
	if _hud._map_selector != null and _hud._map_selector.is_open():
		_hud.close_map_selector()
	GameState.needs_region_pick = false
	for i in range(30):
		await get_tree().process_frame

	var origin := _pick_strip_origin(_world)
	var strip_y := _build_strip(_world, origin)
	var surface := float(strip_y + 1)
	var craft_pos := Vector3(
		float(origin.x) + 5.0, surface + 0.1, float(origin.y) + 10.0)
	_craft = Aircraft.spawn(main_scene, craft_pos, PI)
	_craft.crashed.connect(func(reason: String):
		print("DBG CRASH reason=", reason, " vel=", _craft.velocity,
			" on_floor=", _craft.is_on_floor(), " agl=", _craft.snapshot()["altitude_agl"]))

	# 未登机：仪表盘应当隐藏。
	for i in range(10):
		await get_tree().physics_frame
	_check(not _hud._flight_panel.visible, "未登机时飞行仪表盘隐藏")

	# 登机并交给探针驾驶（drive_remotely = 纳入控制通路但输入全部外部写）。
	_player.ride_aircraft(_craft)
	_craft.drive_remotely()
	for i in range(10):
		await get_tree().physics_frame
	print("DBG ride: hud_player_is_player=", _hud._player == _player,
		" player.aircraft=", _player.aircraft(),
		" piloted=", _craft.piloted, " use_player_input=", _craft.use_player_input,
		" wrecked=", _craft.is_wrecked(), " throttle=", _craft.controls.throttle,
		" on_floor=", _craft.is_on_floor(), " pos=", _craft.global_position,
		" panel=", _hud._flight_panel.visible)
	_check(_hud._flight_panel.visible, "登机后飞行仪表盘显示")

	# ── ① 地面满油门滑跑 ────────────────────────────────
	# 注意：pitch 锁 0 时飞机永不抬头离地，满油门约 4~5 s 就会冲出 64 格跑道尽头
	# 撞上外侧自然地形台阶而解体。故滑跑到「抬轮速度」即停下截图（仍贴地），
	# 真正离地交给 phase ② 的拉杆爬升——与 flight_probe 的起飞逻辑一致。
	_craft.controls.throttle = 1.0
	_craft.controls.pitch = 0.0
	_craft.controls.roll = 0.0
	var elapsed := 0.0
	var frame := 0
	while _craft.is_on_floor() and not _craft.is_wrecked() and elapsed < PHASE_TIMEOUT:
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()
		frame += 1
		var s := _craft.snapshot()
		if frame % 30 == 0:
			print("DBG ground t=%.1f throttle=%.2f wrecked=%s vel=%s on_floor=%s agl=%.2f" % [
				elapsed, _craft.controls.throttle, _craft.is_wrecked(),
				_craft.velocity, _craft.is_on_floor(), float(s["altitude_agl"])])
		# 到抬轮速度（≈0.85·失速）就停滑跑，留足跑道余量、避免冲出尽头撞地形。
		if float(s["airspeed"]) >= float(s["stall_speed"]) * 0.85:
			break
	var snap := _craft.snapshot()
	_check(snap["airspeed"] > 5.0, "滑跑中空速已起来（%.1f m/s）" % snap["airspeed"])
	_check(_craft.is_on_floor(), "滑跑态仍贴地未离地")
	_check(absf(float(snap["altitude_agl"])) < 0.6,
		"滑跑中离地读数≈0（%.2f m）" % snap["altitude_agl"])
	# 收油+刹车停住飞机：满油门贴地会继续滚，截图期间物理追帧会推进数秒、
	# 不等离地就冲出跑道尽头撞山解体。先断油刹车，再「同帧验证面板」后截图——
	# 验证必须在截图前，否则 3 帧等待里失速告警可能抖动消失、读数也可能漂移。
	_craft.controls.throttle = 0.0
	_craft.controls.brake = true
	_verify_panel("滑跑态")
	await _shoot("flight_hud_ground.png")

	# ── ② 空中巡航：抬到净空再改平 ──────────────────────
	# 跑道外侧自然地形更高，若从地面贴地爬升，飞机会在跑道尽头撞山解体
	# （实测 impact≈25 m/s）。故直接抬升到跑道面上 ≈40 m 净空，再交比例俯仰
	# 保持高度——与 flight_probe 巡航段「投到区块高度上限之上」同思路，避开地形。
	_craft.global_position.y += 40.0
	_craft.launch(30.0)
	_craft.controls.brake = false
	elapsed = 0.0
	while elapsed < PHASE_TIMEOUT and not _craft.is_wrecked():
		var agl := float(_craft.snapshot()["altitude_agl"])
		if not _craft.is_on_floor() and absf(agl - CRUISE_ALT) < 6.0 \
				and float(_craft.snapshot()["airspeed"]) > 18.0:
			break
		# 低于目标拉杆、高于目标推杆；滚转让风标稳定性去管。
		_craft.controls.pitch = clampf((CRUISE_ALT - agl) * 0.08, -0.35, 0.5)
		_craft.controls.throttle = 0.55
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()
	# 稳住两秒再拍，读数节流 10 Hz 需要时间跟上。
	for i in range(120):
		var agl := float(_craft.snapshot()["altitude_agl"])
		_craft.controls.pitch = clampf((CRUISE_ALT - agl) * 0.08, -0.35, 0.5)
		await get_tree().physics_frame
	snap = _verify_panel("巡航态")
	_check(not _craft.is_on_floor(), "已离地巡航")
	_check(float(snap["altitude_agl"]) > 20.0,
		"巡航离地高度达标（%.1f m）" % snap["altitude_agl"])
	_check(not bool(snap["stall_warning"]), "巡航态无失速告警")
	_check(not _hud._flight_stall.visible, "巡航态告警行隐藏")
	await _shoot("flight_hud_cruise.png")

	# ── ③ 满拉杆逼出失速告警 ─────────────────────────────
	_craft.controls.throttle = 1.0
	_craft.controls.pitch = 1.0
	elapsed = 0.0
	while not bool(_craft.snapshot()["stall_warning"]) and elapsed < PHASE_TIMEOUT \
			and not _craft.is_wrecked():
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()
	snap = _verify_panel("失速态")
	_check(bool(snap["stall_warning"]), "满拉杆后出现失速告警")
	_check(_hud._flight_stall.visible, "告警态告警行显示")
	await _shoot("flight_hud_stall.png")

	# 改出：推杆低头，等告警消失后下机。
	_craft.controls.pitch = -0.6
	elapsed = 0.0
	while bool(_craft.snapshot()["stall_warning"]) and elapsed < PHASE_TIMEOUT:
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()
	_check(not bool(_craft.snapshot()["stall_warning"]), "推杆后失速告警解除")

	# 下机：仪表盘应当重新隐藏。
	_player.exit_aircraft()
	for i in range(10):
		await get_tree().physics_frame
	_check(not _hud._flight_panel.visible, "下机后飞行仪表盘隐藏")

	print("FLIGHT_HUD_DONE fails=%d" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


## 面板文案与物理快照逐项比对。
## 关键修复：强制面板以「当前帧」状态刷新，再取同一时刻的物理快照，
## 二者必然同源——消除「陈旧快照 vs 实时面板」的时序 FAIL（滑跑态空速/油门、
## 巡航与失速态 1 帧漂移、失速告警行在截图等待中抖动消失）。
## 返回该同帧快照，供调用方复用做物理断言。
func _verify_panel(phase: String) -> Dictionary:
	# 先让面板按当前物理状态刷新，再取同一时刻的快照——都来自同一个 _state。
	_hud._refresh_flight_panel()
	var snap := _craft.snapshot()
	var kmh := str(int(snap["kmh"]))
	var agl := str(int(snap["altitude_agl"]))
	var pct := str(int(float(snap["throttle"]) * 100.0))
	_check(_hud._flight_speed.text.contains(kmh),
		"%s：空速行含 %s km/h（面板「%s」）" % [phase, kmh, _hud._flight_speed.text])
	_check(_hud._flight_altitude.text.contains(agl),
		"%s：离地行含 %s m（面板「%s」）" % [phase, agl, _hud._flight_altitude.text])
	_check(_hud._flight_throttle.text.contains(pct + "%"),
		"%s：油门行含 %s%%（面板「%s」）" % [phase, pct, _hud._flight_throttle.text])
	# 失速参考速度也应在面板上，且随高度衰减（同源气动函数）。
	var stall_kmh := str(int(float(snap["stall_speed"]) * AircraftFlight.MPS_TO_KMH))
	_check(_hud._flight_speed.text.contains(stall_kmh),
		"%s：空速行含失速参考 %s km/h" % [phase, stall_kmh])
	return snap


func _shoot(name: String) -> void:
	# 少等几帧：截图期间物理会追帧，wait 太久会推进大量 sim 时间（地面态尤其致命）。
	for i in range(3):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	# 截图是「取证」用的附属产物：headless 或无渲染目标时取不到图像，
	# 绝不因截图失败中断核心断言（面板显隐与读数比对才是验证主体）。
	var img := get_viewport().get_texture().get_image()
	if img == null:
		print("WARN 截图跳过（无可用图像，可能不是窗口模式）：", name)
		return
	img.save_png(_shot_path(name))


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
