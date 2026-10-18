extends Node
## 飞行视角与回放验证探针（D-033，窗口模式：截图需 Vulkan 渲染）。
## 覆盖：登机 → 相机激活 → 发动机启停与油门门控 → C 视角切换（平滑不瞬移）
## → V 自由观察（偏移生效 + 松手回正）→ R 后视 → M 战术地图（采样 + 开关）
## → 回放（录制 → 电影运镜 → 机体重演 → 幽灵轨迹 → 跳过复位）。
## 四张截图：座舱 / 追尾 / 战术地图 / 回放运镜。
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/flight_view_probe.tscn

const SHOT_DIR := "res://tmp"
const REGION := RegionAtlas.ASIA

var _ok := true
var _saved_progress := ""
var _saved_settings := ""
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
	FlightSettings.set_current(FlightSettings.for_difficulty(FlightSettings.Difficulty.NORMAL))

	# ── 存档隔离（D-010 铁律 3）──
	_saved_progress = _read_user_text("user://progress.json")
	_saved_settings = _read_user_text("user://settings.json")
	_saved_counters = Progress.counters.duplicate()
	_saved_states = Progress.states.duplicate()
	_saved_quiz = Progress._quiz_correct_since_reward

	# 儿童友好默认值（D-033）：抖动开 + 自动回正开。
	_check(FlightSettings.current().camera_shake, "设置：镜头抖动默认开启")
	_check(FlightSettings.current().auto_recenter, "设置：松手自动回正默认开启")

	GameState.current_region = REGION
	GameState.set_mode(GameState.Mode.EXPLORE)
	GameState.needs_region_pick = false

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame

	var player: Player = main_scene.get_node("Player")
	var hud: HUD = main_scene.get_node("UI")
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()

	var craft: Aircraft = null
	for n in get_tree().get_nodes_in_group("aircraft"):
		craft = n as Aircraft
		break
	_check(craft != null, "① 跑道上已自动生成可见飞机")
	if craft == null:
		_finish()
		return

	# 视角三件套由 main 装配（D-033）。
	var cam: AircraftCamera = main_scene._flight_camera
	var recorder: FlightRecorder = main_scene._recorder
	var replay: FlightReplay = main_scene._replay
	_check(cam != null and recorder != null and replay != null, "① main 已装配相机/录制/回放三件套")

	# ── ② 登机（真实 F 键路径）──
	player.set_physics_process(false)
	craft.set_physics_process(false)
	player.global_position = craft.global_position + Vector3(2.0, 0.0, 0.0)
	player.set_physics_process(true)
	craft.set_physics_process(true)
	await _frames(3)
	player._handle_aircraft_key()
	await _frames(5)
	_check(player.is_riding(), "② 登机：player.is_riding()")
	_check(craft.piloted, "② 登机：piloted=true")
	_check(cam.is_active(), "② 登机即激活飞行相机")
	_check(recorder.is_recording(), "② 登机即开始轨迹录制")

	# ── ③ 发动机：默认熄火；F 启动后油门门控放开；熄火后油门锁 0 ──
	_check(not craft.engine_running, "③ 登机后发动机默认熄火")
	craft.toggle_engine()
	await _frames(2)
	_check(craft.engine_running, "③ 按 F（toggle_engine）发动机启动")
	# 模拟按住 W（move_forward）推油：门控放开后油门应增长。
	Input.action_press("move_forward")
	await _frames(40)
	var thr := craft.controls.throttle
	_check(thr > 0.1, "③ 发动机运转时 W 推油生效（油门 %.2f）" % thr)
	Input.action_release("move_forward")
	# 熄火：油门应被锁回 0（无推力），舵面仍可写。
	craft.set_engine(false)
	await _frames(10)
	_check(not craft.engine_running, "③ 再按 F 发动机熄火")
	_check(craft.controls.throttle <= 0.0001, "③ 熄火后油门锁 0（当前 %.3f）" % craft.controls.throttle)

	# ── ④ C 视角切换：平滑过渡 + 落位正确 ──
	cam.toggle_first_third()   # → 座舱
	await _frames(2)
	var cam_pos_a: Vector3 = cam.global_position
	await _frames(1)
	var cam_pos_b: Vector3 = cam.global_position
	var step := cam_pos_a.distance_to(cam_pos_b)
	# 阈值取「跳变全程」（追尾 13 m → 座舱 ≈16.7 m）的 1/3：本机实测 3.04 m
	# （渲染 ~20 fps 时步长最大；步长 = 全程 × (1−e^(−RATE_FAR·delta))，随渲染
	# 帧率浮动）。历史上按 9 m 追尾距标定的 3.0 m，在 D-035 把追尾距加宽到
	# 13 m 后必然击穿——「不瞬移」判的是数量级（17 m 级硬切才算瞬移）。
	_check(step < 5.0, "④ 视角切换平滑不瞬移（首帧位移 %.2f m < 5 m）" % step)
	await _frames(90)   # 阻尼收敛（RATE_FAR=4：90 帧 ≈ 1.5 s，残余 < 0.1 m）
	var cockpit_expect: Vector3 = craft.global_transform * Vector3(0.0, 1.15, -3.4)
	_check(cam.current_mode() == AircraftCamera.ViewMode.FIRST_PERSON, "④ C 切到第一人称座舱")
	_check(cam.global_position.distance_to(cockpit_expect) < 1.5,
		"④ 座舱相机落位正确（偏差 %.2f m）" % cam.global_position.distance_to(cockpit_expect))
	await _shot("flight_view_cockpit.png")

	cam.toggle_first_third()   # → 追尾
	await _frames(40)
	_check(cam.current_mode() == AircraftCamera.ViewMode.CHASE, "④ C 再切回第三人称追尾")
	var chase_dist := cam.global_position.distance_to(craft.global_position)
	_check(chase_dist > 9.0 and chase_dist < 18.0,
		"④ 追尾距离更远更宽（%.1f m，默认 13 m，旧值 9 m）" % chase_dist)
	_check(absf(cam.fov - 82.0) < 1.0,
		"④ 追尾 FOV 更宽（%.0f°，D-035 由 75° 加宽）" % cam.fov)
	await _shot("flight_view_chase.png")

	# ── ⑤ V 自由观察：鼠标偏移生效 + 松手自动回正 ──
	cam.set_free_look(true)
	cam.apply_look_delta(Vector2(240.0, 0.0))
	await _frames(20)
	_check(cam.current_mode() == AircraftCamera.ViewMode.FREE_LOOK, "⑤ V 进入自由观察")
	var off := _view_yaw_offset(cam, craft)
	_check(absf(off) > 0.15, "⑤ 自由观察鼠标环顾生效（偏航 %.2f rad）" % off)
	cam.set_free_look(false)
	await _frames(90)   # 回正 τ≈0.4 s，留 2 倍余量（渲染帧/物理帧 1:1 假定）
	var back := _view_yaw_offset(cam, craft)
	_check(absf(back) < 0.08, "⑤ 松手自动回正（残余 %.3f rad < 0.08）" % back)
	_check(cam.current_mode() == AircraftCamera.ViewMode.CHASE, "⑤ 退出自由观察回到底层追尾")

	# ── ⑥ R 后视 ──
	cam.toggle_rear()
	await _frames(30)
	_check(cam.current_mode() == AircraftCamera.ViewMode.REAR, "⑥ R 进入后视")
	var nose: Vector3 = craft.global_transform.basis * Vector3(0.0, 0.0, -1.0)
	var to_cam: Vector3 = cam.global_position - craft.global_position
	_check(to_cam.normalized().dot(nose) > 0.5,
		"⑥ 后视相机位于机头前方（点积 %.2f）" % to_cam.normalized().dot(nose))
	cam.toggle_rear()
	await _frames(20)
	_check(cam.current_mode() == AircraftCamera.ViewMode.CHASE, "⑥ 再按 R 退出后视")

	# ── ⑦ M 战术地图 ──
	hud._toggle_tactical_map()
	await _frames(5)
	var tmap: FlightTacticalMap = hud._tactical_map
	_check(tmap != null and tmap.is_open(), "⑦ M 打开飞行战术地图")
	var cells: int = FlightTacticalMap.GRID_CELLS * FlightTacticalMap.GRID_CELLS
	_check(tmap._cell_pos.size() == cells,
		"⑦ 地形网格一次性采样缓存（%d 格）" % tmap._cell_pos.size())
	await _shot("flight_view_tactical.png")
	tmap.close_map()
	await _frames(3)
	_check(not tmap.is_open(), "⑦ 再按 M 关闭战术地图")

	# ── ⑧ 回放：录制一段完整飞行 → 电影运镜 → 机体重演 → 幽灵轨迹 → 跳过复位 ──
	# 脚本驾驶（use_player_input=false 后直接写 controls，与 e2e 同路径）；
	# 整平一段进近带，防止飞出平整区撞山（探针教训）。带南界包到飞机起点前
	# 12 格：停机位在跑道南段，带面高跑道 1 格，不覆盖起点会撞带南缘台阶。
	var world: World = player.world_ref()
	var center: Vector3i = main_scene._airport_center(REGION)
	var surface_y := int(craft.global_position.y - Aircraft.GROUND_CLEARANCE)
	_flatten_lane(world, center, surface_y, int(craft.global_position.z))
	craft.use_player_input = false
	craft.set_engine(true)
	craft.controls.throttle = 1.0
	craft.controls.pitch = 0.0
	var lifted := -1
	for i in range(1500):
		await get_tree().physics_frame
		if not is_instance_valid(craft) or craft.is_wrecked():
			break
		var s := craft.snapshot()
		if float(s["airspeed"]) >= float(s["stall_speed"]) * 0.9:
			craft.controls.pitch = 0.8
		if not craft.is_on_floor():
			lifted = i
			break
	_check(lifted > 0 and not craft.is_wrecked(), "⑧ 起飞供录制（第 %d 帧离地）" % lifted)
	if is_instance_valid(craft) and not craft.is_wrecked():
		# 重定位到跑道中线上空短平飞（跳过向北导航段）。
		craft.place(Vector3(center.x + 0.5, float(surface_y) + 15.0, float(center.z) + 0.5), PI)
		craft._state.velocity = Vector3(0.0, 0.3, 18.0)
		craft.velocity = craft._state.velocity
		craft.controls.throttle = 0.4
		craft.controls.pitch = 0.0
		for i in range(90):
			await get_tree().physics_frame
			if not is_instance_valid(craft) or craft.is_wrecked():
				break
			var drift := craft.global_position.y - (float(surface_y) + 15.0)
			craft.controls.pitch = clampf(-drift * 0.05, -0.3, 0.3)
		# 受控下滑落回跑道（COBBLESTONE 落地带）。
		if is_instance_valid(craft) and not craft.is_wrecked():
			craft.place(Vector3(center.x + 0.5, float(surface_y) + 5.0,
				float(center.z - 25) + 0.5), PI)
			craft._state.velocity = Vector3(0.0, 0.0, 13.0)
			craft.velocity = craft._state.velocity
			craft.controls.throttle = 0.35
			craft.controls.pitch = 0.0
			for i in range(900):
				await get_tree().physics_frame
				if not is_instance_valid(craft) or craft.is_wrecked():
					break
				var s2 := craft.snapshot()
				var agl := float(s2["altitude_agl"])
				var sink := -craft.velocity.y
				var tgt := 2.5 if agl > 1.5 else 1.0
				craft.controls.pitch = clampf((sink - tgt) * 0.25, -0.4, 0.4)
				var spd := float(s2["airspeed"])
				craft.controls.throttle = clampf(0.25 + (12.0 - spd) * 0.08, 0.12, 0.45)
				if agl < 1.2:
					craft.controls.throttle = 0.05
				if craft.is_on_floor() and agl < 1.5 and i > 30:
					break
	await _frames(30)
	_check(recorder.sample_count() > 60, "⑧ 轨迹录制中（%d 样本 / %.1f s）" % [
		recorder.sample_count(), recorder.duration()])
	var pre_pos: Vector3 = craft.global_position
	var pre_xform: Transform3D = craft.global_transform

	hud._start_replay()
	await _frames(3)
	_check(replay.is_playing(), "⑧ 回放开始（电影运镜）")
	_check(cam.current_mode() == AircraftCamera.ViewMode.REPLAY, "⑧ 相机进入回放模式")
	await _frames(150)   # 运镜推进：机体应被重演到录制轨迹上
	var replayed := craft.global_position.distance_to(pre_pos)
	_check(replayed > 1.0, "⑧ 机体重演（位移 %.1f m，非停在空中）" % replayed)
	_check(replay._trail != null and replay._trail.mesh != null
		and replay._trail.mesh.get_surface_count() == 1,
		"⑧ 幽灵轨迹网格已建立（1 个 surface）")
	await _shot("flight_view_replay.png")

	replay.skip()
	# 同步复位：skip → _finish 在本帧内还原位姿与速度态，先于任何物理帧
	# 读取 → 位姿应严格相等（D-033：回放=时间未流逝）。
	_check(craft.global_transform.origin.distance_to(pre_xform.origin) < 0.01,
		"⑧ 机体位姿同步复位（偏差 %.4f m）" % craft.global_transform.origin.distance_to(pre_xform.origin))
	await _frames(3)
	_check(not replay.is_playing(), "⑧ Esc 跳过回放")
	_check(cam.current_mode() != AircraftCamera.ViewMode.REPLAY, "⑧ 跳过后退回飞行视角")
	# 物理恢复后按还原的速度态继续滑行（回放前在滚跑道，3 帧合法前进），
	# 不坠毁不解体即为通过。
	var post_dev: float = craft.global_transform.origin.distance_to(pre_xform.origin)
	_check(post_dev < 3.0 and not craft.is_wrecked(),
		"⑧ 复位后按原速继续滑行（%.2f m，未异常）" % post_dev)

	# ── 收尾：下机 ──
	player.exit_aircraft()
	await _frames(5)
	_check(not player.is_riding(), "⑨ X 下机：退出驾驶")
	_check(not cam.is_active(), "⑨ 下机即停用飞行相机")
	_check(not recorder.is_recording(), "⑨ 下机即停止录制")

	_finish()


## 当前相机视线相对机头的偏航角（rad，正 = 向右偏）。
func _view_yaw_offset(cam: AircraftCamera, craft: Aircraft) -> float:
	var look: Vector3 = -cam.global_transform.basis.z
	look.y = 0.0
	if look.length_squared() < 0.0001:
		return 0.0
	look = look.normalized()
	var nose: Vector3 = craft.global_transform.basis * Vector3(0.0, 0.0, -1.0)
	nose.y = 0.0
	if nose.length_squared() < 0.0001:
		return 0.0
	nose = nose.normalized()
	return atan2(nose.x * look.z - nose.z * look.x, nose.x * look.x + nose.z * look.z)


## 沿 +Z 整平一段进近带（中心以南 25 格 → 北端以外），防止飞出平整区撞山。
## 带南界另需包到飞机起点前 12 格：带面比跑道铺装高 1 格（surface_y 取自机体
## 下方），起点在带外时滑跑会在带南缘撞 0.5 m 台阶（D-040 停机位南移后踩过）。
func _flatten_lane(world: World, center: Vector3i, surface_y: int, from_z: int = 1 << 30) -> void:
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


func _shot(name: String) -> void:
	await _frames(6)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path(name))
	print("FLIGHT_VIEW_SHOT " + name)


func _frames(count: int) -> void:
	for i in range(count):
		await get_tree().physics_frame


func _finish() -> void:
	_restore_user_saves()
	if _ok:
		print("FLIGHT_VIEW_OK")
		get_tree().quit(0)
	else:
		print("FLIGHT_VIEW_FAILED")
		get_tree().quit(1)


func _restore_user_saves() -> void:
	_write_user_text("user://progress.json", _saved_progress)
	_write_user_text("user://settings.json", _saved_settings)
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
