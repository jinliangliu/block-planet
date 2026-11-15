extends Node
## 3D 座舱内装取证（D-065，**需窗口**）：L1 环绕框 + L2 仪表台 + L3 杆手。
##
## 几何观感（视差、遮挡关系、比例、穿模）无头查不出来，只能出图目检；逻辑契约
## 由 cockpit_interior_probe 与 cockpit_align_probe 钉（断言数以实测 PASS 行为准）。
##
## 出图清单（目检要点）：
##   ① fp          正视：2D 簇在位，3D 只该露出顶部横梁与两条 A 柱（与 2D 柱同形）
##   ② left/right  环顾：侧 console 外框 + 铆钉条 + 拨杆，视差成立、2D 簇已让位
##   ③ down        低头：仪表台底板 + 3D 仪表台 + 杆手 + 地板 + 踏板，杆不压读数
##   ④ lookback    回头：椅背 + 头枕 + 后拱（"回头有物"）
##   ⑤ blueprint   蓝图机：无任何内装几何（对照 ①）
##   ⑥ free        2D 簇全隐藏：纯 3D 座舱全貌，检查比例与座舱感
##   ⑦ shake       满油门连拍 3 帧（D-097 后作「座舱硬边零位移」取证）：三帧的
##                 A 柱内缘 / 2D-3D 交界硬边位置必须逐像素一致，由
##                 _check_cockpit_still() 用 ROI 边缘位置 + 构造式反向对照钉住。
##                 注意：整帧不可能零 diff——满油门时飞机在跑道滑跑加速，地面、
##                 跑道线、教学提示与仪表读数都在变；「三帧逐像素一致」是错误口径。
##                 PANEL_W/H 未动
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
	# D-076 起窗口态启动自动弹 ProfilePicker（main.gd:214 只豁免无头）。回归把
	# profiles/ 移出后空槽态必弹，其米白模态卡片会盖住仪表台四角的屏幕取样点，
	# 让「非白屏」断言读到 0.949 而误判。显式关闭，恢复 D-076 之前的取证条件。
	if _hud._profile_picker != null and _hud._profile_picker.is_open():
		_hud.close_profile_picker()
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

	# ⑥ 满油门连拍（D-097 后改为「座舱硬边零位移」取证）：D-097 已把
	# COCKPIT_SHAKE_SCALE 收敛为 0，座舱内视不再有相机位置抖动；3D A 柱挂在机体上、
	# 与眼位刚性 ⇒ 内缘硬边不得逐帧爬行。外部视角抖动与包络仍在，只是不进座舱。
	# 旧注释的「座舱只取 40%、横向峰值约 18 px、呼吸 ±2%」是 D-075 口径，已失效。
	# **不要再写「三帧逐像素一致」**：D-097 验收桌面实测三帧 md5 全不同、整帧差异
	# 10~14%，差异集中在滑跑的地面/跑道线（28~37%）、左下开口透出的世界（21~28%）、
	# 教学提示与仪表读数；座舱几何区（柱区/天空/仪表簇）只有 0.25~1.28%。
	# 连拍前仍等 90 物理帧（1.5 s）：包络平滑 τ≈0.33 s，确保进入 settled，
	# 三张图的差别只可能来自抖动而非包络爬升，避免取证假象。
	_craft.set_engine(true)
	_craft.controls.throttle = 1.0
	await _wait_physics(90)
	var shake_frames: Array[Image] = []
	for k in range(3):
		var frame: Image = await _snap("cockpit3d_throttle_shake%d.png" % (k + 1))
		shake_frames.append(frame)
		await _wait_physics(6)
	_check_cockpit_still(shake_frames)
	_craft.controls.throttle = 0.0
	_craft.set_engine(false)
	await _wait(4)

	# ⑦ 蓝图机对照：无任何内装几何
	await _check_blueprint(main_scene, spawn_pos)

	SaveGuard.restore()
	_restored = true
	print("COCKPIT3D_SHOT_DONE fails=%d" % _fails)
	get_tree().quit(0 if _fails == 0 else 1)


## 座舱硬边零位移闸（D-097 / J1）。只比 A 柱内缘的**位置**，不比整帧像素：
## 帧内有滑跑的世界、跑道线、教学提示与仪表读数，整帧零 diff 是错误口径。
## 取样行只取 y=40..360（纯柱 / 天空），避开 y≥400 的地面、侧 console 亮边与
## 教学卡片，否则「首个亮像素」会取到地面或 UI，边缘检测失效（坑 #15）。
## 三条闸：① 9 行内缘位置三帧全等；② 人为右移 2 px 的构造式反向对照必须被检出；
## ③ 中央地面 ROI 确实逐帧变化，证明三帧不是同一张图、判据有区分力。
const STILL_ROWS: Array[int] = [40, 80, 120, 160, 200, 240, 280, 320, 360]
const STILL_LUM_MIN := 0.353   # ≈ 90/255；柱面约 0.18，天空 / 地面 > 0.5


func _lum(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


func _inner_edges(img: Image, y: int) -> Vector2i:
	var w := img.get_width()
	var half: int = int(w * 0.5)
	var left := -1
	var right := -1
	for x in range(20, half):
		if _lum(img.get_pixel(x, y)) > STILL_LUM_MIN:
			left = x
			break
	for x in range(w - 20, half, -1):
		if _lum(img.get_pixel(x, y)) > STILL_LUM_MIN:
			right = x
			break
	return Vector2i(left, right)


func _check_cockpit_still(frames: Array[Image]) -> void:
	if frames.size() != 3:
		_check(false, "座舱硬边零位移：连拍应为 3 帧，实测 %d" % frames.size())
		return
	var ok_rows := 0
	var spread_max := 0
	for y in STILL_ROWS:
		var base := _inner_edges(frames[0], y)
		var spread := 0
		for i in range(1, 3):
			var e := _inner_edges(frames[i], y)
			spread = maxi(spread, maxi(absi(e.x - base.x), absi(e.y - base.y)))
		# 守卫：内缘必须落在柱区，否则「三帧全等」可能只是阈值失效的假绿。
		if base.x > 20 and base.x < 360 and base.y > 920 and base.y < 1260:
			ok_rows += 1
			spread_max = maxi(spread_max, spread)
	_check(ok_rows == STILL_ROWS.size() and spread_max == 0,
		"座舱硬边零位移：%d/%d 行有效、三帧 A 柱内缘最大位移 %d px（D-097 应为 0）"
			% [ok_rows, STILL_ROWS.size(), spread_max])
	# 构造式反向对照：人为把首帧整体右移 2 px，边缘检测必须报出 +2 px，
	# 否则「spread_max == 0」只是检测函数恒真的假绿（坑 #15）。
	var shifted := Image.new()
	shifted.copy_from(frames[0])
	shifted.blit_rect(frames[0],
		Rect2i(0, 0, frames[0].get_width(), frames[0].get_height()), Vector2i(2, 0))
	var probe_y: int = STILL_ROWS[4]
	var e0 := _inner_edges(frames[0], probe_y)
	var e1 := _inner_edges(shifted, probe_y)
	_check(e1.x - e0.x == 2,
		"构造式反向对照：人为右移 2 px 后内缘应右移 2 px（实测 %d px），证明边缘检测非恒真"
			% (e1.x - e0.x))
	# 反向对照二：中央地面 ROI 必须逐帧变化，证明三帧确实在推进、不是同一张图。
	var moved := 0
	var total := 0
	for gy in range(420, 520, 4):
		for gx in range(380, 900, 4):
			var a := _lum(frames[0].get_pixel(gx, gy))
			var b := _lum(frames[1].get_pixel(gx, gy))
			if absf(a - b) > 0.02:
				moved += 1
			total += 1
	_check(total > 0 and float(moved) / float(total) > 0.05,
		"反向对照：中央地面 ROI 逐帧变化率 %.1f（%d/%d 采样点），证明三帧非同一张"
			% [100.0 * float(moved) / float(total), moved, total])


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
	var corner_bright := 1.0
	if sv != null:
		print("DBG sv_size=", sv.size, " mode=", sv.render_target_update_mode,
			" transparent=", sv.transparent_bg)
		var ti := sv.get_texture().get_image()
		if ti != null and ti.get_width() > 0:
			var cc := ti.get_pixel(8, 8)
			corner_bright = maxf(cc.r, maxf(cc.g, cc.b))
			print("DBG tex_size=", ti.get_size(), " center=", ti.get_pixel(ti.get_width() / 2, ti.get_height() / 2),
				" corner=", cc)
		var cl := sv.get_child(0) as Control if sv.get_child_count() > 0 else null
		if cl != null:
			print("DBG cluster_size=", cl.size, " children=", cl.get_child_count())
			var plate := cl.get_child(0) as Control if cl.get_child_count() > 0 else null
			if plate != null:
				print("DBG plate_size=", plate.size, " visible=", plate.visible)
	# 坑 #20 反向对照：把「贴图内容非白」与「屏幕取样非白」拆成两条并列断言，
	# 再加一条取证环境守卫。若模态米白卡片遮挡，屏幕取样会亮到 0.949 而贴图仍深色，
	# 一眼区分「取证被遮挡」与「面板真白屏」，不会让遮挡伪装成白屏缺陷。
	_check(corner_bright < 0.3,
		"SubViewport 贴图角点内容非白（最亮通道 %.3f < 0.3）" % corner_bright)
	_check(_hud._profile_picker == null or not _hud._profile_picker.is_open(),
		"前置守卫：取证时无 ProfilePicker 模态遮挡")
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
