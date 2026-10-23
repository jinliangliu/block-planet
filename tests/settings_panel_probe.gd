extends Node

## 无头验证 SettingsPanel 与 FlightSettings 的 UI 闭环（不依赖世界）：
## 三行分段按钮（难度/辅助/涂装）+ 六行开关（镜头抖动/松手回正/HUD 模式/
## 双击改平/警告蜂鸣/气象风场，D-057 补 5 行、D-067 补风行），难度→辅助预设
## 重置、辅助单独覆盖、点击即落盘、选中态同步、模态开/关与 closed 信号、
## 开关与三项互不污染；
## D 段（D-058）：「恢复默认」按钮（9 键回初值 + 信号键名 + 落盘）+ HUD
## _toggle_settings_panel 开关语义（触屏入口函数本体；无头不建触控层，
## 按钮接线由代码评审保证）。
## 注意按钮点击用 pressed.emit() 触发（与真实点击同路）。

var _pass := 0
var _fail := 0
## 真实 settings.json 快照（D-010 铁律 3）：面板点击会经 current().save() 写真实
## 存档，原实现末尾直接删除——用户若有真实飞行设置会被毁。改为结束前原样还原。
var _settings_existed := false
var _settings_text := ""
## 还原幂等标记（_restore_settings 只生效一次）。
var _restored := false


func _check(cond, msg) -> void:
	if cond:
		print("PASS: " + msg)
		_pass += 1
	else:
		print("FAIL: " + msg)
		_fail += 1


func _ready() -> void:
	# 看门狗：脚本错误猝杀协程时强制退出（否则进程挂起、还原不执行）；
	# settings.json 的还原由 _exit_tree 安全网兜底（D-010）。
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		push_warning("settings_panel_probe: 看门狗超时，强制退出")
		get_tree().quit())
	# 先快照真实 settings.json，再隔离单例（面板点击的落盘在结束时还原）。
	if FileAccess.file_exists("user://settings.json"):
		_settings_existed = true
		var sf := FileAccess.open("user://settings.json", FileAccess.READ)
		_settings_text = sf.get_as_text()
		sf.close()
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
	panel.settings_changed.connect(func(_d: int, _a: int, _l: int, _k: String): box["n"] += 1)
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

	# 涂装行：四套涂装，点「落日橙」改 livery_index 并落盘；越界夹回。
	_check(panel._livery_buttons.size() == AircraftLivery.count(),
		"涂装按钮数=涂装数（%d）" % AircraftLivery.count())
	_check(panel._livery_buttons[0].button_pressed, "默认选中第一套涂装")
	panel._livery_buttons[3].pressed.emit()
	_check(FlightSettings.current().livery_index == 3, "点落日橙后涂装索引=3")
	_check(FlightSettings.current().livery_name() == "落日橙", "涂装名=落日橙")
	_check(panel._livery_buttons[3].button_pressed and not panel._livery_buttons[0].button_pressed,
		"涂装选中态同步")
	var read2 := FlightSettings.load_or_new()
	_check(read2.livery_index == 3, "涂装已落盘")
	# 越界保护。
	FlightSettings.current().set_livery(99)
	_check(FlightSettings.current().livery_index == AircraftLivery.count() - 1, "涂装索引越界夹回")

	# ── 开关行（D-057 五行 + D-067 风行）：全部有面板入口 ──
	_check(panel._shake_buttons.size() == 2 and panel._recenter_buttons.size() == 2
		and panel._hud_buttons.size() == 2 and panel._level_buttons.size() == 2
		and panel._beeper_buttons.size() == 2 and panel._wind_buttons.size() == 2,
		"六个开关行各两格按钮")
	_check(panel._shake_buttons[0].text == "开" and panel._shake_buttons[1].text == "关",
		"镜头抖动开关文案")
	_check(panel._hud_buttons[0].text == "简单" and panel._hud_buttons[1].text == "详细",
		"HUD 开关文案（简单|详细）")
	# 默认值选中态：camera_shake/auto_recenter/auto_level/beeper 默认开→[0]；
	# hud_detail 默认简单→[0]（「详细」在 index 1，语义反转）。
	_check(panel._shake_buttons[0].button_pressed, "默认镜头抖动=开")
	_check(panel._recenter_buttons[0].button_pressed, "默认松手回正=开")
	_check(panel._hud_buttons[0].button_pressed, "默认 HUD=简单")
	_check(panel._level_buttons[0].button_pressed, "默认双击改平=开")
	_check(panel._beeper_buttons[0].button_pressed, "默认警告蜂鸣=开")
	_check(panel._wind_buttons[0].text == "开" and panel._wind_buttons[1].text == "关",
		"气象风场开关文案")
	_check(panel._wind_buttons[0].button_pressed, "默认气象风场=开")

	# 逐个切换：单例值 + 信号键名（Dictionary 按引用捕获，可靠计数）。
	var keys := {"n": 0, "last": ""}
	panel.settings_changed.connect(func(_d: int, _a: int, _l: int, k: String) -> void:
		keys["n"] += 1
		keys["last"] = k)
	panel._shake_buttons[1].pressed.emit()
	_check(not FlightSettings.current().camera_shake, "点关后镜头抖动=false")
	_check(keys["last"] == "camera_shake", "信号带变更键名 camera_shake")
	panel._recenter_buttons[1].pressed.emit()
	_check(not FlightSettings.current().auto_recenter, "点关后松手回正=false")
	_check(keys["last"] == "auto_recenter", "信号带变更键名 auto_recenter")
	panel._hud_buttons[1].pressed.emit()
	_check(FlightSettings.current().hud_detail, "点详细后 hud_detail=true")
	_check(keys["last"] == "hud_detail", "信号带变更键名 hud_detail")
	panel._level_buttons[1].pressed.emit()
	_check(not FlightSettings.current().auto_level, "点关后双击改平=false")
	panel._beeper_buttons[1].pressed.emit()
	_check(not FlightSettings.current().beeper_enabled, "点关后警告蜂鸣=false")
	panel._wind_buttons[1].pressed.emit()
	_check(not FlightSettings.current().wind_enabled, "点关后气象风场=false")
	_check(keys["last"] == "wind_enabled", "信号带变更键名 wind_enabled")
	_check(keys["n"] == 6, "六次开关各发一次信号（实际 %d）" % keys["n"])
	# 选中态同步（refresh 路径）：关/详细在 index 1。
	_check(panel._shake_buttons[1].button_pressed and not panel._shake_buttons[0].button_pressed,
		"镜头抖动选中态同步到关")
	_check(panel._hud_buttons[1].button_pressed and not panel._hud_buttons[0].button_pressed,
		"HUD 选中态同步到详细")
	# 落盘读回：6 个开关 + 三项都在。
	var read3 := FlightSettings.load_or_new()
	_check(read3.camera_shake == false and read3.auto_recenter == false
		and read3.hud_detail == true and read3.auto_level == false
		and read3.beeper_enabled == false and read3.wind_enabled == false,
		"六个开关全部落盘，读回一致")
	_check(read3.difficulty == FlightSettings.Difficulty.EXPERT
		and read3.assist_level == FlightSettings.Assist.OFF,
		"开关变更不动难度/辅助（隔离性）")
	# 开关改完再改难度：set_difficulty 只重置 assist，不碰开关。
	panel._difficulty_buttons[0].pressed.emit()
	_check(FlightSettings.current().difficulty == FlightSettings.Difficulty.CASUAL,
		"开关段后改难度=休闲")
	_check(not FlightSettings.current().camera_shake
		and FlightSettings.current().hud_detail,
		"难度变更不重置开关值")

	# ── D 段（D-058）：「恢复默认」按钮 + 触屏开关入口 ──
	# 先把 9 键全改成非默认值，再点「恢复默认」，逐一验回初值 + 落盘。
	var defaults := FlightSettings.default_settings().to_dict()
	_check(panel._reset_button != null and panel._reset_button.text == "恢复默认",
		"标题行有「恢复默认」按钮")
	panel._shake_buttons[1].pressed.emit()      # camera_shake = false
	panel._recenter_buttons[1].pressed.emit()   # auto_recenter = false
	panel._hud_buttons[1].pressed.emit()        # hud_detail = true
	panel._level_buttons[1].pressed.emit()      # auto_level = false
	panel._beeper_buttons[1].pressed.emit()     # beeper_enabled = false
	panel._wind_buttons[1].pressed.emit()       # wind_enabled = false
	panel._livery_buttons[3].pressed.emit()     # livery_index = 3
	var dirty := FlightSettings.current().to_dict()
	var any_dirty := false
	for k in defaults:
		if dirty[k] != defaults[k]:
			any_dirty = true
	_check(any_dirty, "改乱后 9 键至少一项偏离默认（前提）")
	var reset_keys := {"n": 0, "last": ""}
	panel.settings_changed.connect(func(_d: int, _a: int, _l: int, k: String) -> void:
		reset_keys["n"] += 1
		reset_keys["last"] = k)
	panel._reset_button.pressed.emit()
	var after := FlightSettings.current().to_dict()
	var all_default := true
	for k in defaults:
		if after[k] != defaults[k]:
			all_default = false
			print("  恢复默认偏差: %s = %s（期望 %s）" % [k, str(after[k]), str(defaults[k])])
	_check(all_default, "恢复默认后 9 键全部回到默认值")
	_check(reset_keys["n"] == 1 and reset_keys["last"] == "reset",
		"恢复默认发一次信号且键名=reset（实际 n=%d last=%s）"
			% [reset_keys["n"], reset_keys["last"]])
	_check(panel._difficulty_buttons[1].button_pressed and panel._assist_buttons[1].button_pressed
		and panel._livery_buttons[0].button_pressed,
		"恢复默认后三项选中态同步回默认")
	_check(panel._shake_buttons[0].button_pressed and panel._hud_buttons[0].button_pressed
		and panel._beeper_buttons[0].button_pressed and panel._wind_buttons[0].button_pressed,
		"恢复默认后开关选中态同步回默认")
	var read4 := FlightSettings.load_or_new()
	_check(read4.to_dict() == defaults, "恢复默认已落盘，读回一致")

	# 触屏开关入口（D-058）：无头环境不建触控层（is_touchscreen_available()
	# =false），按钮接线由代码评审保证；这里验 toggle 函数本体——与 O 键
	# 同语义：开 → 关 → 开。
	var host := Control.new()
	add_child(host)
	var hud := HUD.new()
	add_child(hud)
	hud._build_settings_panel(host)
	await get_tree().process_frame
	hud._toggle_settings_panel()
	_check(hud._settings_panel.is_open(), "触屏入口：首次调用打开面板")
	hud._toggle_settings_panel()
	_check(not hud._settings_panel.is_open(), "触屏入口：再次调用关闭面板")
	hud.queue_free()
	host.queue_free()

	# 关闭：隐藏 + closed 信号。
	var closed := {"n": 0}
	panel.closed.connect(func(): closed["n"] += 1)
	panel.close()
	_check(not panel.is_open(), "close() 后面板隐藏")
	_check(closed["n"] == 1, "close() 发出 closed 信号")

	# 还原真实 settings.json 原样（D-010）：探针期间的点击落盘不留给用户。
	_restore_settings()

	print("SETTINGS_PANEL_DONE fails=%d" % _fail)
	if _fail > 0:
		print("SETTINGS_PANEL_FAIL")
	else:
		print("SETTINGS_PANEL_OK")
	get_tree().quit()


## 还原 user://settings.json 快照（幂等；正常路径与 _exit_tree 安全网都走它）。
## D-010 教训：探针协程被脚本错误猝杀时，末尾还原不会执行——退出期再兜一层。


func _restore_settings() -> void:
	if _restored:
		return
	_restored = true
	if _settings_existed:
		var sf := FileAccess.open("user://settings.json", FileAccess.WRITE)
		sf.store_string(_settings_text)
		sf.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://settings.json"))
	FlightSettings.set_current(null)


func _exit_tree() -> void:
	_restore_settings()
