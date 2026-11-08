extends Node
## 任务面板窗口取证探针（D-089 阶段 1）：触屏「任务」入口 + 三页签 44px 热区
## + 三张 PNG（任务 / 成就 / 探索课堂）。
##
## D-010：SaveGuard.snapshot() 必须在所有早退分支与 add_child(main_scene) 之前；
## _exit_tree() 幂等 _restore()，窗口态看门狗 180 s。
## FishingSystem / BoatSystem 的 _exit_tree() 无条件 _save_journal()——唯一闸门是
## 各自的 journal_ok，而 _load_journal() 在文件不存在时也会把它置 true。
## fishing_journal.json 不在 SaveGuard.EXTRA_FILES 内，SaveGuard.restore()
## 覆盖不到它；两份根状态文件也都可能在 _run() 暖机 / add_child(main_scene)
## 期间被改写，而拒写闸只挡得住退出期。故收尾必须是「journal_ok 拒写闸 +
## 按开局路径逐字节还原 + SaveGuard.restore()」三层，缺一不可
## （照 fishing_collection_shot.gd:5-11 / :38-44 / :63-78 范式）。
## get_global_rect() 在无头态为 0，热区断言只在窗口态成立，不伪造 headless 验证。
##
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/quest_shot.tscn
## （勿加 --headless；无头下 frame_post_draw 永不触发会挂起）

const SHOT_DIR := "res://tmp"
const SHOT_NAMES: Array[String] = [
	"quest_panel_shot.png", "quest_panel_shot_ach.png", "quest_panel_shot_lesson.png",
]
const TAB_NAMES: Array[String] = ["任务", "成就", "探索课堂"]

var _failed := 0
var _passed := 0
var _restored := false
## D-010：fishing_journal.json 不在 SaveGuard.EXTRA_FILES 内，且两份根状态文件
## 都可能在运行期被改写；开局单独快照「路径 + 原文本 + 是否存在」。
var _fish_path_at_start := ""
var _fish_text := ""
var _fish_existed := false
var _boat_path_at_start := ""
var _boat_text := ""
var _boat_existed := false


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		push_warning("quest_shot: 看门狗超时，强制退出")
		get_tree().quit(1))
	# 快照必须先于任何早退分支：headless 早退同样触发 _exit_tree → _restore()，
	# 若此时 snapshot 未执行，SaveGuard.restore() 会用空静态态删掉真实存档。
	SaveGuard.snapshot()
	# 两份根状态文件按「开局路径 + 原文本 + 是否存在」逐字节快照；必须在
	# headless 早退之前，因为早退同样走 _exit_tree() → _restore()。
	_fish_path_at_start = FishingSystem.JOURNAL_PATH
	if FileAccess.file_exists(_fish_path_at_start):
		_fish_existed = true
		var fish_file: FileAccess = FileAccess.open(_fish_path_at_start, FileAccess.READ)
		if fish_file != null:
			_fish_text = fish_file.get_as_text()
			fish_file.close()
	_boat_path_at_start = BoatSystem.JOURNAL_PATH
	if FileAccess.file_exists(_boat_path_at_start):
		_boat_existed = true
		var boat_file: FileAccess = FileAccess.open(_boat_path_at_start, FileAccess.READ)
		if boat_file != null:
			_boat_text = boat_file.get_as_text()
			boat_file.close()
	if DisplayServer.get_name() == "headless":
		print("QUEST_SHOT_SKIP: 需窗口渲染")
		get_tree().quit(0)
		return
	await _run()
	_finish()


func _finish() -> void:
	_restore()
	if _failed == 0:
		print("QUEST_SHOT_OK passed=%d" % _passed)
	else:
		print("QUEST_SHOT_FAILED count=%d passed=%d" % [_failed, _passed])
	get_tree().quit(0 if _failed == 0 else 1)


## 幂等收尾（正常路径 / _exit_tree 安全网 / 看门狗三条路共用）。
## 顺序固定：先拒写闸、再逐字节还原、最后 SaveGuard.restore()。
func _restore() -> void:
	if _restored:
		return
	_restored = true
	# ① 拒写闸优先：挡住 _process() 防抖写盘与 _exit_tree() 的无条件写盘。
	FishingSystem.journal_ok = false
	BoatSystem.journal_ok = false
	# ② 按开局路径复原，并按开局存在性回写 / 删除。
	if not _fish_path_at_start.is_empty():
		FishingSystem.JOURNAL_PATH = _fish_path_at_start
		_restore_text(_fish_path_at_start, _fish_existed, _fish_text)
	if not _boat_path_at_start.is_empty():
		BoatSystem.JOURNAL_PATH = _boat_path_at_start
		_restore_text(_boat_path_at_start, _boat_existed, _boat_text)
	# ③ 最后还原 SaveGuard 覆盖的存档树与 Progress 内存态。
	SaveGuard.restore()


func _restore_text(path: String, existed: bool, text: String) -> void:
	if existed:
		var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(text)
			f.close()
	elif FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _exit_tree() -> void:
	_restore()


func _run() -> void:
	# Autoload 暖机；窗口尺寸用 get_window().size 设置（canvas_items + expand 下
	# --resolution 无效），随后 PNG 像素与真实窗口尺寸做耦合断言。
	await get_tree().process_frame
	get_window().size = Vector2i(1280, 720)
	await _settle(3)
	print("QUEST_SHOT_WINDOW %s" % get_window().size)

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i: int in range(60):
		await get_tree().process_frame
	var hud: HUD = main_scene.get_node("UI")
	var player: Player = main_scene.get_node("Player")
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
		await _settle(3)
	# 空槽态 main.gd:214 必弹 ProfilePicker：米白模态会遮挡任务面板截图，
	# 且 _set_player_frozen(true) 会锁住玩家输入。close → closed 只解冻不写档。
	if hud._profile_picker != null and hud._profile_picker.is_open():
		hud.close_profile_picker()
		await _settle(3)
	_check(not player.input_locked, "前置守卫：档案选择器已关闭、玩家输入未冻结")

	# 触屏入口：面板行「任务」按钮（76×76），按下后面板打开且玩家冻结。
	# hud.gd:264 只在 is_touchscreen_available() 为真时建触控面板行；桌面窗口机
	# 上该行为假，故缺失时在隐藏 host 上显式建一次，保证入口断言真实执行而不是
	# 跳过。host 不显示、不进截图，也不改任务面板的层级。
	var task_button: Button = _find_task_button(hud)
	if task_button == null:
		var touch_host := Control.new()
		touch_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		touch_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
		touch_host.visible = false
		hud.add_child(touch_host)
		hud._build_action_buttons(touch_host)
		task_button = _find_task_button(hud)
	_check(task_button != null, "面板行存在触屏「任务」按钮（76×76）")
	if task_button != null:
		task_button.pressed.emit()
		await _settle(3)
		_check(bool(hud._quest_panel.is_open()), "点触屏「任务」按钮可打开任务面板")
		_check(not player.is_physics_processing(), "任务面板打开后玩家被冻结")
	else:
		hud.open_quest_panel()
		await _settle(3)

	# refresh() 整页重建，选项/领取按钮只在对应页出现，必须逐页断言热区。
	for tab_index: int in range(3):
		hud._quest_panel.set_tab(tab_index)
		await _settle(3)
		_check(hud._quest_panel.get_tab() == tab_index,
			"第 %d 页签切换生效" % (tab_index + 1))
		_check_hotzones(hud, tab_index)
		await _capture(SHOT_NAMES[tab_index],
			"第 %d 页「%s」" % [tab_index + 1, TAB_NAMES[tab_index]])


func _find_task_button(hud: HUD) -> Button:
	var buttons: Array = hud.find_children("*", "Button", true, false)
	for node: Variant in buttons:
		var btn := node as Button
		if btn != null and btn.text == "任务" and btn.custom_minimum_size == Vector2(76, 76):
			return btn
	return null


func _check_hotzones(hud: HUD, tab_index: int) -> void:
	var buttons: Array = hud._quest_panel.find_children("*", "Button", true, false)
	var hot_ok: bool = true
	var min_height: float = 9999.0
	for node: Variant in buttons:
		var btn := node as Button
		if btn == null:
			continue
		var h: float = btn.get_global_rect().size.y
		min_height = minf(min_height, h)
		if h < 44.0:
			hot_ok = false
	_check(hot_ok and not buttons.is_empty(),
		"第 %d 页全部 Button 热区高 ≥44px（共 %d 个，最小 %.1f）"
			% [tab_index + 1, buttons.size(), min_height])


## 坑 #20：get_image() 之后、save_png() 之前，把证据图与窗口尺寸绑在同一时刻。
func _capture(file_name: String, label: String) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var win: Vector2i = get_window().size
	_check(img.get_width() == win.x and img.get_height() == win.y,
		"%s 证据图尺寸 %dx%d == 窗口 %dx%d"
			% [label, img.get_width(), img.get_height(), win.x, win.y])
	var dir: String = ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var path: String = dir.path_join(file_name)
	img.save_png(path)
	_check(FileAccess.file_exists(path), "%s PNG 已落盘 %s" % [label, file_name])
	print("SHOT: %s -> %s" % [label, path])


func _settle(frames: int) -> void:
	for i: int in range(frames):
		await RenderingServer.frame_post_draw


func _check(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
