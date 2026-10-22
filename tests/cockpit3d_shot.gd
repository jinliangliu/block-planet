extends Node
## 3D 座舱内装取证（D-065，**需窗口**）：L1 环绕框 + L2 仪表台 + L3 杆手。
##
## 几何观感（视差、遮挡关系、比例、穿模）无头查不出来，只能出图目检；逻辑契约
## 由 cockpit_interior_probe（27 断言）与 cockpit_align_probe（12 断言）钉。
##
## 出图清单（目检要点）：
##   ① fp          正视：2D 簇在位，3D 只该露出顶部横梁与两条 A 柱（与 2D 柱同形）
##   ② left/right  环顾：侧 console 外框 + 铆钉条 + 拨杆，视差成立、2D 簇已让位
##   ③ down        低头：仪表台底板 + 3D 仪表台 + 杆手 + 地板 + 踏板，杆不压读数
##   ④ lookback    回头：椅背 + 头枕 + 后拱（"回头有物"）
##   ⑤ blueprint   蓝图机：无任何内装几何（对照 ①）
##   ⑥ free        2D 簇全隐藏：纯 3D 座舱全貌，检查比例与座舱感
##   ⑦ shake       满油门连拍 3 帧：看仪表台抖动是否穿帮 / 底角是否漏出 2D 簇下沿
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/cockpit3d_shot.tscn

const PROBE_PAD := preload("res://tests/probe_pad.gd")
const SHOT_DIR := "res://tmp"

var _fails := 0
var _craft: Aircraft = null
var _player: Player = null
var _cam: AircraftCamera = null
var _hud: HUD = null
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


func _snap(file_name: String) -> Image:
	await _wait(2)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_shot_path(file_name))
	print("SHOT ", file_name)
	return img


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


func _ready() -> void:
	await _run()


func _run() -> void:
	get_window().size = Vector2i(1280, 720)
	await get_tree().process_frame
	SaveGuard.snapshot()
	GameState.needs_region_pick = false
	GameState.current_region = RegionAtlas.ASIA

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	await _wait(120)
	# 光照基准：拨到**正午**。默认 `_time = 0` 是**黎明**（sun = sin(0) = 0 →
	# light_energy 0.2 全天最低、ambient 0.35、天幕 DUSK，且主光
	# rotation.x = lerpf(-85,-10,0) = -85° 属病态角度）。黎明下拍的「黑墙感」
	# 有一半是欠曝造成的假象，取证图必须在白天。天气也要先钉住：_weather == -1
	# 时 get_weather() 按 `_elapsed / WEATHER_SLOT(150 s)` 自动轮换，跨槽会让
	# 整屏半数像素变化，A/B 差分就废了。
	var dn: DayNightCycle = main_scene.get_node("DayNightCycle")
	dn.set_weather(DayNightCycle.Weather.CLEAR)
	dn._time = dn.DAY_LENGTH * 0.5
	dn._apply_lighting()
	_hud = main_scene.get_node("UI")
	if _hud._map_selector != null and _hud._map_selector.is_open():
		_hud.close_map_selector()
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
	await _wait_physics(10)
	if not is_instance_valid(_craft) or _craft.is_wrecked():
		_check(false, "就位阶段机体解体（先查 probe_pad）")
		SaveGuard.restore()
		_restored = true
		get_tree().quit(1)
		return
	_cam = _player.flight_camera

	# ① 正视（发动机熄火：抖动会带来 20~36 px 面板位移，取证要静置）
	await _wait(10)
	await _snap("cockpit3d_fp.png")

	# ② 环顾左右（自由观察：2D 簇按 flight_instrument_hud 的规则自动让位）
	_cam.set_free_look(true)
	await _wait(4)
	_cam.apply_look_delta(Vector2(-380.0, 0.0))
	await _wait(20)
	await _snap("cockpit3d_left.png")
	_cam.recenter()
	await _wait(10)
	_cam.apply_look_delta(Vector2(380.0, 0.0))
	await _wait(20)
	await _snap("cockpit3d_right.png")

	# ③ 低头：仪表台 + 杆手（L2/L3 的价值兑现点）
	_cam.recenter()
	await _wait(10)
	_cam.apply_look_delta(Vector2(0.0, 400.0))
	await _wait(20)
	var down_img: Image = await _snap("cockpit3d_down.png")
	_check_panel_not_white(down_img)

	# ④ 回头：椅背 + 头枕 + 后拱
	_cam.recenter()
	await _wait(10)
	_cam.apply_look_delta(Vector2(-1256.0, 80.0))
	await _wait(20)
	await _snap("cockpit3d_lookback.png")

	# ⑤ 纯 3D 全貌（2D 簇全隐藏）：检查比例与座舱感。必须**正视略低头**——
	# 上一版直接沿用 ④ 的回望角度拍，图里只有椅背与头枕，等于没验到座舱全貌。
	_hud.instrument_hud().hide_all()
	_cam.recenter()
	await _wait(6)
	_cam.apply_look_delta(Vector2(0.0, 150.0))
	await _wait(16)
	await _snap("cockpit3d_free.png")
	_cam.recenter()
	await _wait(8)
	_cam.set_free_look(false)

	# ⑥ 满油门抖动连拍：仪表台在 0.85 m 处会抖 20~36 px——看底角会不会把 2D 簇
	# 下沿的亮边漏出来（DASH_RIM 0.09 的取舍就靠这三张判）。
	_craft.set_engine(true)
	_craft.controls.throttle = 1.0
	await _wait_physics(30)
	for k in range(3):
		await _snap("cockpit3d_throttle_shake%d.png" % (k + 1))
		await _wait_physics(6)
	_craft.controls.throttle = 0.0
	_craft.set_engine(false)
	await _wait(4)

	# ⑦ 蓝图机对照：无任何内装几何
	await _check_blueprint(main_scene, spawn_pos)

	SaveGuard.restore()
	_restored = true
	print("COCKPIT3D_SHOT_DONE fails=%d" % _fails)
	get_tree().quit(0 if _fails == 0 else 1)


## 白屏闸（窗口侧真判据）：3D 仪表台的内边四角必须落在深色板面上。
## 无头那条只验「贴图绑定生效」，验不到「贴图内容是不是白的」——旧实现的白屏恰恰
## 是绑定失效但材质仍亮白，只有读屏幕像素才拦得住。取样点在贴图内缩 8 px 的四角
## （板面 COL_DASH ≈0.145，盘面 0.04~0.09，白屏是 1.0，一测即中）；不取盘心——
## 姿态盘的天空色约 0.80 会误报。
func _check_panel_not_white(img: Image) -> void:
	if img == null:
		_check(false, "低头图取图失败（无法验白屏）")
		return
	var panel: CockpitPanel = null
	for child: Node in _craft.get_children():
		if child is CockpitPanel:
			panel = child as CockpitPanel
			break
	var plane := panel.get_node_or_null("Dashboard") as MeshInstance3D if panel != null else null
	if plane == null:
		_check(false, "找不到 Dashboard 面片（无法验白屏）")
		return
	# 诊断打点：区分「贴图绑定失效」与「SubViewport 内容为白」。
	var sv := panel.get_node_or_null("CockpitSubViewport") as SubViewport
	if sv != null:
		print("DBG sv_size=", sv.size, " mode=", sv.render_target_update_mode,
			" transparent=", sv.transparent_bg)
		var ti := sv.get_texture().get_image()
		if ti != null and ti.get_width() > 0:
			print("DBG tex_size=", ti.get_size(), " center=", ti.get_pixel(ti.get_width() / 2, ti.get_height() / 2),
				" corner=", ti.get_pixel(8, 8))
		var cl := sv.get_child(0) as Control if sv.get_child_count() > 0 else null
		if cl != null:
			print("DBG cluster_size=", cl.size, " children=", cl.get_child_count())
			var plate := cl.get_child(0) as Control if cl.get_child_count() > 0 else null
			if plate != null:
				print("DBG plate_size=", plate.size, " visible=", plate.visible)
	var mat_dbg: StandardMaterial3D = plane.get_surface_override_material(0) as StandardMaterial3D
	if mat_dbg != null:
		print("DBG mat albedo_tex=", mat_dbg.albedo_texture, " albedo=", mat_dbg.albedo_color,
			" emi_tex=", mat_dbg.emission_texture, " emi=", mat_dbg.emission,
			" energy=", mat_dbg.emission_energy_multiplier)
	var xf := plane.global_transform
	var w := CockpitPanel.PANEL_W
	var h := CockpitPanel.PANEL_H
	# 贴图坐标 (8,8)/(760,8)/(8,160)/(760,160) → 面板局部米（贴图 768×168）。
	var uv := [Vector2(8.0, 8.0), Vector2(760.0, 8.0), Vector2(8.0, 160.0), Vector2(760.0, 160.0)]
	var brightest := 0.0
	var sampled := 0
	for t: Vector2 in uv:
		var local := Vector3((t.x / 768.0 - 0.5) * w, (0.5 - t.y / 168.0) * h, 0.0)
		var sp: Vector2 = _cam.unproject_position(xf * local)
		var px := Vector2i(int(sp.x), int(sp.y))
		if px.x < 0 or px.y < 0 or px.x >= img.get_width() or px.y >= img.get_height():
			continue
		var c := img.get_pixelv(px)
		brightest = maxf(brightest, maxf(c.r, maxf(c.g, c.b)))
		sampled += 1
	_check(sampled >= 2 and brightest < 0.62,
		"仪表台四角采样 %d 点最亮通道 %.3f < 0.62（白屏会是 1.0）" % [sampled, brightest])


func _check_blueprint(main_scene: Node, spawn_pos: Vector3) -> void:
	var bp := Blueprint.new()
	bp.parts = PartRegistry.default_loadout()
	# 横向错开落位：不能落在当前这架飞机身上（碰撞盒 15.6 m 长，重叠会被分离顶起解体）。
	var at := Vector3(spawn_pos.x + 10.0, spawn_pos.y, spawn_pos.z + 10.0)
	var bp_craft := Aircraft.from_loadout(main_scene, at, PI, bp)
	await _wait_physics(2)
	_player.ride_aircraft(bp_craft)
	bp_craft.drive_remotely()
	await _wait_physics(20)
	var bp_interior: CockpitInterior = null
	for child: Node in bp_craft.get_children():
		if child is CockpitInterior:
			bp_interior = child as CockpitInterior
			break
	_check(bp_interior != null and bp_interior.interior_box_count() == 0,
		"蓝图机不建内装几何（0 个盒体）")
	await _snap("cockpit3d_blueprint.png")


func _exit_tree() -> void:
	if not _restored:
		_restored = true
		SaveGuard.restore()
