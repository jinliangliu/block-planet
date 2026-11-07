extends Node
## P0-1 竞速结算屏（D-087）窗口截图探针：16:9 / 20:9 两档比例、默认态 /
## 圈速榜展开+滚到底，共 4 张 PNG 供 full 档验收目检。
##
## D-010：开局 SaveGuard.snapshot()（Progress.counters 被本探针改动）、收尾
## SaveGuard.restore()，_exit_tree 与看门狗共用 _restore()。
## 「只改内存」≠「无需存档隔离」：Progress._exit_tree 会补写 progress.json，
## 故 snapshot/restore 必备。竞速侧 race_system.gd 无 _exit_tree，race_records.json
## 只由 submit_result()→save_records() 显式写；本探针绝不调 submit_result()。
##
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/race_result_shot.tscn
## （勿加 --headless；无头下 frame_post_draw 永不触发会挂起）

const SHOT_DIR := "res://tmp"

var _failed := 0
var _passed := 0
var _restored := false
var _ui: RaceResultUI = null
var _card_ctrl: Control = null
var _rows: Array[Dictionary] = []
var _track_def: Dictionary = {}
var _outcome: Dictionary = {}


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		push_warning("race_result_shot: 看门狗超时，强制退出")
		get_tree().quit(1))
	# 快照必须先于 headless 早退：早退同样触发 _exit_tree → _restore()，
	# 若此时 snapshot 未执行，SaveGuard.restore() 会用空静态态删掉真实存档。
	SaveGuard.snapshot()
	if DisplayServer.get_name() == "headless":
		print("RACE_RESULT_SHOT_SKIP: 需窗口渲染")
		get_tree().quit(0)
		return
	await _run()
	_finish()


func _finish() -> void:
	_restore()
	if _failed == 0:
		print("RACE_RESULT_SHOT_OK passed=%d" % _passed)
	else:
		print("RACE_RESULT_SHOT_FAILED count=%d passed=%d" % [_failed, _passed])
	get_tree().quit(0 if _failed == 0 else 1)


func _restore() -> void:
	if _restored:
		return
	_restored = true
	SaveGuard.restore()


func _exit_tree() -> void:
	_restore()


# ────────────────────────── 内存态构造（只改内存、不主动调写盘 API）──────────────────────────

func _seed(tracks: Dictionary) -> void:
	var store: Dictionary = RaceSystem.records()
	store.clear()
	store["version"] = 1
	store["tracks"] = tracks


func _make_results() -> void:
	var rows: Array[Dictionary] = []
	rows.append({"rank": 1, "display": "机器人1", "is_player": false,
		"best_lap": 30.0, "finish_time": 100.0})
	rows.append({"rank": 2, "display": "机器人2", "is_player": false,
		"best_lap": 31.0, "finish_time": 110.0})
	rows.append({"rank": 3, "display": "机器人3", "is_player": false,
		"best_lap": 32.0, "finish_time": 120.0})
	rows.append({"rank": 4, "display": "玩家", "is_player": true,
		"best_lap": 33.0, "finish_time": 130.0})
	_rows = rows
	_track_def = {"id": "desert_ring", "name_zh": "沙丘环线"}
	var unlocked: Array[String] = ["mountain_road"]
	_outcome = {"broke_lap": true, "broke_race": false,
		"first_race": false, "unlocked_now": unlocked}


# ────────────────────────── 主流程 ──────────────────────────

func _run() -> void:
	# add_child 前先让 Autoload 完成首帧暖机（照 race_result_probe.gd:27-28）。
	await get_tree().process_frame
	_seed({
		"desert_ring": {"wins": 2, "total_races": 2, "best_lap_time": 30.0},
		"city_circuit": {"wins": 0, "total_races": 2, "best_lap_time": 25.0},
		"wetland_cross": {"wins": 0, "total_races": 1, "best_lap_time": 20.0},
		"forest_trail": {"wins": 0, "total_races": 1, "best_lap_time": 40.0},
	})
	Progress.counters["race_finished_any"] = 1
	_ui = RaceResultUI.new()
	add_child(_ui)
	await get_tree().process_frame
	_make_results()
	_ui.show_results(_rows, _track_def, _outcome)
	await get_tree().process_frame
	await _settle(3)
	var cards: Array = _ui.find_children("*", "PanelContainer", true, false)
	if cards.size() >= 1:
		_card_ctrl = cards[0] as PanelContainer
	_check(_card_ctrl != null, "① 结算屏 card 已构建")

	# ── 16:9 ──
	await _set_ratio(Vector2i(1280, 720), "16:9", "1280x720")
	_check_common("16:9")
	await _capture("race_result_16x9.png", "① 16:9 默认态", _card_ctrl)

	var body_before: int = _ui._body.get_child_count()
	await _toggle_board()
	_check(_ui._board_box.get_child_count() > 0, "16:9 圈速榜展开后 _board_box 非空")
	_check(_ui._body.get_child_count() == body_before,
		"16:9 展开圈速榜不重建整屏（_body 行数 %d 不变）" % body_before)
	var layers_after: Array = _ui.find_children("*", "CanvasLayer", true, false)
	_check(layers_after.size() == 0, "16:9 展开后子节点 CanvasLayer 数量==0")
	await _scroll_bottom()
	await _capture("race_result_16x9_board.png", "② 16:9 圈速榜展开+滚到底", _card_ctrl)

	# ── 20:9 ──
	await _set_ratio(Vector2i(1280, 576), "20:9", "1280x576")
	# 重绘回默认态（show_results 会把 _leaderboard_open 复位并幂等重建行）。
	_ui.show_results(_rows, _track_def, _outcome)
	await get_tree().process_frame
	# show_results() 只清 _body、不复位 ScrollContainer.scroll_vertical（生产侧每局
	# 都 new 实例故无碍，但本探针复用同一实例）。16:9 已滚到底，若不复位，这张
	# 「默认态」证据图会把顶部「第 N 名」裁掉半截——坑 #20 的证据图/断言脱钩。
	await _scroll_top()
	await _settle(3)
	_check_common("20:9")
	await _capture("race_result_20x9.png", "③ 20:9 默认态", _card_ctrl)

	var body_before_20: int = _ui._body.get_child_count()
	await _toggle_board()
	_check(_ui._board_box.get_child_count() > 0, "20:9 圈速榜展开后 _board_box 非空")
	_check(_ui._body.get_child_count() == body_before_20,
		"20:9 展开圈速榜不重建整屏（_body 行数 %d 不变）" % body_before_20)
	var layers_after_20: Array = _ui.find_children("*", "CanvasLayer", true, false)
	_check(layers_after_20.size() == 0, "20:9 展开后子节点 CanvasLayer 数量==0")
	await _scroll_bottom()
	await _capture("race_result_20x9_board.png", "④ 20:9 圈速榜展开+滚到底", _card_ctrl)


# ────────────────────────── 断言组 ──────────────────────────

## 每档比例都要断言的结构项（两档各调一次）。
func _check_common(tag: String) -> void:
	_check(_ui.visible, "%s 结算屏 visible==true" % tag)
	var body_count: int = _ui._body.get_child_count()
	_check(body_count > 0, "%s _body 已渲染（%d 行）" % [tag, body_count])
	var labels: Array = _ui.find_children("*", "Label", true, false)
	var all_text: String = ""
	for lab: Variant in labels:
		if lab is Label:
			all_text += String((lab as Label).text) + "\n"
	_check(all_text.contains("🎁") and all_text.contains("🔓")
		and all_text.contains("🎯") and all_text.contains("🎉"),
		"%s 五元素文案（🎁/🔓/🎯/🎉）都在" % tag)
	_check(not all_text.contains("失败") and not all_text.contains("输")
		and not all_text.contains("淘汰"),
		"%s 文案无惩罚性字眼（失败/输/淘汰）" % tag)
	_check(all_text.contains("⚡ 打破最快圈速记录！"),
		"%s ⚡ 破最快圈速纪录时刻在" % tag)
	var buttons: Array = _ui.find_children("*", "Button", true, false)
	var btn_ok: bool = buttons.size() == 3
	var board_btn: Button = null
	for entry: Variant in buttons:
		if entry is Button:
			var b: Button = entry as Button
			if b.custom_minimum_size.x < 140.0 or b.custom_minimum_size.y < 44.0:
				btn_ok = false
			if b.focus_mode != Control.FOCUS_NONE:
				btn_ok = false
			if String(b.text).contains("最快圈速"):
				board_btn = b
	_check(btn_ok, "%s 3 个按钮、每个 ≥140×44 且 FOCUS_NONE（实测 %d 个）" % [tag, buttons.size()])
	_check(board_btn != null, "%s 🏁 我的最快圈速按钮存在" % tag)
	var layers: Array = _ui.find_children("*", "CanvasLayer", true, false)
	_check(layers.size() == 0, "%s 子节点里 CanvasLayer 数量==0" % tag)
	# 构造式闸：16:9 已 _scroll_bottom()，20:9 重绘若漏了 _scroll_top() 就必然 FAIL。
	var scrolls: Array = _ui.find_children("*", "ScrollContainer", true, false)
	var at_top: bool = false
	if scrolls.size() == 1:
		at_top = (scrolls[0] as ScrollContainer).scroll_vertical <= 1.0
	_check(at_top, "%s 默认态从顶部开始（scroll_vertical ≤1，标题不被裁）" % tag)
	var vp: Rect2 = get_viewport().get_visible_rect()
	var inside: bool = false
	var geom: String = "card 缺失"
	if _card_ctrl != null:
		var r: Rect2 = _card_ctrl.get_global_rect()
		inside = _rect_inside(r, vp)
		geom = "card=%s vp=%s" % [r, vp]
	_check(inside, "%s card 四边落在视口内（%s）" % [tag, geom])


# ────────────────────────── 比例 / 圈速榜 / 滚动 / 截图工具 ──────────────────────────

func _set_ratio(size: Vector2i, tag: String, window_text: String) -> void:
	get_window().size = size
	await get_tree().process_frame
	await get_tree().process_frame
	await _settle(6)
	var vp: Vector2 = get_viewport().get_visible_rect().size
	print("SHOT_RATIO %s window=%s viewport=%s" % [tag, window_text, vp])
	_check(get_window().size == size, "%s 窗口尺寸 %s 已生效" % [tag, window_text])
	# project.godot: viewport 1280x720 + stretch/mode=canvas_items + aspect=expand。
	# expand 的语义是「逻辑视口高恒为 720、宽按窗口宽高比扩展」：16:9 -> 1280x720，
	# 20:9 窗口 1280x576 -> 逻辑 1600x720；物理 PNG 像素仍等于窗口尺寸（1280x576）。
	# 原断言写死「逻辑视口宽 1280」在 20:9 下必然 FAIL，是规格错误而非生产缺陷。
	var aspect: float = float(size.x) / float(size.y)
	var vp_ok: bool = absf(vp.y - 720.0) < 1.0 and absf(vp.x / vp.y - aspect) < 0.01
	_check(vp_ok, "%s 逻辑视口高恒 720 且宽高比 %.4f 与窗口一致（实测 %s）" % [tag, aspect, vp])


## 🏁 按钮是内联 lambda、无具名回调，只能靠 text 找到后 pressed.emit()。
func _toggle_board() -> void:
	var buttons: Array = _ui.find_children("*", "Button", true, false)
	for entry: Variant in buttons:
		if entry is Button:
			var b: Button = entry as Button
			if String(b.text).contains("最快圈速"):
				b.pressed.emit()
				await get_tree().process_frame
				await _settle(3)
				return


func _scroll_top() -> void:
	var scrolls: Array = _ui.find_children("*", "ScrollContainer", true, false)
	if scrolls.size() != 1:
		return
	var sc: ScrollContainer = scrolls[0] as ScrollContainer
	sc.scroll_vertical = 0.0
	await get_tree().process_frame
	await _settle(3)


func _scroll_bottom() -> void:
	var scrolls: Array = _ui.find_children("*", "ScrollContainer", true, false)
	if scrolls.size() != 1:
		return
	await get_tree().process_frame
	var sc: ScrollContainer = scrolls[0] as ScrollContainer
	sc.scroll_vertical = sc.get_v_scroll_bar().max_value
	await get_tree().process_frame
	await _settle(3)


func _settle(frames: int) -> void:
	for i: int in range(frames):
		await RenderingServer.frame_post_draw


## 坑 #20：get_image() 之后、save_png() 之前，当场把「证据图与状态」绑在同一时刻。
func _capture(file_name: String, label: String, anchor: Control) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	# 坑 #20 耦合断言：把「证据图」与「比例」绑在同一时刻。
	# 渲染缓冲是窗口物理像素（canvas_items 只缩放 2D 坐标），故 20:9 档必须是 1280x576。
	var win: Vector2i = get_window().size
	_check(img.get_width() == win.x and img.get_height() == win.y,
		"%s 证据图尺寸 %dx%d == 窗口 %dx%d" % [label, img.get_width(), img.get_height(), win.x, win.y])
	var variety: int = _pixel_variety(img)
	_check(variety >= 8, "%s 画面有内容（采样色数 %d）" % [label, variety])
	_check(_ui.visible, "%s 截图时刻结算屏仍 visible" % label)
	var vp: Rect2 = get_viewport().get_visible_rect()
	var inside: bool = false
	if anchor != null:
		inside = _rect_inside(anchor.get_global_rect(), vp)
	_check(inside, "%s 截图时刻 card 仍在视口内" % label)
	var dir: String = ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var path: String = dir.path_join(file_name)
	img.save_png(path)
	_check(FileAccess.file_exists(path), "%s PNG 已落盘 %s" % [label, file_name])
	print("SHOT: %s -> %s" % [label, path])


func _rect_inside(r: Rect2, vp: Rect2) -> bool:
	var ok: bool = r.position.x >= vp.position.x - 1.0
	ok = ok and r.position.y >= vp.position.y - 1.0
	ok = ok and r.end.x <= vp.end.x + 1.0
	ok = ok and r.end.y <= vp.end.y + 1.0
	return ok


## 32×32 网格采样不同 rgba32 颜色数：纯色（黑屏/空场景）会得到个位数。
func _pixel_variety(img: Image) -> int:
	var seen: Dictionary = {}
	var w: int = img.get_width()
	var h: int = img.get_height()
	if w <= 0 or h <= 0:
		return 0
	var step_x: int = maxi(w / 32, 1)
	var step_y: int = maxi(h / 32, 1)
	var y: int = 0
	while y < h:
		var x: int = 0
		while x < w:
			seen[img.get_pixel(x, y).to_rgba32()] = true
			x += step_x
		y += step_y
	return seen.size()


func _check(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
