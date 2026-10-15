class_name SettingsPanel
extends Control

## 飞行设置面板（与任务面板同款的模态窗口，ESC/关闭键退出）。
## 两行分段按钮：
##   - 难度：休闲 / 标准 / 硬核（预设决定默认辅助等级）
##   - 辅助稳定：关闭 / 半开 / 全开（可单独覆盖难度的默认值）
## 改动即时生效（飞机每帧读 FlightSettings.current().gains()）并落盘
## user://settings.json；面板本身只做展示与改写，不直接碰飞行动力学。

signal closed
signal settings_changed(difficulty: int, assist_level: int, livery_index: int)

const PANEL_BG := Color(0.95, 0.92, 0.84)
const PANEL_BORDER := Color(0.62, 0.47, 0.27)
const TITLE_COLOR := Color(0.36, 0.26, 0.13)
const BODY_COLOR := Color(0.42, 0.32, 0.18)

var _settings: FlightSettings
var _difficulty_buttons: Array[Button] = []
var _assist_buttons: Array[Button] = []
var _livery_buttons: Array[Button] = []
var _status_label: Label


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_settings = FlightSettings.current()

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
	vbox.custom_minimum_size = Vector2(560, 0)
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)
	var title := Label.new()
	title.text = "飞行设置"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := UiKit.make_close()
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	vbox.add_child(_make_row_label("难度"))
	vbox.add_child(_make_segment(
		["休闲", "标准", "硬核"], _settings.difficulty,
		func(i: int): _on_difficulty(i), _difficulty_buttons))

	vbox.add_child(_make_row_label("辅助稳定"))
	vbox.add_child(_make_segment(
		["关闭", "半开", "全开"], _settings.assist_level,
		func(i: int): _on_assist(i), _assist_buttons))

	vbox.add_child(_make_row_label("涂装"))
	vbox.add_child(_make_segment(
		AircraftLivery.names(), _settings.livery_index,
		func(i: int): _on_livery(i), _livery_buttons))

	var hint := Label.new()
	hint.text = "辅助稳定只在松杆时接管：放手后自动摆平机翼、压住摆头；一压杆立刻让位。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", BODY_COLOR)
	vbox.add_child(hint)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 16)
	_status_label.add_theme_color_override("font_color", BODY_COLOR)
	vbox.add_child(_status_label)

	refresh()


func _make_row_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", TITLE_COLOR)
	return l


## 分段按钮组（ButtonGroup + toggle_mode 呈现选中态）；返回装按钮的 HBoxContainer，
## 按钮本身写入 buttons_out 供 refresh 同步选中态。
func _make_segment(names: Array, current: int, on_pick: Callable,
		buttons_out: Array[Button]) -> HBoxContainer:
	var group := ButtonGroup.new()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	for i in names.size():
		var b := Button.new()
		b.text = String(names[i])
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(160, 36)
		b.add_theme_font_size_override("font_size", 16)
		b.add_theme_color_override("font_color", TITLE_COLOR)
		b.button_pressed = (i == current)
		var idx := i
		b.pressed.connect(func(): on_pick.call(idx))
		row.add_child(b)
		buttons_out.append(b)
	return row


func open() -> void:
	visible = true
	refresh()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func refresh() -> void:
	if _settings == null:
		return
	_sync(_difficulty_buttons, _settings.difficulty)
	_sync(_assist_buttons, _settings.assist_level)
	_sync(_livery_buttons, _settings.livery_index)
	if _status_label != null:
		_status_label.text = "当前：难度 %s · 辅助 %s · 涂装 %s" % [
			_settings.difficulty_name(), _settings.assist_name(), _settings.livery_name()]


func _sync(buttons: Array[Button], current: int) -> void:
	for i in buttons.size():
		buttons[i].button_pressed = (i == current)


func _on_difficulty(index: int) -> void:
	_settings.set_difficulty(index)
	_after_change()


func _on_assist(index: int) -> void:
	_settings.set_assist_level(index)
	_after_change()


func _on_livery(index: int) -> void:
	_settings.set_livery(index)
	_after_change()


func _after_change() -> void:
	# P2-14：设置落盘失败不静默（push_warning 进控制台；设置对本进程仍生效，
	# 玩家下次启动会回到旧值——比无声丢失好排查）。
	if not _settings.save():
		push_warning("SettingsPanel: 设置保存失败（磁盘写入被拒？）")
	refresh()
	settings_changed.emit(
		_settings.difficulty, _settings.assist_level, _settings.livery_index)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(16)
	return style
