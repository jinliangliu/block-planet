class_name FishingTeachingUI
extends Control
## 钓鱼引导教学弹窗：一次讲一课，一课分几步，读完记进日志（下次不再弹）。
##
## 单独一个全屏浮层而不是嵌在渔猎界面里：教学要在「关键操作之前」盖住屏幕，
## 让玩家先读再动手；嵌进界面里会被四个阶段的其他控件挤到角落，读不着。
## 触发判定在 FishingSystem.pending_lesson()，本类只负责显示。

signal closed

const PANEL_BG := Color(0.97, 0.95, 0.88)
const PANEL_BORDER := Color(0.62, 0.47, 0.27)
const TITLE_COLOR := Color(0.32, 0.24, 0.10)
const BODY_COLOR := Color(0.40, 0.31, 0.16)
const STEP_COLOR := Color(0.36, 0.52, 0.20)

var _panel: PanelContainer
var _title: Label
var _step_label: Label
var _progress_label: Label
var _next_button: Button
var _lesson_id := ""
var _steps: PackedStringArray = PackedStringArray()
var _index := 0


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 40
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.05, 0.10, 0.62)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(20)
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(460, 0)
	vbox.add_theme_constant_override("separation", 12)
	_panel.add_child(vbox)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 24)
	_title.add_theme_color_override("font_color", TITLE_COLOR)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_title)

	_progress_label = Label.new()
	_progress_label.add_theme_font_size_override("font_size", 13)
	_progress_label.add_theme_color_override("font_color", Color(0.55, 0.46, 0.30))
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_progress_label)

	_step_label = Label.new()
	_step_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_step_label.custom_minimum_size = Vector2(420, 0)
	_step_label.add_theme_font_size_override("font_size", 18)
	_step_label.add_theme_color_override("font_color", BODY_COLOR)
	vbox.add_child(_step_label)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	var skip := Button.new()
	skip.text = "跳过"
	skip.custom_minimum_size = Vector2(100, 40)
	skip.focus_mode = Control.FOCUS_NONE
	skip.pressed.connect(func(): _finish())
	row.add_child(skip)

	_next_button = Button.new()
	_next_button.text = "下一步"
	_next_button.custom_minimum_size = Vector2(120, 40)
	_next_button.focus_mode = Control.FOCUS_NONE
	_next_button.pressed.connect(_on_next)
	row.add_child(_next_button)


## 弹一课；空字典则不显示（该课已经看过或没有这一课）。
func show_lesson(lesson: Dictionary) -> bool:
	if lesson.is_empty():
		return false
	_lesson_id = String(lesson.get("id", ""))
	_steps = FishingSystem.teaching.steps_of(_lesson_id)
	if _steps.is_empty():
		return false
	_index = 0
	_title.text = String(lesson.get("title_zh", "小提示"))
	visible = true
	_refresh()
	return true


func is_open() -> bool:
	return visible


func close() -> void:
	visible = false


func _on_next() -> void:
	if _index >= _steps.size() - 1:
		_finish()
		return
	_index += 1
	_refresh()


func _refresh() -> void:
	_step_label.text = String(_steps[_index])
	_progress_label.text = "第 %d / %d 步" % [_index + 1, _steps.size()]
	_next_button.text = "知道了" if _index >= _steps.size() - 1 else "下一步"


## 读完（或跳过）都算看过：教学只在第一次挡路，之后可在钓具界面点「重看教学」。
func _finish() -> void:
	if not _lesson_id.is_empty():
		FishingSystem.mark_lesson_seen(_lesson_id)
	visible = false
	closed.emit()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
