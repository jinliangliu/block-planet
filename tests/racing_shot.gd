extends Node
## 竞速视觉验证探针（窗口模式，需 Vulkan 渲染）——无头探针发现不了渲染问题
## （本工程踩过「MeshInstance3D 忘赋 mesh / PlaneMesh 朝向错」都只有截图才看得出）。
##
## 四张图：赛道选择器 / 起跑格（倒计时）/ 比赛中（追尾相机）/ 结算界面。
## 每张同时做「画面不是纯色」的像素多样性断言，抓黑屏/空场景。
##
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/racing_shot.tscn
## （勿加 --headless；截图需窗口渲染）

const SHOT_DIR := "res://tmp"
const DT := 1.0 / 60.0

var _failed := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		# 无头下 frame_post_draw 永不触发会永久挂起（本工程踩过 exit 124），快速退出。
		print("RACING_SHOT_SKIP: 需窗口渲染")
		get_tree().quit(0)
		return

	InputActions.register()
	SaveGuard.snapshot()

	await _shot_selector()
	await _shot_race()

	SaveGuard.restore()
	if _failed == 0:
		print("RACING_SHOT_OK")
		get_tree().quit(0)
	else:
		print("RACING_SHOT_FAILED count=%d" % _failed)
		get_tree().quit(1)


# ── 图 1：赛道选择器 ───────────────────────────────────────
func _shot_selector() -> void:
	var selector := TrackSelectorUI.new()
	add_child(selector)
	selector.open()
	await _settle(6)
	_check(selector.is_open(), "① 赛道选择器已打开")
	await _capture("race_selector.png", "① 赛道选择器（主题/赛道卡/赛车/机器人）")
	selector.queue_free()
	await _settle(3)


# ── 图 2~4：整场比赛 ──────────────────────────────────────
func _shot_race() -> void:
	RaceSystem.select_race("desert_ring", "buggy", 3, "normal")
	var scene: Node3D = load("res://scenes/racing/race_scene.tscn").instantiate()
	scene.autopilot = true
	add_child(scene)
	scene.set_physics_process(false)

	_check(scene._loader != null and scene._loader.arena_radius > 0.0, "② 赛道竞技场已构建")
	_check(scene._cars.size() == 4, "② 4 台赛车节点")
	# 先手动推几帧让 HUD 刷新出倒计时读数（引擎物理已关，HUD 靠 _physics_process 更新）。
	for i in range(20):
		scene._physics_process(DT)
	_check(scene._session.is_counting(), "② 仍处于倒计时阶段")
	await _settle(6)
	await _capture("race_start.png", "② 起跑格（倒计时 3-2-1）")

	# 手动定步长推进到比赛中段（不受实时节流），再让渲染跟上。
	var ticks := 0
	while ticks < 2200 and not scene._finalized:
		scene._physics_process(DT)
		ticks += 1
	_check(not scene._finalized, "③ 中段尚未完赛（tick=%d）" % ticks)
	await _settle(4)
	await _capture("race_mid.png", "③ 比赛中（追尾相机 + HUD）")

	# 跑到终点。
	var guard := 0
	while not scene._finalized and guard < 40000:
		scene._physics_process(DT)
		guard += 1
	_check(scene._finalized, "④ 自动驾驶跑完整场")
	var p: RaceSession.Racer = scene._session.player()
	_check(p != null and int(p.lap) >= int(scene._track_def.get("laps", 3)), "④ 玩家完成全部圈数")
	await _settle(6)
	_check(scene._result.visible, "④ 结算界面已弹出")
	await _capture("race_result.png", "④ 结算界面")

	scene.queue_free()
	await _settle(3)


# ────────────────────────── 工具 ──────────────────────────
func _settle(frames: int) -> void:
	for i in range(frames):
		await RenderingServer.frame_post_draw


func _capture(file_name: String, label: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var variety := _pixel_variety(img)
	_check(variety >= 8, "%s 画面有内容（采样色数 %d）" % [label, variety])
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join(file_name)
	img.save_png(path)
	print("SHOT: %s -> %s" % [label, path])


## 网格采样画面的不同颜色数：纯色（黑屏/空场景）会得到个位数。
func _pixel_variety(img: Image) -> int:
	var seen := {}
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		return 0
	var step_x := maxi(w / 32, 1)
	var step_y := maxi(h / 32, 1)
	var y := 0
	while y < h:
		var x := 0
		while x < w:
			seen[img.get_pixel(x, y).to_rgba32()] = true
			x += step_x
		y += step_y
	return seen.size()


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
