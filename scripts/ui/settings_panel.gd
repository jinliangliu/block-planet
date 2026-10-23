class_name SettingsPanel
extends Control

## 飞行设置面板（与任务面板同款的模态窗口，ESC/关闭键退出）。
## 三行分段按钮：
##   - 难度：休闲 / 标准 / 硬核（预设决定默认辅助等级）
##   - 辅助稳定：关闭 / 半开 / 全开（可单独覆盖难度的默认值）
##   - 涂装：四套 AircraftLivery
## 两组开关行（两格分段按钮，D-057 补齐入口）：
##   「相机与提示」- 镜头抖动 / 松手回正 / HUD 模式（简单|详细）/ 双击改平 / 警告蜂鸣
##   「气象」- 风（D-067 的 wind_enabled：关掉后 State.wind 恒零，气动行为与
##   无气象版逐字节一致）
## 改动即时生效（飞机每帧读 FlightSettings.current().gains()）并落盘
## user://settings.json；面板本身只做展示与改写，不直接碰飞行动力学。
## 9 键全部有面板入口（D-057 补 5 开关、D-067 的风闸同款补行）；标题行带
## 「恢复默认」一键回 9 键初值（D-058，reset_to_defaults 为默认值唯一定义处）；
## 触屏设备经 HUD 动作按钮簇的「设置」按钮打开本面板（D-058，hud.gd）。

signal closed
## changed 为变更键名（camera_shake/auto_recenter/hud_detail/auto_level/
## beeper_enabled/wind_enabled）；难度/辅助/涂装变更时为空串，消费方按需分支。
signal settings_changed(difficulty: int, assist_level: int, livery_index: int, changed: String)

const PANEL_BG := Color(0.95, 0.92, 0.84)
const PANEL_BORDER := Color(0.62, 0.47, 0.27)
const TITLE_COLOR := Color(0.36, 0.26, 0.13)
const BODY_COLOR := Color(0.42, 0.32, 0.18)

var _settings: FlightSettings
var _difficulty_buttons: Array[Button] = []
var _assist_buttons: Array[Button] = []
var _livery_buttons: Array[Button] = []
## 开关行按钮组（D-057）：[0]=开/简单，[1]=关/详细（hud_detail 语义反转）。
var _shake_buttons: Array[Button] = []
var _recenter_buttons: Array[Button] = []
var _hud_buttons: Array[Button] = []
var _level_buttons: Array[Button] = []
var _beeper_buttons: Array[Button] = []
## 「气象」风开关行（D-067 的 wind_enabled，与 D-057 五行同款两格分段）。
var _wind_buttons: Array[Button] = []
## 「恢复默认」按钮（D-058，标题行；探针经此点它）。
var _reset_button: Button
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

	# D-057：开关区加入后面板变高，外包 ScrollContainer 防小屏/竖屏高度溢出。
	# 宽度按内容最宽行（涂装 4×160+间距≈658）取 680：桌面不出现横向滚动条，
	# 窄屏放不下时横向滚动可达（不裁剪涂装行）；横向模式保持默认 AUTO。
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(680, 0)
	var vp_h := get_viewport_rect().size.y
	if vp_h > 0.0:
		scroll.custom_minimum_size.y = mini(int(vp_h * 0.8), 760)
	panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)
	var title := Label.new()
	title.text = "飞行设置"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	# 「恢复默认」（D-058）：放在标题行常驻可见——小屏面板内容可滚动，
	# 放底部会被滚出视野；误点代价仅是重选三行 + 六个开关，不做二次确认。
	var reset_btn := Button.new()
	reset_btn.text = "恢复默认"
	reset_btn.custom_minimum_size = Vector2(96, 36)
	reset_btn.focus_mode = Control.FOCUS_NONE
	reset_btn.add_theme_font_size_override("font_size", 16)
	reset_btn.add_theme_color_override("font_color", TITLE_COLOR)
	reset_btn.pressed.connect(_on_reset)
	header.add_child(reset_btn)
	_reset_button = reset_btn
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

	# 「相机与提示」开关区（D-057）：此前这 5 个键只有快捷键/改 JSON 两种入口，
	# 面板统一暴露；hud_detail 档位文案用「简单|详细」（与 H 键 Toast 一致）。
	vbox.add_child(_make_row_label("相机与提示"))
	vbox.add_child(_make_toggle_row("镜头抖动", "camera_shake", ["开", "关"],
		_settings.camera_shake, _shake_buttons))
	vbox.add_child(_make_toggle_row("松手回正", "auto_recenter", ["开", "关"],
		_settings.auto_recenter, _recenter_buttons))
	vbox.add_child(_make_toggle_row("HUD 模式", "hud_detail", ["简单", "详细"],
		_settings.hud_detail, _hud_buttons))
	vbox.add_child(_make_toggle_row("双击改平", "auto_level", ["开", "关"],
		_settings.auto_level, _level_buttons))
	vbox.add_child(_make_toggle_row("警告蜂鸣", "beeper_enabled", ["开", "关"],
		_settings.beeper_enabled, _beeper_buttons))

	# 「气象」开关区（D-067）：风场总闸。关掉后 State.wind 恒零，气动行为与
	# 无气象版逐字节一致（探针 / 取证同用）；默认开。
	vbox.add_child(_make_row_label("气象"))
	vbox.add_child(_make_toggle_row("风", "wind_enabled", ["开", "关"],
		_settings.wind_enabled, _wind_buttons))

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


## 开关行（D-057）：行名 + 两格分段按钮。names[0] 对应 on=true 的档位
## （「开」/「简单」），names[1] 对应 off；current_on 为当前布尔值。
## 按钮写入 buttons_out 供 refresh 同步选中态。
func _make_toggle_row(row_name: String, key: String, names: Array, current_on: bool,
		buttons_out: Array[Button]) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.add_child(_make_row_label(row_name))
	box.add_child(_make_segment(
		names, 0 if current_on else 1,
		func(i: int): _on_toggle(key, i), buttons_out))
	return box


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
	# 开关选中态：[0]=开/简单。hud_detail 的「详细」在 index 1（语义反转）。
	_sync(_shake_buttons, 0 if _settings.camera_shake else 1)
	_sync(_recenter_buttons, 0 if _settings.auto_recenter else 1)
	_sync(_hud_buttons, 1 if _settings.hud_detail else 0)
	_sync(_level_buttons, 0 if _settings.auto_level else 1)
	_sync(_beeper_buttons, 0 if _settings.beeper_enabled else 1)
	_sync(_wind_buttons, 0 if _settings.wind_enabled else 1)
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


## 开关行回调（D-057）：index 0=开/简单，1=关/详细；hud_detail 语义反转
## （「详细」在 index 1）。直接写属性（纯 bool，无越界风险），随后统一落盘。
func _on_toggle(key: String, index: int) -> void:
	match key:
		"camera_shake":
			_settings.camera_shake = (index == 0)
		"auto_recenter":
			_settings.auto_recenter = (index == 0)
		"hud_detail":
			_settings.hud_detail = (index == 1)
		"auto_level":
			_settings.auto_level = (index == 0)
		"beeper_enabled":
			_settings.beeper_enabled = (index == 0)
		"wind_enabled":
			_settings.wind_enabled = (index == 0)
	_after_change(key)


## 「恢复默认」（D-058）：9 键一次性回到默认值（默认值唯一定义在
## FlightSettings.reset_to_defaults，含 wind_enabled），随后走统一落盘 + Toast 通道
## （changed="reset"，HUD 文案「已恢复默认设置」）。
func _on_reset() -> void:
	_settings.reset_to_defaults()
	_after_change("reset")


func _after_change(changed: String = "") -> void:
	# P2-14：设置落盘失败不静默（push_warning 进控制台；设置对本进程仍生效，
	# 玩家下次启动会回到旧值——比无声丢失好排查）。
	if not _settings.save():
		push_warning("SettingsPanel: 设置保存失败（磁盘写入被拒？）")
	refresh()
	settings_changed.emit(
		_settings.difficulty, _settings.assist_level, _settings.livery_index, changed)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(16)
	return style
