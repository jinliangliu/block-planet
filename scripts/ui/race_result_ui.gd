class_name RaceResultUI
extends CanvasLayer
## 结算界面：名次、完赛时间、最快圈速、是否破纪录，以及全场成绩表。

signal again_requested
signal back_requested

const TEXT := Color(0.10, 0.10, 0.14)
const DIM := Color(0.36, 0.36, 0.42)
const GOLD := Color(0.86, 0.62, 0.12)
const GOOD := Color(0.16, 0.55, 0.28)

var _root: Control
var _body: VBoxContainer
var _built := false


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
	style.content_margin_left = 28.0
	style.content_margin_right = 28.0
	style.content_margin_top = 20.0
	style.content_margin_bottom = 20.0
	card.add_theme_stylebox_override("panel", style)
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.position = Vector2(-260, -200)
	card.custom_minimum_size = Vector2(520, 400)
	_root.add_child(card)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 8)
	card.add_child(_body)


func show_results(results: Array, track_def: Dictionary, outcome: Dictionary) -> void:
	_ensure_built()
	visible = true
	for child in _body.get_children():
		child.queue_free()

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
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	var again := Button.new()
	again.text = "再来一次"
	again.custom_minimum_size = Vector2(150, 44)
	again.focus_mode = Control.FOCUS_NONE
	UiKit.apply_warm_style(again)
	again.pressed.connect(func(): again_requested.emit())
	var back := Button.new()
	back.text = "返回赛道选择"
	back.custom_minimum_size = Vector2(170, 44)
	back.focus_mode = Control.FOCUS_NONE
	UiKit.apply_warm_style(back)
	back.pressed.connect(func(): back_requested.emit())
	row.add_child(again)
	row.add_child(back)
	_body.add_child(row)


func hide_results() -> void:
	visible = false


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
