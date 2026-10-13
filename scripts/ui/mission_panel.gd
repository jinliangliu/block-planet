class_name MissionPanel
extends Control

## 飞行任务面板（K 键唤出的模态窗口，冻结玩家；配色同「任务与成就」面板）。
## 展示 MissionData.default_missions() 的 MVP 三任务（起飞/绕点/降落）：
##   - 未进行时列出可选任务卡（标题/说明/奖励/开始按钮）；
##   - 进行中显示当前任务计时与目标摘要，可放弃；
##   - 结束后显示结果，成功奖励经 mission_reward 信号上交 HUD 发放绿宝石。
##
## 本面板自持 MissionManager（Phase 3a 纯逻辑）；外部（main）每物理帧调用
## feed(dt, telemetry) 喂真实飞行遥测—— altitude_agl / speed(km/h) / position /
## on_ground / vertical_speed / wrecked，与 MissionManager 的遥测约定一致。

signal closed
signal mission_reward(emeralds: int, success: bool, result: Dictionary)

const PANEL_BG := Color(0.95, 0.92, 0.84)
const PANEL_BORDER := Color(0.62, 0.47, 0.27)
const TITLE_COLOR := Color(0.36, 0.26, 0.13)
const BODY_COLOR := Color(0.42, 0.32, 0.18)
const CARD_BG := Color(0.89, 0.85, 0.74)
const GOOD_COLOR := Color(0.30, 0.55, 0.15)
const BAD_COLOR := Color(0.70, 0.25, 0.18)

var _mm := MissionManager.new()
var _missions: Array[MissionData] = []
var _content: VBoxContainer
var _status_label: Label
var _result_label: Label


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

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
	vbox.custom_minimum_size = Vector2(640, 0)
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)
	var title := Label.new()
	title.text = "飞行任务"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := UiKit.make_close()
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	_missions = MissionData.default_missions()
	_mm.mission_result.connect(_on_mission_result)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 15)
	_status_label.add_theme_color_override("font_color", BODY_COLOR)
	vbox.add_child(_status_label)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 360)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 10)
	scroll.add_child(_content)

	_result_label = Label.new()
	_result_label.add_theme_font_size_override("font_size", 17)
	_result_label.add_theme_color_override("font_color", BODY_COLOR)
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_result_label)

	refresh()


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


## 是否正在执行任务（main 据此决定是否喂遥测）。
func is_running() -> bool:
	return _mm.status == MissionManager.Status.RUNNING


## 开始第 index 个任务（已在其他任务进行中则忽略）。
func start_mission(index: int) -> void:
	if _mm.status == MissionManager.Status.RUNNING:
		return
	if index < 0 or index >= _missions.size():
		return
	_result_label.text = ""
	_mm.start(_missions[index])
	refresh()


## 放弃当前任务（判失败，原因「主动放弃」）。
func abandon_mission() -> void:
	_mm.abandon()


## 每物理帧喂遥测；仅在 RUNNING 时透传给 MissionManager，并刷新计时。
func feed(dt: float, telemetry: Dictionary) -> void:
	if _mm.status != MissionManager.Status.RUNNING:
		return
	_mm.step(dt, telemetry)
	_refresh_status()


func refresh() -> void:
	if _content == null:
		return
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()
	if _mm.status == MissionManager.Status.RUNNING:
		_build_running_card()
	else:
		for i in _missions.size():
			_content.add_child(_make_mission_card(i))
	_refresh_status()


## 任务说明文案：由类型与参数现场组织（MissionData 无 desc 字段，保持数据精简）。
func _describe(m: MissionData) -> String:
	match m.type:
		MissionData.Type.TAKEOFF:
			return "爬升到 %.0f m 以上，并保持 %.0f km/h 以上空速。" % [
				m.target_altitude(), m.min_speed()]
		MissionData.Type.CIRCUIT:
			return "按顺序经过 %d 个航点（判定半径 %.0f m）。" % [
				m.waypoints.size(), m.radius()]
		MissionData.Type.LANDING:
			return "以低于 %.1f m/s 的垂直速度触地，停稳在降落区（半径 %.0f m）内。" % [
				m.max_touchdown_vs(), m.zone_radius()]
		_:
			return ""


func _make_mission_card(index: int) -> Control:
	var m := _missions[index]
	var box := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(CARD_BG, 0.55)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(10)
	box.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	box.add_child(vbox)

	var head := HBoxContainer.new()
	vbox.add_child(head)
	var name_label := Label.new()
	name_label.text = m.title
	name_label.add_theme_font_size_override("font_size", 19)
	name_label.add_theme_color_override("font_color", TITLE_COLOR)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_label)

	var reward_label := Label.new()
	reward_label.text = "奖励：绿宝石 ×%d" % m.reward_emeralds()
	reward_label.add_theme_font_size_override("font_size", 15)
	reward_label.add_theme_color_override("font_color", BODY_COLOR)
	head.add_child(reward_label)

	var desc := Label.new()
	desc.text = _describe(m)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 15)
	desc.add_theme_color_override("font_color", BODY_COLOR)
	vbox.add_child(desc)

	var start_btn := Button.new()
	start_btn.text = "开始任务"
	start_btn.focus_mode = Control.FOCUS_NONE
	start_btn.custom_minimum_size = Vector2(120, 34)
	start_btn.add_theme_font_size_override("font_size", 16)
	start_btn.add_theme_color_override("font_color", TITLE_COLOR)
	var idx := index
	start_btn.pressed.connect(func(): start_mission(idx))
	vbox.add_child(start_btn)
	return box


func _build_running_card() -> void:
	var m := _mm.mission
	if m == null:
		return
	var box := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(CARD_BG, 0.75)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(10)
	box.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	box.add_child(vbox)

	var head := HBoxContainer.new()
	vbox.add_child(head)
	var name_label := Label.new()
	name_label.text = "进行中：" + m.title
	name_label.add_theme_font_size_override("font_size", 19)
	name_label.add_theme_color_override("font_color", TITLE_COLOR)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_label)

	var abandon_btn := Button.new()
	abandon_btn.text = "放弃"
	abandon_btn.focus_mode = Control.FOCUS_NONE
	abandon_btn.custom_minimum_size = Vector2(90, 32)
	abandon_btn.add_theme_font_size_override("font_size", 15)
	abandon_btn.add_theme_color_override("font_color", BAD_COLOR)
	abandon_btn.pressed.connect(abandon_mission)
	head.add_child(abandon_btn)

	var desc := Label.new()
	desc.text = _describe(m)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 15)
	desc.add_theme_color_override("font_color", BODY_COLOR)
	vbox.add_child(desc)

	var hint := Label.new()
	hint.text = "（回到驾驶舱飞行，遥测会实时驱动判定）"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", BODY_COLOR)
	vbox.add_child(hint)
	_content.add_child(box)


func _refresh_status() -> void:
	if _status_label == null:
		return
	if _mm.status == MissionManager.Status.RUNNING:
		var t := _mm.elapsed()
		_status_label.text = "已用时间：%.1f s" % t
	else:
		_status_label.text = ""


func _on_mission_result(success: bool, result: Dictionary) -> void:
	_result_label.text = "%s：%s（用时 %.1f s，得分 %d）" % [
		"任务成功" if success else "任务失败",
		String(result.get("reason", "")),
		float(result.get("elapsed", 0.0)),
		int(result.get("score", 0)),
	]
	_result_label.add_theme_color_override(
		"font_color", GOOD_COLOR if success else BAD_COLOR)
	refresh()
	if success:
		mission_reward.emit(int(result.get("reward", 0)), true, result)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(16)
	return style
