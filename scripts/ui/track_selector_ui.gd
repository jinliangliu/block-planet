class_name TrackSelectorUI
extends Control
## 赛道选择器（模态）：选主题 → 选赛道 → 选赛车 → 设机器人数量与难度 → 开始比赛。
## 附带「竞速记录」页，显示每条赛道的最佳圈速 / 最短完赛 / 胜场 / 总场次，可清空。

signal closed
signal race_requested(track_id: String, vehicle_id: String, ai_count: int, ai_difficulty: String)

const PANEL_BG := Color(0.96, 0.94, 0.88)
const PANEL_BORDER := Color(0.62, 0.47, 0.27)
const TITLE_COLOR := Color(0.34, 0.24, 0.12)
const BODY_COLOR := Color(0.40, 0.31, 0.18)
const CARD_BG := Color(0.90, 0.87, 0.78)
const CARD_SEL := Color(0.99, 0.90, 0.60)
const LOCKED_BG := Color(0.82, 0.80, 0.76)
const CHIP_ACTIVE := Color(0.87, 0.72, 0.42)

const THEMES := [
	["all", "全部"], ["desert", "沙漠"], ["forest", "森林"],
	["wetland", "湿地"], ["mountain", "山地"], ["city", "城市"], ["mixed", "混合"],
]

var _theme_filter := "all"
var _selected_track := ""
var _selected_vehicle := "tricycle"
var _ai_count := 3
var _ai_difficulty := "easy"
var _show_records := false

var _card_row: HBoxContainer
var _card_grid: GridContainer
var _theme_row: HBoxContainer
var _vehicle_row: HBoxContainer
var _ai_count_row: HBoxContainer
var _ai_diff_row: HBoxContainer
var _start_button: Button
var _summary: Label
var _records_box: VBoxContainer
var _content_stack: Control
var _detail_title: Label
var _detail_body: Label


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.04, 0.07, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(16)
	style.content_margin_left = 24.0
	style.content_margin_right = 24.0
	style.content_margin_top = 16.0
	style.content_margin_bottom = 16.0
	card.add_theme_stylebox_override("panel", style)
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.position = Vector2(-450, -300)
	card.custom_minimum_size = Vector2(900, 600)
	add_child(card)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	card.add_child(box)

	var head := HBoxContainer.new()
	box.add_child(head)
	var title := _label("选择赛道", 30, TITLE_COLOR)
	head.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	var close := UiKit.make_close(24)
	close.pressed.connect(close_panel)
	head.add_child(close)

	_theme_row = HBoxContainer.new()
	_theme_row.add_theme_constant_override("separation", 6)
	box.add_child(_theme_row)

	_card_grid = GridContainer.new()
	_card_grid.columns = 3
	_card_grid.add_theme_constant_override("h_separation", 10)
	_card_grid.add_theme_constant_override("v_separation", 10)
	box.add_child(_card_grid)

	_summary = _label("", 18, BODY_COLOR)
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.custom_minimum_size = Vector2(840, 44)
	box.add_child(_summary)

	_vehicle_row = HBoxContainer.new()
	_vehicle_row.add_theme_constant_override("separation", 6)
	box.add_child(_row_labeled("赛车", _vehicle_row))

	_ai_count_row = HBoxContainer.new()
	_ai_count_row.add_theme_constant_override("separation", 6)
	box.add_child(_row_labeled("机器人数量", _ai_count_row))

	_ai_diff_row = HBoxContainer.new()
	_ai_diff_row.add_theme_constant_override("separation", 6)
	box.add_child(_row_labeled("机器人难度", _ai_diff_row))

	_records_box = VBoxContainer.new()
	_records_box.add_theme_constant_override("separation", 4)
	_records_box.visible = false
	box.add_child(_records_box)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 10)
	box.add_child(foot)
	_start_button = Button.new()
	_start_button.text = "开始比赛"
	_start_button.custom_minimum_size = Vector2(180, 46)
	_start_button.focus_mode = Control.FOCUS_NONE
	UiKit.apply_warm_style(_start_button)
	_start_button.pressed.connect(_on_start)
	foot.add_child(_start_button)
	var rec_btn := Button.new()
	rec_btn.text = "竞速记录"
	rec_btn.custom_minimum_size = Vector2(140, 46)
	rec_btn.focus_mode = Control.FOCUS_NONE
	UiKit.apply_warm_style(rec_btn)
	rec_btn.pressed.connect(func():
		_show_records = not _show_records
		_refresh())
	foot.add_child(rec_btn)


func open() -> void:
	visible = true
	_show_records = false
	var tracks := RaceSystem.tracks()
	if _selected_track.is_empty() and not tracks.is_empty():
		_selected_track = String((tracks[0] as Dictionary).get("id", ""))
	_refresh()


func close_panel() -> void:
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func _refresh() -> void:
	_refresh_themes()
	_refresh_cards()
	_refresh_vehicles()
	_refresh_ai_count()
	_refresh_ai_diff()
	_refresh_summary()
	_refresh_records()


func _refresh_themes() -> void:
	_clear(_theme_row)
	for pair: Array in THEMES:
		var id := String(pair[0])
		var b := _chip(String(pair[1]), id == _theme_filter)
		b.pressed.connect(func():
			_theme_filter = id
			_refresh())
		_theme_row.add_child(b)


func _refresh_cards() -> void:
	_clear(_card_grid)
	for item: Variant in RaceSystem.tracks():
		var t: Dictionary = item
		if _theme_filter != "all" and String(t.get("theme", "")) != _theme_filter:
			continue
		_card_grid.add_child(_track_card(t))


func _track_card(t: Dictionary) -> Control:
	var id := String(t.get("id", ""))
	var unlocked := RaceSystem.is_unlocked(String(t.get("unlock", "default")))
	var selected := id == _selected_track
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = CARD_SEL if selected else (CARD_BG if unlocked else LOCKED_BG)
	style.set_corner_radius_all(10)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	if selected:
		style.border_color = Color(0.75, 0.55, 0.18)
		style.set_border_width_all(2)
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size = Vector2(266, 118)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	panel.add_child(box)
	box.add_child(_label(String(t.get("name_zh", "赛道")), 20, TITLE_COLOR))
	box.add_child(_label(_stars(int(t.get("difficulty", 1))), 16, Color(0.80, 0.55, 0.10)))
	box.add_child(_label("%d m · %d 圈" % [int(t.get("length_m", 0)), int(t.get("laps", 3))],
		15, BODY_COLOR))
	var best := RaceSystem.entry_of(id)
	var bl := float(best["best_lap_time"])
	box.add_child(_label("最佳圈速 %s" % RaceSystem.format_lap(bl), 15,
		Color(0.20, 0.48, 0.22) if bl > 0.0 else Color(0.52, 0.48, 0.42)))
	if not unlocked:
		box.add_child(_label("🔒 %s" % RaceSystem.unlock_hint(String(t.get("unlock", ""))),
			14, Color(0.55, 0.28, 0.20)))
	else:
		box.add_child(_label("%s · 推荐 %d 台" % [
			_difficulty_name(String(t.get("ai_difficulty", "easy"))),
			int(t.get("ai_count", 3))], 14, Color(0.45, 0.40, 0.32)))
	if unlocked:
		panel.gui_input.connect(func(ev: InputEvent) -> void:
			if ev is InputEventMouseButton and ev.pressed \
					and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
				_selected_track = id
				_refresh())
	return panel


func _refresh_vehicles() -> void:
	_clear(_vehicle_row)
	for item: Variant in RaceSystem.player_vehicles():
		var v: Dictionary = item
		var id := String(v.get("id", ""))
		if not RaceSystem.is_unlocked(String(v.get("unlock", "default"))):
			continue
		var b := _chip(String(v.get("name_zh", id)), id == _selected_vehicle)
		b.tooltip_text = String(v.get("desc", ""))
		b.pressed.connect(func():
			_selected_vehicle = id
			_refresh())
		_vehicle_row.add_child(b)


func _refresh_ai_count() -> void:
	_clear(_ai_count_row)
	for n in range(0, 6):
		var b := _chip("%d" % n, n == _ai_count)
		b.pressed.connect(func():
			_ai_count = n
			_refresh())
		_ai_count_row.add_child(b)


func _refresh_ai_diff() -> void:
	_clear(_ai_diff_row)
	for item: Variant in RaceSystem.difficulties():
		var d: Dictionary = item
		var id := String(d.get("id", ""))
		var b := _chip(String(d.get("name_zh", id)), id == _ai_difficulty)
		b.pressed.connect(func():
			_ai_difficulty = id
			_refresh())
		_ai_diff_row.add_child(b)


func _refresh_summary() -> void:
	var t := RaceSystem.track(_selected_track)
	if t.is_empty():
		_summary.text = "还没有可选的赛道。"
		_start_button.disabled = true
		return
	var unlocked := RaceSystem.is_unlocked(String(t.get("unlock", "default")))
	_start_button.disabled = not unlocked
	if not unlocked:
		_summary.text = "🔒 %s（%s）" % [String(t.get("name_zh", "")),
			RaceSystem.unlock_hint(String(t.get("unlock", "")))]
		return
	var terrains := PackedStringArray()
	var seen := {}
	for seg: Variant in (t.get("terrain_segments", []) as Array):
		var tid := String((seg as Dictionary).get("terrain_id", ""))
		if seen.has(tid):
			continue
		seen[tid] = true
		terrains.append(String(RaceSystem.terrain(tid).get("name_zh", tid)))
	var v := RaceSystem.vehicle(_selected_vehicle)
	_summary.text = "%s：%s · %d 圈 · 路面 %s｜赛车 %s（极速 %d km/h）｜机器人 %d 台·%s" % [
		String(t.get("name_zh", "")),
		_stars(int(t.get("difficulty", 1))),
		int(t.get("laps", 3)),
		"，".join(terrains),
		String(v.get("name_zh", _selected_vehicle)),
		int(round(float(v.get("max_speed_mps", 20.0)) * 3.6)),
		_ai_count,
		_difficulty_name(_ai_difficulty),
	]


func _refresh_records() -> void:
	_clear(_records_box)
	_records_box.visible = _show_records
	if not _show_records:
		return
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	head.add_child(_label("竞速记录", 20, TITLE_COLOR))
	var clr := Button.new()
	clr.text = "清空记录"
	clr.custom_minimum_size = Vector2(110, 34)
	clr.focus_mode = Control.FOCUS_NONE
	UiKit.apply_warm_style(clr)
	clr.pressed.connect(func():
		RaceSystem.clear_records()
		_refresh())
	head.add_child(clr)
	_records_box.add_child(head)
	var any := false
	for item: Variant in RaceSystem.tracks():
		var t: Dictionary = item
		var id := String(t.get("id", ""))
		var e := RaceSystem.entry_of(id)
		if int(e["total_races"]) <= 0:
			continue
		any = true
		_records_box.add_child(_label("%s｜最快圈 %s｜最短完赛 %s｜胜 %d / 共 %d 场｜最好名次 %d" % [
			String(t.get("name_zh", id)),
			RaceSystem.format_lap(float(e["best_lap_time"])),
			RaceSystem.format_time(float(e["best_race_time"])),
			int(e["wins"]), int(e["total_races"]), int(e["best_rank"]),
		], 15, BODY_COLOR))
	if not any:
		_records_box.add_child(_label("还没有比赛记录，先去跑一场吧！", 15, BODY_COLOR))


func _on_start() -> void:
	var t := RaceSystem.track(_selected_track)
	if t.is_empty() or not RaceSystem.is_unlocked(String(t.get("unlock", "default"))):
		return
	race_requested.emit(_selected_track, _selected_vehicle, _ai_count, _ai_difficulty)


func _row_labeled(name: String, row: HBoxContainer) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var l := _label(name, 17, TITLE_COLOR)
	l.custom_minimum_size = Vector2(96, 0)
	h.add_child(l)
	h.add_child(row)
	return h


func _chip(text: String, active: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 16)
	var style := StyleBoxFlat.new()
	style.bg_color = CHIP_ACTIVE if active else CARD_BG
	style.set_corner_radius_all(8)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	for state in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(state, style)
	b.add_theme_color_override("font_color", Color(0.28, 0.20, 0.08))
	return b


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _stars(n: int) -> String:
	return "★".repeat(clampi(n, 1, 5))


func _difficulty_name(id: String) -> String:
	return String(RaceSystem.difficulty(id).get("name_zh", id))


func _clear(node: Node) -> void:
	for child in node.get_children():
		child.queue_free()
		node.remove_child(child)
