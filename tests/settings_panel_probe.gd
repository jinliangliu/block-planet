extends Node

## 无头验证 SettingsPanel 与 FlightSettings 的 UI 闭环（不依赖世界）：
## 两行分段按钮、难度→辅助预设重置、辅助单独覆盖、点击即落盘、选中态同步、
## 模态开/关与 closed 信号。注意按钮点击用 pressed.emit() 触发（与真实点击同路）。

var _pass := 0
var _fail := 0


func _check(cond, msg) -> void:
	if cond:
		print("PASS: " + msg)
		_pass += 1
	else:
		print("FAIL: " + msg)
		_fail += 1


func _ready() -> void:
	# 用干净的默认实例做单例，避免探针污染真实 user://settings.json。
	FlightSettings.set_current(FlightSettings.default_settings())
	var panel := SettingsPanel.new()
	add_child(panel)
	await get_tree().process_frame

	# 初始隐藏 + 两行分段按钮。
	_check(not panel.is_open(), "面板初始隐藏")
	_check(panel._difficulty_buttons.size() == 3, "难度三档按钮（实际 %d）" % panel._difficulty_buttons.size())
	_check(panel._assist_buttons.size() == 3, "辅助三档按钮（实际 %d）" % panel._assist_buttons.size())
	_check(panel._difficulty_buttons[0].text == "休闲" and panel._difficulty_buttons[2].text == "硬核", "难度按钮文案")
	_check(panel._assist_buttons[0].text == "关闭" and panel._assist_buttons[2].text == "全开", "辅助按钮文案")
	# 默认：标准 + 半开，选中态在索引 1。
	_check(panel._difficulty_buttons[1].button_pressed, "默认选中标准难度")
	_check(panel._assist_buttons[1].button_pressed, "默认选中半开辅助")

	panel.open()
	_check(panel.is_open(), "open() 后面板可见")

	# 点击「休闲」：难度变更并把辅助重置为预设（全开）。
	var box := {"n": 0}
	panel.settings_changed.connect(func(_d: int, _a: int): box["n"] += 1)
	panel._difficulty_buttons[0].pressed.emit()
	_check(FlightSettings.current().difficulty == FlightSettings.Difficulty.CASUAL, "点击休闲后难度=休闲")
	_check(FlightSettings.current().assist_level == FlightSettings.Assist.FULL,
		"难度预设把辅助重置为全开（实际 %s）" % FlightSettings.current().assist_name())
	_check(box["n"] == 1, "settings_changed 信号发出一次（实际 %d）" % box["n"])
	_check(panel._difficulty_buttons[0].button_pressed and panel._assist_buttons[2].button_pressed,
		"选中态同步到休闲/全开")

	# 单独覆盖辅助为「关闭」，难度仍休闲。
	panel._assist_buttons[0].pressed.emit()
	_check(FlightSettings.current().assist_level == FlightSettings.Assist.OFF,
		"辅助可单独覆盖为关闭")
	_check(FlightSettings.current().difficulty == FlightSettings.Difficulty.CASUAL, "覆盖辅助不动难度")

	# 再点难度「硬核」：辅助被重置为关闭（硬核默认）。
	panel._difficulty_buttons[2].pressed.emit()
	_check(FlightSettings.current().difficulty == FlightSettings.Difficulty.EXPERT, "点击硬核后难度=硬核")
	_check(FlightSettings.current().assist_level == FlightSettings.Assist.OFF, "硬核默认辅助关闭")

	# 落盘：读回一致。
	var read := FlightSettings.load_or_new()
	_check(read.difficulty == FlightSettings.Difficulty.EXPERT and read.assist_level == FlightSettings.Assist.OFF,
		"设置已落盘，读回一致")

	# 关闭：隐藏 + closed 信号。
	var closed := {"n": 0}
	panel.closed.connect(func(): closed["n"] += 1)
	panel.close()
	_check(not panel.is_open(), "close() 后面板隐藏")
	_check(closed["n"] == 1, "close() 发出 closed 信号")

	# 清理：不留下真实存档污染。
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://settings.json"))
	FlightSettings.set_current(null)

	print("SETTINGS_PANEL_DONE fails=%d" % _fail)
	if _fail > 0:
		print("SETTINGS_PANEL_FAIL")
	else:
		print("SETTINGS_PANEL_OK")
	get_tree().quit()
