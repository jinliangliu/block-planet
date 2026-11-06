class_name FishingGearUI
extends Control
## 钓具选择界面：进入某大洋钓点前整备装备（海竿 / 渔轮 / 鱼线 / 鱼饵 / 铅坠）。
##
## 从地图选择器四大洋的「🎣 去钓鱼」按钮打开，选完点「开始钓鱼」交给
## FishingSystem.start_fishing()，随后由 FishingUI 接管四个操作阶段。
##
## 拥有状态来自 FishingSystem 的日志（user://fishing_journal.json），
## 不是生存背包的 36 格——钓具是成套的装备库，塞进背包会被方块挤掉，
## 也会让「出发前整备」变成翻格子。任务奖励解锁的新钓具同样记在日志里。

signal closed
## 装备整备完成，请求打开渔猎界面。
signal start_requested
## 请求打开鱼类收集册（D-087）。HUD 收到后先关钓具、再开收集册（不叠加模态）。
signal collection_requested

const PANEL_BG := Color(0.97, 0.95, 0.88)
const PANEL_BORDER := Color(0.62, 0.47, 0.27)
const TITLE_COLOR := Color(0.32, 0.24, 0.10)
const BODY_COLOR := Color(0.40, 0.31, 0.16)
const HINT_COLOR := Color(0.55, 0.46, 0.30)
const OK_COLOR := Color(0.24, 0.50, 0.18)
const BAD_COLOR := Color(0.70, 0.25, 0.18)
const ON_BG := Color(0.42, 0.66, 0.36)
const OFF_BG := Color(0.88, 0.84, 0.74)

var _atlas_region := -1
var _spot_id := ""
var _selected: Dictionary = {}
## 出海模式（D-042）：在船上开钓，钓点由距港距离决定，不给自由选点。
var _boat_mode := false
var _distance_m := 0.0
var _spot_row: HBoxContainer
var _gear_rows: Dictionary = {}
var _hint: Label
var _detail: Label
var _start_button: Button
## 鱼类收集册入口（D-087）：不带完成度徽标的纯按钮，文字在 _refresh() 现取刷新。
var _collection_button: Button


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 30
	_build()


func _build() -> void:
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.05, 0.10, 0.6)
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
	vbox.custom_minimum_size = Vector2(760, 0)
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "整理钓具"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var spot_title := Label.new()
	spot_title.text = "钓点"
	spot_title.add_theme_font_size_override("font_size", 15)
	spot_title.add_theme_color_override("font_color", HINT_COLOR)
	vbox.add_child(spot_title)

	_spot_row = HBoxContainer.new()
	_spot_row.add_theme_constant_override("separation", 8)
	vbox.add_child(_spot_row)

	for kind: String in FishingGear.KINDS:
		var kind_title := Label.new()
		kind_title.text = String(FishingGear.KIND_TITLES.get(kind, kind))
		kind_title.add_theme_font_size_override("font_size", 15)
		kind_title.add_theme_color_override("font_color", HINT_COLOR)
		vbox.add_child(kind_title)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		vbox.add_child(row)
		_gear_rows[kind] = row

	_detail = Label.new()
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.custom_minimum_size = Vector2(720, 0)
	_detail.add_theme_font_size_override("font_size", 14)
	_detail.add_theme_color_override("font_color", BODY_COLOR)
	vbox.add_child(_detail)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size = Vector2(720, 0)
	_hint.add_theme_font_size_override("font_size", 14)
	vbox.add_child(_hint)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	var replay := Button.new()
	replay.text = "重看教学"
	replay.custom_minimum_size = Vector2(120, 42)
	replay.focus_mode = Control.FOCUS_NONE
	replay.pressed.connect(_on_replay_teaching)
	row.add_child(replay)

	_start_button = Button.new()
	_start_button.text = "开始钓鱼"
	_start_button.custom_minimum_size = Vector2(140, 42)
	_start_button.focus_mode = Control.FOCUS_NONE
	_start_button.pressed.connect(_on_start)
	row.add_child(_start_button)

	# 鱼类收集册入口（D-087）：独立可点 Button，不塞进 _refresh_hint() 的纯文本里。
	# 触摸热区 ≥44px（同排按钮 42px 是历史值，新入口按裁决 6 取 44）。
	_collection_button = Button.new()
	_collection_button.custom_minimum_size = Vector2(0, 44)
	_collection_button.focus_mode = Control.FOCUS_NONE
	_collection_button.pressed.connect(func() -> void: collection_requested.emit())
	row.add_child(_collection_button)

	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(100, 42)
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func(): _close())
	row.add_child(close)


## 打开某个世界区域（RegionAtlas 区域号）的钓具界面（岸边垂钓：
## 只列 unlock=default 的岸钓点；出海钓点不在此列，见 open_for_boat）。
func open_for_atlas(atlas_region: int) -> void:
	_atlas_region = atlas_region
	_boat_mode = false
	var spots := FishingSystem.get_shore_spots_for_atlas(atlas_region)
	if spots.is_empty():
		_close()
		return
	_spot_id = String((spots[0] as Dictionary).get("id", ""))
	_selected = {}
	for kind: String in FishingGear.KINDS:
		var owned := FishingSystem.owned_items(kind)
		if not owned.is_empty():
			_selected[kind] = String((owned[0] as Dictionary).get("id", ""))
		else:
			_selected[kind] = ""
	visible = true
	_refresh()


## 打开出海钓具界面（D-042）：在船上按距港距离定位唯一钓点。
## 三个分带按钮全部列出，但只有当前距离够得着的能选——其余置灰并标注
## 距离要求，把「开得越远鱼种越多」直接做进界面。
func open_for_boat(atlas_region: int, distance_m: float) -> void:
	_atlas_region = atlas_region
	_boat_mode = true
	_distance_m = distance_m
	_spot_id = BoatSystem.spot_for_distance(atlas_region, distance_m)
	if FishingSystem.get_spot(_spot_id).is_empty():
		_close()
		return
	_selected = {}
	for kind: String in FishingGear.KINDS:
		var owned := FishingSystem.owned_items(kind)
		if not owned.is_empty():
			_selected[kind] = String((owned[0] as Dictionary).get("id", ""))
		else:
			_selected[kind] = ""
	visible = true
	_refresh()


func is_open() -> bool:
	return visible


func close() -> void:
	visible = false


func _close() -> void:
	visible = false
	closed.emit()


func _on_replay_teaching() -> void:
	var lesson := FishingSystem.reset_lessons()
	if not lesson.is_empty():
		Events.notice.emit("钓鱼教学已重置，进入渔猎界面时会重新讲解")


func _on_start() -> void:
	var gear_set := {
		"rod": String(_selected.get("rods", "")),
		"reel": String(_selected.get("reels", "")),
		"line": String(_selected.get("lines", "")),
	}
	if not FishingSystem.start_fishing(_spot_id, gear_set):
		Events.notice.emit("钓具没配好，先补齐海竿、渔轮和鱼线")
		return
	# 鱼饵与铅坠也预选好：渔猎界面第一阶段仍可改（那一阶段本来就是「鱼饵搭配」），
	# 这里只是让玩家不必重复点一遍。
	var bait_id := String(_selected.get("baits", ""))
	if not bait_id.is_empty():
		FishingSystem.select_bait(bait_id)
	var sinker_id := String(_selected.get("sinkers", ""))
	if not sinker_id.is_empty():
		FishingSystem.select_sinker(sinker_id)
	visible = false
	start_requested.emit()


func _refresh() -> void:
	_rebuild_spot_row()
	for kind: String in FishingGear.KINDS:
		_rebuild_gear_row(kind)
	_refresh_hint()
	_refresh_collection_button()


## 完成度徽标每次打开钓具界面都现取（discovered_count 是标量，不缓存容器）。
func _refresh_collection_button() -> void:
	_collection_button.text = "◆ 鱼类收集册 %d / %d" % [
		FishingSystem.discovered_count(), FishingSystem.fish_list.size()]


func _rebuild_spot_row() -> void:
	for child in _spot_row.get_children():
		child.queue_free()
	if _boat_mode:
		_rebuild_boat_spot_row()
		return
	for spot_value: Variant in FishingSystem.get_shore_spots_for_atlas(_atlas_region):
		var spot: Dictionary = spot_value
		var spot_id := String(spot.get("id", ""))
		var btn := Button.new()
		btn.text = "🎣 " + String(spot.get("name_zh", spot_id))
		btn.custom_minimum_size = Vector2(240, 38)
		btn.focus_mode = Control.FOCUS_NONE
		btn.toggle_mode = true
		btn.button_pressed = spot_id == _spot_id
		btn.pressed.connect(func(): _spot_id = spot_id; _refresh())
		_spot_row.add_child(btn)


## 出海模式选点行：近/中/远三个渔场，按当前距离只有一格可点。
## 置灰的按钮 tooltip 写明距离要求——儿童玩家也看得懂「再开远点」。
func _rebuild_boat_spot_row() -> void:
	var current_band := BoatSystem.band_of(_distance_m)
	var band_order := ["near", "mid", "far"]
	var dist_need := {"near": 0.0, "mid": BoatSystem.NEAR_MAX_M, "far": BoatSystem.MID_MAX_M}
	for band: String in band_order:
		var spot_id := BoatSystem.spot_id_for(_atlas_region, band)
		var reachable: bool = band == current_band
		var btn := Button.new()
		btn.text = "⛵ %s" % BoatSystem.band_title(band)
		if reachable:
			btn.text += "（当前 %.0f m）" % _distance_m
		btn.custom_minimum_size = Vector2(240, 38)
		btn.focus_mode = Control.FOCUS_NONE
		btn.toggle_mode = true
		btn.button_pressed = reachable
		btn.disabled = not reachable
		if reachable:
			btn.pressed.connect(func(): _spot_id = spot_id; _refresh())
		else:
			var need := float(dist_need.get(band, 0.0))
			if band == "near":
				btn.tooltip_text = "太远了就会错过近海鱼群——开回 %.0f m 以内" % need
			else:
				btn.tooltip_text = "再往外海开 %.0f m 才能解锁" % maxf(0.0, need - _distance_m)
		_spot_row.add_child(btn)


func _rebuild_gear_row(kind: String) -> void:
	var row: HBoxContainer = _gear_rows[kind]
	for child in row.get_children():
		child.queue_free()
	for item_value: Variant in FishingSystem.gear.items_of(kind):
		var item: Dictionary = item_value
		var item_id := String(item.get("id", ""))
		var owned := FishingSystem.owns(item_id)
		var btn := Button.new()
		btn.text = _item_text(kind, item)
		btn.custom_minimum_size = Vector2(180, 36)
		btn.focus_mode = Control.FOCUS_NONE
		btn.toggle_mode = true
		btn.button_pressed = String(_selected.get(kind, "")) == item_id
		btn.disabled = not owned
		if owned:
			btn.pressed.connect(func(): _selected[kind] = item_id; _refresh())
		else:
			btn.text += "（未解锁）"
			btn.tooltip_text = _unlock_text(item)
		_apply_toggle_style(btn)
		row.add_child(btn)


func _item_text(kind: String, item: Dictionary) -> String:
	var name_zh := String(item.get("name_zh", "?"))
	match kind:
		"rods":
			return "%s（强度%d·最大%d号线）" % [
				name_zh, int(item.get("strength", 0)), int(item.get("max_line", 0))]
		"reels":
			return "%s（卸力%d·收线%d）" % [
				name_zh, int(item.get("drag_max", 0)), int(item.get("speed", 0))]
		"lines":
			return "%s（拉力%d）" % [name_zh, int(item.get("strength", 0))]
		"sinkers":
			return "%s（%d g）" % [name_zh, int(item.get("weight", 0))]
	return name_zh


func _unlock_text(item: Dictionary) -> String:
	var quest_id := FishingSystem.gear.quest_of(item)
	if quest_id.is_empty():
		return "尚未解锁"
	var entry := QuestData.entry_by_id(quest_id)
	if entry.is_empty():
		return "完成任务后解锁：" + quest_id
	return "领取任务「%s」后解锁" % String(entry.get("title", quest_id))


func _apply_toggle_style(btn: Button) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = ON_BG if btn.button_pressed else OFF_BG
	style.set_corner_radius_all(6)
	style.set_content_margin_all(4)
	btn.add_theme_stylebox_override("normal", style)


func _refresh_hint() -> void:
	var spot := FishingSystem.get_spot(_spot_id)
	var lines := PackedStringArray()
	lines.append("钓点：%s —— %s" % [
		String(spot.get("name_zh", "?")), String(spot.get("intro_zh", ""))])
	if _boat_mode:
		lines.append("出海距离 %.0f m · %s：近海 %.0f m 内 / 中海到 %.0f m / 更远是远海——鱼种随距离换" % [
			_distance_m, BoatSystem.band_title(BoatSystem.band_of(_distance_m)),
			BoatSystem.NEAR_MAX_M, BoatSystem.MID_MAX_M])
	var sinker_id := String(_selected.get("sinkers", ""))
	if not sinker_id.is_empty():
		var sinker := FishingSystem.gear.sinker(sinker_id)
		var near := FishingGear.cast_distance(sinker, 0.0)
		var far := FishingGear.cast_distance(sinker, 1.0)
		lines.append("这颗铅坠能抛 %.0f~%.0f 米：轻抛到 %s，满力到 %s" % [
			near, far, FishingGear.band_title(FishingGear.band_of(near)),
			FishingGear.band_title(FishingGear.band_of(far))])
	var issues := FishingSystem.gear.validate({
		"rod": String(_selected.get("rods", "")),
		"reel": String(_selected.get("reels", "")),
		"line": String(_selected.get("lines", "")),
	})
	if issues.is_empty():
		_hint.text = "装备齐了，可以出发。"
		_hint.add_theme_color_override("font_color", OK_COLOR)
		_start_button.disabled = false
	else:
		_hint.text = String(issues[0])
		_hint.add_theme_color_override("font_color", BAD_COLOR)
		_start_button.disabled = true
	_detail.text = "\n".join(lines)
