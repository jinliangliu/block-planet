class_name BestiaryUI
extends Control
## 星球生物图鉴（F2）：两页签的模态窗口，配色与储物箱/说明书同色系。
##
##   图鉴页 —— 左栏三组筛选芯片（界 / 类 / 地区）+ 搜索框，右栏卡片网格，
##             下栏条目详情；卡片按界的主色描边，游戏里能遇见的物种额外标记。
##   问答页 —— data/bestiary/quiz.json 的题目打乱出题，答对计入 Progress
##             （沿用既有的「知识问答」成就与每 3 题发奖链路，不另建一套）。
##
## 为什么 UI 全用代码搭、不留 .tscn：本工程其余面板（说明书、任务、背包、地图）
## 都是纯代码构建，只有 main/player 两个场景文件。场景文件与代码两处描述同一棵
## 节点树，改一处就得记得同步另一处——图鉴本来就有 170+ 张卡片，更需要单一来源。
##
## 卡片是「建一次、按筛选切换显隐」，不是每次筛选都重建：170 张卡片里每张都带
## 3 个子标签，重建一次要 new 500 多个节点，切换筛选会明显卡顿。

signal closed

enum Tab { ENTRIES, QUIZ }

const PANEL_BG := Color(0.95, 0.92, 0.84)
const PANEL_BORDER := Color(0.62, 0.47, 0.27)
const TITLE_COLOR := Color(0.36, 0.26, 0.13)
const BODY_COLOR := Color(0.42, 0.32, 0.18)
const CHIP_BG := Color(0.89, 0.85, 0.74)
const CHIP_ACTIVE := Color(0.80, 0.72, 0.55)
const DETAIL_BG := Color(0.91, 0.87, 0.77)
const CLOSE_COLOR := Color(0.85, 0.22, 0.20)
const GOOD_COLOR := Color(0.30, 0.55, 0.15)
const BAD_COLOR := Color(0.70, 0.25, 0.18)

const PANEL_SIZE := Vector2(1160.0, 664.0)
const LEFT_WIDTH := 272.0
const CARD_COLUMNS := 4
const CHIP_SIZE := Vector2(0.0, 30.0)

## 题库按 id 前缀分组，显示成主题徽章（q_polar_001 → 极地）。
const QUIZ_THEMES := [
	["q_polar", "极地"],
	["q_ocean", "海洋"],
	["q_continent", "大洲"],
	["q_plant", "植物"],
]

var _tab := Tab.ENTRIES
var _tab_buttons: Array[Button] = []
var _entry_page: Control
var _quiz_page: Control
var _status_label: Label

var _search_box: LineEdit
var _kingdom_flow: HFlowContainer
var _category_flow: HFlowContainer
var _region_flow: HFlowContainer
var _grid: GridContainer
var _summary_label: Label
var _detail_name: Label
var _detail_latin: Label
var _detail_badges: HBoxContainer
var _detail_fact: Label
var _detail_game: Label
var _cards: Dictionary = {}
var _selected_card: EntryCard

var _quiz_theme_label: Label
var _quiz_question: Label
var _quiz_options: VBoxContainer
var _quiz_feedback: Label
var _quiz_next: Button
var _quiz_correct_label: Label
var _quiz_pool: Array[int] = []
var _quiz_index := -1
var _quiz_answer := ""
var _quiz_answered := false
var _quiz_correct := 0

var _kingdom := ""
var _category := ""
var _region := ""


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	if BestiaryData.is_loaded:
		_on_bestiary_loaded()
	else:
		BestiaryData.bestiary_loaded.connect(_on_bestiary_loaded)


func open() -> void:
	visible = true


## 从地图页跳进来：按该世界区域预置地区筛选，直接看到当地物种。
func open_for_atlas_region(atlas_id: int) -> void:
	var ids: Array = BestiaryData.region_ids_of_atlas(atlas_id)
	if not ids.is_empty():
		_region = String(ids[0])
		_kingdom = ""
		_category = ""
		_set_tab(Tab.ENTRIES)
		_rebuild_chips()
		_refresh_grid()
	open()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func get_tab() -> int:
	return _tab


# ────────────────────────────── 构建 ──────────────────────────────

func _build() -> void:
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var wrapper := Control.new()
	wrapper.custom_minimum_size = PANEL_SIZE
	center.add_child(wrapper)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", _panel_style())
	wrapper.add_child(panel)

	var main := VBoxContainer.new()
	main.add_theme_constant_override("separation", 8)
	panel.add_child(main)

	main.add_child(_build_header())

	_entry_page = _build_entry_page()
	_entry_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(_entry_page)

	_quiz_page = _build_quiz_page()
	_quiz_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_quiz_page.visible = false
	main.add_child(_quiz_page)

	main.add_child(_build_status_bar())


func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)

	var title := Label.new()
	title.text = "星球生物图鉴"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	_tab_buttons.clear()
	var labels := ["图鉴", "知识问答"]
	for i in labels.size():
		var btn := Button.new()
		btn.text = labels[i]
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(108, 36)
		btn.add_theme_font_size_override("font_size", 17)
		btn.add_theme_color_override("font_color", TITLE_COLOR)
		var index := i
		btn.pressed.connect(func(): _set_tab(index))
		header.add_child(btn)
		_tab_buttons.append(btn)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.add_theme_color_override("font_color", CLOSE_COLOR)
	close_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.35, 0.32))
	close_btn.add_theme_font_size_override("font_size", 22)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)
	return header


func _build_entry_page() -> Control:
	var page := HBoxContainer.new()
	page.add_theme_constant_override("separation", 14)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(LEFT_WIDTH, 0.0)
	left.add_theme_constant_override("separation", 6)
	page.add_child(left)

	_search_box = LineEdit.new()
	_search_box.placeholder_text = "搜索：大熊猫 / bamboo / 南极"
	_search_box.clear_button_enabled = true
	_search_box.custom_minimum_size = Vector2(0.0, 34.0)
	_search_box.add_theme_font_size_override("font_size", 15)
	_search_box.text_changed.connect(_on_search_changed)
	left.add_child(_search_box)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(scroll)

	var filters := VBoxContainer.new()
	filters.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	filters.add_theme_constant_override("separation", 6)
	scroll.add_child(filters)

	_kingdom_flow = HFlowContainer.new()
	_category_flow = HFlowContainer.new()
	_region_flow = HFlowContainer.new()
	for spec in [["界", _kingdom_flow], ["类", _category_flow], ["地区", _region_flow]]:
		var label := Label.new()
		label.text = String(spec[0])
		label.add_theme_font_size_override("font_size", 14)
		label.add_theme_color_override("font_color", Color(BODY_COLOR, 0.75))
		filters.add_child(label)
		var flow: HFlowContainer = spec[1]
		flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		flow.add_theme_constant_override("h_separation", 5)
		flow.add_theme_constant_override("v_separation", 5)
		filters.add_child(flow)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	page.add_child(right)

	_summary_label = Label.new()
	_summary_label.add_theme_font_size_override("font_size", 15)
	_summary_label.add_theme_color_override("font_color", BODY_COLOR)
	right.add_child(_summary_label)

	var card_scroll := ScrollContainer.new()
	card_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	card_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(card_scroll)

	_grid = GridContainer.new()
	_grid.columns = CARD_COLUMNS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	card_scroll.add_child(_grid)

	right.add_child(_build_detail())
	return page


func _build_detail() -> Control:
	var detail := PanelContainer.new()
	detail.custom_minimum_size = Vector2(0.0, 148.0)
	var style := StyleBoxFlat.new()
	style.bg_color = DETAIL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(10)
	detail.add_theme_stylebox_override("panel", style)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	detail.add_child(column)

	_detail_name = Label.new()
	_detail_name.add_theme_font_size_override("font_size", 20)
	_detail_name.add_theme_color_override("font_color", TITLE_COLOR)
	_detail_name.text = "点上面的卡片，查看它的资料"
	column.add_child(_detail_name)

	_detail_latin = Label.new()
	_detail_latin.add_theme_font_size_override("font_size", 13)
	_detail_latin.add_theme_color_override("font_color", Color(BODY_COLOR, 0.85))
	column.add_child(_detail_latin)

	_detail_badges = HBoxContainer.new()
	_detail_badges.add_theme_constant_override("separation", 6)
	column.add_child(_detail_badges)

	_detail_fact = Label.new()
	_detail_fact.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_fact.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_fact.add_theme_font_size_override("font_size", 15)
	_detail_fact.add_theme_color_override("font_color", BODY_COLOR)
	column.add_child(_detail_fact)

	_detail_game = Label.new()
	_detail_game.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_game.add_theme_font_size_override("font_size", 13)
	_detail_game.add_theme_color_override("font_color", GOOD_COLOR)
	column.add_child(_detail_game)
	return detail


func _build_quiz_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)

	var head := HBoxContainer.new()
	page.add_child(head)
	var caption := Label.new()
	caption.text = "答对题目会累计到「成就 · 知识问答」，每答对 %d 题自动获得奖励。" % QuestData.QUIZ_REWARD_EVERY
	caption.add_theme_font_size_override("font_size", 15)
	caption.add_theme_color_override("font_color", BODY_COLOR)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(caption)
	_quiz_correct_label = Label.new()
	_quiz_correct_label.add_theme_font_size_override("font_size", 15)
	_quiz_correct_label.add_theme_color_override("font_color", GOOD_COLOR)
	head.add_child(_quiz_correct_label)

	var question_box := PanelContainer.new()
	question_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	question_box.add_theme_stylebox_override("panel", _detail_style())
	page.add_child(question_box)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	question_box.add_child(column)

	_quiz_theme_label = Label.new()
	_quiz_theme_label.add_theme_font_size_override("font_size", 13)
	_quiz_theme_label.add_theme_color_override("font_color", Color(BODY_COLOR, 0.8))
	column.add_child(_quiz_theme_label)

	_quiz_question = Label.new()
	_quiz_question.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_quiz_question.add_theme_font_size_override("font_size", 21)
	_quiz_question.add_theme_color_override("font_color", TITLE_COLOR)
	column.add_child(_quiz_question)

	_quiz_options = VBoxContainer.new()
	_quiz_options.add_theme_constant_override("separation", 6)
	column.add_child(_quiz_options)

	_quiz_feedback = Label.new()
	_quiz_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_quiz_feedback.add_theme_font_size_override("font_size", 15)
	_quiz_feedback.add_theme_color_override("font_color", BODY_COLOR)
	column.add_child(_quiz_feedback)

	var foot := HBoxContainer.new()
	page.add_child(foot)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(spacer)
	_quiz_next = Button.new()
	_quiz_next.text = "下一题 ▶"
	_quiz_next.focus_mode = Control.FOCUS_NONE
	_quiz_next.custom_minimum_size = Vector2(150, 42)
	_quiz_next.add_theme_font_size_override("font_size", 17)
	_quiz_next.add_theme_color_override("font_color", TITLE_COLOR)
	_quiz_next.pressed.connect(_draw_question)
	foot.add_child(_quiz_next)
	return page


func _build_status_bar() -> Control:
	var status := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = CHIP_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 7.0
	style.content_margin_bottom = 7.0
	status.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	status.add_child(row)

	_status_label = Label.new()
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", BODY_COLOR)
	row.add_child(_status_label)

	var hint := Label.new()
	hint.text = "Esc 或 F2 关闭"
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(BODY_COLOR, 0.7))
	row.add_child(hint)
	return status


# ────────────────────────────── 图鉴页 ──────────────────────────────

func _on_bestiary_loaded() -> void:
	_build_cards()
	_rebuild_chips()
	_refresh_grid()


## 卡片建一次：170+ 张卡片每张带三个子标签，反复重建会在切换筛选时明显卡顿。
func _build_cards() -> void:
	if _grid == null:
		return
	for child in _grid.get_children():
		child.queue_free()
	_cards.clear()
	for entry_value: Variant in BestiaryData.get_entries():
		var entry: Dictionary = entry_value
		var card := EntryCard.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.set_entry(entry, BestiaryData.kingdom_color(String(entry.get("kingdom", ""))),
			BestiaryData.mob_of_entry(entry) >= 0)
		var entry_id := String(entry.get("id", ""))
		card.pressed.connect(_on_card_pressed.bind(entry_id))
		_grid.add_child(card)
		_cards[entry_id] = card


func _rebuild_chips() -> void:
	_fill_chips(_kingdom_flow, [["", "全部"]], _kingdom)
	for kingdom_value: Variant in BestiaryData.get_kingdoms():
		var kingdom: Dictionary = kingdom_value
		_add_kingdom_chip(kingdom)
	_fill_chips(_category_flow, [["", "全部"]], _category)
	for category_value: Variant in BestiaryData.categories_of(_kingdom):
		var category: Dictionary = category_value
		_add_chip(_category_flow, String(category.get("name_zh", "")),
			String(category.get("id", "")), _category, _set_category)
	_fill_chips(_region_flow, [["", "全部"]], _region)
	for region_value: Variant in BestiaryData.get_regions():
		var region: Dictionary = region_value
		_add_chip(_region_flow, String(region.get("name_zh", "")),
			String(region.get("id", "")), _region, _set_region)


func _add_kingdom_chip(kingdom: Dictionary) -> void:
	var kingdom_id := String(kingdom.get("id", ""))
	var chip := _make_chip(String(kingdom.get("name_zh", "")), kingdom_id == _kingdom)
	chip.add_theme_color_override("font_color",
		BestiaryData.kingdom_color(kingdom_id) if kingdom_id == _kingdom else TITLE_COLOR)
	chip.pressed.connect(func(): _set_kingdom(kingdom_id))
	_kingdom_flow.add_child(chip)


## 顶掉旧芯片再摆新的。三组筛选各自独立重建，改一组不影响另外两组的选择。
func _fill_chips(flow: HFlowContainer, first: Array, current: String) -> void:
	if flow == null:
		return
	for child in flow.get_children():
		flow.remove_child(child)
		child.queue_free()
	var first_id := String(first[0][0])
	_add_chip(flow, String(first[0][1]), first_id, current, _set_chip_target(flow))


## 三组芯片共用一套回调：哪一组收到的 id 就改哪一组的状态。
func _set_chip_target(flow: HFlowContainer) -> Callable:
	if flow == _kingdom_flow:
		return _set_kingdom
	if flow == _category_flow:
		return _set_category
	return _set_region


func _add_chip(flow: HFlowContainer, text: String, chip_id: String, current: String, setter: Callable) -> void:
	var chip := _make_chip(text, chip_id == current)
	chip.pressed.connect(func(): setter.call(chip_id))
	flow.add_child(chip)


func _make_chip(text: String, active: bool) -> Button:
	var chip := Button.new()
	chip.text = text
	chip.focus_mode = Control.FOCUS_NONE
	chip.custom_minimum_size = CHIP_SIZE
	chip.add_theme_font_size_override("font_size", 14)
	chip.add_theme_color_override("font_color", TITLE_COLOR)
	chip.add_theme_color_override("font_hover_color", Color(0.20, 0.14, 0.06))
	chip.add_theme_color_override("font_pressed_color", TITLE_COLOR)
	var style := _chip_style(CHIP_ACTIVE if active else CHIP_BG)
	chip.add_theme_stylebox_override("normal", style)
	chip.add_theme_stylebox_override("hover", _chip_style(CHIP_BG.lightened(0.06)))
	chip.add_theme_stylebox_override("pressed", style)
	chip.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return chip


func _set_kingdom(kingdom_id: String) -> void:
	# 换界时清掉类：类是属于界的，留着上一个界的类会筛出空列表。
	_kingdom = kingdom_id
	_category = ""
	_rebuild_chips()
	_refresh_grid()


func _set_category(category_id: String) -> void:
	_category = category_id
	_rebuild_chips()
	_refresh_grid()


func _set_region(region_id: String) -> void:
	_region = region_id
	_rebuild_chips()
	_refresh_grid()


func _on_search_changed(_new_text: String) -> void:
	_refresh_grid()


func _refresh_grid() -> void:
	if _grid == null:
		return
	var keyword := "" if _search_box == null else _search_box.text
	var matched := BestiaryData.filter(_kingdom, _category, _region, keyword)
	var visible_ids := {}
	for entry_value: Variant in matched:
		var entry: Dictionary = entry_value
		visible_ids[String(entry.get("id", ""))] = true
	for entry_id: String in _cards:
		var card: EntryCard = _cards[entry_id]
		card.visible = visible_ids.has(entry_id)
	if _summary_label != null:
		_summary_label.text = "筛选：%s · %s · %s · 命中 %d 种" % [
			_filter_name(_kingdom, "全部界"),
			_filter_name(_category, "全部类"),
			_filter_name(_region, "全部地区"),
			matched.size(),
		]
	_refresh_status(matched)


func _filter_name(filter_id: String, fallback: String) -> String:
	if filter_id.is_empty():
		return fallback
	if BestiaryData.categories.has(filter_id):
		return BestiaryData.category_name(filter_id)
	var region := BestiaryData.region_by_id(filter_id)
	if not region.is_empty():
		return String(region.get("name_zh", filter_id))
	return BestiaryData.kingdom_name(filter_id)


func _refresh_status(matched: Array) -> void:
	if _status_label == null:
		return
	if _tab == Tab.QUIZ:
		_status_label.text = "本轮已答对 %d 题 · 题库共 %d 题" % [_quiz_correct, BestiaryData.get_quiz().size()]
		return
	var in_game := 0
	for entry_value: Variant in matched:
		var entry: Dictionary = entry_value
		if BestiaryData.mob_of_entry(entry) >= 0:
			in_game += 1
	_status_label.text = "图鉴收录 %d 种 · 当前命中 %d 种（其中 %d 种能在游戏里遇见）" % [
		BestiaryData.get_entries().size(), matched.size(), in_game
	]


func _on_card_pressed(entry_id: String) -> void:
	var entry := BestiaryData.get_entry(entry_id)
	if entry.is_empty():
		return
	if _selected_card != null and is_instance_valid(_selected_card):
		_selected_card.set_selected(false)
	var card: EntryCard = _cards.get(entry_id)
	if card != null:
		card.set_selected(true)
		_selected_card = card
	_show_detail(entry)


func _show_detail(entry: Dictionary) -> void:
	_detail_name.text = "%s / %s" % [
		String(entry.get("name_zh", "")),
		String(entry.get("name_en", "")),
	]
	var scientific := String(entry.get("scientific", ""))
	_detail_latin.text = scientific if not scientific.is_empty() else "（这一类生物没有单一学名）"
	_detail_fact.text = String(entry.get("fact_zh", ""))

	for child in _detail_badges.get_children():
		_detail_badges.remove_child(child)
		child.queue_free()
	_add_badge(BestiaryData.kingdom_name(String(entry.get("kingdom", ""))), Color(0.55, 0.42, 0.25))
	_add_badge(BestiaryData.category_name(String(entry.get("category", ""))),
		BestiaryData.category_color(String(entry.get("category", ""))))
	_add_badge(String(entry.get("region_name_zh", "")), Color(0.35, 0.50, 0.62))

	var mob_type := BestiaryData.mob_of_entry(entry)
	if mob_type < 0:
		_detail_game.text = ""
	else:
		var extra := ""
		if Mob.is_protected(mob_type):
			extra = "（受保护动物，名牌是绿色，打不到）"
		elif Mob.is_passive(mob_type):
			extra = "（温顺动物，狩猎前先想想留不留种）"
		else:
			extra = "（敌对生物，夜里会出来，小心）"
		_detail_game.text = "游戏内可遇见：%s%s" % [String(Mob.MOB_NAMES.get(mob_type, "")), extra]


func _add_badge(text: String, tint: Color) -> void:
	if text.is_empty():
		return
	var label := Label.new()
	label.text = " " + text + " "
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.16, 0.12, 0.06))
	var style := StyleBoxFlat.new()
	style.bg_color = Color(tint, 0.30)
	style.border_color = Color(tint, 0.75)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 5.0
	style.content_margin_right = 5.0
	style.content_margin_top = 1.0
	style.content_margin_bottom = 1.0
	label.add_theme_stylebox_override("normal", style)
	_detail_badges.add_child(label)


# ────────────────────────────── 问答页 ──────────────────────────────

func _set_tab(tab: int) -> void:
	_tab = clampi(tab, 0, 1)
	for i in _tab_buttons.size():
		var style := _chip_style(CHIP_ACTIVE if i == _tab else CHIP_BG)
		_tab_buttons[i].add_theme_stylebox_override("normal", style)
		_tab_buttons[i].add_theme_stylebox_override("pressed", style)
		if _entry_page != null:
			_entry_page.visible = _tab == Tab.ENTRIES
		if _quiz_page != null:
			_quiz_page.visible = _tab == Tab.QUIZ
	if _tab == Tab.QUIZ:
		if _quiz_pool.is_empty():
			_draw_question()
		_refresh_status([])
	else:
		_refresh_grid()


func _draw_question() -> void:
	var bank := BestiaryData.get_quiz()
	if bank.is_empty():
		_quiz_question.text = "题库为空，检查 data/bestiary/quiz.json"
		return
	if _quiz_pool.is_empty():
		var pool: Array[int] = []
		for i in bank.size():
			pool.append(i)
		pool.shuffle()
		_quiz_pool = pool
	_quiz_index = _quiz_pool.pop_back()
	var item: Dictionary = bank[_quiz_index]

	_quiz_theme_label.text = "主题：" + _quiz_theme(String(item.get("id", "")))
	_quiz_question.text = String(item.get("question_zh", ""))
	_quiz_feedback.text = ""
	_quiz_answered = false
	_quiz_answer = String(item.get("answer_zh", ""))
	_quiz_next.disabled = true

	for child in _quiz_options.get_children():
		_quiz_options.remove_child(child)
		child.queue_free()
	var options: Array = item.get("options", [])
	for option_value: Variant in options:
		var option := String(option_value)
		var btn := Button.new()
		btn.text = option
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(0.0, 40.0)
		btn.add_theme_font_size_override("font_size", 17)
		btn.add_theme_color_override("font_color", TITLE_COLOR)
		btn.pressed.connect(_on_option_pressed.bind(option))
		_quiz_options.add_child(btn)
	if _status_label != null:
		_status_label.text = "本轮已答对 %d 题 · 题库共 %d 题" % [_quiz_correct, bank.size()]


func _quiz_theme(quiz_id: String) -> String:
	for pair: Array in QUIZ_THEMES:
		if quiz_id.begins_with(String(pair[0])):
			return String(pair[1])
	return "综合"


func _on_option_pressed(option: String) -> void:
	if _quiz_answered:
		return
	_quiz_answered = true
	var correct := option == _quiz_answer
	var bank := BestiaryData.get_quiz()
	var item: Dictionary = bank[_quiz_index]
	var explain := String(item.get("explain_zh", ""))
	if correct:
		_quiz_correct += 1
		_quiz_feedback.text = "答对了！"
		if not explain.is_empty():
			_quiz_feedback.text += "  " + explain
		_quiz_feedback.add_theme_color_override("font_color", GOOD_COLOR)
	else:
		_quiz_feedback.text = "正确答案是「%s」。%s" % [_quiz_answer, explain]
		_quiz_feedback.add_theme_color_override("font_color", BAD_COLOR)
	# 计入既有的知识问答进度：成就「初识世界 / 地理小学者 / 行走的百科全书」与
	# 每答对 3 题的奖励都走这一条链路，图鉴不另建一套计分。
	Progress.answer_quiz(correct)
	_quiz_correct_label.text = "本次已答对 %d 题" % _quiz_correct
	for child in _quiz_options.get_children():
		var btn := child as Button
		btn.disabled = true
		if btn.text == _quiz_answer:
			btn.add_theme_color_override("font_color", GOOD_COLOR)
		elif btn.text == option:
			btn.add_theme_color_override("font_color", BAD_COLOR)
	_quiz_next.disabled = false
	_refresh_status([])


# ────────────────────────────── 样式 ──────────────────────────────

func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(16)
	return style


func _detail_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = DETAIL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(12)
	return style


func _chip_style(bg: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = PANEL_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 8.0
	style.content_margin_right = 8.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	return style
