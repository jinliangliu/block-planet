extends Control
## 鱼类收集册（D-087）：按四大洋分组展示 20 种鱼的钓获记录，集齐海域可领奖。
##
## 不引入 class_name（避免 global_script_class_cache 失配导致无头解析失败，见踩坑 #24），
## 由 HUD 以 preload 方式实例化（同 profile_picker.gd）。全代码现场搭节点，不配 .tscn。
##
## 现取约束（D-086 起是运行时硬要求，不是防御性假设）：_load_journal() 里的
## journal = {...} 会整体替换 Dictionary，任何缓存过 journal / journal["records"] /
## record_of() 子字典的旧引用都会在换槽瞬间失效且不报错。因此本 UI 成员只持有
## 控件引用（_cells / _group_titles / _claim_buttons / _badge）与纯静态常量，
## 绝不持有玩家态容器；所有展示数据在 _refresh() 里当场调 FishingSystem 的 API、
## 当场读标量。唯一刷新入口是 open()/refresh()（每次打开按当前槽现取），
## 不连 slot_changed 自己刷新、不挂 Progress 的 refresh 链。

signal closed
## 领取集齐奖励：把 FishingSystem.claim_bundle() 的 reward 交给 HUD 发绿宝石 + Toast。
## UI 不直接碰背包（照 hud.gd:_on_quest_claimed 的分工）。
signal reward_claimed(reward: Dictionary)

## 海域顺序与中文名用 UI 常量，不复用 RegionAtlas 的 int 键（裁决 5）。
## 取值与 FishingSystem.BUNDLE_TITLES 一致，两处各管一处（数据 / 展示）。
const REGION_ORDER: Array[String] = [
	"pacific_ocean", "atlantic_ocean", "indian_ocean", "arctic_ocean",
]
const REGION_TITLES := {
	"pacific_ocean": "太平洋",
	"atlantic_ocean": "大西洋",
	"indian_ocean": "印度洋",
	"arctic_ocean": "北冰洋",
	"all": "四大洋",
}

## 控件引用（不是玩家态数据容器，允许跨 open() 生命周期持有）。
var _cells: Dictionary = {}            # fish_id -> Label
var _group_titles: Dictionary = {}     # region_id -> Label
var _claim_buttons: Dictionary = {}    # region_id / "all" -> Button
var _badge: Label
var _all_hint: Label


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 30
	_build()


func is_open() -> bool:
	return visible


func open() -> void:
	visible = true
	refresh()   # 唯一刷新入口：每次打开都按当前槽现取 journal


## 供「不关闭界面」的换槽 / 领奖场景显式刷新（探针断言 11 也走这里）。
func refresh() -> void:
	_refresh()


func close() -> void:
	visible = false
	closed.emit()


# ────────────────────────── 构建（一次性，纯控件） ──────────────────────────

func _build() -> void:
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.05, 0.10, 0.60)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = FishingGearUI.PANEL_BG
	style.border_color = FishingGearUI.PANEL_BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(720, 0)
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	# 标题行：标题 + 完成度徽标 + ✕（触屏必达 44×44；make_close 只造字形，
	# 需显式设 min size 与字号，见 ui_kit.gd:28-38、tab-lessons 补充 ③）。
	var header := HBoxContainer.new()
	vbox.add_child(header)
	var title := Label.new()
	title.text = "◆ 鱼类收集册"
	title.add_theme_font_size_override("font_size", 19)
	title.add_theme_color_override("font_color", FishingGearUI.TITLE_COLOR)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	_badge = Label.new()
	_badge.add_theme_font_size_override("font_size", 16)
	_badge.add_theme_color_override("font_color", FishingGearUI.OK_COLOR)
	header.add_child(_badge)

	var close_btn := UiKit.make_close(24)
	close_btn.custom_minimum_size = Vector2(44, 44)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	# 单个 ScrollContainer（禁止嵌套：触屏抢手势，与探索课堂页同一条红线）。
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(700, 420)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	var groups := VBoxContainer.new()
	groups.add_theme_constant_override("separation", 14)
	scroll.add_child(groups)

	for region_id: String in REGION_ORDER:
		_build_group(groups, region_id)
	_build_all_group(groups)


func _build_group(parent: VBoxContainer, region_id: String) -> void:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 6)
	parent.add_child(group)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	group.add_child(head)

	var title := Label.new()
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", FishingGearUI.TITLE_COLOR)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_group_titles[region_id] = title

	var claim := Button.new()
	claim.custom_minimum_size = Vector2(0, 44)
	claim.focus_mode = Control.FOCUS_NONE
	claim.pressed.connect(func() -> void: _on_claim_pressed(region_id))
	head.add_child(claim)
	_claim_buttons[region_id] = claim

	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	group.add_child(grid)

	for id: String in FishingSystem.bundle_ids(region_id):
		var cell := _make_cell()
		grid.add_child(cell)
		_cells[id] = cell


func _make_cell() -> Label:
	var cell := Label.new()
	cell.custom_minimum_size = Vector2(124, 72)
	cell.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cell.add_theme_font_size_override("font_size", 13)
	cell.add_theme_color_override("font_color", FishingGearUI.BODY_COLOR)
	var cell_style := StyleBoxFlat.new()
	cell_style.bg_color = Color(1.0, 1.0, 1.0, 0.55)
	cell_style.set_corner_radius_all(8)
	cell_style.set_content_margin_all(6)
	cell.add_theme_stylebox_override("normal", cell_style)
	return cell


func _build_all_group(parent: VBoxContainer) -> void:
	var group := HBoxContainer.new()
	group.add_theme_constant_override("separation", 10)
	parent.add_child(group)

	_all_hint = Label.new()
	_all_hint.text = "集齐四大洋，解锁「四大洋收藏家」称号"
	_all_hint.add_theme_font_size_override("font_size", 15)
	_all_hint.add_theme_color_override("font_color", FishingGearUI.BODY_COLOR)
	_all_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_all_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	group.add_child(_all_hint)

	var claim := Button.new()
	claim.custom_minimum_size = Vector2(0, 44)
	claim.focus_mode = Control.FOCUS_NONE
	claim.pressed.connect(func() -> void: _on_claim_pressed("all"))
	group.add_child(claim)
	_claim_buttons["all"] = claim


# ────────────────────────── 现取渲染 ──────────────────────────
## 每次调用都当场调 API 读标量；不缓存 journal / 子字典 / record_of() 返回引用。

func _refresh() -> void:
	for region_id: String in REGION_ORDER:
		var ids := FishingSystem.bundle_ids(region_id)
		var owned := 0
		for id: String in ids:
			var n := FishingSystem.catch_count(id)
			if n > 0:
				owned += 1
			_apply_cell(id, region_id, n)
		var title: Label = _group_titles[region_id]
		title.text = "%s %d / %d" % [
			String(REGION_TITLES.get(region_id, region_id)), owned, ids.size()]
		_apply_claim(region_id, FishingSystem.bundle_complete(region_id),
			FishingSystem.bundle_claimed(region_id))
	_apply_claim("all", FishingSystem.all_bundles_complete(),
		FishingSystem.bundle_claimed("all"))
	_badge.text = "%d / %d" % [
		FishingSystem.discovered_count(), FishingSystem.fish_list.size()]


func _apply_cell(id: String, region_id: String, n: int) -> void:
	var cell := _cells[id] as Label
	var fish := FishingSystem.get_fish(id)
	var name_zh := String(fish.get("name_zh", id))
	# 海域前缀：pacific_clownfish 与 clownfish 中文名 / 学名全同，靠前缀区分（§2.1③）。
	var prefix := String(REGION_TITLES.get(region_id, ""))
	if n <= 0:
		cell.text = "%s·%s\n？ 还没见过这条鱼" % [prefix, name_zh]
		cell.modulate = Color(0.60, 0.60, 0.60, 1.0)
		return
	cell.modulate = Color(1, 1, 1, 1)
	var r := FishingSystem.record_of(id)   # 局部引用，函数结束即释放，绝不缓存
	var best := float(r.get("max_weight_kg", 0.0))
	var spot_id := String(r.get("first_caught_spot", ""))
	var spot_zh := String(FishingSystem.get_spot(spot_id).get("name_zh", spot_id))
	cell.text = "%s·%s\n%d 次 · 最大 %.2f kg\n首次：%s" % [
		prefix, name_zh, n, best, spot_zh]


## 儿童向温和文案：未集齐说「还差 N 种，慢慢来」，不用「失败 / 未完成 / 错过」。
func _apply_claim(region_id: String, complete: bool, claimed: bool) -> void:
	var btn := _claim_buttons[region_id] as Button
	btn.disabled = not complete or claimed
	if claimed:
		btn.text = "已领取 ✓"
	elif complete:
		btn.text = "◆ 领取奖励"
	else:
		var missing := 0
		if region_id == "all":
			for reg: String in REGION_ORDER:
				if not FishingSystem.bundle_complete(reg):
					missing += 1
			btn.text = "还差 %d 个海域，慢慢来" % missing
		else:
			for id: String in FishingSystem.bundle_ids(region_id):
				if FishingSystem.catch_count(id) <= 0:
					missing += 1
			btn.text = "还差 %d 种，慢慢来" % missing


func _on_claim_pressed(region_id: String) -> void:
	var reward := FishingSystem.claim_bundle(region_id)
	if reward.is_empty():
		return
	reward_claimed.emit(reward)
	_refresh()   # 按钮立刻变「已领取 ✓」，状态取自刚落盘的 stats


# ────────────────────────── 只读查询（供探针断言，读的是已渲染控件值） ──────────────────────────

func badge_text() -> String:
	return _badge.text


func cell_text(fish_id: String) -> String:
	if not _cells.has(fish_id):
		return ""
	return (_cells[fish_id] as Label).text


func cell_dimmed(fish_id: String) -> bool:
	if not _cells.has(fish_id):
		return false
	return (_cells[fish_id] as Label).modulate.r < 1.0


func claim_state(region_id: String) -> Dictionary:
	if not _claim_buttons.has(region_id):
		return {}
	var btn := _claim_buttons[region_id] as Button
	return {"disabled": btn.disabled, "text": btn.text}


func cell_count() -> int:
	return _cells.size()
