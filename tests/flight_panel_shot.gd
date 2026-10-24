extends Node
## 飞行仪表面板 / HUD 渲染取证探针（D-034，窗口模式：需 Vulkan 渲染截图）。
## 复用飞行视角探针的「登机 → 起飞」路径，让 main 自动装配座舱 3D 面板、
## 世界标注与屏幕 HUD，然后：
##   · 第一人称座舱视角截图（2D 像素座舱框 + 座舱仪表簇，D-050 起 3D 机模隐藏）
##   · 第三人称追尾视角截图（屏幕四角 HUD + 小地图）
##   · 详细模式截图（左侧 12 仪表全清单）
## 仅作可视化取证，不考核断言数量；截图落到 tmp/ 供人工目检。
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/flight_panel_shot.tscn

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

	var cam: AircraftCamera = main_scene._flight_camera
	_check(cam != null, "① main 已装配飞行相机")

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
	_check(main_scene._cockpit_panel != null, "② main 已装配座舱 3D 仪表盘")
	_check(main_scene._flight_markers != null, "② main 已装配世界标注")
	_check(hud.instrument_hud() != null, "② main 已装配屏幕飞行 HUD")

	# 发动机启动 + 推油，让仪表有可读数值。
	craft.toggle_engine()
	await _frames(2)
	Input.action_press("move_forward")
	await _frames(40)
	Input.action_release("move_forward")

	# ── ③ 第一人称座舱：登机默认视角（D-049）──
	# 用户要求「默认登机后进入第一人称视角，界面突出座舱驾驶界面」——登机即
	# 座舱，无需按键；本断言是 D-049 的窗口侧回归闸。
	_check(cam.current_mode() == AircraftCamera.ViewMode.FIRST_PERSON,
		"③ 登机默认第一人称座舱（D-049）")
	# D-050：座舱内视——3D 外部机模隐藏：座舱眼位在机身盒内部，不隐藏的话
	# 机翼横贯全屏（用户实测）。
	_check(craft.is_interior_view(), "③ 座舱内视：3D 外部机模隐藏（D-050）")
	# L2 反转（feature_cockpit_3d §6）：座舱 3D 仪表台**不再**随内视隐藏——它就
	# 装在仪表台位置，正视时与不透明的 2D 簇完全重合（被 2D 遮住），环顾/低头时
	# 2D 簇自动让位、由它接管画面。这里断言它「在」而不是「藏」，与反转前相反。
	_check(main_scene._cockpit_panel != null and main_scene._cockpit_panel.visible,
		"③ 座舱 3D 仪表台在座舱视角显示（L2 反转：与 2D 簇重合）")
	await _frames(60)
	await _shot("flight_panel_cockpit.png")

	# ── ④ 第三人称追尾：屏幕四角 HUD + 小地图 ──
	cam.toggle_first_third()  # → 追尾
	await _frames(60)
	_check(cam.current_mode() == AircraftCamera.ViewMode.CHASE,
		"④ 第三人称追尾视角（四角 HUD + 小地图）")
	_check(not craft.is_interior_view() and main_scene._cockpit_panel.visible,
		"④ 追尾视角恢复 3D 机体与座舱面板可见（D-050，防幽灵飞机）")
	await _shot("flight_panel_chase.png")

	# ── ⑤ 详细模式：左侧 12 仪表全清单 ──
	FlightSettings.current().hud_detail = true
	await _frames(20)
	await _shot("flight_panel_detail.png")

	# ── 收尾：下机 ──
	player.exit_aircraft()
	await _frames(5)
	_check(not player.is_riding(), "⑥ 下机退出驾驶")

	_finish()


func _shot(name: String) -> void:
	await _frames(6)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path(name))
	print("FLIGHT_PANEL_SHOT " + name)


func _frames(count: int) -> void:
	for i in range(count):
		await get_tree().physics_frame


func _finish() -> void:
	_restore_user_saves()
	if _ok:
		print("FLIGHT_PANEL_SHOT_OK")
		get_tree().quit(0)
	else:
		print("FLIGHT_PANEL_SHOT_FAILED")
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
