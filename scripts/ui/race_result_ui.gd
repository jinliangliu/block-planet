class_name RaceResultUI
extends CanvasLayer
## 结算界面：名次、完赛时间、最快圈速、破纪录、全场成绩表，
## 以及 P0-1「跑完就有收获」五元素（参与奖 / 解锁进度 / 下一目标 / 解锁时刻 / 圈速榜入口）。
##
## 数值全部由 RaceSystem.build_result_view() 纯读装配；本层不写盘、不 emit、
## 不播音效、不发奖励、不新增 CanvasLayer / 子模态。

signal again_requested
signal back_requested

const TEXT := Color(0.10, 0.10, 0.14)
const DIM := Color(0.36, 0.36, 0.42)
const GOLD := Color(0.86, 0.62, 0.12)
const GOOD := Color(0.16, 0.55, 0.28)
const BTN_SIZE := Vector2(150, 48)

var _root: Control
var _body: VBoxContainer
var _board_box: VBoxContainer
var _built := false
var _leaderboard_open := false
var _saved_track_def: Dictionary = {}
var _saved_outcome: Dictionary = {}


func _ready() -> void:
	layer = 10
	visible = false


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.04, 0.07, 0.62)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.97, 0.95, 0.90)
	style.set_corner_radius_all(16)
	style.content_margin_left = 20.0
	style.content_margin_right = 20.0
	style.content_margin_top = 20.0
	style.content_margin_bottom = 20.0
	card.add_theme_stylebox_override("panel", style)
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.position = Vector2(-280, -270)
	card.custom_minimum_size = Vector2(560, 540)
	_root.add_child(card)
	# 五元素 + 成绩表会超过一屏：用 ScrollContainer 包住 _body。_body 仍是
	# VBoxContainer 且字段名不变（racing_shot 与探针都依赖它）。
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(520, 480)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.add_child(scroll)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 8)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_body)


## 三参签名不变（race_scene / racing_shot 依赖）。重复调用是纯重绘：先清空
## 子节点 → 天然幂等，不叠加行、不重复发任何东西。
func show_results(results: Array, track_def: Dictionary, outcome: Dictionary) -> void:
	_ensure_built()
	visible = true
	_leaderboard_open = false
	_saved_track_def = track_def
	_saved_outcome = outcome
	_clear_container(_body)
	var view := RaceSystem.build_result_view(String(track_def.get("id", "")), outcome)

	_body.add_child(_text("比赛结束！", 34, TEXT, HORIZONTAL_ALIGNMENT_CENTER))
	_body.add_child(_text(String(track_def.get("name_zh", "赛道")), 20, DIM,
		HORIZONTAL_ALIGNMENT_CENTER))

	var mine: Dictionary = {}
	for row: Variant in results:
		if row is Dictionary and bool((row as Dictionary).get("is_player", false)):
			mine = row
	var rank := int(mine.get("rank", 0))
	var total := results.size()
	var rank_color := GOLD if rank == 1 else TEXT
	_body.add_child(_text("第 %d 名 / 共 %d 位" % [rank, total], 40, rank_color,
		HORIZONTAL_ALIGNMENT_CENTER))
	if rank == 1:
		_body.add_child(_text("🏆 冠军！", 22, GOOD, HORIZONTAL_ALIGNMENT_CENTER))

	_body.add_child(_text("完赛时间  %s" % RaceSystem.format_time(float(mine.get("finish_time", -1.0))),
		22, TEXT, HORIZONTAL_ALIGNMENT_CENTER))
	_body.add_child(_text("最快圈速  %s" % RaceSystem.format_lap(float(mine.get("best_lap", 0.0))),
		22, TEXT, HORIZONTAL_ALIGNMENT_CENTER))

	var lines := PackedStringArray()
	if bool(outcome.get("broke_lap", false)):
		lines.append("⚡ 打破最快圈速记录！")
	if bool(outcome.get("broke_race", false)):
		lines.append("⚡ 打破最短完赛时间记录！")
	if bool(outcome.get("first_race", false)):
		lines.append("这是本赛道的第一场比赛，记录已记下。")
	_body.add_child(_text("\n".join(lines), 20, GOLD, HORIZONTAL_ALIGNMENT_CENTER))

	# ── P0-1 五元素（任何名次都给；文案不出现「失败 / 输 / 淘汰」）──
	# 1) 参与奖：只做文案，不发道具、不新增 goal.key。
	_body.add_child(_text("🎁 完成第 %d 场比赛！跑完就有收获～" % int(view.get("races_total", 0)),
		20, GOOD, HORIZONTAL_ALIGNMENT_CENTER))
	# 2) 解锁进度
	_body.add_child(_text("🔓 已解锁 %d / %d 条赛道" % [
		int(view.get("unlocked_count", 0)), int(view.get("track_count", 0))],
		18, DIM, HORIZONTAL_ALIGNMENT_CENTER))
	# 3) 下一目标
	var goal: Dictionary = view.get("next_goal", {})
	if bool(view.get("all_unlocked", false)) or goal.is_empty():
		_body.add_child(_text("🎉 全部赛道都解锁啦！", 20, GOLD, HORIZONTAL_ALIGNMENT_CENTER))
	else:
		_body.add_child(_text("🎯 下一目标：%s —— %s" % [
			String(goal.get("name_zh", "")), String(goal.get("progress_text", ""))],
			18, TEXT, HORIZONTAL_ALIGNMENT_CENTER))
	# 4) 解锁时刻：本场没有新解锁就不建这一行，避免空行。
	var raw_unlocked: Variant = view.get("unlocked_now", [])
	if raw_unlocked is Array and not (raw_unlocked as Array).is_empty():
		var names := PackedStringArray()
		for tid: Variant in (raw_unlocked as Array):
			var def := RaceSystem.track(String(tid))
			names.append(String(def.get("name_zh", String(tid))))
		_body.add_child(_text("🎉 解锁了新赛道：%s！" % "、".join(names),
			22, GOLD, HORIZONTAL_ALIGNMENT_CENTER))

	# 成绩表
	var table := VBoxContainer.new()
	table.add_theme_constant_override("separation", 2)
	_body.add_child(_text("—— 全场成绩 ——", 18, DIM, HORIZONTAL_ALIGNMENT_CENTER))
	for row: Variant in results:
		if not (row is Dictionary):
			continue
		var d: Dictionary = row
		var prefix := "▶ " if bool(d.get("is_player", false)) else "   "
		table.add_child(_text("%s%d. %-8s 最快 %s  总 %s" % [
			prefix,
			int(d.get("rank", 0)),
			String(d.get("display", "?")),
			RaceSystem.format_lap(float(d.get("best_lap", 0.0))),
			RaceSystem.format_time(float(d.get("finish_time", -1.0))),
		], 16, TEXT, HORIZONTAL_ALIGNMENT_CENTER))
	_body.add_child(table)

	_body.add_child(_spacer(6))
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	var again := Button.new()
	again.text = "再来一次"
	again.custom_minimum_size = BTN_SIZE
	again.focus_mode = Control.FOCUS_NONE
	UiKit.apply_warm_style(again)
	again.pressed.connect(func(): again_requested.emit())
	# 5) 最快圈速榜入口：屏内 toggle，不新增 CanvasLayer / 子模态 / 冻结调用。
	var board_btn := Button.new()
	board_btn.text = "🏁 我的最快圈速"
	board_btn.custom_minimum_size = BTN_SIZE
	board_btn.focus_mode = Control.FOCUS_NONE
	UiKit.apply_warm_style(board_btn)
	board_btn.pressed.connect(func():
		_leaderboard_open = not _leaderboard_open
		_render_leaderboard())
	var back := Button.new()
	back.text = "返回赛道选择"
	back.custom_minimum_size = BTN_SIZE
	back.focus_mode = Control.FOCUS_NONE
	UiKit.apply_warm_style(back)
	back.pressed.connect(func(): back_requested.emit())
	btn_row.add_child(again)
	btn_row.add_child(board_btn)
	btn_row.add_child(back)
	_body.add_child(btn_row)

	_board_box = VBoxContainer.new()
	_board_box.add_theme_constant_override("separation", 2)
	_body.add_child(_board_box)
	_render_leaderboard()


func hide_results() -> void:
	visible = false


## 立即 remove_child + queue_free：重复 show_results() 时子节点数当场稳定，
## 不用等一帧，也不需要探针 await process_frame 才能断言幂等。
func _clear_container(box: Container) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()


## 圈速榜只在既有 _board_box 内增删行，不重建整屏、不新建 CanvasLayer。
func _render_leaderboard() -> void:
	if _board_box == null:
		return
	_clear_container(_board_box)
	if not _leaderboard_open:
		return
	var view := RaceSystem.build_result_view(String(_saved_track_def.get("id", "")), _saved_outcome)
	var board: Array = []
	var raw_board: Variant = view.get("leaderboard", [])
	if raw_board is Array:
		board = raw_board as Array
	if board.is_empty():
		_board_box.add_child(_text("还没有圈速记录，跑一场就有啦！", 16, DIM,
			HORIZONTAL_ALIGNMENT_CENTER))
		return
	for item: Variant in board:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		_board_box.add_child(_text("%s  %s" % [
			String(d.get("name_zh", "")), String(d.get("best_lap_text", ""))],
			16, GOOD, HORIZONTAL_ALIGNMENT_CENTER))


func _text(t: String, size: int, color: Color, align: int) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = align
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(460, 0)
	return l


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c
