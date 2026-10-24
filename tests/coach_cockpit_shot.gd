extends Node
## 起飞教练合并进飞行面板后的座舱视角取证（D-046；重写自 D-045 的底部横条版）。
##
## 背景：D-043 的教练条原是屏幕底部独立横条，D-045 为避开座舱玻璃 HUD 的底部
## 三行读数带（y H-120…H-60）给它加了 reserve=200 的避让。D-046 按用户要求
## 「2区和3区合并按照2区风格展示」把教练条并进顶部居中的飞行面板卡片后，底部
## 避让整条链路失去存在理由——本探针改验新布局的四件事：
##   ① 教练区（主句 / 副句 / 进度条）整块落在飞行面板卡片矩形内——真的合并了；
##   ② 追尾视角下卡片与左上角读数 _c_tl 零重叠；
##   ③ 座舱视角下卡片与座舱仪表簇零重叠（D-047 起 CockpitInstruments 替换了
##      玻璃 HUD 底部三行文字带，旧「玻璃读数带」冲突从此不该存在）；
##   ④ 登机后左上角状态块与顶部居中世界名都隐藏（D-046 用户要求「1区不显示」）。
## 需窗口运行（截图走 Vulkan），勿加 --headless。
## 运行：Godot_v4.6.3-stable_win64_console.exe --path . res://tests/coach_cockpit_shot.tscn

const PROBE_PAD := preload("res://tests/probe_pad.gd")
const SHOT_DIR := "res://tmp"

var _fails := 0
var _craft: Aircraft = null
var _player: Player = null
var _hud: HUD = null


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


## 墙钟等待（秒）。**不要用 `_wait(帧数)` 等「视角阻尼收敛」这类真实时间过程**：
## 引擎 0.3 油门一直在推，而全量回归下流式队列一忙单帧可达 100~200 ms，
## 90 帧可能横跨十几秒 —— 飞机早已滑出探针平台摔成残骸，D-056 自动归位把
## 玩家弹回出生点，于是「仪表簇不可见」这种假失败（2026-10-22 全量回归实测）。
func _wait_sec(t: float) -> void:
	await get_tree().create_timer(t).timeout


func _ready() -> void:
	await _run()


func _run() -> void:
	SaveGuard.snapshot()
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
	# 场地：出生点周围铺平整平台并给出安全落位点（落位为什么要偏开玩家、
	# 平台高度为什么要实心面扫描，见 tests/probe_pad.gd 的类注释）。
	var pad := PROBE_PAD.prepare(world, _player)
	await _wait_physics(12)
	# 显式标类型：字典取值是 Variant，直接传参触发 UNSAFE_CALL_ARGUMENT
	# （本项目 GDScript 警告即错误）。
	var spawn_pos: Vector3 = pad["spawn"]
	_craft = Aircraft.spawn(main_scene, spawn_pos, PI)
	await _wait_physics(2)

	_player.ride_aircraft(_craft)
	_craft.drive_remotely()
	# 踩坑（aircraft.gd:345-347）：drive_remotely() 内部 set_piloted(true) **不带 who**，
	# 会把 ride_aircraft 刚设好的 _craft.rider 清回 null。真实手动登机没有这一步，
	# rider 正常；座舱判据（rider.flight_camera）正依赖它。这里补一次带 who 的
	# set_piloted 把探针拉回「真人驾驶」状态。
	_craft.set_piloted(true, _player)
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
		print("PROBE_ABORT[COACH_COCKPIT_DONE] fails=%d" % _fails)
		get_tree().quit(1)
		return

	# 引擎点火 + 油门半程：教练停在「② 按住【W】推满油门」。该步 flash=false
	# → 主句 alpha=1.0、颜色固定为 COL_KEY(1.0, 0.88, 0.35)，截图可复现（不闪）。
	_craft.set_engine(true)
	_craft.controls.throttle = 0.3
	await _wait_physics(6)

	var cam: AircraftCamera = _player.flight_camera
	_check(cam != null, "AircraftCamera 已注入 Player.flight_camera")
	# D-049：登机默认第一人称座舱（用户要求「默认登机后进入第一人称视角」）。
	# ② 的追尾几何/截图改由一次 C 键切出覆盖（互切双向可用本身也是回归点）。
	_check(cam.current_mode() == AircraftCamera.ViewMode.FIRST_PERSON,
		"默认视角为第一人称座舱（D-049）")
	# D-050：座舱内视——第一人称隐藏 3D 外部机模（眼位在机身盒内部、机翼
	# 正压视平线，修复前「第一人称」看到的是自己的机翼横贯全屏）。
	_check(_craft.is_interior_view(),
		"座舱视角隐藏 3D 外部机模（D-050，不再看见机翼）")
	cam.toggle_first_third()   # → 追尾
	await _wait_sec(1.5)   # 视角阻尼收敛（墙钟，不用帧数：见 _wait_sec 注释）
	_check(cam.current_mode() == AircraftCamera.ViewMode.CHASE,
		"C 键切到追尾（② 追尾几何取证的起点）")
	_check(not _craft.is_interior_view(),
		"切追尾恢复 3D 机体外观（D-050，防幽灵飞机）")
	_check(_craft.rider == _player,
		"drive_remotely() 未抹掉 rider（aircraft.gd:347 的坑，已按真人状态补回）")

	# ── ④ D-046：登机后状态块与世界名都隐藏 ──
	_check(not _hud._stats_box.is_visible_in_tree(),
		"登机后左上角状态块隐藏（姓名+生命+饥饿，用户要求「1区不显示」）")
	_check(not _hud._map_name_label.is_visible_in_tree(),
		"登机后顶部居中世界名隐藏（不再贴住飞行面板标题右侧）")

	# ── ① 教练区真的并进了飞行面板卡片 ──
	var card: Rect2 = _hud._flight_panel.get_global_rect()
	var main_rect: Rect2 = _hud._coach_main.get_global_rect()
	var sub_rect: Rect2 = _hud._coach_sub.get_global_rect()
	var bar_rect: Rect2 = _hud._coach_bar.get_global_rect()
	print("DBG  card=", card, " coach_main=", main_rect)
	_check(_hud._coach_main.is_visible_in_tree(), "教练主句在树内可见（登机即带一遍）")
	_check(card.encloses(main_rect), "教练主句整块落在飞行面板卡片内（真的合并了）")
	_check(card.encloses(sub_rect), "教练副句整块落在飞行面板卡片内")
	_check(card.encloses(bar_rect), "教练进度条整块落在飞行面板卡片内")
	_check(String(_hud._coach_main.text).contains("W"), "教练主句是第②步推油门（含 W）")
	# U-8 目检后续（D-069）：字号只对失速教案放大（17/13），起飞教练维持
	# 15/12——其内容非安全关键，且卡片行高按 15 排过版。
	_check(_hud._coach_main.get_theme_font_size("font_size") == 15,
		"起飞教练主句字号维持 15（实际 %d）" % _hud._coach_main.get_theme_font_size("font_size"))
	_check(_hud._coach_sub.get_theme_font_size("font_size") == 12,
		"起飞教练副句字号维持 12（实际 %d）" % _hud._coach_sub.get_theme_font_size("font_size"))

	# ── ② 追尾：卡片与左上角读数 _c_tl 零重叠 ──
	var c_tl: Rect2 = _hud._instrument_hud._c_tl.get_global_rect()
	_check(not card.intersects(c_tl),
		"追尾：卡片与左上角读数 _c_tl 零重叠（卡片 x %.0f…%.0f vs 读数 x %.0f…%.0f）"
			% [card.position.x, card.end.x, c_tl.position.x, c_tl.end.x])
	await _snap("coach_cockpit_ctrl_chase.png")

	# ── 切座舱 ──
	cam.toggle_first_third()   # → 第一人称座舱
	await _wait_sec(0.4)   # 进座舱是刚性吸附（D-065），只等 HUD 完成一次重布局
	_check(cam.current_mode() == AircraftCamera.ViewMode.FIRST_PERSON,
		"C 键切回第一人称座舱")
	await _wait_physics(2)
	# 前置守卫：这一段的三条断言全依赖「人还在座舱里」。少了这条，一次
	# 意外坠机（自动归位 → 步行 HUD）会被报成「仪表簇不可见」这种误导性失败。
	var on_board := _player.is_riding() and is_instance_valid(_craft) and not _craft.is_wrecked()
	_check(on_board, "座舱段前置：玩家仍在座舱内（riding=%s）" % str(_player.is_riding()))
	if not on_board:
		SaveGuard.restore()
		print("COACH_COCKPIT_DONE fails=%d" % _fails)
		get_tree().quit(1)
		return

	# ── ③ 座舱：卡片与座舱仪表簇（D-047）零重叠 ──
	# D-047 起玻璃 HUD 底部三行文字带被 CockpitInstruments 仪表簇（地平仪 +
	# 高度计 + 航向仪 + SPD 框，锚底居中）替换；旧 GLASS_* 常量随文字带退役，
	# 这里直接取真实节点矩形。
	var vp := get_viewport().get_visible_rect().size
	var cluster: CockpitInstruments = _hud._instrument_hud._cockpit
	var gauge_r: Rect2 = (cluster.gauge as Control).get_global_rect()
	var tape_r: Rect2 = (cluster.tape as Control).get_global_rect()
	card = _hud._flight_panel.get_global_rect()
	print("DBG  viewport=", vp, " card=", card, " gauge=", gauge_r, " tape=", tape_r)
	_check(cluster.is_visible_in_tree(), "座舱视角下仪表簇可见（D-047 替换玻璃文字带）")
	_check(not card.intersects(gauge_r) and not card.intersects(tape_r),
		"座舱：卡片与座舱仪表簇零重叠（卡片底 %.0f < 簇顶 %.0f，间隙 %.0f px）"
			% [card.end.y, tape_r.position.y, tape_r.position.y - card.end.y])
	_check(gauge_r.end.y <= vp.y and tape_r.position.y >= 0.0,
		"座舱仪表簇整簇在屏内（不出画面）")
	_check(_hud._coach_main.is_visible_in_tree(),
		"座舱视角下教练区仍显示（不因切视角被清掉）")
	await _snap("coach_cockpit_view.png")

	SaveGuard.restore()
	print("COACH_COCKPIT_DONE fails=%d" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _snap(file_name: String) -> void:
	await _wait(2)
	await RenderingServer.frame_post_draw
	var path := _shot_path(file_name)
	get_viewport().get_texture().get_image().save_png(path)
	print("DBG  saved ", path)


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)
