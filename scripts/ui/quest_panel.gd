class_name QuestPanel
extends Control

## 任务与成就面板：J 键唤出的模态窗口（冻结玩家），配色与储物箱同色系。
## 左侧页签「任务 / 成就」；任务页含新手引导链与知识问答区，
## 成就页按五类分组。达成条目可点「领取奖励」，发放由 HUD 执行。

signal closed

enum Tab { QUESTS, ACHIEVEMENTS }

const PANEL_BG := Color(0.95, 0.92, 0.84)
const PANEL_BORDER := Color(0.62, 0.47, 0.27)
const TITLE_COLOR := Color(0.36, 0.26, 0.13)
const BODY_COLOR := Color(0.42, 0.32, 0.18)
const TAB_BG := Color(0.89, 0.85, 0.74)
const TAB_ACTIVE := Color(0.80, 0.72, 0.55)
const BAR_BG := Color(0.85, 0.80, 0.68)
const BAR_FILL := Color(0.64, 0.78, 0.36)
const GOOD_COLOR := Color(0.30, 0.55, 0.15)
const BAD_COLOR := Color(0.70, 0.25, 0.18)

var _tab := Tab.QUESTS
var _tab_buttons: Array[Button] = []
var _content: VBoxContainer
var _quiz_question := ""
var _quiz_options: Array[String] = []
var _quiz_answer := -1
var _quiz_pool: Array[int] = []
var _quiz_feedback: Label
var _quiz_busy := false


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(720, 0)
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)
	var title := Label.new()
	title.text = "任务与成就"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.add_theme_color_override("font_color", Color(0.85, 0.22, 0.20))
	close_btn.add_theme_font_size_override("font_size", 22)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	vbox.add_child(tabs)
	for i in 2:
		var btn := Button.new()
		btn.text = "任务" if i == Tab.QUESTS else "成就"
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(120, 38)
		btn.add_theme_font_size_override("font_size", 18)
		btn.add_theme_color_override("font_color", TITLE_COLOR)
		var idx := i
		btn.pressed.connect(func(): set_tab(idx))
		tabs.add_child(btn)
		_tab_buttons.append(btn)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 400)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 10)
	scroll.add_child(_content)

	refresh()


func open() -> void:
	visible = true
	if _quiz_options.is_empty():
		_draw_question()
	refresh()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func get_tab() -> int:
	return _tab


func set_tab(tab: int) -> void:
	_tab = clampi(tab, 0, 1)
	refresh()


## 重建整页内容（条目数量有限，整页重建代价可忽略）。
func refresh() -> void:
	if _content == null:
		return
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()
	for i in _tab_buttons.size():
		var style := _btn_style(TAB_ACTIVE if i == _tab else TAB_BG)
		_tab_buttons[i].add_theme_stylebox_override("normal", style)
		_tab_buttons[i].add_theme_stylebox_override("pressed", style)
	if _tab == Tab.QUESTS:
		_build_quest_page()
	else:
		_build_achievement_page()


func _build_quest_page() -> void:
	var any_visible := false
	for entry in QuestData.quests():
		if not Progress.is_visible(entry):
			continue
		any_visible = true
		_content.add_child(_make_entry(entry, String(entry["prerequisite"]).is_empty()))
	if not any_visible:
		var empty := Label.new()
		empty.text = "暂无可做的任务"
		empty.add_theme_color_override("font_color", BODY_COLOR)
		_content.add_child(empty)
	_content.add_child(HSeparator.new())
	_build_quiz_section()


func _build_achievement_page() -> void:
	for category in [
		QuestData.Category.QUIZ, QuestData.Category.SURVIVAL,
		QuestData.Category.EXPLORE, QuestData.Category.CHALLENGE,
	]:
		var header := Label.new()
		header.text = "◆ " + QuestData.category_title(category)
		header.add_theme_font_size_override("font_size", 19)
		header.add_theme_color_override("font_color", TITLE_COLOR)
		_content.add_child(header)
		for entry in QuestData.achievements():
			if int(entry["category"]) != category:
				continue
			_content.add_child(_make_entry(entry, true))


## 单条任务/成就行：标题 + 描述 + 进度条 + 状态按钮。
func _make_entry(entry: Dictionary, show_status: bool) -> Control:
	var state := Progress.state_of(String(entry["id"]))
	var box := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(TAB_BG, 0.55)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(8)
	box.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	box.add_child(vbox)

	var head := HBoxContainer.new()
	vbox.add_child(head)
	var name_label := Label.new()
	name_label.text = String(entry["title"])
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", TITLE_COLOR)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_label)

	if show_status:
		var status := Label.new()
		if state == Progress.State.CLAIMED:
			status.text = "已完成 ✓"
			status.add_theme_color_override("font_color", GOOD_COLOR)
		elif state == Progress.State.DONE:
			status.text = "可领奖"
			status.add_theme_color_override("font_color", GOOD_COLOR)
		else:
			status.text = "进行中"
			status.add_theme_color_override("font_color", BODY_COLOR)
		status.add_theme_font_size_override("font_size", 15)
		head.add_child(status)

	var desc := Label.new()
	desc.text = String(entry["desc"])
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 15)
	desc.add_theme_color_override("font_color", BODY_COLOR)
	vbox.add_child(desc)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	vbox.add_child(row)

	var goal: Dictionary = entry["goal"]
	var cur := Progress.goal_progress(goal)
	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = cur.y
	bar.value = cur.x
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(300, 16)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var bg := StyleBoxFlat.new()
	bg.bg_color = BAR_BG
	bg.set_corner_radius_all(6)
	var fill := StyleBoxFlat.new()
	fill.bg_color = BAR_FILL
	fill.set_corner_radius_all(6)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)
	row.add_child(bar)

	var progress_label := Label.new()
	progress_label.text = "%d / %d" % [cur.x, cur.y]
	progress_label.add_theme_font_size_override("font_size", 14)
	progress_label.add_theme_color_override("font_color", BODY_COLOR)
	row.add_child(progress_label)

	var reward: Dictionary = entry["reward"]
	var reward_label := Label.new()
	reward_label.text = "奖励：%s ×%d" % [ItemTypes.item_name(int(reward["item"])), int(reward["count"])]
	reward_label.add_theme_font_size_override("font_size", 14)
	reward_label.add_theme_color_override("font_color", BODY_COLOR)
	reward_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(reward_label)

	var action := Button.new()
	action.focus_mode = Control.FOCUS_NONE
	action.custom_minimum_size = Vector2(110, 30)
	action.add_theme_font_size_override("font_size", 14)
	var entry_id := String(entry["id"])
	if state == Progress.State.DONE:
		action.text = "领取奖励"
		action.pressed.connect(func(): Progress.claim(entry_id))
	elif state == Progress.State.CLAIMED:
		action.text = "已领取 ✓"
		action.disabled = true
	else:
		action.text = "未达成"
		action.disabled = true
	row.add_child(action)
	return box


## 知识问答区：随机出题，答对累计进度（每 3 题由 Progress 自动发奖）。
func _build_quiz_section() -> void:
	var title := Label.new()
	title.text = "◆ 知识问答（每答对 %d 题奖励 %s ×%d）" % [
		QuestData.QUIZ_REWARD_EVERY,
		ItemTypes.item_name(QuestData.QUIZ_REWARD_ITEM),
		QuestData.QUIZ_REWARD_COUNT,
	]
	title.add_theme_font_size_override("font_size", 19)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	_content.add_child(title)

	var q_label := Label.new()
	q_label.text = _quiz_question if not _quiz_question.is_empty() else "（点选项开始作答）"
	q_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	q_label.add_theme_font_size_override("font_size", 17)
	q_label.add_theme_color_override("font_color", BODY_COLOR)
	_content.add_child(q_label)
	_quiz_question = q_label.text

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_content.add_child(row)
	for i in _quiz_options.size():
		var btn := Button.new()
		btn.text = _quiz_options[i]
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(0, 36)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 15)
		btn.disabled = _quiz_busy
		var idx := i
		btn.pressed.connect(func(): _on_quiz_answer(idx))
		row.add_child(btn)

	_quiz_feedback = Label.new()
	_quiz_feedback.add_theme_font_size_override("font_size", 15)
	_quiz_feedback.add_theme_color_override("font_color", BODY_COLOR)
	_content.add_child(_quiz_feedback)


func _draw_question() -> void:
	if _quiz_pool.is_empty():
		var pool: Array[int] = []
		for i in QuestData.quiz_bank().size():
			pool.append(i)
		_quiz_pool = pool
		_quiz_pool.shuffle()
	var index: int = _quiz_pool.pop_back()
	var card: Dictionary = QuestData.quiz_bank()[index]
	var options: Array[String] = []
	for option: String in card["options"]:
		options.append(option)
	var answer_text: String = options[int(card["answer"])]
	options.shuffle()
	_quiz_question = String(card["q"])
	_quiz_options = options
	_quiz_answer = options.find(answer_text)
	_quiz_busy = false
	refresh()


func _on_quiz_answer(index: int) -> void:
	if _quiz_busy or _quiz_answer < 0:
		return
	_quiz_busy = true
	var correct := index == _quiz_answer
	if _quiz_feedback != null:
		_quiz_feedback.text = "回答正确！" if correct \
			else "答错了，正确答案是「%s」。" % _quiz_options[_quiz_answer]
		_quiz_feedback.add_theme_color_override("font_color", GOOD_COLOR if correct else BAD_COLOR)
	Progress.answer_quiz(correct)
	var timer := get_tree().create_timer(1.2)
	timer.timeout.connect(func():
		_quiz_busy = false
		if visible:
			_draw_question())


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(16)
	return style


func _btn_style(bg: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = PANEL_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(6)
	return style
