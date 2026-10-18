extends Node
## 座舱视角下起飞教练条避让取证（takeoff_coach_shot 的补充，不是替代）。
##
## 存在理由：takeoff_coach_shot.gd 全文不切视角（ride_aircraft 后无 set_mode），
## AircraftCamera._mode 默认 CHASE，六张截图全程走 BOTTOM_RESERVE=122 的旧路，
## 对「座舱视角 reserve=200」这条新路径零覆盖——那条正好是会把座舱玻璃 HUD
## 底部三行读数整块盖住的唯一路径。
##
## 本探针单独跑，不改 takeoff_coach_shot 的任何行为（六张截图保持原样）。
## 需窗口运行（截图走 Vulkan），勿加 --headless。
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/coach_cockpit_shot.tscn

const SHOT_DIR := "res://tmp"

## 四角 HUD 左右各留白（角标 230 + 16 边距 + 8 余量）：与 takeoff_coach._draw_bar
## 的窄屏兜底同源，此处用于算横条左右边界。
const SIDE_KEEP := 254.0
## 座舱玻璃 HUD 底部三行读数带（flight_instrument_hud._build_glass）：
## 锚底，offset_top=-120 / offset_bottom=-60，横向 W/2±160。
const GLASS_TOP := 120.0
const GLASS_BOTTOM := 60.0
const GLASS_HALF_W := 160.0

var _fails := 0
var _craft: Aircraft = null
var _player: Player = null


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
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	await _wait(20)

	_player = main_scene.get_node("Player")
	var world: World = main_scene.get_node("World")
	# 出生点即平地：只清头顶杂物并抹平脚下（与 takeoff_coach_shot 同法，
	# 比自建跑道稳——候选跑道坐标会随区域尺寸落到地图外）。
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
	# 踩坑（aircraft.gd:345-347）：drive_remotely() 内部 set_piloted(true) **不带 who**，
	# 会把 ride_aircraft 刚设好的 _craft.rider 清回 null。真实手动登机没有这一步，
	# rider 正常；takeoff_coach._refresh_bottom_reserve 正是读 rider.flight_camera。
	# 这里补一次带 who 的 set_piloted 把探针拉回「真人驾驶」状态，否则座舱判据失效。
	_craft.set_piloted(true, _player)
	for i in range(300):
		await get_tree().physics_frame
		if _craft.is_on_floor() and _craft.velocity.length() < 0.5:
			break
	await _wait_physics(6)

	# 引擎点火 + 油门半程：教练停在「② 按住【W】把油门推到底」。该步 flash=false
	# → 描边 alpha=1.0、颜色固定为 COL_KEY(1.0, 0.88, 0.35)，截图可复现（不闪）。
	_craft.set_engine(true)
	_craft.controls.throttle = 0.3
	await _wait_physics(6)

	var cam: AircraftCamera = _player.flight_camera
	_check(cam != null, "AircraftCamera 已注入 Player.flight_camera")
	_check(cam.current_mode() == AircraftCamera.ViewMode.CHASE,
		"默认视角为追尾 CHASE（与 takeoff_coach_shot 一致）")
	_check(_craft.rider == _player,
		"drive_remotely() 未抹掉 rider（aircraft.gd:347 的坑，已按真人状态补回）")
	var coach: TakeoffCoach = hud._takeoff_coach
	_check(coach != null, "HUD 持有起飞教练节点")
	await _wait_physics(2)
	_check(is_equal_approx(coach._bottom_reserve, TakeoffCoach.BOTTOM_RESERVE),
		"追尾视角 reserve=122.0（实测 %.1f）" % coach._bottom_reserve)
	# 追尾对照截图：证明本探针不改 takeoff_coach_shot 六张图的旧行为（reserve 122）。
	await _snap(coach, "coach_cockpit_ctrl_chase.png")

	# ── 切座舱 ──
	cam.set_mode(AircraftCamera.ViewMode.FIRST_PERSON)
	await _wait(90)   # 视角阻尼收敛，与 flight_view_probe 同等待时长
	_check(cam.current_mode() == AircraftCamera.ViewMode.FIRST_PERSON,
		"已切到第一人称座舱")
	await _wait_physics(2)
	_check(is_equal_approx(coach._bottom_reserve, TakeoffCoach.BOTTOM_RESERVE_COCKPIT),
		"座舱视角 reserve=200.0（实测 %.1f）" % coach._bottom_reserve)

	var size := coach.get_size()
	var w := minf(520.0, size.x - 2.0 * SIDE_KEEP)
	var rect := Rect2(Vector2(size.x * 0.5 - w * 0.5, size.y - coach._bottom_reserve),
		Vector2(w, 58.0))
	var glass := Rect2(Vector2(size.x * 0.5 - GLASS_HALF_W, size.y - GLASS_TOP),
		Vector2(GLASS_HALF_W * 2.0, GLASS_TOP - GLASS_BOTTOM))
	print("DBG  viewport=", size, " cockpit rect=", rect, " glass band=", glass)

	# 几何断言：横条必须整块落在读数带**上方**（不遮挡玻璃 HUD 三行读数）。
	_check(rect.intersection(glass).get_area() < 0.0001,
		"教练条与玻璃 HUD 读数带零重叠（横条底 %.0f < 读数带顶 %.0f，间隙 %.0f px）"
			% [rect.end.y, glass.position.y, glass.position.y - rect.end.y])
	# 1280×720 与 1560×720（最小横向投影分辨率）下的期望值。
	for want: Vector2i in [Vector2i(1280, 720), Vector2i(1560, 720)]:
		var ew := minf(520.0, float(want.x) - 2.0 * SIDE_KEEP)
		var ex := float(want.x) * 0.5 - ew * 0.5
		_check(absf(rect.size.x - ew) < 0.001,
			"%d×%d 横条宽 %.0f（minf 窄屏兜底未触发）" % [want.x, want.y, rect.size.x])
		if absf(float(want.x) - size.x) < 0.001:
			_check(absf(rect.position.x - ex) < 0.001,
				"%d×%d 横条左界 %.0f（期望 %.0f）" % [want.x, want.y, rect.position.x, ex])
	_check(absf(rect.position.y - (size.y - 200.0)) < 0.001,
		"座舱横条顶边 y=%.0f（期望 %.0f）" % [rect.position.y, size.y - 200.0])

	var path := _shot_path("coach_7_cockpit.png")

	# 像素取证：冻结场景树，只切教练显隐各拍一张，diff 出教练真正画出来的像素，
	# 与计算的 rect 比。比抠描边色稳（座舱场景本身有黄色物体会污染阈值）；
	# 冻结是必须的——不冻的话相机阻尼/物理在两帧间继续走，diff 会糊满全屏
	# （实测未冻结时外包矩形 1280×667，噪声把教练淹了）。
	get_tree().paused = true
	coach.visible = true
	coach.queue_redraw()
	await _wait(2)
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(path)
	coach.visible = false
	await _wait(1)
	await RenderingServer.frame_post_draw
	var img_off: Image = get_viewport().get_texture().get_image()
	get_tree().paused = false
	coach.visible = true
	print("DBG  saved ", path, "（座舱、教练可见）")
	var bbox := _diff_bbox(img, img_off)
	print("DBG  coach 画出来的像素外包矩形=", bbox, "（计算 rect=", rect, "）")
	if bbox.get_area() > 0.0:
		_check(absf(bbox.size.x - rect.size.x) < 6.0
				and absf(bbox.size.y - rect.size.y) < 6.0,
			"像素外包矩形与计算矩形同尺寸（%.0f×%.0f vs %.0f×%.0f）"
				% [bbox.size.x, bbox.size.y, rect.size.x, rect.size.y])
		_check(absf(bbox.position.y - rect.position.y) < 5.0
				and absf(bbox.position.x - rect.position.x) < 6.0,
			"像素位置与计算位置一致（y %.0f vs %.0f，x %.0f vs %.0f）"
				% [bbox.position.y, rect.position.y, bbox.position.x, rect.position.x])
		_check(bbox.end.y <= glass.position.y,
			"像素证据：教练图形底边 %.0f 未侵入读数带顶 %.0f（余 %.0f px）"
				% [bbox.end.y, glass.position.y, glass.position.y - bbox.end.y])
	else:
		_check(false, "diff 未找到教练图形（界面没画出来？）")

	# 不吃鸟：Coach 在座舱视角下仍可见（不该被清掉）。
	_check(coach.visible, "座舱视角下教练条仍可见")

	SaveGuard.restore()
	print("COACH_COCKPIT_DONE fails=%d" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _snap(coach: TakeoffCoach, file_name: String) -> void:
	await _wait(2)
	await RenderingServer.frame_post_draw
	var path := _shot_path(file_name)
	get_viewport().get_texture().get_image().save_png(path)
	print("DBG  saved ", path, " reserve=", coach._bottom_reserve,
		" visible=", coach.visible)


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


## 两屏差异像素的外包矩形（差异阈值偏大以吸收两帧间的轻微噪声）。
func _diff_bbox(a: Image, b: Image) -> Rect2:
	if a.get_size() != b.get_size():
		return Rect2()
	var min_x := 1 << 30
	var min_y := 1 << 30
	var max_x := -(1 << 30)
	var max_y := -(1 << 30)
	for y in range(0, a.get_height()):
		for x in range(0, a.get_width()):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > 0.12:
				min_x = mini(min_x, x)
				min_y = mini(min_y, y)
				max_x = maxi(max_x, x)
				max_y = maxi(max_y, y)
	if max_x < min_x:
		return Rect2()
	return Rect2(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)
