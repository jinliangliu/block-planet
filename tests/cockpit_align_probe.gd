extends Node
## 3D 仪表台「与 2D 簇重合」对齐探针（D-065，无头）。
##
## 为什么这条必须是断言而不是目检：L2 的全部价值就是「正视时 3D 仪表台正落在
## 2D dash 板里」。差 30 px 读起来就是「另一块板」，而窗口截图靠肉眼判不出 12 px
## 级的偏差。这里把 uiux 用投影反解出来的四角目标值钉成闸，改任何一侧的常量
## （PANEL_W/H/POS/TILT、FOV、眼位、2D dash 矩形）都会立刻红。
##
## 目标值来源（1280×720、FOV 82° KEEP_HEIGHT、视线 = 机头轴 +6.26°）：
##   TL(373.7, 572.1)  TR(906.3, 572.1)  BL(323.7, 726.8)  BR(956.3, 726.8)
## 底边 726.8 已在画面外（720）——这是有意的：面板下沿要「切」在屏幕底，否则
## 2D dash 板上沿与面板顶沿之间会露出一条世界。
##
## 前置：**发动机必须熄火**（默认就是熄火）。镜头抖动 SHAKE_AMP=0.05 在 0.85 m
## 处会带来 20~36 px 的投影位移，比 12 px 容差还大——开着发动机量对齐等于量噪声。
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/cockpit_align_probe.tscn

const PROBE_PAD := preload("res://tests/probe_pad.gd")
const VIEW := Vector2(1280.0, 720.0)
## 四角目标（uiux 反解值），顺序 TL / TR / BL / BR。
const TARGET := [
	Vector2(373.7, 572.1),
	Vector2(906.3, 572.1),
	Vector2(323.7, 726.8),
	Vector2(956.3, 726.8),
]
## 容差（px）：dash 板最小结构特征是 3 px 勾边、9 px 螺钉，12 px ≈ 4 倍特征尺寸；
## 再大就会读成「另一块板」而不是「同一块」。同时 12 px = 屏宽 0.94%，V 切换时
## 位置交接肉眼无感。
const TOL := 12.0

var _fails := 0
var _craft: Aircraft = null
var _player: Player = null
var _cam: AircraftCamera = null
var _panel: CockpitPanel = null
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


func _ready() -> void:
	await _run()


func _run() -> void:
	# 无头根视口默认是 1280×1280（正方形），unproject 出来的不是真实投影——
	# 对齐断言必须先把窗口钉成项目的 1280×720 才有意义。
	get_window().size = Vector2i(int(VIEW.x), int(VIEW.y))
	await get_tree().process_frame
	SaveGuard.snapshot()
	GameState.needs_region_pick = false
	GameState.current_region = RegionAtlas.ASIA
	FlightSettings.set_current(FlightSettings.for_difficulty(FlightSettings.Difficulty.NORMAL))
	# 关风：本条是**静态几何**闸——量面板四角与 2D dash 矩形的重合，与气象无关。
	# D-067 起默认有风：停放机在地面风的气动力矩下持续微转动（机轮支撑vs风扭矩），
	# 而座舱相机姿态走 slerp 阻尼（D-065 刻意不做刚性——旋转平滑是舒适度需要），
	# 机体微转动→相机基滞后→面板投影整体偏移数 px（实测 +3.8 px，BR 角 960.4
	# 越过 dash 右缘 958.0，C2 零余量闸误红；且是否撞线看当次风向/切变，随运行
	# 翻转——同代码两次运行一绿一红）。与 A0「熄火再量」同一方法论：量对齐前
	# 先掐掉运动源。风的飞行影响由 wind_flight_probe 专责验证。
	FlightSettings.current().wind_enabled = false

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
	await _wait_physics(6)
	if not is_instance_valid(_craft) or _craft.is_wrecked():
		_fail_and_quit("就位阶段机体解体（先查 probe_pad）")
		return
	_cam = _player.flight_camera
	# 面板按类型取：脚本类 new() 出来的节点名由引擎决定，按名字 find_child 会静默
	# 取不到（内装探针踩过一次）。
	for child: Node in _craft.get_children():
		if child is CockpitPanel:
			_panel = child as CockpitPanel
			break
	if _panel == null:
		_fail_and_quit("机体下没有 CockpitPanel")
		return
	await _wait(4)   # 让相机跑过一次 _process，位姿落到眼位上

	_check(not _craft.engine_running, "A0 发动机熄火（抖动会带来 20~36 px 投影位移，量对齐须静置）")
	_check_material_binding()
	_check_2d_dash()
	await _check_corners()
	await _check_modes()

	GameState.needs_region_pick = true
	SaveGuard.restore()
	_restored = true
	print("COCKPIT_ALIGN_TEST_%s" % ("OK" if _fails == 0 else "FAILED"))
	get_tree().quit(0 if _fails == 0 else 1)


## ── 2D 侧：dash 板矩形未被动过（D-053 尺寸纪律红线）──────────
func _check_2d_dash() -> void:
	var metrics := CockpitInstruments.metrics(VIEW)
	var dash: Rect2 = metrics["dash"]
	# 分数几何：dash 高度恒为屏高 25.18%（D-053 定稿 14.1% 是 dash 内读数带，
	# 25.2% 是整块 dash 板）。用分数而不是像素，才能同时约束其它分辨率。
	var frac := dash.size.y / VIEW.y
	_check(absf(frac - 0.2518) < 1e-3,
		"A1 2D dash 板高恒为屏高 25.18%%（实测 %.4f；D-053 红线不得顶回去）" % frac)
	_check(absf(dash.position.x - 322.0) < 1.0 and absf(dash.size.x - 636.0) < 1.0,
		"A2 2D dash 板矩形未变形（x %.1f..%.1f）" % [dash.position.x, dash.end.x])


## ── 贴图绑定（白屏闸）──────────────────────────────────────
## 旧实现把路径式 ViewportTexture 同时贴到 albedo 与 emission 上，路径在「材质」这种
## 不属于任何场景节点的资源上解析失败 → 两侧都退化成白，面板整块白板。它从 D-034 起
## 就存在，只是因为面板一直藏在不透明机身盒里、没人看见过画面，直到 L2 反转把面板
## 推到台前才暴露。现在改成 `get_texture()` 直接引用 + 只用 emission 显示（albedo 黑），
## 失败模式也从「刺眼白板」改为「黑板（深座舱里看不见）」。
func _check_material_binding() -> void:
	var plane := _panel.get_node_or_null("Dashboard") as MeshInstance3D
	if plane == null:
		_check(false, "A0a 找不到 Dashboard 面片")
		return
	var mat: StandardMaterial3D = plane.get_surface_override_material(0) as StandardMaterial3D
	if mat == null:
		_check(false, "A0a 面板没有材质")
		return
	# 现行做法是 **unshaded + albedo 贴图**（不再走 emission）：贴图直出、不做光照，
	# 失败模式是「黑屏」而不是「刺眼白板」。曾经用 emission 路线时它把路径式
	# ViewportTexture 同时贴 albedo 与 emission，路径在材质资源上解析失败 → 两侧都
	# 退化成白，面板整块白板（从 D-034 起就存在，只是面板一直埋在不透明机身盒里）。
	_check(mat.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED,
		"A0a 面板材质是 unshaded（贴图直出，不参与光照）")
	_check(mat.albedo_texture is ViewportTexture,
		"A0b albedo 贴图是 ViewportTexture（不是路径回退的空纹理）")
	_check(mat.albedo_texture != null
			and mat.albedo_texture.get_size() == Vector2(768.0, 168.0),
		"A0c 贴图尺寸 = SubViewport 尺寸 768×168（绑定生效；失效会退回 0 或默认尺寸）")
	# 只走一条采样路径：emission 不参与，否则贴图内容会被乘两遍。
	_check(not mat.emission_enabled and mat.emission_texture == null,
		"A0d emission 关闭（只走 albedo 一条采样路径）")


## ── 3D 侧：面板四角投影 ─────────────────────────────────────
func _check_corners() -> void:
	# 面板几何在**子节点 Dashboard（PlaneMesh）**上：CockpitPanel 节点本身在机体原点，
	# PANEL_POS/PANEL_TILT_DEG 是 plane 的局部变换。用错节点会拿到「面板在机腹原点、
	# 法线朝机头」的假位姿（投影会左右翻转 + 缩小 2.4 倍，一度让人以为朝向配错）。
	var plane := _panel.get_node_or_null("Dashboard") as Node3D
	if plane == null:
		_check(false, "B0 找不到 Dashboard 面片节点（命名契约变了）")
		return
	var xf := plane.global_transform
	var half := Vector3(CockpitPanel.PANEL_W * 0.5, CockpitPanel.PANEL_H * 0.5, 0.0)
	var corners := [
		xf * Vector3(-half.x, half.y, 0.0),    # TL：屏幕坐标 y 向下，故 +half.y 在上
		xf * Vector3(half.x, half.y, 0.0),
		xf * Vector3(-half.x, -half.y, 0.0),
		xf * Vector3(half.x, -half.y, 0.0),
	]
	var names := ["TL", "TR", "BL", "BR"]
	var dash: Rect2 = CockpitInstruments.metrics(VIEW)["dash"]
	for i in range(4):
		var px: Vector2 = _cam.unproject_position(corners[i])
		var tgt: Vector2 = TARGET[i]
		var d := px.distance_to(tgt)
		_check(d <= TOL, "B%d %s 投影 %s 距目标 %s 偏差 %.1f px ≤ %.0f"
			% [i + 1, names[i], str(px.round()), str(tgt), d, TOL])
	# 上两角必须落在 2D dash 板内（否则正视时 3D 面板会在 2D 板上沿露出）
	var tl: Vector2 = _cam.unproject_position(corners[0])
	var tr: Vector2 = _cam.unproject_position(corners[1])
	_check(dash.has_point(tl) and dash.has_point(tr),
		"C1 面板上两角落在 2D dash 板内（TL/TR 都在板内 → 正视时被完全遮住）")
	# 下两角允许出屏（有意下切），但不能超出板宽太多
	var bl: Vector2 = _cam.unproject_position(corners[2])
	var br: Vector2 = _cam.unproject_position(corners[3])
	_check(bl.x >= dash.position.x - 2.0 and br.x <= dash.end.x + 2.0,
		"C2 面板下两角落在 dash 板宽度以内（BL x=%.1f / BR x=%.1f，板 %.1f..%.1f）"
			% [bl.x, br.x, dash.position.x, dash.end.x])


## ── 可见性反转（与 flight_panel_shot 的窗口断言同源，这里是无头闸）──
func _check_modes() -> void:
	_check(_panel.visible, "D1 第一人称：3D 仪表台**显示**（L2 反转，不再随内视隐藏）")
	_cam.toggle_first_third()
	await _wait(2)
	_check(_panel.visible, "D2 追尾：3D 仪表台仍显示（本来就被不透明机身遮住，与反转前一致）")
	_cam.toggle_first_third()
	await _wait(2)
	_cam.set_free_look(true)
	await _wait(2)
	_check(_panel.visible and _cam.is_cockpit_view(),
		"D3 自由观察：面板显示且 2D 簇已让位（低头即见世界里的仪表台）")
	_cam.set_free_look(false)
	await _wait(2)


func _fail_and_quit(reason: String) -> void:
	_check(false, reason)
	SaveGuard.restore()
	_restored = true
	print("COCKPIT_ALIGN_TEST_FAILED")
	get_tree().quit(1)


func _exit_tree() -> void:
	if not _restored:
		_restored = true
		SaveGuard.restore()
