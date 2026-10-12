class_name ManualPanel
extends Control

## 游戏说明书：F1 唤出的分页说明窗口，配色与储物箱面板同色系。
## 左侧页签导航（文字居中），右侧正文；底部为状态栏，随页显示该页 Tips；
## ESC 或 F1 关闭，左右方向键翻页。

signal closed

const PANEL_BG := Color(0.95, 0.92, 0.84)
const PANEL_BORDER := Color(0.62, 0.47, 0.27)
const TITLE_COLOR := Color(0.36, 0.26, 0.13)
const BODY_COLOR := Color(0.42, 0.32, 0.18)
const PAGE_BTN_BG := Color(0.89, 0.85, 0.74)
const PAGE_BTN_ACTIVE := Color(0.80, 0.72, 0.55)

const PAGES: Array[Dictionary] = [
	{
		"title": "基础操作",
		"lines": [
			"WASD —— 移动 · 鼠标 —— 转动视角",
			"空格 —— 跳跃；快速连按两次空格可以起飞（创造与探索模式），再按一次落地",
			"Ctrl —— 下降（飞行时）· Shift —— 冲刺，跑得更快但更容易饿",
			"F1 —— 打开游戏说明书（就是本页）· F2 —— 打开生物图鉴",
			"Esc —— 释放或重新捕获鼠标",
		],
		"tip": "走路掉进水里会游泳，按空格往上浮。",
	},
	{
		"title": "挖掘与建造",
		"lines": [
			"左键按住 —— 破坏方块（对准生物则是攻击）",
			"右键 —— 放置当前手持方块 / 吃食物 / 打开储物箱 / 使用冶炼炉",
			"数字键 1-9 或滚轮 —— 选择快捷栏物品",
			"先选中快捷栏里的方块，再指到哪里放哪里",
		],
		"tip": "用对工具挖得更快——镐子敲石头、斧头砍木头、铲子挖沙土、镰刀收作物。",
	},
	{
		"title": "生存须知",
		"lines": [
			"头顶的爱心是生命，饿肚子时不会自动回血，先吃点东西",
			"夜晚会出没敌对生物，天黑前盖好庇护所、插好火把",
			"死亡后会在出生点复活，掉落的东西记得回去捡",
			"G —— 在生存模式和创造模式之间一键切换（创造可飞行、方块无限）",
			"探索模式在地图页里选择：生存规则照旧，但没有夜间敌对生物，还能飞行，开局送一架飞机",
		],
		"tip": "食物可以从村庄农田采集，也可以击杀温顺动物获得。",
	},
	{
		"title": "合成与熔炼",
		"lines": [
			"E —— 打开合成台，把材料凑齐后点击「合成」",
			"先合成木板，再做工具；石头工具比木头的更快更耐用",
			"冶炼炉可以把沙子烧成玻璃、把矿石炼成锭",
			"工具会用旧：快捷栏上的耐久条变短就该换新的了",
			"工具分 4 级：木 → 石 → 青铜 → 铁，等级越高越快、越耐用",
			"矿石也有等级门槛：锡矿要石镐、铁矿要青铜镐、金矿要铁镐",
		],
		"tip": "储物箱能帮你把多余的物资分门别类存好。",
	},
	{
		"title": "村庄与交易",
		"lines": [
			"世界里散落着村庄，村民会在村口迎接你",
			"T —— 打开交易面板，用农作物和村民换好东西",
			"B —— 打开背包窗口：27 格常用区 + 9 格待售区",
			"待售区的物品点「一键售卖」就能换成绿宝石",
			"右键储物箱可以存取物品，箱子里的东西只属于你",
			"村里的农田是可靠的食物来源，收割后会长回来",
		],
		"tip": "把基地建在村庄附近，交易和补给都方便。",
	},
	{
		"title": "世界地图",
		"lines": [
			"M —— 打开 3D 地球，拖动可以让它转起来",
			"点选七大洲或四大洋，看完介绍就能进入那片区域",
			"地球页下方可以选生存 / 创造 / 探索三种模式，点一下即时生效",
			"每个区域的地形、植被、生物和天空颜色都不一样",
			"切换区域会重新生成世界，背包里的东西都会带走",
		],
		"tip": "右上角小地图带指南针框，红色指针永远指向北方。",
	},
	{
		"title": "狩猎与生态",
		"lines": [
			"狩猎要用对工具：斧头对付牛羊猪和敌对生物，鱼竿捕鱼虾",
			"用错工具也能打，但伤害减半——屏幕上的提示会告诉你该用什么",
			"弓要先做箭（木头 + 圆石 + 羽毛），按住右键蓄力，松手射出去",
			"鱼竿右键抛竿，浮标沉下去的那一刻再右键，就能钓上鱼",
			"小动物会长大：每过一个游戏日成长一阶段，长大后才适合狩猎",
			"蝌蚪变青蛙、毛毛虫结茧变蝴蝶、鸡蛋孵出小鸡，都可以慢慢观察",
			"大熊猫、金丝猴、朱鹮、白头海雕、北极熊、袋鼠受保护，名牌是绿色，打不到",
			"村民和蜻蜓蝴蝶同样是我们的朋友，请让它们自由生活",
		],
		"tip": "弓和鱼竿都在合成台制作，打猎前记得提前备足箭。",
	},
	{
		"title": "探索的乐趣",
		"lines": [
			"这个世界有 11 片区域，试试把它们都走一遍",
			"创造与探索模式下按两次空格起飞，从天上俯瞰大地",
			"探索模式开局还送一架真飞机，比徒步飞行更快更远",
			"给自己盖一座小屋，种上树、挖口井",
			"收集不同区域的方块，是完成收藏的好办法",
		],
		"tip": "键位速查可随时按 F1 打开本说明书的第一页。",
	},
	{
		"title": "驾驶飞机",
		"lines": [
			"轻型飞机用铁锭 4 + 原木 6 + 线 2 合成；探索模式开局会送一架",
			"手持飞机右键，在身前的平地上放下；走近按 F 登机，再按 F 下机",
			"W / S —— 加 / 减油门 · 晃动鼠标 —— 操纵杆（俯仰和滚转）",
			"A / D —— 方向舵（地面上就是前轮转向）· 空格 —— 机轮刹车",
			"起飞要领：油门推到底滑跑，空速到 50 km/h 左右轻轻拉杆抬轮",
			"拉得太猛会失速：仪表盘亮出告警时，推杆低头并加油门改出",
			"屏幕顶部仪表盘显示空速、离地高度、油量和失速告警，飞天时盯着它",
			"滚轮拉近是座舱视角，拉远是追尾视角，驾驶中随时切换",
			"俯冲会超过极限速度、落得太快要摔坏——轻轻落，慢慢停",
		],
		"tip": "飞机比村子大一圈，降落要找块开阔平地，别往树冠里扎。",
	},
	{
		"title": "生物图鉴",
		"lines": [
			"F2 —— 打开生物图鉴，地球上的动物、植物、真菌都在里面",
			"一共 13 个地区 170 多种：七大洲、四大洋，还有南北极地区",
			"左边按「界 / 类 / 地区」三层筛选，也可以直接搜名字或学名",
			"卡片上标着「游戏内可遇见」的物种，在游戏里真的能找到它",
			"点开资料卡，会告诉你它住在哪、吃什么、有什么小秘密",
			"「知识问答」页每次随机出一题，答对会计入成就，每答对 3 题还有奖励",
			"在地球上点一片区域，介绍页里也有「看看这里的生物」，直接跳到当地图鉴",
		],
		"tip": "问答的答案都能在说明书、地球知识卡片或图鉴里找到线索，答错也没关系。",
	},
]

var _open := false
var _page := 0
var _page_title: Label
var _page_body: Label
var _status_label: Label
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

	# 主列布局：上方为导航 + 正文，底部整窗宽状态栏。
	var main := VBoxContainer.new()
	main.add_theme_constant_override("separation", 10)
	panel.add_child(main)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 14)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(columns)

	var nav := VBoxContainer.new()
	nav.custom_minimum_size = Vector2(150, 0)
	nav.add_theme_constant_override("separation", 6)
	columns.add_child(nav)

	for i in PAGES.size():
		var btn := Button.new()
		btn.text = String(PAGES[i]["title"])
		btn.focus_mode = Control.FOCUS_NONE
		btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.custom_minimum_size = Vector2(150, 40)
		btn.add_theme_font_size_override("font_size", 16)
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
	_page_title.add_theme_font_size_override("font_size", 23)
	_page_title.add_theme_color_override("font_color", TITLE_COLOR)
	content.add_child(_page_title)

	var rule := HSeparator.new()
	content.add_child(rule)

	_page_body = Label.new()
	_page_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_page_body.custom_minimum_size = Vector2(440, 0)
	_page_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_page_body.add_theme_font_size_override("font_size", 17)
	_page_body.add_theme_constant_override("line_spacing", 8)
	_page_body.add_theme_color_override("font_color", BODY_COLOR)
	content.add_child(_page_body)

	# 状态栏：左侧随页显示 Tips，右侧保留翻页/关闭键位提示。
	var status := PanelContainer.new()
	var status_style := StyleBoxFlat.new()
	status_style.bg_color = PAGE_BTN_BG
	status_style.border_color = PANEL_BORDER
	status_style.set_border_width_all(1)
	status_style.set_corner_radius_all(8)
	status_style.content_margin_left = 12.0
	status_style.content_margin_right = 12.0
	status_style.content_margin_top = 7.0
	status_style.content_margin_bottom = 7.0
	status.add_theme_stylebox_override("panel", status_style)
	main.add_child(status)

	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 12)
	status.add_child(status_row)

	_status_label = Label.new()
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", BODY_COLOR)
	status_row.add_child(_status_label)

	var keys_hint := Label.new()
	keys_hint.text = "左右方向键翻页 · Esc 或 F1 关闭"
	keys_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	keys_hint.add_theme_font_size_override("font_size", 12)
	keys_hint.add_theme_color_override("font_color", Color(BODY_COLOR, 0.7))
	status_row.add_child(keys_hint)

	# 关闭按钮：UiKit 统一透明底，只留红色 ✕ 字形压在说明书右肩上。
	var close_btn := UiKit.make_close()
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
	_status_label.text = "提示：" + String(data.get("tip", ""))
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
