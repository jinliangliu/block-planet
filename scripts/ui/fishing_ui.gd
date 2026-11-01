class_name FishingUI
extends Control
## 渔猎操作界面：鱼饵搭配 → 铅坠配重 → 抛投 → 收线，四阶段一气呵成。
##
## 状态机的真正持有者是 FishingSystem（Autoload），本界面只做两件事：
## 把玩家输入翻译成状态机的方法调用，再把状态机的数字画出来。
## 界面自己不保存「这一竿钓到什么鱼」之类的状态——刷新即重建，
## 不存在 UI 与逻辑各记一套而对不上的情况。
##
## 输入一律在 _process 里轮询（Input.is_key_pressed / is_mouse_button_pressed），
## 不走 _input：HUD 的命令分发对模态窗口会提前 return 并消费事件，
## 事件顺序一乱「按住收线」就会丢帧；轮询与事件顺序无关，手感稳定。

signal closed
## 请求弹一次教学（HUD 持有教学浮层，负责显示）。
signal teaching_requested(lesson: Dictionary)

const PANEL_BG := Color(0.97, 0.95, 0.88)
const PANEL_BORDER := Color(0.62, 0.47, 0.27)
const TITLE_COLOR := Color(0.32, 0.24, 0.10)
const BODY_COLOR := Color(0.40, 0.31, 0.16)
const HINT_COLOR := Color(0.55, 0.46, 0.30)
const OK_COLOR := Color(0.24, 0.50, 0.18)
const WARN_COLOR := Color(0.78, 0.55, 0.10)
const BAD_COLOR := Color(0.70, 0.25, 0.18)

## 蓄力速度（每秒）：满力约 1.7 秒，松手即抛。
const CAST_CHARGE := 0.6
## 卸力每次调整步长。
const DRAG_STEP := 0.5

var _title: Label
var _subtitle: Label
var _stage_box: VBoxContainer
var _power_bar: ProgressBar
var _wait_bar: ProgressBar
var _progress_bar: ProgressBar
var _tension_bar: ProgressBar
var _fish_bar: Control
var _drag_label: Label
var _info_label: Label
var _action_button: Button
var _result: Dictionary = {}
var _power := 0.0
var _paused := false
var _prev_left := false
var _prev_right := false
var _prev_confirm := false
var _reel_state: Dictionary = {}
var _fish_pos := 0.5
var _safe_min := 0.32
var _safe_max := 0.68
## 抛投提示的缓存：水层不变时那一层的鱼名单也不会变，不必每帧重算（D-083）。
var _cast_band := ""
var _cast_preview: Dictionary = {}


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 32
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.06, 0.12, 0.5)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(680, 0)
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 24)
	_title.add_theme_color_override("font_color", TITLE_COLOR)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_title)

	_subtitle = Label.new()
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_subtitle.custom_minimum_size = Vector2(640, 0)
	_subtitle.add_theme_font_size_override("font_size", 15)
	_subtitle.add_theme_color_override("font_color", HINT_COLOR)
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_subtitle)

	_stage_box = VBoxContainer.new()
	_stage_box.add_theme_constant_override("separation", 8)
	vbox.add_child(_stage_box)

	_power_bar = _make_bar(Color(0.30, 0.58, 0.78))
	_wait_bar = _make_bar(Color(0.42, 0.66, 0.36))
	_progress_bar = _make_bar(Color(0.42, 0.66, 0.36))
	_tension_bar = _make_bar(Color(0.80, 0.40, 0.20))

	_fish_bar = Control.new()
	_fish_bar.custom_minimum_size = Vector2(0, 40)
	_fish_bar.draw.connect(_draw_fish_bar)

	_info_label = Label.new()
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.custom_minimum_size = Vector2(640, 0)
	_info_label.add_theme_font_size_override("font_size", 14)
	_info_label.add_theme_color_override("font_color", BODY_COLOR)
	vbox.add_child(_info_label)

	_drag_label = Label.new()
	_drag_label.add_theme_font_size_override("font_size", 14)
	_drag_label.add_theme_color_override("font_color", BODY_COLOR)
	_drag_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_drag_label)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	_action_button = Button.new()
	_action_button.custom_minimum_size = Vector2(150, 42)
	_action_button.focus_mode = Control.FOCUS_NONE
	_action_button.pressed.connect(func(): _restart())
	row.add_child(_action_button)

	var exit := Button.new()
	exit.text = "收竿离开"
	exit.custom_minimum_size = Vector2(120, 42)
	exit.focus_mode = Control.FOCUS_NONE
	exit.pressed.connect(func(): _close())
	row.add_child(exit)


func _make_bar(fill_color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = 0.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 16)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.85, 0.81, 0.70)
	bg.set_corner_radius_all(6)
	var fill := StyleBoxFlat.new()
	fill.bg_color = fill_color
	fill.set_corner_radius_all(6)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)
	return bar


# ────────────────────────── 生命周期 ──────────────────────────

## 打开界面（FishingSystem 已经 start_fishing 过）。
func open_session() -> void:
	visible = true
	_power = 0.0
	_result = {}
	# 换钓点 / 换饵后水层名单会变，抛投预告必须重算。
	_cast_band = ""
	_cast_preview = {}
	_prev_confirm = true  # 开局那一下按键不算「确认」，免得刚打开就被跳过
	_rebuild()


func is_open() -> bool:
	return visible


func close() -> void:
	visible = false


func _close() -> void:
	FishingSystem.end_session()
	visible = false
	closed.emit()


## 教学浮层打开期间冻结收线（不然读教学的时候鱼早跑了）。
func set_paused(value: bool) -> void:
	_paused = value


func _process(delta: float) -> void:
	if not visible or _paused:
		return
	var state := FishingSystem.state
	if state == FishingSystem.State.CASTING:
		_tick_cast(delta)
	elif state == FishingSystem.State.WAITING:
		_tick_wait(delta)
	elif state == FishingSystem.State.HOOKED:
		FishingSystem.hook_fish()
		_maybe_teach("first_time_reel")
		_maybe_teach("first_time_drag")
		_rebuild()
	elif state == FishingSystem.State.REELING:
		_tick_reel(delta)
	elif state == FishingSystem.State.RESULT:
		_tick_result()


# ────────────────────────── 各阶段 ──────────────────────────

func _tick_cast(delta: float) -> void:
	if _holding():
		_power = clampf(_power + CAST_CHARGE * delta, 0.0, 1.0)
	elif _power > 0.0:
		_do_cast()
		return
	_power_bar.value = _power
	var info := FishingSystem.session_info()
	var distance := FishingGear.cast_distance(
		FishingSystem.gear.sinker(String(info["sinker_id"])), _power)
	var band := FishingGear.band_of(distance)
	if band != _cast_band:
		_cast_band = band
		_cast_preview = FishingSystem.cast_preview(_power)
	_info_label.text = _cast_hint(distance, _cast_preview)


## 抛投前提示：力度 / 落点 / **这一层最猛的是谁**（D-083）。
## 最后一项是这次加的：收线是「拉力越高压得越难」的博弈，孩子没法从「深水」
## 两个字反推出「这里有拉力 9 的大白鲨」，原来只有先白跑一趟才知道。
func _cast_hint(distance: float, preview: Dictionary) -> String:
	var head := "力度 %.0f%% —— 松手将抛到约 %.0f 米（%s）" % [
		_power * 100.0, distance, FishingGear.band_title(FishingGear.band_of(distance))]
	var fight := int(preview.get("hardest_fight", 0))
	if fight <= 0:
		return head + "\n这一层这一竿暂时没鱼：换个鱼饵，或者改个力度。"
	var tail := "这一层最猛：%s · 拉力 %d" % [
		String(preview.get("hardest_name", "")), fight]
	if bool(preview.get("line_short", false)):
		tail += "（线偏细，容易断——记得随时松手泄力）"
	return head + "\n" + tail


func _do_cast() -> void:
	var distance := FishingSystem.cast_power(_power)
	_power = 0.0
	_power_bar.value = 0.0
	if FishingSystem.state == FishingSystem.State.RESULT:
		_info_label.text = "等了很久也没有鱼咬钩。换个鱼饵，或者换个水层试试。"
		_subtitle.text = "这一竿没动静"
		_rebuild()
		return
	_subtitle.text = "抛出 %.0f 米，落在%s" % [distance, FishingGear.band_title(
		FishingGear.band_of(distance))]
	_rebuild()


func _tick_wait(delta: float) -> void:
	var outcome := FishingSystem.update_wait(delta)
	var info := FishingSystem.session_info()
	var total := maxf(float(info["wait_total"]), 0.1)
	_wait_bar.value = clampf(1.0 - float(info["wait_left"]) / total, 0.0, 1.0)
	if outcome == 1:
		_rebuild()
	elif outcome == -1:
		_info_label.text = "这一竿没鱼上钩。"
		_rebuild()


func _tick_reel(delta: float) -> void:
	_read_keys()
	FishingSystem.update_reel(delta, 1.0 if _holding() else 0.0)
	_reel_state = FishingSystem.reel_state()
	_fish_pos = float(_reel_state.get("fish_pos", 0.5))
	_safe_min = float(_reel_state.get("safe_min", 0.32))
	_safe_max = float(_reel_state.get("safe_max", 0.68))
	_progress_bar.value = float(_reel_state.get("progress", 0.0))
	_tension_bar.value = float(_reel_state.get("tension", 0.0))
	_fish_bar.queue_redraw()
	var tension := float(_reel_state.get("tension", 0.0))
	_info_label.text = "进度 %.0f%%　张力 %.0f%%　逃脱 %.0f%%" % [
		float(_reel_state.get("progress", 0.0)) * 100.0, tension * 100.0,
		float(_reel_state.get("escape", 0.0)) * 100.0]
	if tension > 0.7:
		_info_label.add_theme_color_override("font_color", BAD_COLOR)
	elif tension > 0.4:
		_info_label.add_theme_color_override("font_color", WARN_COLOR)
	else:
		_info_label.add_theme_color_override("font_color", BODY_COLOR)
	_drag_label.text = "卸力 %.1f / %.1f（← → 调整）" % [
		float(_reel_state.get("drag", 0.0)), float(_reel_state.get("drag_max", 2.0))]
	if FishingSystem.state != FishingSystem.State.REELING:
		_finish_reel()


func _finish_reel() -> void:
	if FishingSystem._progress >= 1.0:
		_result = FishingSystem.try_catch()
	else:
		_result = {}
	_rebuild()


func _tick_result() -> void:
	# 结果页用「重新按下」才算确认，避免收线时按住的那一下连点跳过结算卡片。
	var confirm := Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_ENTER) \
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if confirm and not _prev_confirm:
		_restart()
	_prev_confirm = confirm


func _restart() -> void:
	var info := FishingSystem.session_info()
	var gear_set: Dictionary = info["gear"]
	FishingSystem.start_fishing(String(info["spot_id"]), gear_set)
	_result = {}
	_power = 0.0
	_cast_band = ""
	_cast_preview = {}
	_prev_confirm = true
	_rebuild()


func _holding() -> bool:
	return Input.is_key_pressed(KEY_SPACE) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)


func _read_keys() -> void:
	var left := Input.is_key_pressed(KEY_LEFT)
	var right := Input.is_key_pressed(KEY_RIGHT)
	if left and not _prev_left:
		FishingSystem.add_drag(-DRAG_STEP)
	if right and not _prev_right:
		FishingSystem.add_drag(DRAG_STEP)
	_prev_left = left
	_prev_right = right


# ────────────────────────── 界面重建 ──────────────────────────

func _rebuild() -> void:
	# 蓄力条 / 等待条 / 进度条 / 张力条是常驻控件，各阶段轮流挂进 _stage_box：
	# 这里必须 remove_child 而不是 queue_free——后者会把它们真的删掉，
	# 下一阶段再 add_child 就是往已释放的节点上挂载。
	for child in _stage_box.get_children():
		_stage_box.remove_child(child)
	var info := FishingSystem.session_info()
	_title.text = "%s　·　%s" % [String(info["spot_name_zh"]), FishingSystem.state_name()]
	var state := FishingSystem.state
	match state:
		FishingSystem.State.SELECT_BAIT:
			_build_bait_stage()
		FishingSystem.State.SELECT_SINKER:
			_build_sinker_stage()
		FishingSystem.State.CASTING:
			_build_cast_stage()
		FishingSystem.State.WAITING:
			_build_wait_stage()
		FishingSystem.State.REELING:
			_build_reel_stage()
		FishingSystem.State.RESULT:
			_build_result_stage()
	_action_button.visible = state == FishingSystem.State.RESULT


func _build_bait_stage() -> void:
	_maybe_teach("first_time_bait")
	_subtitle.text = "第一步：选一样鱼饵。不同的鱼爱吃不同的饵。"
	_info_label.text = ""
	for item_value: Variant in FishingSystem.owned_items("baits"):
		var item: Dictionary = item_value
		var item_id := String(item.get("id", ""))
		var best := 0.0
		var loved := 0
		for pool_value: Variant in FishingSystem.get_fish_pool(
				FishingSystem.session_info()["spot_id"], item_id, ""):
			var entry: Dictionary = pool_value
			var match_value := FishingGear.bait_match(item, entry)
			best = maxf(best, match_value)
			if match_value >= FishingGear.MATCH_PREFERRED:
				loved += 1
		var btn := Button.new()
		btn.text = "%s（%s：%d 种最爱）" % [
			String(item.get("name_zh", "?")),
			"活饵" if String(item.get("type", "")) == "live" else "假饵", loved]
		btn.custom_minimum_size = Vector2(0, 38)
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(func():
			FishingSystem.select_bait(item_id)
			_maybe_teach("first_time_sinker")
			_rebuild()
		)
		_stage_box.add_child(btn)


func _build_sinker_stage() -> void:
	_subtitle.text = "第二步：配一颗铅坠。越重抛得越远，但下沉也越快。"
	_info_label.text = ""
	for item_value: Variant in FishingSystem.owned_items("sinkers"):
		var item: Dictionary = item_value
		var item_id := String(item.get("id", ""))
		var near := FishingGear.cast_distance(item, 0.0)
		var far := FishingGear.cast_distance(item, 1.0)
		var btn := Button.new()
		btn.text = "%s：%.0f~%.0f 米（%s → %s）" % [
			String(item.get("name_zh", "?")), near, far,
			FishingGear.band_title(FishingGear.band_of(near)),
			FishingGear.band_title(FishingGear.band_of(far))]
		btn.custom_minimum_size = Vector2(0, 38)
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(func():
			FishingSystem.select_sinker(item_id)
			_maybe_teach("first_time_cast")
			_rebuild()
		)
		_stage_box.add_child(btn)


func _build_cast_stage() -> void:
	_subtitle.text = "第三步：按住空格（或鼠标左键）蓄力，松手抛投。"
	_stage_box.add_child(_power_bar)


func _build_wait_stage() -> void:
	_subtitle.text = "静静等待…"
	_stage_box.add_child(_wait_bar)
	_info_label.text = "浮标一动不动，再等等。"


func _build_reel_stage() -> void:
	var fish := FishingSystem.get_fish(FishingSystem.reel_state().get("fish_id", ""))
	# 触屏没有键盘，而卸力是决定断线/跑鱼的核心机制——此前界面上写着「← → 调整」
	# 但手机根本按不出来（M9 钓鱼完善）。
	var touch := DisplayServer.is_touchscreen_available()
	_subtitle.text = "第四步：鱼咬钩了！按住收线，鱼挣扎时松手放线。"
	_drag_label.text = "卸力 ——" + ("（用下方按钮调整）" if touch else "（← → 调整）")
	_stage_box.add_child(_fish_bar)
	_stage_box.add_child(_progress_bar)
	_stage_box.add_child(_tension_bar)
	_info_label.text = "鱼在动：让它待在绿色安全区里再收线，硬拉会断线。"
	if not fish.is_empty():
		_title.text = "%s　·　收线中" % String(fish.get("name_zh", "?"))
	if touch:
		_build_drag_buttons()


## 触屏专用卸力按钮（与键盘 ← → 同一套 add_drag，行为完全一致）。
func _build_drag_buttons() -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	var loose := Button.new()
	loose.text = "卸力 −"
	loose.custom_minimum_size = Vector2(124, 54)
	loose.focus_mode = Control.FOCUS_NONE
	loose.pressed.connect(func(): FishingSystem.add_drag(-DRAG_STEP))
	row.add_child(loose)
	var tight := Button.new()
	tight.text = "卸力 ＋"
	tight.custom_minimum_size = Vector2(124, 54)
	tight.focus_mode = Control.FOCUS_NONE
	tight.pressed.connect(func(): FishingSystem.add_drag(DRAG_STEP))
	row.add_child(tight)
	_stage_box.add_child(row)


func _build_result_stage() -> void:
	_action_button.text = "再来一竿"
	if _result.is_empty():
		_subtitle.text = "这一竿没成"
		# 失败原因从收线状态里读，不另存一份：断线与跑鱼是同一套数字的两端。
		var last := FishingSystem.reel_state()
		var reason := "鱼跑了。"
		if float(last.get("tension", 0.0)) >= 1.0:
			reason = "线断了 —— 卸力太紧，或者鱼线拉力不够。下次把卸力调松一点试试。"
		elif float(last.get("escape", 0.0)) >= 1.0:
			reason = "鱼跑掉了 —— 卸力太松，拉不住它。下次把卸力调紧一点。"
		_info_label.text = reason
		return
	var fish: Dictionary = _result["fish"]
	_subtitle.text = "钓到了！"
	if bool(_result.get("is_new_species", false)):
		_build_unlock_card(fish)
	else:
		# 重复钓获也要有正反馈（M9 钓鱼完善）：max_weight_kg 此前只写不读，
		# 个人最佳孩子永远看不到。这里把它变成「新纪录！」与「最大 X kg」，
		# 再给一个长期目标（已收集 n / 总数），让「又钓到同一条」不再是空手而归。
		var record := FishingSystem.record_of(String(_result.get("fish_id", "")))
		var total := FishingSystem.fish_list.size()
		var progress := "已收集 %d / %d 种" % [FishingSystem.discovered_count(), total]
		if bool(_result.get("is_personal_best", false)):
			_info_label.text = "%s　%.2f kg　🏅 新纪录！（第 %d 次钓到）　%s" % [
				String(fish.get("name_zh", "?")), float(_result.get("weight_kg", 0.0)),
				int(_result.get("catch_count", 1)), progress]
		else:
			_info_label.text = "%s　%.2f kg　（第 %d 次钓到，最大 %.2f kg）　%s" % [
				String(fish.get("name_zh", "?")), float(_result.get("weight_kg", 0.0)),
				int(_result.get("catch_count", 1)),
				float(record.get("max_weight_kg", 0.0)), progress]
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	_stage_box.add_child(row)
	var release := Button.new()
	release.text = "放生它"
	release.custom_minimum_size = Vector2(110, 38)
	release.focus_mode = Control.FOCUS_NONE
	release.pressed.connect(func():
		var fish_id := String(_result.get("fish_id", ""))
		FishingSystem.release_fish(fish_id)
		Events.notice.emit("放生了 %s，谢谢你让它回到海里" % String(fish.get("name_zh", "?")))
		# 放生直接开下一竿：停在结算页会让「放生/再来一竿」两个按钮互相打架
		# （点完放生还停在 RESULT，下一帧的空格轮询会被当成确认而自动重开）。
		_restart()
	)
	row.add_child(release)


## 新鱼种解锁卡片（首次钓到才弹）。
func _build_unlock_card(fish: Dictionary) -> void:
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.99, 0.97, 0.86)
	style.border_color = Color(0.80, 0.66, 0.20)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(14)
	card.add_theme_stylebox_override("panel", style)
	_stage_box.add_child(card)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	card.add_child(vbox)

	var head := Label.new()
	head.text = "🎉 新鱼种解锁！"
	head.add_theme_font_size_override("font_size", 20)
	head.add_theme_color_override("font_color", Color(0.72, 0.50, 0.08))
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(head)

	var name_label := Label.new()
	name_label.text = "%s　%s" % [String(fish.get("name_zh", "?")), String(fish.get("name_en", ""))]
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", TITLE_COLOR)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(name_label)

	var scientific := String(fish.get("scientific", ""))
	if not scientific.is_empty():
		var sci := Label.new()
		sci.text = scientific
		sci.add_theme_font_size_override("font_size", 13)
		sci.add_theme_color_override("font_color", HINT_COLOR)
		sci.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(sci)

	var fact := Label.new()
	fact.text = "“%s”" % String(fish.get("fact_zh", ""))
	fact.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	fact.custom_minimum_size = Vector2(600, 0)
	fact.add_theme_font_size_override("font_size", 15)
	fact.add_theme_color_override("font_color", BODY_COLOR)
	vbox.add_child(fact)

	var meta := Label.new()
	var record := FishingSystem.record_of(String(_result.get("fish_id", "")))
	meta.text = "首次钓获：%s　钓点：%s　%.2f kg" % [
		String(record.get("first_caught_at", "")), String(_result.get("spot_name_zh", "")),
		float(_result.get("weight_kg", 0.0))]
	meta.add_theme_font_size_override("font_size", 13)
	meta.add_theme_color_override("font_color", HINT_COLOR)
	vbox.add_child(meta)

	var kept := Label.new()
	kept.text = "已收入生物图鉴（按 F2 查看）"
	kept.add_theme_font_size_override("font_size", 14)
	kept.add_theme_color_override("font_color", OK_COLOR)
	kept.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(kept)


## 鱼位置移动条：绿色是安全区，方块是鱼。鱼在安全区里收线最稳。
func _draw_fish_bar() -> void:
	var size := _fish_bar.size
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var track := Rect2(0.0, size.y * 0.35, size.x, size.y * 0.3)
	_fish_bar.draw_rect(track, Color(0.86, 0.82, 0.70))
	var safe := Rect2(size.x * _safe_min, track.position.y,
		size.x * (_safe_max - _safe_min), track.size.y)
	_fish_bar.draw_rect(safe, Color(0.45, 0.72, 0.38, 0.85))
	var marker_x := size.x * clampf(_fish_pos, 0.0, 1.0)
	_fish_bar.draw_rect(Rect2(marker_x - 4.0, track.position.y - 4.0, 8.0, track.size.y + 8.0),
		Color(0.85, 0.35, 0.20))


func _maybe_teach(trigger: String) -> void:
	var lesson := FishingSystem.pending_lesson(trigger)
	if not lesson.is_empty():
		teaching_requested.emit(lesson)
