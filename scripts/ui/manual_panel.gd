class_name ManualPanel
extends Control

## 游戏说明书：F1 唤出的分页说明窗口，配色与储物箱面板同色系。
## 左侧页签导航，右侧正文；ESC 或 F1 关闭，左右方向键翻页。

signal closed

const PANEL_BG := Color(0.95, 0.92, 0.84)
const PANEL_BORDER := Color(0.62, 0.47, 0.27)
const TITLE_COLOR := Color(0.36, 0.26, 0.13)
const BODY_COLOR := Color(0.42, 0.32, 0.18)
const PAGE_BTN_BG := Color(0.89, 0.85, 0.74)
const PAGE_BTN_ACTIVE := Color(0.80, 0.72, 0.55)
const CLOSE_COLOR := Color(0.85, 0.22, 0.20)

const PAGES: Array[Dictionary] = [
	{
		"title": "基础操作",
		"lines": [
			"WASD —— 移动 · 鼠标 —— 转动视角",
			"空格 —— 跳跃；快速连按两次空格可以起飞（创造模式），再按一次落地",
			"Ctrl —— 下降（飞行时）· Shift —— 冲刺，跑得更快但更容易饿",
			"Esc —— 释放或重新捕获鼠标",
			"小提示：走路掉进水里会游泳，按空格往上浮。",
		],
	},
	{
		"title": "挖掘与建造",
		"lines": [
			"左键按住 —— 破坏方块（对准生物则是攻击）",
			"右键 —— 放置当前手持方块 / 吃食物 / 打开储物箱 / 使用冶炼炉",
			"数字键 1-9 或滚轮 —— 选择快捷栏物品",
			"先选中快捷栏里的方块，再指到哪里放哪里",
			"小提示：用对工具挖得更快——镐子敲石头、斧头砍木头、铲子挖沙土。",
		],
	},
	{
		"title": "生存须知",
		"lines": [
			"头顶的爱心是生命，饿肚子时不会自动回血，先吃点东西",
			"夜晚会出没敌对生物，天黑前盖好庇护所、插好火把",
			"死亡后会在出生点复活，掉落的东西记得回去捡",
			"G —— 在生存模式和创造模式之间切换（创造可飞行、方块无限）",
			"小提示：食物可以从村庄农田采集，也可以击杀温顺动物获得。",
		],
	},
	{
		"title": "合成与熔炼",
		"lines": [
			"E —— 打开合成台，把材料凑齐后点击「合成」",
			"先合成木板，再做工具；石头工具比木头的更快更耐用",
			"冶炼炉可以把沙子烧成玻璃、把矿石炼成锭",
			"工具会用旧：快捷栏上的耐久条变短就该换新的了",
			"小提示：储物箱能帮你把多余的物资分门别类存好。",
		],
	},
	{
		"title": "村庄与交易",
		"lines": [
			"世界里散落着村庄，村民会在村口迎接你",
			"T —— 打开交易面板，用农作物和村民换好东西",
			"B —— 打开背包窗口：18 格常用区 + 9 格待售区",
			"待售区的物品点「一键售卖」就能换成绿宝石",
			"右键储物箱可以存取物品，箱子里的东西只属于你",
			"村里的农田是可靠的食物来源，收割后会长回来",
			"小提示：把基地建在村庄附近，交易和补给都方便。",
		],
	},
	{
		"title": "世界地图",
		"lines": [
			"M —— 打开 3D 地球，拖动可以让它转起来",
			"点选七大洲或四大洋，看完介绍就能进入那片区域",
			"每个区域的地形、植被、生物和天空颜色都不一样",
			"切换区域会重新生成世界，背包里的东西都会带走",
			"小提示：右上角小地图带指南针框，红色指针永远指向北方。",
		],
	},
	{
		"title": "探索的乐趣",
		"lines": [
			"这个世界有 11 片区域，试试把它们都走一遍",
			"创造模式下按两次空格起飞，从天上俯瞰大地",
			"给自己盖一座小屋，种上树、挖口井",
			"收集不同区域的方块，是完成收藏的好办法",
			"小提示：键位速查可随时按 F1 打开本说明书的第一页。",
		],
	},
]

var _open := false
var _page := 0
var _page_title: Label
var _page_body: Label
var _nav_buttons: Array[Button] = []


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

	var wrapper := Control.new()
	wrapper.custom_minimum_size = Vector2(680, 520)
	center.add_child(wrapper)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", _make_panel_style())
	wrapper.add_child(panel)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 14)
	panel.add_child(columns)

	var nav := VBoxContainer.new()
	nav.custom_minimum_size = Vector2(150, 0)
	nav.add_theme_constant_override("separation", 6)
	columns.add_child(nav)

	for i in PAGES.size():
		var btn := Button.new()
		btn.text = String(PAGES[i]["title"])
		btn.focus_mode = Control.FOCUS_NONE
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.custom_minimum_size = Vector2(150, 40)
		btn.add_theme_font_size_override("font_size", 17)
		btn.add_theme_color_override("font_color", TITLE_COLOR)
		btn.add_theme_color_override("font_hover_color", Color(0.20, 0.14, 0.06))
		btn.add_theme_color_override("font_pressed_color", TITLE_COLOR)
		var style := _make_btn_style(PAGE_BTN_BG)
		btn.add_theme_stylebox_override("normal", style)
		btn.add_theme_stylebox_override("hover", _make_btn_style(PAGE_BTN_BG.lightened(0.06)))
		btn.add_theme_stylebox_override("pressed", style)
		var idx := i
		btn.pressed.connect(func(): select_page(idx))
		nav.add_child(btn)
		_nav_buttons.append(btn)

	var content := VBoxContainer.new()
	content.custom_minimum_size = Vector2(440, 0)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	columns.add_child(content)

	_page_title = Label.new()
	_page_title.add_theme_font_size_override("font_size", 24)
	_page_title.add_theme_color_override("font_color", TITLE_COLOR)
	content.add_child(_page_title)

	var rule := HSeparator.new()
	content.add_child(rule)

	_page_body = Label.new()
	_page_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_page_body.custom_minimum_size = Vector2(440, 0)
	_page_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_page_body.add_theme_font_size_override("font_size", 18)
	_page_body.add_theme_constant_override("line_spacing", 8)
	_page_body.add_theme_color_override("font_color", BODY_COLOR)
	content.add_child(_page_body)

	var footer := Label.new()
	footer.text = "左右方向键翻页 · Esc 或 F1 关闭"
	footer.add_theme_font_size_override("font_size", 14)
	footer.add_theme_color_override("font_color", Color(BODY_COLOR, 0.7))
	content.add_child(footer)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.add_theme_color_override("font_color", CLOSE_COLOR)
	close_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.35, 0.32))
	close_btn.add_theme_color_override("font_pressed_color", Color(0.70, 0.15, 0.14))
	close_btn.add_theme_font_size_override("font_size", 22)
	close_btn.pressed.connect(close)
	wrapper.add_child(close_btn)
	close_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	close_btn.position = Vector2(680 - 52, 10)

	select_page(0)


func open() -> void:
	_open = true
	visible = true


func close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	closed.emit()


func is_open() -> bool:
	return _open


func get_page() -> int:
	return _page


func select_page(index: int) -> void:
	_page = clampi(index, 0, PAGES.size() - 1)
	var data: Dictionary = PAGES[_page]
	_page_title.text = String(data["title"])
	_page_body.text = "\n".join(PackedStringArray(data["lines"]))
	for i in _nav_buttons.size():
		var style := _make_btn_style(PAGE_BTN_ACTIVE if i == _page else PAGE_BTN_BG)
		_nav_buttons[i].add_theme_stylebox_override("normal", style)
		_nav_buttons[i].add_theme_stylebox_override("pressed", style)


func _unhandled_key_input(event: InputEvent) -> void:
	if not _open:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_LEFT:
			select_page(_page - 1)
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_RIGHT:
			select_page(_page + 1)
			get_viewport().set_input_as_handled()


## 面板样式与储物箱完全一致：淡米底、黄铜棕描边。
func _make_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(16)
	return style


func _make_btn_style(bg: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = PANEL_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(6)
	return style
