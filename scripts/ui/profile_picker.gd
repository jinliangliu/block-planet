extends Control
## 档案选择器（M7.4）：J/O 之外的玩家档案切换界面。
## 列出所有存档槽，提供「进入 / 删除」与「新建档案」；选中即切换 Progress 当前槽。
## 作为 HUD 模态窗口（冻结玩家），配色与任务面板同色系。
##
## 不引入 class_name（避免 global_script_class_cache 失配导致无头解析失败，见踩坑 #24），
## 由 HUD 以 preload 方式实例化。

signal closed
signal slot_selected(id: String)

const PANEL_BG := Color(0.95, 0.92, 0.84)
const PANEL_BORDER := Color(0.62, 0.47, 0.27)
const TITLE_COLOR := Color(0.36, 0.26, 0.13)
const BODY_COLOR := Color(0.42, 0.32, 0.18)
const TAB_BG := Color(0.89, 0.85, 0.74)
const GOOD_COLOR := Color(0.30, 0.55, 0.15)
const BAD_COLOR := Color(0.70, 0.25, 0.18)

var _list: VBoxContainer
var _name_input: LineEdit
var _hint: Label


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
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
	title.text = "选择玩家档案"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := UiKit.make_close()
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_font_size_override("font_size", 15)
	_hint.add_theme_color_override("font_color", BODY_COLOR)
	vbox.add_child(_hint)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 280)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)

	# 新建档案区
	var new_row := HBoxContainer.new()
	new_row.add_theme_constant_override("separation", 8)
	vbox.add_child(new_row)
	_name_input = LineEdit.new()
	_name_input.placeholder_text = "新档案名称（如：小明的档案）"
	_name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_input.max_length = 16
	new_row.add_child(_name_input)
	var create_btn := _warm_button("创建并进入")
	create_btn.pressed.connect(_on_create)
	new_row.add_child(create_btn)

	refresh()


func open() -> void:
	refresh()
	visible = true


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


## 重建槽列表（条目有限，整页重建代价可忽略）。
func refresh() -> void:
	if _list == null:
		return
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()

	var slots: Array[Dictionary] = Profile.list_slots()
	if slots.is_empty():
		_hint.text = "还没有档案，创建你的第一个吧！（已有的游戏进度会自动并入）"
	else:
		_hint.text = "选择要进入的档案；每个档案的进度独立保存。"
		var only_one := slots.size() == 1
		for s: Dictionary in slots:
			_list.add_child(_make_row(String(s["id"]), String(s["name"]), only_one))

	# 无槽时禁用名称输入框下方的「删除」逻辑由行内按钮控制；这里确保新建始终可用。
	_name_input.editable = true


func _make_row(id: String, name: String, only_one: bool) -> Control:
	var box := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(TAB_BG, 0.55)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(8)
	box.add_theme_stylebox_override("panel", style)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)

	var name_label := Label.new()
	name_label.text = name
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", TITLE_COLOR)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var is_current := Profile.current_slot() == id
	var enter := _warm_button("当前" if is_current else "进入")
	enter.disabled = is_current
	enter.pressed.connect(func(): _on_enter(id))
	row.add_child(enter)

	var del := _warm_button("删除")
	del.disabled = only_one
	del.add_theme_color_override("font_color", BAD_COLOR)
	del.pressed.connect(func(): _on_delete(id))
	row.add_child(del)
	return box


func _on_enter(id: String) -> void:
	if not Profile.select_slot(id):
		return
	Progress.set_slot(id)
	slot_selected.emit(id)
	close()


func _on_delete(id: String) -> void:
	if not Profile.delete_slot(id):
		return
	# 删掉的是当前槽时，Progress 内存态仍指向旧文件；切到新当前槽以刷新。
	if Profile.current_slot() != "":
		Progress.set_slot(Profile.current_slot())
	refresh()


func _on_create() -> void:
	var name := _name_input.text.strip_edges()
	if name.is_empty():
		name = "玩家%d" % (Profile.list_slots().size() + 1)
	var id := Profile.create_slot(name)
	if not Profile.select_slot(id):
		return
	Progress.set_slot(id)
	slot_selected.emit(id)
	close()


func _warm_button(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(96, 34)
	btn.add_theme_font_size_override("font_size", 15)
	btn.add_theme_color_override("font_color", TITLE_COLOR)
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(6)
	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("pressed", style)
	btn.add_theme_stylebox_override("disabled", style)
	style.set_border_width_all(1)
	return btn


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(16)
	return style
