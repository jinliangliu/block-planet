extends Node
## 端到端飞行验证探针（窗口模式，需 Vulkan 渲染）：
## 选 ASIA 机场进入探索模式 → 自动摆机 → 登机（F）→ 起飞（满油门滑跑抬轮）
## → 爬升 → 受控下滑降落（软着陆、不解体）于跑道铺面。
## 三个关键阶段各截一张图：boarding / airborne / landed。
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/flight_e2e_shot.tscn
## （勿加 --headless；截图需窗口渲染）

const SHOT_DIR := "res://tmp"
const REGION := RegionAtlas.ASIA

var _ok := true
var _saved_progress := ""
var _saved_settings := ""
## U-9：飞行一次性教学提示进度（user://flight_teaching.json）。本探针会真实
## 起飞到 15 m 以上，座舱视角 + 教练区空闲时会触发提示并新建该文件。
var _saved_teaching := ""
var _saved_counters: Dictionary = {}
var _saved_states: Dictionary = {}
var _saved_quiz := 0


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


func _ready() -> void:
	await _run()


func _run() -> void:
	InputActions.register()
	# 飞行设置钉死标准/半开，使逐帧行为可复现（不依赖磁盘设置）。
	FlightSettings.set_current(FlightSettings.for_difficulty(FlightSettings.Difficulty.NORMAL))

	# ── 存档隔离（D-010 铁律 3）──
	_saved_progress = _read_user_text("user://progress.json")
	_saved_settings = _read_user_text("user://settings.json")
	_saved_teaching = _read_user_text("user://flight_teaching.json")
	_saved_counters = Progress.counters.duplicate()
	_saved_states = Progress.states.duplicate()
	_saved_quiz = Progress._quiz_correct_since_reward

	# 选定机场区域、探索模式、跳过地图选择器。
	GameState.current_region = REGION
	GameState.set_mode(GameState.Mode.EXPLORE)
	GameState.needs_region_pick = false

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame

	var player: Player = main_scene.get_node("Player")
	var hud: HUD = main_scene.get_node("UI")
	var world: World = main_scene.get_node("World")
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()

	# 找出探索模式开局自动摆出的飞机。
	var craft: Aircraft = null
	for n in get_tree().get_nodes_in_group("aircraft"):
		craft = n as Aircraft
		break
	_check(craft != null, "① 进入 ASIA 机场探索模式：跑道上已自动生成可见飞机")
	if craft == null:
		_finish()
		return

	player.set_physics_process(false)
	craft.set_physics_process(false)
	# 跑道铺面 y（方块高度）。
	var surface_y := int(craft.global_position.y - Aircraft.GROUND_CLEARANCE)
	var center: Vector3i = main_scene._airport_center(REGION)
	# 进近落地区沿 +Z（北端）整平一段，保证降落落在平地上（非山丘）。
	# 带南界包到飞机起点前 12 格：停机位在跑道南段，带面高跑道 1 格，
	# 不覆盖起点就会在带南缘撞台阶（D-040 教训）。
	_flatten_lane(world, center, surface_y, int(craft.global_position.z))
	# 在整平带上重铺一段 COBBLESTONE 落地带（覆盖被整平覆盖的原跑道中线），
	# 让降落最终落在真正的跑道铺面上（block=COBBLESTONE），而非 DIRT。
	_pave_landing_strip(world, center, surface_y)

	# ── ① 登机（真实 F 键路径）──
	# 把玩家挪到机身侧旁（仍在登机判定范围内），再按 F。
	player.global_position = craft.global_position + Vector3(2.0, 0.0, 0.0)
	player.set_physics_process(true)
	craft.set_physics_process(true)
	await _frames(3)
	player._handle_aircraft_key()          # 等同按下 F
	await _frames(3)
	_check(player.is_riding(), "② 登机：玩家进入驾驶（player.is_riding）")
	_check(craft.piloted, "② 登机：飞机标记 piloted=true")
	_check(player.aircraft() == craft, "② 登机：player.aircraft() 指向该机")
	await _frames(6)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("flight_e2e_boarded.png"))
	print("FLIGHT_E2E_SHOT boarded -> " + _shot_path("flight_e2e_boarded.png"))

	# 转为脚本驾驶（保留 rider，直接写 controls）。
	craft.use_player_input = false

	# ── ② 起飞：满油门滑跑 → 到抬轮速度拉杆离地 ──
	craft.controls.throttle = 1.0
	craft.controls.pitch = 0.0
	var lifted := -1
	var rotate_f := -1
	for i in range(1500):
		await get_tree().physics_frame
		var s := craft.snapshot()
		if rotate_f < 0 and float(s["airspeed"]) >= float(s["stall_speed"]) * 0.9:
			craft.controls.pitch = 0.8
			rotate_f = i
		if not craft.is_on_floor():
			lifted = i
			break
	_check(rotate_f > 0, "③ 起飞：到抬轮速度前保持三点滑跑（第 %d 帧拉杆）" % rotate_f)
	_check(lifted > 0, "③ 起飞：满油门滑跑 + 拉杆后离地（第 %d 帧）" % lifted)
	_check(not craft.is_wrecked(), "③ 起飞过程未解体")
	craft.controls.pitch = 0.0
	if not is_instance_valid(craft) or craft.is_wrecked():
		_check(false, "③ 起飞后飞机异常释放，无法继续")
		_finish()
		return

	# 离地后即在跑道中线上方重定位到安全高度，避免向北长距离飞行撞出整平区山丘。
	# （验证重心在「起→落」机制本身；起降路径用重定位跳过导航段，不测航线。）
	craft.place(Vector3(center.x + 0.5, float(surface_y) + 15.0, float(center.z) + 0.5), PI)
	# 机头朝 +Z（北）：前向速度必须是 +Z（之前误用 -Z 倒飞，攻角/空速失真）。
	craft._state.velocity = Vector3(0.0, 0.3, 18.0)   # 前向 +Z、略带爬升
	craft.velocity = craft._state.velocity
	craft.controls.throttle = 0.4
	craft.controls.pitch = 0.0
	# 短平飞保持高度，截图「空中」。
	for i in range(90):
		await get_tree().physics_frame
		if not is_instance_valid(craft) or craft.is_wrecked():
			break
		var drift := craft.global_position.y - (float(surface_y) + 15.0)
		craft.controls.pitch = clampf(-drift * 0.05, -0.3, 0.3)
	_check(is_instance_valid(craft) and not craft.is_wrecked(), "④ 空中：重定位后短平飞未解体")
	_check(is_instance_valid(craft) and not craft.is_on_floor(), "④ 爬升：飞机处于空中（已离地）")
	await _frames(6)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("flight_e2e_airborne.png"))
	print("FLIGHT_E2E_SHOT airborne -> " + _shot_path("flight_e2e_airborne.png"))

	# ── ⑤ 降落：受控下滑，软着陆于跑道铺面 ──
	# 重定位到跑道中段上方、机头朝 +Z，做一段短五边进近（验证着陆机制本身）。
	if is_instance_valid(craft):
		# 重定位到跑道南端上方、机头朝 +Z（北=进近/起飞方向），做一段受控五边下滑。
		# 起始参数按滑跑距离调校：5 m 高度 × 下沉 ~3 m/s ≈ 1.4 s ≈ 35 格，
		# 从 center-25 落到 center+10 附近——落在 COBBLESTONE 跑道内（±28）。
		craft.place(Vector3(center.x + 0.5, float(surface_y) + 5.0, float(center.z - 25) + 0.5), PI)
		craft._state.velocity = Vector3(0.0, 0.0, 13.0)   # 前向 +Z、水平
		craft.velocity = craft._state.velocity
		craft.controls.throttle = 0.35
		craft.controls.pitch = 0.0
	var landed := -1
	var max_sink := 0.0
	for i in range(900):
		await get_tree().physics_frame
		if not is_instance_valid(craft):
			_check(false, "⑤ 降落：飞机在着陆前被释放（异常）")
			break
		var s := craft.snapshot()
		var agl := float(s["altitude_agl"])
		var sink := -craft.velocity.y
		max_sink = maxf(max_sink, sink)
		# 稳定下沉：前向空速压在失速速度(13)以下 → 升力不足，必然下沉，不会平飞悬停。
		var tgt := 2.5 if agl > 1.5 else 1.0
		craft.controls.pitch = clampf((sink - tgt) * 0.25, -0.4, 0.4)
		var spd := float(s["airspeed"])
		craft.controls.throttle = clampf(0.25 + (12.0 - spd) * 0.08, 0.12, 0.45)
		if agl < 1.2:
			craft.controls.throttle = 0.05   # 最后阶段收油门，自然下沉接地
		if craft.is_on_floor() and agl < 1.5 and i > 30:
			landed = i
			break
		if craft.is_wrecked():
			break
	_check(landed > 0, "⑤ 降落：受控下滑后触地（第 %d 帧）" % landed)
	_check(is_instance_valid(craft) and not craft.is_wrecked(),
		"⑤ 降落：触地未解体（全程最大下沉率 %.1f m/s，解体阈值 7.0）" % max_sink)

	# 机身下方方块应为跑道铺面（COBBLESTONE）或整平地面（DIRT）。
	if is_instance_valid(craft) and landed > 0:
		var cell := Vector3i(craft.global_position.floor())
		var block := BlockTypes.Block.AIR
		for k in range(6):
			var b := world.get_block(cell - Vector3i(0, k, 0))
			if b != BlockTypes.Block.AIR:
				block = b
				break
		_check(block == BlockTypes.Block.COBBLESTONE or block == BlockTypes.Block.DIRT,
			"⑤ 降落：机身下方为实地铺面（block=%d，期望 COBBLESTONE/DIRT）" % block)
	await _frames(8)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path("flight_e2e_landed.png"))
	print("FLIGHT_E2E_SHOT landed -> " + _shot_path("flight_e2e_landed.png"))

	_finish()


## 在整平带上重铺一段 COBBLESTONE 落地带（覆盖被整平覆盖的原跑道中线），
## 确保降落检测与截图落在真正的跑道铺面上。覆盖降落路径 z∈[center-26, center+14]、x±3。
func _pave_landing_strip(world: World, center: Vector3i, surface_y: int) -> void:
	var z0 := center.z - 26
	var z1 := center.z + 14
	var x0 := center.x - 3
	var x1 := center.x + 3
	world.ensure_chunks_in_region(Vector3i(x0, 0, z0), Vector3i(x1, 0, z1))
	for x in range(x0, x1 + 1):
		for z in range(z0, z1 + 1):
			world.set_block_deferred(Vector3i(x, surface_y, z), BlockTypes.Block.COBBLESTONE)
	world.rebuild_chunks_in_region(Vector3i(x0, 0, z0), Vector3i(x1, 0, z1))


## 沿 +Z 方向整平一段落地带（中心以南 15 格 → 北端以外），保证降落落在平地。
func _flatten_lane(world: World, center: Vector3i, surface_y: int, from_z: int = 1 << 30) -> void:
	# 整平带必须覆盖飞机起点（停机位）：带面比跑道铺装高 1 格（surface_y 取自
	# 机体下方），若起点在带外，滑跑会在带南缘撞 0.5 m 台阶解体/卡住
	# （D-040 跑道加倍、停机位南移后踩过，故 from_z 向南包到起点前 12 格）。
	var z0 := mini(center.z - 25, from_z - 12)
	var z1 := center.z + 70
	var x0 := center.x - 8
	var x1 := center.x + 8
	world.ensure_chunks_in_region(
		Vector3i(x0, 0, z0), Vector3i(x1, 0, z1))
	for x in range(x0, x1 + 1):
		for z in range(z0, z1 + 1):
			for y in range(surface_y - 2, surface_y):
				world.set_block_deferred(Vector3i(x, y, z), BlockTypes.Block.DIRT)
			world.set_block_deferred(Vector3i(x, surface_y, z), BlockTypes.Block.DIRT)
			for h in range(1, 8):
				world.set_block_deferred(Vector3i(x, surface_y + h, z), BlockTypes.Block.AIR)
	world.rebuild_chunks_in_region(
		Vector3i(x0, 0, z0), Vector3i(x1, 0, z1))


func _frames(count: int) -> void:
	for i in range(count):
		await get_tree().physics_frame


func _finish() -> void:
	_restore_user_saves()
	if _ok:
		print("FLIGHT_E2E_OK")
		get_tree().quit(0)
	else:
		print("FLIGHT_E2E_FAILED")
		get_tree().quit(1)


func _restore_user_saves() -> void:
	_write_user_text("user://progress.json", _saved_progress)
	_write_user_text("user://settings.json", _saved_settings)
	_write_user_text("user://flight_teaching.json", _saved_teaching)
	Progress.counters = _saved_counters.duplicate()
	Progress.states = _saved_states.duplicate()
	Progress._quiz_correct_since_reward = _saved_quiz


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


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_ok = false
		print("FAIL: " + label)
