extends Node
## 座舱仪表簇取证（D-047，窗口模式：截图走 Vulkan）：真实飞行到巡航高度后
## 切第一人称，三段取证 + 几何断言：
##   ① 转弯带坡度：地平仪天地随滚转歪、固定飞机标记仍正对玩家、航向带
##      滚动、俯仰阶梯可见；
##   ② 低空俯冲：alt_warn>0（AGL<15 且下沉）时 ALT 数字变红闪烁；
##   ③ 几何：仪表簇四件互不重叠、与顶部飞行面板卡片零重叠、整簇在屏内。
## 飞行脚本复用 takeoff_coach_shot 的「launch 给速 + 外部写操纵」路径，
## 与飞行手感无关，只验证仪表渲染与布局。
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/cockpit_instruments_shot.tscn

const SHOT_DIR := "res://tmp"

var _craft: Aircraft = null
var _player: Player = null
var _hud: HUD = null
var _fails := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		_fails += 1
		print("FAIL: ", msg)


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


func _wait(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


func _wait_physics(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


## 视角阻尼收敛等待 + 比例俯仰稳高（D-049 踩坑）：drive_remotely 下
## _prepare_input 不碰 controls，探针不写杆量就永远保持上一帧的值——相机
## 切换等 3 秒的功夫，巡航段最后的 −0.35 全杆俯仰会把飞机全杆俯冲扎出
## 净空垫撞山解体（实测 impact 46.9 m/s）。故任何「等相机」的窗口都必须
## 继续写高度保持，与巡航段同一写法。alt = 目标 AGL（巡航高度）。
func _hold_and_wait(n: int, alt: float) -> void:
	for i in range(n):
		var agl := float(_craft.snapshot()["altitude_agl"])
		_craft.controls.pitch = clampf((alt - agl) * 0.08, -0.35, 0.5)
		await get_tree().physics_frame
		if _craft.is_wrecked():
			return


func _snap(file_name: String) -> void:
	await _wait(2)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path(file_name))
	var fi: FlightInstruments = _hud.instrument_hud().instruments_ref()
	print("DBG ", file_name, " pitch=%.1f roll=%.1f head=%.1f alt=%.0f agl=%.1f alt_warn=%d"
		% [fi.pitch_deg, fi.roll_deg, fi.heading_deg, fi.altitude_msl,
			fi.altitude_agl, fi.alt_warn])
	print("DBG ", file_name, " wrecked=", _craft.is_wrecked(), " on_floor=",
		_craft.is_on_floor(), " pos=", _craft.global_position, " vel=", _craft.velocity)


func _dbg_state(tag: String) -> void:
	print("DBG ", tag, " wrecked=", _craft.is_wrecked(), " on_floor=",
		_craft.is_on_floor(), " agl=%.1f" % float(_craft.snapshot()["altitude_agl"]),
		" m/s=%.1f" % float(_craft.snapshot()["airspeed"]),
		" pos=", _craft.global_position)


func _ready() -> void:
	await _run()


func _run() -> void:
	SaveGuard.snapshot()
	# 飞行设置钉死「标准/半开」（同 flight_probe）：探针逐帧行为不依赖开发者
	# 磁盘设置档；半开辅助的松杆配平也让转弯后的回正段确定可收敛。
	FlightSettings.set_current(FlightSettings.for_difficulty(FlightSettings.Difficulty.NORMAL))
	GameState.needs_region_pick = false
	GameState.current_region = RegionAtlas.ASIA

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	await _wait(120)

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
	# 以出生点为中心清净空 + 抹平（同 coach_cockpit_shot）：取证段要低空通场。
	var base := _player.global_position
	var ox := int(base.x)
	var oz := int(base.z)
	var ground_y := int(base.y) - 1
	var min_cell := Vector3i(ox - 16, 0, oz - 16)
	var max_cell := Vector3i(ox + 16, 0, oz + 16)
	world.ensure_chunks_in_region(min_cell, max_cell)
	for x in range(ox - 16, ox + 17):
		for z in range(oz - 16, oz + 17):
			if world.get_block(Vector3i(x, ground_y, z)) == BlockTypes.Block.AIR:
				world.set_block_deferred(Vector3i(x, ground_y, z),
					BlockTypes.Block.COBBLESTONE)
			for h in range(1, 13):
				world.set_block_deferred(Vector3i(x, ground_y + h, z),
					BlockTypes.Block.AIR)
	world.rebuild_chunks_in_region(min_cell, max_cell)
	await _wait_physics(12)

	var spawn_pos := Vector3(float(ox) + 0.5, float(ground_y) + 0.3, float(oz) + 0.5)
	_craft = Aircraft.spawn(main_scene, spawn_pos, PI)
	await _wait_physics(2)

	_player.ride_aircraft(_craft)
	_craft.drive_remotely()
	# 坑（aircraft.gd:345-347）：drive_remotely() 的 set_piloted(true) 不带 who，
	# 会抹掉 rider；座舱判据（rider.flight_camera）依赖它——补一次带 who 的。
	_craft.set_piloted(true, _player)
	for i in range(300):
		await get_tree().physics_frame
		if _craft.is_on_floor() and _craft.velocity.length() < 0.5:
			break
	await _wait_physics(6)

	# ── 起飞到巡航（复用 flight_hud_shot 验证过的模式：抬升 + launch 给速 ──
	# 从地面贴地爬升会在跑道尽头撞山解体（实测 impact≈25 m/s）；且出生点北侧
	# 就是 50m+ 山丘，35m 巡航转弯漂移直接撞坡解体（本探针实测：z≈145 地形
	# 升到 53m，40 m/s 撞山）——故巡航抬到 65m，山丘全高 53m 以下净空 ≥50m。
	# 注意 place() 不复活已解体机体（_wrecked 不清），取证段必须先保住不坠毁。
	const CRUISE_ALT := 65.0
	_craft.set_engine(true)   # 熄火状态油门锁 0，必须先点火
	_craft.global_position.y += 50.0
	_craft.launch(30.0, 2.0)
	_craft.controls.brake = false
	_craft.controls.throttle = 0.55
	var settled := false
	for i in range(600):
		await get_tree().physics_frame
		if _craft.is_wrecked():
			break
		var agl := float(_craft.snapshot()["altitude_agl"])
		if not _craft.is_on_floor() and absf(agl - CRUISE_ALT) < 6.0 \
				and float(_craft.snapshot()["airspeed"]) > 20.0:
			settled = true
			break
		_craft.controls.pitch = clampf((CRUISE_ALT - agl) * 0.08, -0.35, 0.5)
	_check(settled and not _craft.is_wrecked(),
		"进入 %.0fm 巡航（空速健康，供转弯取证）" % CRUISE_ALT)
	# 比例俯仰稳住两秒再切视角，读数节流需要时间跟上。
	for i in range(120):
		var agl := float(_craft.snapshot()["altitude_agl"])
		_craft.controls.pitch = clampf((CRUISE_ALT - agl) * 0.08, -0.35, 0.5)
		await get_tree().physics_frame
		if i % 30 == 0:
			_dbg_state("hold")
	_dbg_state("hold_end")

	var cam: AircraftCamera = _player.flight_camera
	# D-049：登机即第一人称座舱——上面的起飞/巡航段全程就在座舱视角里飞
	# （用户要求「默认登机后进入第一人称视角，界面突出座舱驾驶界面」）。
	# 先把默认值钉死，再 C 键往返一次：覆盖互切后仍能回到座舱取证。
	_check(cam.current_mode() == AircraftCamera.ViewMode.FIRST_PERSON,
		"登机默认第一人称座舱（D-049，起飞段全程座舱视角）")
	cam.toggle_first_third()   # → 追尾
	await _hold_and_wait(90, CRUISE_ALT)   # 视角阻尼收敛（同 flight_view_probe）
	_check(cam.current_mode() == AircraftCamera.ViewMode.CHASE, "C 切到追尾")
	# D-050：切追尾必须恢复 3D 机体外观——下机同理（set_active(false) 同规则），
	# 飞机仍停在场上，隐藏着会变「幽灵飞机」。
	_check(not _craft.is_interior_view(),
		"C 切追尾恢复 3D 机体外观（D-050，防幽灵飞机）")
	cam.toggle_first_third()   # → 座舱
	await _hold_and_wait(90, CRUISE_ALT)
	_check(cam.current_mode() == AircraftCamera.ViewMode.FIRST_PERSON, "C 切回座舱")

	# ── ③ 几何断言（先于截图，布局已稳定）──
	var cluster: CockpitInstruments = _hud._instrument_hud._cockpit
	_check(cluster != null and cluster.is_visible_in_tree(),
		"座舱视角下仪表簇可见（CockpitInstruments 已挂 HUD 覆盖层）")
	var tape_r: Rect2 = (cluster.tape as Control).get_global_rect()
	var gauge_r: Rect2 = (cluster.gauge as Control).get_global_rect()
	var alt_r: Rect2 = (cluster.alt_box as Control).get_global_rect()
	var spd_r: Rect2 = (cluster.spd_box as Control).get_global_rect()
	var vp := get_viewport().get_visible_rect().size
	print("DBG  viewport=", vp, " tape=", tape_r, " gauge=", gauge_r,
		" alt=", alt_r, " spd=", spd_r)
	_check(not tape_r.intersects(gauge_r) and not gauge_r.intersects(alt_r)
		and not gauge_r.intersects(spd_r) and not alt_r.intersects(spd_r)
		and not tape_r.intersects(alt_r) and not tape_r.intersects(spd_r),
		"仪表簇四件互不重叠（航向带/地平仪/ALT/SPD）")
	var card: Rect2 = _hud._flight_panel.get_global_rect()
	_check(not card.intersects(tape_r) and not card.intersects(gauge_r)
		and not card.intersects(alt_r) and not card.intersects(spd_r),
		"仪表簇与飞行面板卡片零重叠（卡片底 %.0f < 簇顶 %.0f）"
			% [card.end.y, mini(tape_r.position.y, mini(gauge_r.position.y,
				mini(alt_r.position.y, spd_r.position.y)))])
	_check(tape_r.position.y >= 0.0 and gauge_r.end.y <= vp.y
		and spd_r.position.x >= 0.0 and alt_r.end.x <= vp.x,
		"整簇在屏内（不出画面）")

	# ── D-050 座舱内视回归闸 ──
	# 根因（用户实测 cockpit_inst_bank.png「为何图中有机翼」）：座舱眼位
	# COCKPIT_OFFSET 落在机身盒内部，机翼（y 1.335..1.785）正压视平线、
	# 翼底面正对相机——第一人称看到的先是自己的机翼再是世界。修复：FP 隐藏
	# 3D 外部机模，座舱内装由 2D 像素座舱框（frame_rects）+ 仪表簇提供。
	_check(_craft.is_interior_view(),
		"座舱视角隐藏 3D 外部机模（D-050，不再横贯全屏的机翼）")
	var frame := CockpitInstruments.frame_rects(vp)
	var dash_r: Rect2 = frame["dash"]
	var post_l: Rect2 = frame["post_l"]
	var post_r: Rect2 = frame["post_r"]
	var rail: Rect2 = frame["rail"]
	_check(dash_r.encloses(tape_r) and dash_r.encloses(gauge_r)
		and dash_r.encloses(alt_r) and dash_r.encloses(spd_r),
		"dash 底板包住四件仪表（座舱内装分层：先画框、仪表坐上）")
	_check(not post_l.intersects(tape_r) and not post_r.intersects(tape_r)
		and not rail.intersects(card),
		"座舱框不压航向带与顶部卡片")

	# ── ① 转弯带坡度 ──
	# 比例俯仰保持高度 + 半幅副翼：30 m/s 入场能量下约 2~3 s 建立 22° 坡度。
	# 掉高度兜底：agl<18 立即回正（防转弯中失速坠地，首版实测过）。
	_craft.controls.roll = 0.45
	var banked := false
	for i in range(360):
		await get_tree().physics_frame
		if _craft.is_wrecked():
			_dbg_state("bank_wrecked")
			break
		var agl := float(_craft.snapshot()["altitude_agl"])
		_craft.controls.pitch = clampf((CRUISE_ALT - agl) * 0.08, -0.35, 0.5)
		if absf(_hud.instrument_hud().instruments_ref().roll_deg) > 22.0:
			banked = true
			break
		if agl < 40.0:
			_dbg_state("bank_low")
			break
		if i % 30 == 0:
			_dbg_state("bank")
	_check(banked and not _craft.is_wrecked(),
		"转弯建立 22° 以上坡度（仪表应有可读姿态）")
	# D-048 回归闸：节点位姿必须逐列等于纯逻辑姿态——座舱仪表与相机都读
	# global_transform，修复前节点 basis 冻结在出生值（模型坡度 45° 时
	# 仪表恒 0°），本断言把这类「会转弯不转身」回归钉死。
	# 不能改用「仪表读数 vs snapshot」同期比对：仪表 tick 走 _process（渲染
	# 帧），比物理帧慢，57°/s 的滚转里能差出 5°（实测 22.1° vs 16.9°）。
	_check(_craft.global_transform.basis.is_equal_approx(_craft._state.basis),
		"节点位姿跟随飞行模型（basis 逐列一致）")
	await _snap("cockpit_inst_bank.png")
	# 不回正、不拖延：下面的低空段与收尾段都走 place()（make_state 全新状态
	# + 速度归零 + 姿态水平 + 满油），预先带的坡度会被 place 整个覆盖。而转弯
	# 取证末飞机正以 ~22 m/s 俯冲（D-049 实测：放任 4 秒回正会飘出净空垫撞
	# 山解体，place() 又不复活残骸）——截图后直接进 place，把暴露窗口压到几帧。

	# ── ② 低空俯冲触发过低警告（ALT 变红闪烁）──
	# 放到净空垫上方 18m、给 -3 m/s 下沉：无前向速度即近似自由落体，1 秒后
	# AGL≈10、下沉率<-2.5 → alt_warn≥1；撞地前约 2s，截图窗口足够。
	# 首版教训：给前向速度会让失速速度下的升力不足、下沉率不可控；纯下落最稳。
	_craft.place(Vector3(float(ox) + 0.5, float(ground_y) + 18.0, float(oz) + 0.5), PI)
	_craft._state.velocity = Vector3(0.0, -3.0, 0.0)
	_craft.velocity = _craft._state.velocity
	_craft.controls.throttle = 0.3
	_craft.controls.pitch = 0.0
	_craft.controls.roll = 0.0
	await _wait_physics(60)   # 下沉率到位（AGL≈10m、vs<-2.5）
	var fi: FlightInstruments = _hud.instrument_hud().instruments_ref()
	_check(fi.alt_warn > 0 and not _craft.is_wrecked(),
		"低空俯冲触发高度过低警告（alt_warn=%d，AGL %.1f m）" % [fi.alt_warn, fi.altitude_agl])
	var st: Dictionary = cluster.debug_state()
	_check(st["alt_warn"], "警告态传到高度计（ALT 数字应变红闪烁）")
	await _snap("cockpit_inst_lowalt.png")

	# 拉回安全高度再收尾（带前向速度避免无升力直坠解体）。
	_craft.place(Vector3(float(ox) + 0.5, float(ground_y) + 28.0, float(oz) + 0.5), PI)
	_craft._state.velocity = Vector3(14.0, 1.0, 0.0)
	_craft.velocity = _craft._state.velocity
	_craft.controls.throttle = 0.6
	_craft.controls.pitch = 0.3
	await _wait_physics(90)

	SaveGuard.restore()
	print("COCKPIT_INST_DONE fails=%d" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)
