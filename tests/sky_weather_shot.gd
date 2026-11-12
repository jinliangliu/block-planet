extends Node
## 天空/天气取证（D-093，需窗口）：220 m 高空无遮挡相机下四组 A/B 对照，证明
## BG_SKY 天空渐变、三档天气可辨识、昼夜驱动生效、距离雾未被误关。
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/sky_weather_shot.tscn

const SHOT_DIR := "res://tmp"
const SKY_BAND_Y_MAX := 360

var _pass := 0
var _fail := 0
var _restored := false
var _snapshot_done := false
var _probe_cam: Camera3D
var _dn: DayNightCycle
var _env: Environment
var _samples: Dictionary = {}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("PASS: ", msg)
	else:
		_fail += 1
		print("FAIL: ", msg)


func _wait(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


func _ready() -> void:
	# 120 s 看门狗：先于任何写操作挂上，卡死也强制退出，_exit_tree 仍会还原。
	get_tree().create_timer(120.0).timeout.connect(_on_watchdog)
	await _run()


func _on_watchdog() -> void:
	print("SKY_WEATHER_SHOT_WATCHDOG_TIMEOUT")
	get_tree().quit(1)


func _exit_tree() -> void:
	# D-010 早退配对：幂等安全网，仅当快照已完成才还原。
	if _snapshot_done and not _restored:
		_restored = true
		SaveGuard.restore()


## 四组统一入口：钉天气 + 拨时刻 + 夺回相机 + 取图 + 测量。
func _group(tag: String, weather: int, t: float, fade_frames: int) -> void:
	_dn.set_weather(weather)
	_dn._time = t
	_dn._apply_lighting()
	if fade_frames > 0:
		await _wait(fade_frames)
	# 主场景可能某帧把玩家相机设回 current；每组取样前无条件夺回。
	_probe_cam.make_current()
	await _wait(2)
	await RenderingServer.frame_post_draw
	var vp_cam := get_viewport().get_camera_3d()
	_check(vp_cam == _probe_cam, "%s 取图相机为 ProbeSkyCam" % tag)
	var img := get_viewport().get_texture().get_image()
	var path := _shot_path("sky_weather_%s.png" % tag)
	img.save_png(path)
	_samples[tag] = _measure(img, tag)
	print("SKY_WEATHER %s png=%s" % [tag, path])


## 六点 RGB + 天空带(y 0–360)平均亮度与不同 rgba32 色数（8 px 步长取样）。
func _measure(img: Image, tag: String) -> Dictionary:
	var pts: Array[Vector2i] = [
		Vector2i(640, 80), Vector2i(640, 150), Vector2i(640, 220),
		Vector2i(420, 150), Vector2i(860, 150), Vector2i(640, 300),
	]
	var six: Array[int] = []
	for p: Vector2i in pts:
		if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
			continue
		var pc := img.get_pixelv(p)
		six.append(pc.to_rgba32())
		print("SKY_WEATHER %s px(%d,%d)= r=%.4f g=%.4f b=%.4f rgba32=%d"
			% [tag, p.x, p.y, pc.r, pc.g, pc.b, pc.to_rgba32()])
	var lum_sum := 0.0
	var lum_n := 0
	var colors := {}
	for y in range(0, SKY_BAND_Y_MAX, 8):
		for x in range(0, img.get_width(), 8):
			var bc := img.get_pixel(x, y)
			lum_sum += (bc.r + bc.g + bc.b) / 3.0
			lum_n += 1
			colors[bc.to_rgba32()] = true
	var lum := 0.0 if lum_n == 0 else lum_sum / float(lum_n)
	print("SKY_WEATHER %s sky_band_lum=%.4f distinct_rgba32=%d"
		% [tag, lum, colors.size()])
	return {"six": six, "lum": lum, "distinct": colors.size()}


## 构造式断言 + 反向对照：不依赖机会性观察，四组均为主动设置后验证系统响应。
func _run_assertions() -> void:
	var clear: Dictionary = _samples["noon_clear"]
	var cloudy: Dictionary = _samples["noon_cloudy"]
	var rain: Dictionary = _samples["noon_rain"]
	var night: Dictionary = _samples["night_clear"]
	var six_clear: Array = clear["six"]
	var unique := {}
	for v: int in six_clear:
		unique[v] = true
	_check(six_clear.size() == 6 and unique.size() > 1,
		"noon_clear 六点颜色不全等（%d 种，证明天空有渐变）" % unique.size())
	if six_clear.size() >= 6:
		var zenith: int = six_clear[0]
		var horizon: int = six_clear[5]
		_check(zenith != horizon,
			"noon_clear 天顶(640,80) ≠ 地平线(640,300)（证明有层次）")
	else:
		_check(false, "noon_clear 六点取样不足 6 个（无法验层次）")
	var lum_clear: float = clear["lum"]
	var lum_cloudy: float = cloudy["lum"]
	var lum_rain: float = rain["lum"]
	var d_cloudy := absf(lum_cloudy - lum_clear)
	var d_rain := absf(lum_rain - lum_clear)
	var weather_diff := maxf(d_cloudy, d_rain)
	_check(weather_diff > 0.05,
		"三档天气至少一组天空带亮度差 > 0.05（阴差 %.4f / 雨差 %.4f，最大 %.4f）"
			% [d_cloudy, d_rain, weather_diff])
	var lum_night: float = night["lum"]
	print("SKY_WEATHER sky_band_lum noon_clear=%.4f noon_cloudy=%.4f noon_rain=%.4f night_clear=%.4f"
		% [lum_clear, lum_cloudy, lum_rain, lum_night])
	# 阶段 B 精修：正午防过曝闸（阶段 A C2 标定 0.7439 落在 0.55~0.75）。
	_check(lum_clear >= 0.55 and lum_clear <= 0.75,
		"noon_clear 天空带亮度落在 0.55~0.75 防过曝区（%.4f）" % lum_clear)
	# 阶段 B 精修：夜晚收紧为绝对阈值 0.25（阶段 A N1 标定 0.1317）。
	_check(lum_night < 0.25,
		"night_clear 天空带亮度 < 0.25（%.4f，夜晚够暗）" % lum_night)
	_check(_env.background_mode == Environment.BG_SKY and _env.fog_sky_affect == 0.0,
		"D-093 收尾复核：BG_SKY + fog_sky_affect=0.0")


func _run() -> void:
	get_window().size = Vector2i(1280, 720)
	await get_tree().process_frame
	# D-010：快照必须先于任何写操作（改 GameState / 实例化 main）。
	SaveGuard.snapshot()
	_snapshot_done = true
	InputActions.register()
	GameState.needs_region_pick = false
	GameState.current_region = RegionAtlas.ASIA

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	await _wait(120)
	# 窗口态出生加载屏（MAX_WAIT=8s + FADE=0.35s）：纯帧数不够，显式等它自毁。
	var extra := 0
	while main_scene.get_node_or_null("UI/SpawnLoading") != null and extra < 600:
		await get_tree().process_frame
		extra += 1
	print("SKY_WEATHER spawn_loading_gone=",
		main_scene.get_node_or_null("UI/SpawnLoading") == null,
		" extra_frames=", extra)

	# 关掉可能遮挡取样的模态 + 冻结刷怪（照 cockpit3d_shot.gd:85-96）。
	var hud := main_scene.get_node("UI") as HUD
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
	if hud._profile_picker != null and hud._profile_picker.is_open():
		hud.close_profile_picker()
	var spawner := main_scene.get_node("MobSpawner") as MobSpawner
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	await _wait(20)

	_dn = main_scene.get_node("DayNightCycle") as DayNightCycle
	var we := main_scene.get_node("WorldEnvironment") as WorldEnvironment
	_env = we.environment
	_check(_env.background_mode == Environment.BG_SKY,
		"D-093 主世界 background_mode=BG_SKY")
	_check(_env.fog_sky_affect == 0.0, "D-093 主世界 fog_sky_affect=0.0")

	# 220 m 高空无遮挡相机，水平朝 -Z（默认朝向），取代步行第一人称出生点相机。
	_probe_cam = Camera3D.new()
	_probe_cam.name = "ProbeSkyCam"
	add_child(_probe_cam)
	_probe_cam.position = Vector3(0.0, 220.0, 0.0)
	_probe_cam.current = true
	await _wait(2)

	await _group("noon_clear", DayNightCycle.Weather.CLEAR,
		DayNightCycle.DAY_LENGTH * 0.5, 0)
	await _group("noon_cloudy", DayNightCycle.Weather.CLOUDY,
		DayNightCycle.DAY_LENGTH * 0.5, 0)
	await _group("noon_rain", DayNightCycle.Weather.RAIN,
		DayNightCycle.DAY_LENGTH * 0.5, 0)
	await _group("night_clear", DayNightCycle.Weather.CLEAR,
		DayNightCycle.DAY_LENGTH + DayNightCycle.NIGHT_LENGTH * 0.5, 90)

	_run_assertions()

	SaveGuard.restore()
	_restored = true
	print("SKY_WEATHER_SHOT_DONE pass=%d fail=%d" % [_pass, _fail])
	if _fail > 0:
		print("SKY_WEATHER_SHOT_FAIL")
	else:
		print("SKY_WEATHER_SHOT_OK")
	get_tree().quit(0 if _fail == 0 else 1)
