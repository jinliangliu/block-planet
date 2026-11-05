extends Node3D
## 赛道竞速场景（scenes/racing/race_scene.tscn 的根脚本）。
##
## 进出方式：主场景把「选了什么」写进 RaceSystem.pending，再切到本场景；
## 本场景读走参数、生成赛道与赛车、跑完比赛、结算，然后切回主场景
## （RaceSystem.open_selector_on_return 决定回去后是否直接再开选择器）。
##
## 场景里的一切（相机/光照/天空/UI）都在代码里搭，.tscn 只挂一个脚本根节点——
## 与本工程「全代码 UI」的一贯做法一致，也避免手写 .tscn 出错。

const MAIN_SCENE := "res://scenes/main.tscn"
const PLAYER_NAME := "玩家"
const MAX_RACE_SECONDS := 900.0
const COUNTDOWN_SECONDS := 3.2

var _track_def: Dictionary = {}
var _layout: TrackLayout = null
var _loader: TrackLoader = null
var _session: RaceSession = null
var _vehicle_id := ""
## 场地极速（玩家车极速，m/s）：机器人配速归一的上界。0 = 取不到，退回不归一。
var _field_top := 0.0
var _racers: Array = []
var _cars: Array[RaceCar] = []
var _idx: Array[int] = []
var _off_road: Array[bool] = []
var _camera: Camera3D = null
var _light: DirectionalLight3D = null
var _hud: RaceHUD = null
var _result: RaceResultUI = null
var _teaching: RaceTeachingUI = null
var _tick := 0
var _steer_input := 0.0
var _lights_on := false
var _finalized := false
## 自动驾驶（自检/探针用）：置真后玩家车改由 AI 驾驶，用来在无头环境里
## 跑完一整场比赛、验证流程与排名，而不必模拟真实按键。
var autopilot := false
var _player_ai: AiRacer = null
## 倒计时滴答的音效游标：记录上一次响过的 ceil(countdown) 值。
## -1 表示尚未开始（begin_countdown 后重置）。COUNTDOWN_SECONDS 是 3.2，
## 首帧 ceil 得 4，本游标配合「只响 1~3」自动跳过那个 4（HUD 的「4」闪帧
## 是既有显示问题，不在本轮范围）。
var _countdown_tick := -1


func _ready() -> void:
	InputActions.register()
	_vehicle_id = String(RaceSystem.pending.get("vehicle_id", "tricycle"))
	var tid := String(RaceSystem.pending.get("track_id", ""))
	_track_def = RaceSystem.track(tid)
	if _track_def.is_empty():
		push_warning("RaceScene: 没有待开赛的场次，返回主场景")
		_back_to_main()
		return

	_layout = TrackLayout.build(_track_def)
	_setup_environment()
	_loader = TrackLoader.new()
	_loader.name = "Track"
	add_child(_loader)
	_loader.build(_layout)
	_spawn_racers()
	_setup_camera()
	_setup_ui()
	_session.begin_countdown(COUNTDOWN_SECONDS)
	_countdown_tick = -1
	RaceSystem.race_started.emit(tid)


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.30, 0.55, 0.92)
	mat.sky_horizon_color = Color(0.80, 0.88, 0.96)
	mat.ground_bottom_color = Color(0.26, 0.32, 0.24)
	mat.ground_horizon_color = Color(0.72, 0.78, 0.66)
	sky.sky_material = mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.85
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_light = DirectionalLight3D.new()
	_light.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	_light.light_energy = 1.05
	# 阴影关掉：目标平台是中低端 Android，Mobile 渲染器下阴影是第一笔要省的开销。
	_light.shadow_enabled = false
	add_child(_light)


func _spawn_racers() -> void:
	var start := _layout.point(0)
	var dir := _layout.direction(0)
	var nrm := _layout.normal(0)
	var heading := atan2(dir.x, dir.z)
	var ai_total := clampi(int(RaceSystem.pending.get("ai_count", 3)), 0, 5)
	var diff := RaceSystem.difficulty(String(RaceSystem.pending.get("ai_difficulty", "easy")))
	var names := RaceSystem.ai_names()
	var pool := RaceSystem.ai_vehicle_ids()
	# 配速归一：机器人目标速度的上界是「玩家车的极速」，不是它自己车的极速。
	# 否则 AI 车池里的 racer(40 m/s) 开 easy(0.7) 仍有 28 m/s，孩子开小三轮(24 m/s)必输。
	_field_top = float(RaceSystem.vehicle(_vehicle_id).get("max_speed_mps", 0.0))

	# 玩家占最靠前的发车格（0 号位），机器人排在其后，两列错开。
	for i in ai_total + 1:
		var row := i / 2
		var col := i % 2
		var lateral := 2.8 if col == 1 else -2.8
		var behind := 7.0 + float(row) * 5.6
		var at := start - dir * behind + nrm * lateral
		var r := RaceSession.Racer.new()
		r.is_player = i == 0
		if r.is_player:
			r.id = "player"
			r.display = PLAYER_NAME
			r.vehicle_id = _vehicle_id
		else:
			var k := i - 1
			r.id = "ai_%d" % k
			r.display = String(names[k % names.size()]) if names.size() > 0 else "机器人%d" % (k + 1)
			r.vehicle_id = String(pool[k % pool.size()])
			r.ai = AiRacer.new()
			r.ai.setup(_layout, diff, _layout.seed + k * 17 + 3, _field_top)
		var spec := RaceSystem.vehicle(r.vehicle_id)
		r.color = Color(String(spec.get("color", "#b0b0b0")))
		r.car = CarPhysics.new()
		r.car.setup(spec, Vector2(at.x, at.z), heading)
		_racers.append(r)

		var node := RaceCar.new()
		node.name = "Car_%s" % r.id
		add_child(node)
		node.build(spec, Color.WHITE if r.is_player else Color(0.62, 0.62, 0.68))
		node.sync_from(r.car, 0.0)
		_cars.append(node)
		_idx.append(0)
		_off_road.append(false)

	_session = RaceSession.new()
	_session.setup(_layout, int(_track_def.get("laps", 3)), _racers)
	_session.lap_completed.connect(_on_lap_completed)
	_session.gate_passed.connect(_on_gate_passed)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 76.0
	_camera.near = 0.2
	_camera.far = 5000.0
	add_child(_camera)
	_camera.current = true
	_update_camera(0.0, true)


func _setup_ui() -> void:
	_hud = RaceHUD.new()
	add_child(_hud)
	# 触屏层的「返回」/「重开」按钮：与键盘的 race_exit / race_restart 同一出口，
	# 手机上没有 ESC 键，孩子只能靠这两个按钮离开或重开。
	_hud.touch_exit_requested.connect(_back_to_selector)
	_hud.touch_restart_requested.connect(_restart)
	_result = RaceResultUI.new()
	add_child(_result)
	_result.again_requested.connect(_restart)
	_result.back_requested.connect(_back_to_selector)
	_teaching = RaceTeachingUI.new()
	add_child(_teaching)
	# 无头 / 自检：教学弹窗会把 _physics_process 冻结在 is_showing() 上，
	# 自动跑圈的探针永远跑不完，直接抑制。
	if autopilot or DisplayServer.get_name() == "headless":
		_teaching.suppress()


func _physics_process(delta: float) -> void:
	if _session == null:
		return
	# 教学弹窗期间冻结比赛：孩子在看说明，倒计时不该偷跑。
	if _teaching != null and _teaching.is_showing():
		return

	var was_counting := _session.is_counting()
	_session.tick(delta)
	if was_counting and not _session.is_counting():
		_on_countdown_finished()
	elif _session.is_counting():
		# 倒计时滴答（M9 音效）：3-2-1 各响一声，孩子不用盯着屏幕也知道要出发了。
		var tick_sec := int(ceilf(_session.countdown))
		if tick_sec != _countdown_tick:
			_countdown_tick = tick_sec
			if tick_sec >= 1 and tick_sec <= 3:
				Sfx.play("race_beep")
	_tick += 1

	var counting := _session.is_counting()
	# 只减速侧橡皮筋：本帧先算一次玩家的沿赛道里程，每个机器人用它换算差距。
	# AI 大幅领先就松油、落后恒 1.0（不加速），孩子永远有追上的机会。
	var player: RaceSession.Racer = _session.player()
	var player_m := _track_progress_m(player)
	for i in _racers.size():
		var r: RaceSession.Racer = _racers[i]
		var terr := _terrain_for(r, i)
		if counting:
			r.car.throttle = 0.0
			r.car.brake = 1.0
			r.car.steer = 0.0
			r.car.handbrake = true
		elif r.is_player:
			if autopilot:
				if _player_ai == null:
					_player_ai = AiRacer.new()
					_player_ai.setup(_layout, RaceSystem.difficulty("hard"),
						_layout.seed + 91, _field_top)
				var pin: Dictionary = _player_ai.think(r.car, terr, delta)
				r.car.throttle = float(pin["throttle"])
				r.car.brake = float(pin["brake"])
				r.car.steer = float(pin["steer"])
				r.car.handbrake = bool(pin.get("handbrake", false))
			else:
				_apply_player_input(r, delta)
		elif r.finished():
			# 完赛后滑行收油，别在终点线上堵成一团。
			r.car.throttle = 0.3
			r.car.brake = 0.0
			r.car.steer = 0.0
			r.car.handbrake = false
		else:
			r.ai.set_gap(_track_progress_m(r) - player_m)
			var inp: Dictionary = r.ai.think(r.car, terr, delta)
			r.car.throttle = float(inp["throttle"])
			r.car.brake = float(inp["brake"])
			r.car.steer = float(inp["steer"])
			r.car.handbrake = bool(inp.get("handbrake", false))

		r.car.step(delta, terr)
		_clamp_arena(r.car)
		_session.update_progress(r, _off_road[i], delta)
		_cars[i].sync_from(r.car, delta)
		# 地形粒子（M9）：跑到沙石扬尘、湿地溅水花——速度感的主要来源之一。
		_cars[i].set_terrain_fx(terr, r.car.speed() / maxf(r.car.max_speed(), 1.0))

	_session.refresh_rankings()
	_update_camera(delta, false)
	if counting:
		_hud.set_countdown(_session.countdown)
	else:
		_hud.clear_countdown()
	_hud.update_view(_session, String(RaceSystem.terrain(_current_terrain_id(0)).get("name_zh", "")))
	_check_finish()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("race_exit"):
		_back_to_selector()
	elif event.is_action_pressed("race_restart"):
		_restart()
	elif event.is_action_pressed("race_lights"):
		_toggle_lights()
	elif event.is_action_pressed("race_horn"):
		_hud.banner("📣 嘟嘟——", Color(0.55, 0.85, 1.0))


func _apply_player_input(r: RaceSession.Racer, delta: float) -> void:
	# 触屏优先：touch_input().active 为真说明手机上存在触屏驾驶层，
	# 此时不能再读键盘（手机上键盘恒为松开，会把车「锁」在原地）。
	var ti: Dictionary = _hud.touch_input()
	if bool(ti.get("active", false)):
		# 触屏按钮是离散按下的，方向这里再做一次平滑，松手自动回到 0。
		var want := clampf(float(ti.get("steer", 0.0)), -1.0, 1.0)
		_steer_input = lerpf(_steer_input, want, clampf(delta * 9.0, 0.0, 1.0))
		r.car.steer = _steer_input
		r.car.throttle = clampf(float(ti.get("throttle", 0.0)), 0.0, 1.0)
		r.car.brake = clampf(float(ti.get("brake", 0.0)), 0.0, 1.0)
		r.car.handbrake = bool(ti.get("handbrake", false))
		if r.car.handbrake:
			r.used_handbrake = true
		return

	var target := 0.0
	if Input.is_action_pressed("move_right") or Input.is_action_pressed("aircraft_roll_right"):
		target += 1.0
	if Input.is_action_pressed("move_left") or Input.is_action_pressed("aircraft_roll_left"):
		target -= 1.0
	# 键盘是二元输入，直接映射会让车「一跳一跳」地转，这里做一点平滑。
	_steer_input = lerpf(_steer_input, target, clampf(delta * 9.0, 0.0, 1.0))
	r.car.steer = _steer_input
	r.car.throttle = 1.0 if (Input.is_action_pressed("move_forward")
		or Input.is_action_pressed("aircraft_pitch_up")) else 0.0
	r.car.brake = 1.0 if (Input.is_action_pressed("move_back")
		or Input.is_action_pressed("aircraft_pitch_down")) else 0.0
	r.car.handbrake = Input.is_action_pressed("jump")
	if r.car.handbrake:
		r.used_handbrake = true


func _toggle_lights() -> void:
	_lights_on = not _lights_on
	for c in _cars:
		c.set_lights(_lights_on)
	_hud.banner("车灯 %s" % ("开" if _lights_on else "关"), Color(1.0, 0.95, 0.65))


## 该车当前所处地形（路面内按路段地形，出路面一律草地）+ 记录是否出界。
func _terrain_for(r: RaceSession.Racer, i: int) -> Dictionary:
	var at := Vector3(r.car.pos.x, 0.0, r.car.pos.y)
	var pi := 0
	if r.ai != null:
		pi = r.ai.index
	else:
		pi = _layout.nearest_index_forward(_idx[i], at, 30)
		_idx[i] = pi
	var lat := absf(_layout.lateral_offset(at, pi))
	_off_road[i] = lat > _layout.half_width
	if _off_road[i]:
		return RaceSystem.terrain("grass")
	return RaceSystem.terrain(_layout.terrain_at_index(pi))


func _current_terrain_id(i: int) -> String:
	var at := Vector3(_racers[i].car.pos.x, 0.0, _racers[i].car.pos.y)
	if _off_road[i]:
		return "grass"
	return _layout.terrain_at_index(_idx[i])


## 沿赛道的累计里程（m，跨圈单调），橡皮筋差距用它来算。
## gates_passed 跨圈单调递增，每门间隔 ≈ total/gate_count；gate_distance 是到
## 「下一个门」的直线距离，于是 seg − gate_distance 就是刚过门后跑出的段内里程。
## 发车格都排在起跑线之后（段内里程钳到 0），所以开赛瞬间所有人的进度都是 0。
func _track_progress_m(r: RaceSession.Racer) -> float:
	if r == null or _layout == null:
		return 0.0
	var gates := _layout.gate_count()
	if gates <= 0:
		return 0.0
	var seg := _layout.total / float(gates)
	var since_gate := clampf(seg - r.gate_distance, 0.0, seg)
	return float(r.gates_passed) * seg + since_gate


## 软性边界：竞技场地台之外没有东西，越界就把车拉回来并卸掉大部分速度。
func _clamp_arena(car: CarPhysics) -> void:
	var limit := _loader.arena_radius * 0.92
	var d := car.pos.length()
	if d > limit:
		car.pos = car.pos * (limit / d)
		car.vel *= 0.35


func _update_camera(delta: float, snap: bool) -> void:
	var r: RaceSession.Racer = _racers[0]
	var fwd := Vector3(sin(r.car.heading), 0.0, cos(r.car.heading))
	var focus := Vector3(r.car.pos.x, 1.25, r.car.pos.y)
	var want := focus - fwd * 13.0 + Vector3(0.0, 5.6, 0.0)
	if snap:
		_camera.position = want
	else:
		_camera.position = _camera.position.lerp(want, clampf(delta * 5.5, 0.0, 1.0))
	_camera.look_at(focus, Vector3.UP)
	# 速度越快视野越宽，速度感更足。
	var top := maxf(r.car.max_speed() * 1.1, 1.0)
	_camera.fov = lerpf(74.0, 88.0, clampf(r.car.speed() / top, 0.0, 1.0))


func _on_countdown_finished() -> void:
	_hud.banner("出发！", Color(0.55, 0.95, 0.60))
	Sfx.play("race_go")
	_log("race_start")
	_teaching.enqueue("first_checkpoint")


func _on_lap_completed(racer_id: String, lap: int, lap_time: float) -> void:
	if racer_id != "player":
		return
	_hud.banner("第 %d 圈完成  %s" % [lap, RaceSystem.format_time(lap_time)],
		Color(0.55, 0.95, 0.60))
	Sfx.play("race_lap")
	_log("lap_complete")
	_teaching.enqueue("first_lap")


func _on_gate_passed(racer_id: String, _gate: int) -> void:
	if racer_id == "player":
		Sfx.play("race_checkpoint")
		_log("checkpoint")


func _check_finish() -> void:
	if _finalized:
		return
	var player: RaceSession.Racer = _session.player()
	var timed_out := _session.elapsed > MAX_RACE_SECONDS
	if player != null and player.finished():
		_finalize()
	elif timed_out:
		_finalize()


func _finalize() -> void:
	if _finalized:
		return
	_finalized = true
	_session.state = RaceSession.State.FINISHED
	_session.refresh_rankings()
	var results := _session.results()
	var player: RaceSession.Racer = _session.player()
	var outcome := RaceSystem.submit_result(
		String(_track_def.get("id", "")),
		_vehicle_id,
		player.rank,
		player.best_lap,
		player.finish_time,
		player.is_clean(),
		player.lap,
	)
	_log("race_finish")
	_hud.banner("冲线！第 %d 名" % player.rank, Color(1.0, 0.90, 0.40))
	_result.show_results(results, _track_def, outcome)


func _log(action: String) -> void:
	var player: RaceSession.Racer = _session.player()
	var at := Vector3.ZERO
	if player != null:
		at = Vector3(player.car.pos.x, 0.0, player.car.pos.y)
	RaceReplayLog.append(_tick, action, String(_track_def.get("id", "")), _vehicle_id,
		at, PLAYER_NAME)


func _restart() -> void:
	# 清掉触屏残留按下态：抬指事件若被教学弹窗/成绩单吃掉，_touch_brake 会留成
	# true，重开后新车一出发就「刹车踩着」动不了。这是真机上的坑，代价一行。
	if _hud != null:
		_hud.clear_touch_input()
	var p: Dictionary = RaceSystem.pending
	RaceSystem.select_race(String(p["track_id"]), String(p["vehicle_id"]),
		int(p["ai_count"]), String(p["ai_difficulty"]))
	get_tree().reload_current_scene()


## 回主场景并直接再开赛道选择器。
func _back_to_selector() -> void:
	RaceSystem.open_selector_on_return = true
	_back_to_main()


func _back_to_main() -> void:
	get_tree().change_scene_to_file(MAIN_SCENE)
