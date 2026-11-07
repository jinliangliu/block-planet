extends Node
## 起飞教练取证（D-043 / D-046）：登机后按「点火 → 推油门 → 滑跑 → 抬轮 → 离地」
## 六个阶段各出一张截图，验证教练区文案、配色与进度条是否随状态推进。
## D-046 起教练区不再是屏幕底部独立横条，而是合并进顶部居中的飞行面板卡片
## （「2区和3区合并按照2区风格展示」）——截图里它是卡片的最后几行，另在
## coach_7_cruise 验证起飞成功后教练区收起、卡片缩回原高度。
##
## 不依赖长跑道：速度由 Aircraft.launch() 直接给（抬轮段给到抬轮速度以上即可
## 触发「按 ↑ 抬轮」，无需真的滑跑 18 m）。操纵量走 drive_remotely 外部写入，
## 与飞行手感无关，只验证教练区的状态机与渲染。
## 需窗口运行，勿加 --headless。
## 运行：Godot_v4.6.3-stable_win64_console.exe --path . res://tests/takeoff_coach_shot.tscn

const PROBE_PAD := preload("res://tests/probe_pad.gd")
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


func _snap(file_name: String) -> void:
	await _wait(2)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path(file_name))
	# 机体可能已被坠机回收（残骸 4 s 自消散）：对已释放对象发消息会抛
	# SCRIPT ERROR 杀掉协程，restore/quit 都跑不到 —— 进程挂到超时 rc=124，
	# 而回归脚本只看 PASS/FAIL 汇总，会把这当成「探针本身坏了」。这里判有效
	# 性并记一条 FAIL，让失败以断言形式暴露。
	if not is_instance_valid(_craft):
		_fails += 1
		print("FAIL: 截图时机体已释放（", file_name, " 之前已坠机）")
		return
	var s := _craft.snapshot()
	print("DBG ", file_name, " engine=", s["engine"], " throttle=%.2f" % float(s["throttle"]),
		" kmh=%.1f" % float(s["kmh"]), " vs=%.1f m/s" % float(s["stall_speed"]),
		" on_ground=", s["on_ground"], " agl=%.1f" % float(s["altitude_agl"]))


## 写入杆量：机体已释放（坠机残骸 4 s 自消散后被回收）时静默跳过，避免对
## freed 对象发消息抛 SCRIPT ERROR 杀掉协程（见 _snap 注释）。
func _set_pitch(value: float) -> void:
	if is_instance_valid(_craft):
		_craft.controls.pitch = value


## 离地高度读数；机体已释放（坠机回收）时返回 -1，让等待循环自然退出而不是
## 对 freed 对象发消息（那会抛 SCRIPT ERROR 杀掉协程，见 _snap 注释）。
func _agl() -> float:
	if not is_instance_valid(_craft):
		return -1.0
	return float(_craft.snapshot()["altitude_agl"])


func _ready() -> void:
	await _run()


func _run() -> void:
	SaveGuard.snapshot()
	GameState.needs_region_pick = false
	GameState.current_region = RegionAtlas.ASIA

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	await _wait(120)

	var hud: HUD = main_scene.get_node("UI")
	_hud = hud
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
	# 停刷怪：生物撞机会扰动滑跑段（对齐 flight_hud_shot）。
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	await _wait(20)

	_player = main_scene.get_node("Player")
	var world: World = main_scene.get_node("World")
	# 场地：出生点周围铺平整平台并给出安全落位点（落位为什么要偏开玩家、
	# 平台高度为什么要实心面扫描，见 tests/probe_pad.gd 的类注释）。
	var pad := PROBE_PAD.prepare(world, _player)
	await _wait_physics(12)
	# 显式标类型：字典取值是 Variant，直接传参触发 UNSAFE_CALL_ARGUMENT
	# （本项目 GDScript 警告即错误）。
	var spawn_pos: Vector3 = pad["spawn"]
	_craft = Aircraft.spawn(main_scene, spawn_pos, PI)
	await _wait_physics(2)

	# 先登机 + 远程驾驶：飞机在**未驾驶**时物理积分不跑，先等落地会永远悬空。
	# 登机后物理激活，再等它自然落稳（on_ground 且几乎不动）。
	_player.ride_aircraft(_craft)
	_craft.drive_remotely()
	for i in range(300):
		await get_tree().physics_frame
		# 机体可能已被坠机回收（残骸 4 s 自消散）：继续读它会抛 SCRIPT ERROR
		# 杀掉协程，restore/quit 都跑不到 —— 进程挂到 rc=124 且污染存档。
		if not is_instance_valid(_craft):
			break
		if _craft.is_on_floor() and _craft.velocity.length() < 0.5:
			break
	await _wait_physics(6)
	if not is_instance_valid(_craft):
		_check(false, "就位阶段机体解体并被回收（落位点压到玩家/地形）")
		SaveGuard.restore()
		print("PROBE_ABORT[COACH_SHOT_DONE] fails=%d" % _fails)
		get_tree().quit(1)
		return

	# ① 刚登机：发动机默认熄火（这正是新手「推油门没反应」的卡点）。
	# D-046 合并布局断言：教练区是飞行面板卡片的最后几行；登机即隐藏状态块
	# 与世界名（用户要求「1区不显示」）。
	# 先钉「机体完好」：飞机若在就位阶段就被地形顶穿解体，教练卡片会整卡隐藏
	# （_refresh_flight_panel 见 is_wrecked 直接 return），后面四条断言全部连坐
	# 假阴性——把根因单独钉出来，一眼看出是落位问题还是 UI 问题。
	_check(not _craft.is_wrecked(), "就位后机体完好（未被地形顶穿解体）")
	_check(_hud._flight_panel.visible, "登机后飞行面板卡片显示（教练区挂在其中）")
	_check(_hud._coach_main.is_visible_in_tree(), "教练主句在卡片内显示（第①步点火）")
	var card: Rect2 = _hud._flight_panel.get_global_rect()
	_check(card.encloses(_hud._coach_main.get_global_rect()),
		"教练主句整块落在飞行面板卡片内（D-046 合并）")
	_check(not _hud._stats_box.is_visible_in_tree(), "登机后左上角状态块隐藏")
	_check(not _hud._map_name_label.is_visible_in_tree(), "登机后顶部居中世界名隐藏")
	await _snap("coach_1_engine_off.png")

	# ② 已点火、油门 0。
	_craft.set_engine(true)
	_craft.controls.throttle = 0.0
	await _wait_physics(4)
	await _snap("coach_2_throttle.png")

	# ③ 油门推满、速度还不够。
	_craft.controls.throttle = 1.0
	await _wait_physics(40)
	await _snap("coach_3_roll.png")

	# ④ 给到抬轮速度以上：教练该喊「按 ↑ 抬轮」。
	var vr_mps := float(_craft.snapshot()["stall_speed"]) * 1.2
	_craft.launch(vr_mps + 2.0)
	await _wait_physics(4)
	await _snap("coach_4_rotate.png")

	# ⑤ 拉杆离地：爬升中 / 起飞成功。
	_set_pitch(0.7)
	for i in range(180):
		await get_tree().physics_frame
		if _agl() > 4.0:
			break
	await _snap("coach_5_climb.png")

	for i in range(240):
		await get_tree().physics_frame
		if _agl() > 16.0:
			break
	await _snap("coach_6_success.png")

	# ⑦ D-074 Gap A 是**双门槛**：横幅 SUCCESS_HOLD(3.5 s) 过期后，还要
	# AGL >= SAFE_AGL(40 m) 才返回空字典收起教练区；未到 40 m 会持续提示
	# 「继续爬升到安全高度」（takeoff_coach.gd:148，防新手在谷地提前下降）。
	# 旧探针只等 _agl()>20 就停爬，实测停在 38.2 m → 断言必然红，是规格过时
	# 造成的机会性失败（10-27 恰好爬到 41.3 m 才侥幸全绿）。
	# 等真实时间一律用墙钟（坑 #1：帧数 ≠ 时间）；横幅计时器走 _process(delta)。
	# 且不能持续压杆：controls.pitch 是角速度目标而非姿态（坑 #21），一直压 0.4
	# 会抬头失速、把 68 m 掉回 32 m，反而重新触发「继续爬升」。改成松杆 + 被动
	# 高度配平（D-074）、低于门槛才轻拉的构造式保高循环。
	_set_pitch(0.4)
	for i in range(600):
		await get_tree().physics_frame
		if _agl() >= TakeoffCoach.SAFE_AGL + 2.0:
			break
	var hold_ms := int((TakeoffCoach.SUCCESS_HOLD + 0.5) * 1000.0)
	var t_start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t_start < hold_ms:
		await get_tree().physics_frame
		if _agl() < TakeoffCoach.SAFE_AGL + 2.0:
			_set_pitch(0.15)
		else:
			_set_pitch(0.0)
	_set_pitch(0.0)
	# 坑 #2：process_frame 在 _process 之前发出，至少等 3 帧让 coach 的
	# _process(delta) → step_for() 真正跑到「横幅过期 + AGL 达标」的那一帧。
	for i in range(3):
		await get_tree().process_frame
	# 反向对照守卫：去掉 SAFE_AGL 门槛或保高循环，本条先红，不会静默误报。
	_check(_agl() >= TakeoffCoach.SAFE_AGL,
		"前置守卫：横幅过期时仍维持安全高度 %.1f m >= SAFE_AGL %.0f m" % [_agl(), TakeoffCoach.SAFE_AGL])
	_check(not _hud._coach_main.is_visible_in_tree(),
		"起飞成功横幅过期且已到安全高度后教练区收起（卡片缩回原高度，巡航不占屏）")
	await _snap("coach_7_cruise.png")

	SaveGuard.restore()
	print("COACH_SHOT_DONE fails=%d" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)
