extends Node
## 飞行视角与回放验证探针（D-033，窗口模式：截图需 Vulkan 渲染）。
## 覆盖：登机 → 相机激活 → 发动机启停与油门门控 → C 视角切换（平滑不瞬移）
## → V 自由观察（偏移生效 + 松手回正）→ R 后视 → M 战术地图（采样 + 开关）
## → ⑩ 座舱内鼠标 = 驾驶员视角（D-070：视野跟随 + 杆量零写入 + 限幅 + 持久）
## → 回放（录制 → 电影运镜 → 机体重演 → 幽灵轨迹 → 跳过复位）。
## 五张截图：座舱 / 追尾 / 战术地图 / 环顾中的座舱 / 回放运镜。
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/flight_view_probe.tscn

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
	FlightSettings.set_current(FlightSettings.for_difficulty(FlightSettings.Difficulty.NORMAL))

	# ── 存档隔离（D-010 铁律 3）──
	_saved_progress = _read_user_text("user://progress.json")
	_saved_settings = _read_user_text("user://settings.json")
	_saved_teaching = _read_user_text("user://flight_teaching.json")
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
	# 轮询等待而非死等固定帧数：本探针是**窗口探针**（飞机由 main.gd:126的
	# `DisplayServer.get_name() != "headless"` 守卫才摆上跑道，无头下永远等不到）。
	# 轮询对帧率/负载波动更稳，也避免误判成「飞机没生成」。
	for i in range(240):
		for n in get_tree().get_nodes_in_group("aircraft"):
			craft = n as Aircraft
			break
		if craft != null:
			break
		await get_tree().process_frame
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
	# D-049：登机默认第一人称座舱（默认登机后进入第一人称视角）。随后按 C
	# 切到追尾，恢复 ④⑤⑥ 的既有起点——自由观察/后视的退出回落断言都以
	# _base_mode == CHASE 为前提，直接接着测会把它们全变成座舱分支。
	_check(cam.current_mode() == AircraftCamera.ViewMode.FIRST_PERSON,
		"② 登机默认第一人称座舱（D-049）")
	# D-050：座舱内视——第一人称隐藏 3D 外部机模；切追尾必须恢复（下机
	# 同理，飞机仍停在场上，隐藏会变「幽灵飞机」）。
	_check(craft.is_interior_view(),
		"② 登机即座舱内视：3D 外部机模隐藏（D-050）")
	cam.toggle_first_third()   # → 追尾
	await _frames(2)
	_check(cam.current_mode() == AircraftCamera.ViewMode.CHASE,
		"② C 键从座舱切到追尾（互切双向可用）")
	_check(not craft.is_interior_view(),
		"② 切追尾恢复 3D 机体外观（D-050）")

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

	# ── ④ C视角切换：进座舱刚性吸附 + 出座舱平滑 + 落位正确 ──
	# D-065（L1/L2 座舱 3D 化）后这条判据必须劈成两半，两侧语义相反：
	#  · chase → 座舱 = **刚性硬切**（一帧到位）。这是 R1 修复的必然结果：
	#    指数阻尼对匀速目标的稳态滞后 = v/rate，dist > TRANSITION_DIST 时 rate
	#    掉到 RATE_FAR=4 → 50 m/s 滞后 12.09 m、55 m/s 滞后 13.30 m。座舱里
	#    3D 仪表台与 2D 簇要重合、仪表读数要跟机头，12 m 滞后等于全盘失准，
	#    因此座舱两模式位置改为每帧吸附眼位（姿态仍走 slerp）。
	#  · 座舱 → chase = 仍走位移阻尼，必须平滑。这才是「不瞬移」的原意：
	#    防止退出座舱时相机从机身内部弹出去。
	# 阈值仍按**全程比例**给（历史：9 m 追尾距标定的 3.0 m 被 D-035 的 13 m
	# 击穿；D-055 世界抬高 4 倍后固定 5 m 又被 6.51 m 击穿）。
	var pre_toggle := cam.global_position
	cam.toggle_first_third()   # → 座舱
	# 采样走 process_frame（不是 _frames() 的 physics_frame），判据用「单步最大
	# 占比」：硬切会在一次 `_process` 里走完 ~100%，位移阻尼单步最多
	# 1-exp(-4·delta)（62 ms 约 22%）——与首步何时到来无关，时序免疫。
	var enter := await _sample_steps(cam, pre_toggle, 8)
	var enter_span: float = float(enter["span"])
	var enter_max: float = float(enter["max_step"])
	_check(enter_span > 0.5 and enter_max >= enter_span * 0.9,
		"④ 进座舱刚性吸附（最大单步 %.2f m / 全程 %.2f m，%.0f%% ≥ 90%%）"
			% [enter_max, enter_span, 100.0 * enter_max / maxf(enter_span, 0.001)])
	await _frames(20)   # 座舱已一帧到位，这里只为让座舱内装/仪表簇完成首帧布局
	var cockpit_expect: Vector3 = craft.global_transform * Vector3(0.0, 1.15, -3.4)
	_check(cam.current_mode() == AircraftCamera.ViewMode.FIRST_PERSON, "④ C 切到第一人称座舱")
	_check(cam.global_position.distance_to(cockpit_expect) < 1.5,
		"④ 座舱相机落位正确（偏差 %.2f m）" % cam.global_position.distance_to(cockpit_expect))
	await _shot("flight_view_cockpit.png")

	var pre_out := cam.global_position
	cam.toggle_first_third()   # → 追尾
	# 与进座舱同一套采样与判据（见上）：逐 process_frame 取 12 步，卡「单步
	# 最大占比 < 95%」。硬切会在一次 `_process` 里走完全程（100%），位移阻尼
	# 单步最多 1-exp(-4·delta)（62 ms 约 22%），12 步覆盖全程 ~94%。
	var out := await _sample_steps(cam, pre_out, 12)
	var out_span: float = float(out["span"])
	var out_max: float = float(out["max_step"])
	_check(out_span > 0.5 and out_max < out_span * 0.95,
		"④ 出座舱平滑不瞬移（最大单步 %.2f m / 全程 %.2f m，%.0f%% < 95%%）"
			% [out_max, out_span, 100.0 * out_max / maxf(out_span, 0.001)])
	# 距离断言要等阻尼**收敛**：指数阻尼按墙钟推进（delta 制），60 fps 下
	# 12 个 process_frame 只有 0.2 s（覆盖率 55%，实测距机 6.8 m 误红），
	# 45 个物理帧 ≈0.75 s（覆盖率 95%）才稳。与平滑断言分工：前者卡「单步
	# 占比」（时序免疫），后者卡「终值」（必须等收敛）。
	await _frames(45)
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

	# ── ⑩ 座舱内鼠标 = 驾驶员视角（D-070）──
	# 经 player._unhandled_input 派发**真实**鼠标位移（不是直接调相机 API）：
	# 这条路同时守两件事——视野要跟着转，且一个杆量都不许写进飞机（D-070
	# 前鼠标是座舱操纵杆，第二条断言在那时是红的，反向对照成立）。
	cam.toggle_first_third()   # ⑤/⑥/⑦ 后基座是 CHASE → 切座舱
	await _frames(10)
	_check(cam.current_mode() == AircraftCamera.ViewMode.FIRST_PERSON,
		"⑩ C 切回第一人称座舱")
	var prev_mouse_mode := Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var roll0: float = craft.controls.roll
	var pitch0: float = craft.controls.pitch
	for i in range(6):
		var ev := InputEventMouseMotion.new()
		ev.relative = Vector2(60.0, 0.0)   # 右移 6×60 px ≈ 0.9 rad
		player._unhandled_input(ev)
	await _frames(20)
	var off10: float = _view_yaw_offset(cam, craft)
	_check(absf(off10) > 0.15, "⑩ 座舱内鼠标环顾生效（视野偏航 %.2f rad）" % off10)
	_check(absf(craft.controls.roll - roll0) < 0.01 and absf(craft.controls.pitch - pitch0) < 0.01,
		"⑩ 鼠标不再写入飞机杆量（Δroll %.3f / Δpitch %.3f）"
			% [craft.controls.roll - roll0, craft.controls.pitch - pitch0])
	# 眼位刚性吸附不被视角偏移破坏（D-065 R1：座舱位置每帧吸附 COCKPIT_OFFSET）。
	var eye10: Vector3 = craft.global_transform * Vector3(0.0, 1.15, -3.4)
	_check(cam.global_position.distance_to(eye10) < 0.5,
		"⑩ 环顾只转向不位移（眼位偏差 %.2f m）" % cam.global_position.distance_to(eye10))
	await _shot("flight_view_look.png")
	# 偏航限幅：来回猛甩 40×400 px ≈ 40 rad，必须钳在 LOOK_YAW_LIMIT——
	# 座舱里这是「驾驶员的头」，不是绕飞机的轨道相机。
	for i in range(40):
		var ev2 := InputEventMouseMotion.new()
		ev2.relative = Vector2(400.0, 0.0)
		player._unhandled_input(ev2)
	await _frames(10)
	_check(absf(cam._look_yaw) <= AircraftCamera.LOOK_YAW_LIMIT + 0.001,
		"⑩ 环顾偏航限幅 ±%.1f rad（实际 %.2f）"
			% [AircraftCamera.LOOK_YAW_LIMIT, cam._look_yaw])
	# 持久：停手不自动回正——驾驶员的视线停在落下的地方（回正只归中键）。
	# 先等姿态收敛：相机朝向按 RATE_ROT=10 对目标做 slerp（τ≈0.1 s），
	# 0.87→2.4 rad 的大角度要 ~1 s 才到位——不等收敛就采样，「漂移」量到的
	# 全是 slerp 残余（run1 实测 0.331 rad 全从这里来，不是回正）。
	await _frames(60)
	var yaw_state: float = cam._look_yaw
	var off10b: float = _view_yaw_offset(cam, craft)
	await _frames(90)
	_check(absf(cam._look_yaw - yaw_state) < 0.001,
		"⑩ 座舱内环顾状态不自动回正（_look_yaw %.3f → %.3f）"
			% [yaw_state, cam._look_yaw])
	_check(absf(_view_yaw_offset(cam, craft) - off10b) < 0.02,
		"⑩ 座舱内环顾视野不自动回正（90 帧漂移 %.3f rad）"
			% absf(_view_yaw_offset(cam, craft) - off10b))
	cam.recenter()
	await _frames(90)   # 2.4 rad → 0 的 slerp 收敛（τ≈0.1 s，90 帧 ≈1.5 s）
	_check(absf(_view_yaw_offset(cam, craft)) < 0.05,
		"⑩ recenter 后视野归位（残余 %.3f rad）" % _view_yaw_offset(cam, craft))
	Input.mouse_mode = prev_mouse_mode
	cam.toggle_first_third()   # → 追尾，恢复 ⑧ 起点
	await _frames(5)

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


## 逐 `process_frame` 采样相机位移，返回 {"span": 全程, "max_step": 单步最大}。
## 必须在 process_frame 上等：相机位姿在节点 `_process` 里更新，与 physics_frame
## 拍点无关——窗口档一帧可挤进 6~8 个物理 tick 且全部早于首次 `_process`，
## 按物理帧采样会读到「还没动」的 0.00 m（④ 出座舱侧实测误红；同一点在
## D-065 期还表现为「第 4 次才跳」，纯看当帧渲染快慢，时序敏感）。
func _sample_steps(cam: Camera3D, from: Vector3, frames: int) -> Dictionary:
	var max_step := 0.0
	var prev := from
	for i in range(frames):
		await get_tree().process_frame
		var now: Vector3 = cam.global_position
		max_step = maxf(max_step, now.distance_to(prev))
		prev = now
	return {"span": prev.distance_to(from), "max_step": max_step}


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
