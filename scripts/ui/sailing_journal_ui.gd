extends Control
## 我的航海记录（D-089 阶段 2）：累计出海里程 + 最远离港距离 + 三档分带到访 +
## 里程碑徽章。定名「我的航海记录」而非「航海日志」——J 键 Journal 已占用
## 「我的冒险记录」语义（decisions.md:158），避免混淆。
##
## 不引入 class_name（坑 #24）：由 HUD 以 preload 实例化（同 profile_picker.gd /
## fishing_collection_ui.gd），全代码现场搭节点，不配 .tscn。
##
## 现取约束（D-086 §2 / D-089 裁决）：_load_journal() 会整体替换 journal，
## 任何缓存的 journal / sail 子字典 / sail_state() 返回引用都会在换槽瞬间
## 静默失效。故本 UI 成员只持控件引用与静态常量；唯一刷新入口是
## open()/refresh()，每次打开按当前槽现取，不连 slot_changed 自刷新。

signal closed

const PANEL_BG: Color = Color(0.95, 0.92, 0.84)
const PANEL_BORDER: Color = Color(0.62, 0.47, 0.27)
const TITLE_COLOR: Color = Color(0.36, 0.26, 0.13)
const BODY_COLOR: Color = Color(0.42, 0.32, 0.18)
const OK_COLOR: Color = Color(0.30, 0.55, 0.15)
const CARD_BG: Color = Color(1.0, 1.0, 1.0, 0.55)

## 与 BoatSystem.SAIL_BADGES / SAIL_BADGE_TARGETS 对齐，UI 侧各管一处展示。
const BADGE_KEYS: Array[String] = ["sail_100", "sail_500", "sail_1000"]
const BADGE_TITLES: Dictionary = {
	"sail_100": "初次远航", "sail_500": "近海熟客", "sail_1000": "远洋探险家",
}
const BADGE_TARGETS: Dictionary = {
	"sail_100": 100.0, "sail_500": 500.0, "sail_1000": 1000.0,
}
const BAND_KEYS: Array[String] = ["near", "mid", "far"]
const BAND_TITLES: Dictionary = {
	"near": "近海", "mid": "中海", "far": "远海",
}

## 只持控件引用，绝不持有玩家态容器。
var _title: Label
var _badge: Label
var _total_label: Label
var _farthest_label: Label
var _band_labels: Dictionary = {}
var _badge_rows: Dictionary = {}
var _claim_buttons: Dictionary = {}


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
	refresh()


## 唯一刷新入口：每次调用都当场调 BoatSystem 的 API 读标量 / 拷贝。
func refresh() -> void:
	_refresh()


## 幂等（照 profile_picker.gd:98-102）：已关闭时不再 emit closed，
## 避免 HUD 的 closed 回调重复解冻 / 重复收鼠标。
func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


# ────────────────────────── 构建（一次性，纯控件） ──────────────────────────

func _build() -> void:
	var dim: ColorRect = ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.05, 0.10, 0.60)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	# CenterContainer + 相对锚点 + 单个 ScrollContainer，照顾
	# canvas_items + aspect=expand（逻辑视口高恒 720、20:9 宽 1600）。
	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(720, 0)
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var header: HBoxContainer = HBoxContainer.new()
	vbox.add_child(header)
	_title = Label.new()
	_title.text = "⛵ 我的航海记录"
	_title.add_theme_font_size_override("font_size", 19)
	_title.add_theme_color_override("font_color", TITLE_COLOR)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)

	_badge = Label.new()
	_badge.add_theme_font_size_override("font_size", 16)
	_badge.add_theme_color_override("font_color", OK_COLOR)
	header.add_child(_badge)

	# make_close() 默认热区约 38×26，触屏必达 44×44，必须显式设。
	var close_btn: Button = UiKit.make_close(24)
	close_btn.custom_minimum_size = Vector2(44, 44)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	# 单个 ScrollContainer（禁止嵌套：触屏抢手势，与探索课堂 / 收集册同红线）。
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(700, 420)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	var body: VBoxContainer = VBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)

	_build_mileage(body)
	_build_bands(body)
	_build_badges(body)


func _card() -> PanelContainer:
	var card: PanelContainer = PanelContainer.new()
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = CARD_BG
	style.set_corner_radius_all(8)
	style.set_content_margin_all(10)
	card.add_theme_stylebox_override("panel", style)
	return card


func _body_label(text: String, font_size: int) -> Label:
	var lab: Label = Label.new()
	lab.text = text
	lab.add_theme_font_size_override("font_size", font_size)
	lab.add_theme_color_override("font_color", BODY_COLOR)
	return lab


func _build_mileage(parent: VBoxContainer) -> void:
	var card: PanelContainer = _card()
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	card.add_child(box)
	parent.add_child(card)

	_total_label = _body_label("累计出海：0.0 m", 18)
	box.add_child(_total_label)
	_farthest_label = _body_label("最远离港：0.0 m", 16)
	box.add_child(_farthest_label)
	var hint: Label = _body_label("每划一小段都会记下来，慢慢来，海很大。", 14)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hint)


func _build_bands(parent: VBoxContainer) -> void:
	var card: PanelContainer = _card()
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	card.add_child(box)
	parent.add_child(card)
	box.add_child(_body_label("去过的海面", 17))
	for key: String in BAND_KEYS:
		var lab: Label = _body_label("%s：还没去过" % String(BAND_TITLES.get(key, key)), 15)
		box.add_child(lab)
		_band_labels[key] = lab


func _build_badges(parent: VBoxContainer) -> void:
	var card: PanelContainer = _card()
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	card.add_child(box)
	parent.add_child(card)
	box.add_child(_body_label("里程碑徽章", 17))
	for key: String in BADGE_KEYS:
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		box.add_child(row)
		var lab: Label = _body_label("", 15)
		lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(lab)
		_badge_rows[key] = lab
		var btn: Button = Button.new()
		btn.custom_minimum_size = Vector2(140, 44)
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(func() -> void: _on_claim_pressed(key))
		row.add_child(btn)
		_claim_buttons[key] = btn


# ────────────────────────── 现取渲染 ──────────────────────────

func _refresh() -> void:
	# 每次现取：sail_state() 返回拷贝，badge_of() 返回标量，绝不缓存引用。
	var state: Dictionary = BoatSystem.sail_state()
	var total: float = float(state.get("total_m", 0.0))
	var farthest: float = float(state.get("farthest_m", 0.0))
	_total_label.text = "累计出海：%.1f m" % total
	_farthest_label.text = "最远离港：%.1f m" % farthest
	var bands: Dictionary = state["bands"]
	for key: String in BAND_KEYS:
		var lab: Label = _band_labels[key]
		# 数据层 bands 是「有位移的采样拍数」（boat_system.gd:392-396），长航程会到
		# 几千；儿童向 UI 只呈现「到过 / 没到过」，避免把拍数误读成到访次数。
		var visited: String = "已去过 ✓" if int(bands.get(key, 0)) > 0 else "还没去过"
		lab.text = "%s：%s" % [String(BAND_TITLES.get(key, key)), visited]
	var earned: int = 0
	for badge_key: String in BADGE_KEYS:
		var claimed: bool = BoatSystem.badge_of(badge_key) > 0
		if claimed:
			earned += 1
		var row: Label = _badge_rows[badge_key]
		row.text = "%s · 累计 %.0f m" % [
			String(BADGE_TITLES.get(badge_key, badge_key)),
			float(BADGE_TARGETS.get(badge_key, 0.0))]
		_apply_claim(badge_key, total, claimed)
	_badge.text = "徽章 %d / %d" % [earned, BADGE_KEYS.size()]


## 儿童向温和文案：未达标说「还差 N m，慢慢来」，不承诺永久拥有物品、
## 无失败 / 惩罚 / QTE。
func _apply_claim(key: String, total: float, claimed: bool) -> void:
	var btn: Button = _claim_buttons[key]
	var target: float = float(BADGE_TARGETS.get(key, 0.0))
	if claimed:
		btn.disabled = true
		btn.text = "已点亮 ✓"
		return
	if total < target:
		btn.disabled = true
		btn.text = "还差 %d m，慢慢来" % int(ceilf(target - total))
		return
	btn.disabled = false
	btn.text = "◆ 点亮徽章"


func _on_claim_pressed(key: String) -> void:
	if not BoatSystem.claim_badge(key):
		return
	_refresh()


# ────────────────────────── 只读查询（供探针断言，读的是已渲染控件值） ──────────────────────────

func title_text() -> String:
	return _title.text


func total_text() -> String:
	return _total_label.text


func farthest_text() -> String:
	return _farthest_label.text


func badge_text() -> String:
	return _badge.text


func band_text(key: String) -> String:
	if not _band_labels.has(key):
		return ""
	return (_band_labels[key] as Label).text


func claim_state(key: String) -> Dictionary:
	if not _claim_buttons.has(key):
		return {}
	var btn: Button = _claim_buttons[key] as Button
	return {"disabled": btn.disabled, "text": btn.text}


func row_count() -> int:
	return BADGE_KEYS.size()
