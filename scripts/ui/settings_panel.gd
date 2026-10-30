class_name SettingsPanel
extends Control

## 设置面板（与任务面板同款的模态窗口，ESC/关闭键退出）。
## 标题叫「设置」（D-078 前是「飞行设置」）：本面板已经不止管飞行——
## 「世界」区的和平开关是每档案一份的世界设定，与飞行无关。
## 三行分段按钮：
##   - 难度：休闲 / 标准 / 硬核（预设决定默认辅助等级）
##   - 辅助稳定：关闭 / 半开 / 全开（可单独覆盖难度的默认值）
##   - 涂装：四套 AircraftLivery
## 三组开关行（两格分段按钮，D-057 补齐入口，D-067 / D-078 各补一组）：
##   「相机与提示」- 镜头抖动 / 松手回正 / HUD 模式（简单|详细）/ 双击改平 / 警告蜂鸣
##   「气象」- 风（D-067 的 wind_enabled：关掉后 State.wind 恒零，气动行为与
##   无气象版逐字节一致）
##   「世界」- 和平模式（D-078 的 GameState.peaceful：每**档案**一份，落在当前槽的
##   world.json，**不走** FlightSettings）——关闭要一次确认，开启则即时生效。
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
## 「世界」区的和平开关行（D-078）：[0]=开，[1]=关。数值不来自 FlightSettings。
var _peaceful_buttons: Array[Button] = []
## 关闭和平模式的一次性确认层（D-078 非对称确认；懒建后复用）。
var _confirm_layer: Control = null
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
	title.text = "设置"
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

	# ── 「世界」区（D-078）：和平模式开关 ──
	# 位置刻意排在**难度之前**：本面板包了 ScrollContainer（高度 = min(视口高×0.8,
	# 760)）且已有十余个键，再往下会被滑出视野，而这是「夜里有没有怪物」这类
	# 安全相关设置，孩子和家长都得在第一屏就够得到。
	vbox.add_child(_make_row_label("世界"))
	var peaceful_box := VBoxContainer.new()
	peaceful_box.add_theme_constant_override("separation", 2)
	peaceful_box.add_child(_make_row_label("和平模式"))
	peaceful_box.add_child(_make_segment(
		["开", "关"], 0 if GameState.is_peaceful() else 1,
		func(i: int): _on_peaceful(i), _peaceful_buttons))
	var peaceful_hint := Label.new()
	peaceful_hint.text = "夜里不会有怪物、怪物也打不到你；但仍然会饿、会摔、飞机会摔坏。"
	peaceful_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	peaceful_hint.add_theme_font_size_override("font_size", 13)
	peaceful_hint.add_theme_color_override("font_color", BODY_COLOR)
	peaceful_box.add_child(peaceful_hint)
	vbox.add_child(peaceful_box)

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
	# 未完成的确认随面板一起收起：下一次打开不该凭空冒出一层对话框。
	_hide_peaceful_confirm()
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
	# 和平开关的真值在 GameState（由 Profile 按档灌入），不在 FlightSettings
	# ——这里只读不写，保证换槽/切换后回到面板看到的就是当前档的值。
	_sync(_peaceful_buttons, 0 if GameState.is_peaceful() else 1)
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
## 注意它**不管**和平开关——那是另一个存储体系（档案 vs 设备），改成一起复位
## 会让「恢复默认」悄悄改动别的孩子的档。
func _on_reset() -> void:
	_settings.reset_to_defaults()
	_after_change("reset")


## 和平开关回调（D-078）：落盘走 Profile 的档案通道，**绝不进 _after_change**——
## 后者是 FlightSettings.save()，写的是设备级 user://settings.json。和平每档案
## 一份，写过去就成了两套真值：换档不跟随、两边还可能给出矛盾的答案。
func _on_peaceful(index: int) -> void:
	var wanted := (index == 0)
	if wanted == GameState.is_peaceful():
		# 点了当前已选中的那一格：状态没变，只需把选中态拉回来。
		_sync(_peaceful_buttons, 0 if wanted else 1)
		return
	if wanted:
		_commit_peaceful(true)
		return
	# 关要确认（非对称）：开错一次零成本（再关掉即可）；关错则夜里怪物回来，
	# 而且孩子未必知道该去哪儿把它开回去。
	_show_peaceful_confirm()


## 真正改值：先写档（失败也继续——内存态照常生效，玩家当下不至于「点了没反应」，
## 只由 push_warning 记录），再推 GameState 发信号给 HUD，最后同步选中态。
func _commit_peaceful(value: bool) -> void:
	var settings := Profile.read_slot_settings()
	settings["peaceful"] = value
	if not Profile.write_slot_settings(settings):
		push_warning("SettingsPanel: 和平模式保存失败（磁盘写入被拒？）")
	_hide_peaceful_confirm()
	GameState.set_peaceful(value)
	_sync(_peaceful_buttons, 0 if value else 1)


func _show_peaceful_confirm() -> void:
	if _confirm_layer == null:
		_confirm_layer = _build_peaceful_confirm()
	_confirm_layer.visible = true


func _hide_peaceful_confirm() -> void:
	if _confirm_layer != null:
		_confirm_layer.visible = false


## 确认层现场搭在同一面板里而不新建场景：它只服务于「关和平」这一种情境，
## 没有第二个调用方，独立成 scene 反而多一处要同步配色与布局的地方。
func _build_peaceful_confirm() -> Control:
	var layer := Control.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 必须吃掉鼠标：确认没结束之前，底下的开关、恢复默认与 ✕ 都不该能被点到。
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.45)
	layer.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(center)
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", _panel_style())
	center.add_child(box)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	box.add_child(vbox)
	var question := Label.new()
	question.text = "关掉后，夜里会重新出现怪物，确定要关掉和平模式吗？"
	question.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	question.custom_minimum_size = Vector2(340, 0)
	question.add_theme_font_size_override("font_size", 16)
	question.add_theme_color_override("font_color", BODY_COLOR)
	vbox.add_child(question)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	vbox.add_child(row)
	# 「取消」在前且用主色：不确定时随手一点 = 什么也不发生，这才是默认选项。
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.custom_minimum_size = Vector2(120, 40)
	cancel.focus_mode = Control.FOCUS_NONE
	cancel.add_theme_font_size_override("font_size", 16)
	UiKit.apply_warm_style(cancel)
	cancel.pressed.connect(_hide_peaceful_confirm)
	row.add_child(cancel)
	var ok := Button.new()
	ok.text = "确定"
	ok.custom_minimum_size = Vector2(120, 40)
	ok.focus_mode = Control.FOCUS_NONE
	ok.add_theme_font_size_override("font_size", 16)
	ok.pressed.connect(func(): _commit_peaceful(false))
	row.add_child(ok)
	add_child(layer)
	layer.visible = false
	return layer


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
