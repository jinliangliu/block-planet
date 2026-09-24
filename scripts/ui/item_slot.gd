class_name ItemSlot
extends Button
## 自绘物品格：格底 + 物品微缩图 + 数量/耐久角标。
## 方块绘制等距小立方体，工具绘制柄+头部剪影，其余物品按造型剪影绘制。
## 亮色变体用于储物箱面板，深色变体用于悬浮在 3D 画面上的快捷装备栏。

const EMPTY_TEXT_COLOR_LIGHT := Color(0.62, 0.56, 0.44, 0.7)
const EMPTY_TEXT_COLOR_DARK := Color(0.85, 0.83, 0.76, 0.6)
const TEXT_COLOR_LIGHT := Color(0.28, 0.20, 0.10)
const TEXT_COLOR_DARK := Color(0.95, 0.93, 0.86)

var _item_id := 0
var _count := 0
var _durability := 0
var _deficit := false

var _cell_style: StyleBoxFlat
var _hover_style: StyleBoxFlat
var _active_style: StyleBoxFlat
var _deficit_style: StyleBoxFlat
var _chip_style: StyleBoxFlat
var _text_color := TEXT_COLOR_LIGHT
var _empty_color := EMPTY_TEXT_COLOR_LIGHT


func _init() -> void:
	focus_mode = Control.FOCUS_NONE
	_build_styles(false)
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())


## 深色半透明变体：快捷装备栏悬浮在 3D 画面上时使用。
func set_dark_style() -> void:
	_build_styles(true)
	queue_redraw()


func _build_styles(dark: bool) -> void:
	_cell_style = StyleBoxFlat.new()
	if dark:
		_cell_style.bg_color = Color(0.10, 0.10, 0.13, 0.72)
		_cell_style.border_color = Color(0.38, 0.36, 0.34, 0.9)
		_text_color = TEXT_COLOR_DARK
		_empty_color = EMPTY_TEXT_COLOR_DARK
	else:
		_cell_style.bg_color = Color(0.98, 0.96, 0.90)
		_cell_style.border_color = Color(0.80, 0.70, 0.50)
		_text_color = TEXT_COLOR_LIGHT
		_empty_color = EMPTY_TEXT_COLOR_LIGHT
	_cell_style.set_border_width_all(2)
	_cell_style.set_corner_radius_all(8)
	_hover_style = _cell_style.duplicate()
	_hover_style.border_color = Color(0.90, 0.62, 0.20)
	_hover_style.set_border_width_all(3)
	_active_style = _cell_style.duplicate()
	_active_style.border_color = Color(1.0, 0.84, 0.30)
	_active_style.set_border_width_all(3)
	_deficit_style = _cell_style.duplicate()
	_deficit_style.border_color = Color(0.85, 0.25, 0.22)
	_deficit_style.set_border_width_all(3)
	_chip_style = StyleBoxFlat.new()
	_chip_style.set_corner_radius_all(6)
	_chip_style.set_border_width_all(2)


## 以背包槽位数据刷新格子内容（无该格数据时传 0 即显示空格）。
func set_slot(slot: Dictionary) -> void:
	_item_id = int(slot["item"])
	_count = int(slot["count"])
	# 缺省 -1（无耐久信息）：合成路径里的工具预览格没有耐久概念，
	# 若缺省 0 会在角标显示误导性的「0」。
	_durability = int(slot.get("durability", -1))
	queue_redraw()


## 标记材料不足（红色描边提示）。
func set_deficit(on: bool) -> void:
	if _deficit == on:
		return
	_deficit = on
	queue_redraw()


## 当前展示的物品 ID（悬停预览用），空格为 0。
func item_id() -> int:
	return _item_id


func _draw() -> void:
	draw_style_box(_cell_style, Rect2(Vector2.ZERO, size))
	if _item_id == 0 or _count <= 0:
		draw_string(get_theme_default_font(), Vector2(0.0, size.y * 0.5 + 6.0), "·",
			HORIZONTAL_ALIGNMENT_CENTER, size.x, 18, _empty_color)
		return
	if button_pressed:
		draw_style_box(_active_style, Rect2(Vector2.ZERO, size))
	elif is_hovered():
		draw_style_box(_hover_style, Rect2(Vector2.ZERO, size))
	if _deficit:
		draw_style_box(_deficit_style, Rect2(Vector2.ZERO, size))

	var base := ItemTypes.item_color(_item_id)
	var half := size.x * 0.28
	var center := size * 0.5
	if ItemTypes.category(_item_id) == 0:
		_draw_mini_cube(center, half, base)
	elif ItemTypes.is_tool_item(_item_id):
		_draw_tool_icon(center, half, base)
	else:
		_draw_item_icon(center, half, base)

	# 有耐久信息的工具角标显示耐久；其余（含无耐久信息的工具预览格）显示数量。
	var corner := "×%d" % _count
	if ItemTypes.is_tool_item(_item_id) and _durability >= 0:
		corner = str(_durability)
	draw_string(get_theme_default_font(), Vector2(4.0, size.y - 5.0), corner,
		HORIZONTAL_ALIGNMENT_RIGHT, size.x - 8.0, 14, _text_color)


## 等距小立方体微缩图：顶/左/右三面明暗区分，颜色取自方块顶面瓦片。
func _draw_mini_cube(center: Vector2, half: float, base: Color) -> void:
	var top := PackedVector2Array([
		center + Vector2(0.0, -half),
		center + Vector2(half, -half * 0.5),
		center + Vector2(0.0, 0.0),
		center + Vector2(-half, -half * 0.5),
	])
	var left := PackedVector2Array([
		center + Vector2(-half, -half * 0.5),
		center + Vector2(0.0, 0.0),
		center + Vector2(0.0, half),
		center + Vector2(-half, half * 0.5),
	])
	var right := PackedVector2Array([
		center + Vector2(half, -half * 0.5),
		center + Vector2(0.0, 0.0),
		center + Vector2(0.0, half),
		center + Vector2(half, half * 0.5),
	])
	draw_colored_polygon(top, base)
	draw_colored_polygon(left, base.darkened(0.18))
	draw_colored_polygon(right, base.darkened(0.35))


## 工具微缩图：木柄 + 按类型区分的头部剪影（镐弧刃/斧侧刃/锹方头）。
func _draw_tool_icon(center: Vector2, half: float, base: Color) -> void:
	var wood := Color(0.45, 0.30, 0.15)
	var grip := half * 0.42
	draw_line(center + Vector2(-half * 0.75, half * 0.8),
		center + Vector2(half * 0.35, -half * 0.45), wood, grip)
	match ItemTypes.tool_type(_item_id):
		"pickaxe":
			var arc := PackedVector2Array([
				center + Vector2(-half * 0.95, -half * 0.1),
				center + Vector2(-half * 0.45, -half * 0.85),
				center + Vector2(half * 0.5, -half * 0.95),
				center + Vector2(half * 1.0, -half * 0.15),
			])
			draw_polyline(arc, base, grip * 1.15)
		"axe":
			var blade := PackedVector2Array([
				center + Vector2(half * 0.15, -half * 1.05),
				center + Vector2(half * 1.05, -half * 0.6),
				center + Vector2(half * 0.9, half * 0.05),
				center + Vector2(half * 0.25, -half * 0.3),
			])
			draw_colored_polygon(blade, base)
		"shovel":
			var head := PackedVector2Array([
				center + Vector2(half * 0.1, -half * 1.1),
				center + Vector2(half * 0.85, -half * 1.0),
				center + Vector2(half * 0.75, -half * 0.3),
				center + Vector2(half * 0.2, -half * 0.35),
			])
			draw_colored_polygon(head, base)
		"sickle":
			# 镰刀：弯月刀身（两段折线近似弧度）+ 尖端收细。
			var moon := PackedVector2Array([
				center + Vector2(-half * 0.6, -half * 0.2),
				center + Vector2(-half * 0.2, -half * 0.95),
				center + Vector2(half * 0.55, -half * 1.0),
				center + Vector2(half * 0.95, -half * 0.3),
			])
			draw_polyline(moon, base, grip * 1.3)
			draw_line(center + Vector2(half * 0.95, -half * 0.3),
				center + Vector2(half * 1.15, -half * 0.05), base, grip * 0.7)
		"rod":
			# 鱼竿：细竿 + 绕线轮 + 垂下的钓线。
			var rod := PackedVector2Array([
				center + Vector2(-half * 0.85, half * 0.85),
				center + Vector2(half * 0.7, -half * 1.0),
			])
			draw_polyline(rod, Color(0.52, 0.38, 0.20), grip * 0.6)
			draw_circle(center + Vector2(-half * 0.25, half * 0.15), grip * 0.45, base)
			draw_line(center + Vector2(half * 0.7, -half * 1.0),
				center + Vector2(half * 0.62, half * 0.1), Color(0.86, 0.86, 0.82), grip * 0.22)
		"bow":
			# 弓：竖立的弓臂弧线 + 弓弦。
			var arm := PackedVector2Array([
				center + Vector2(-half * 0.25, half * 1.05),
				center + Vector2(half * 0.35, half * 0.1),
				center + Vector2(-half * 0.25, -half * 1.05),
			])
			draw_polyline(arm, base, grip * 0.85)
			draw_line(center + Vector2(-half * 0.25, half * 1.05),
				center + Vector2(-half * 0.25, -half * 1.05), Color(0.90, 0.90, 0.86), grip * 0.22)


## 非方块物品微缩图：按物品 ID 分派造型剪影，未识别的退化为锭形。
func _draw_item_icon(center: Vector2, half: float, base: Color) -> void:
	match _item_id:
		ItemTypes.COPPER_INGOT, ItemTypes.TIN_INGOT, ItemTypes.BRONZE_INGOT, ItemTypes.IRON_INGOT, ItemTypes.SILVER_INGOT, ItemTypes.GOLD_INGOT, ItemTypes.ALLOY_INGOT, ItemTypes.CARBON_ROD, ItemTypes.TOTEM:
			_draw_ingot(center, half, base)
		ItemTypes.RAW_BEEF, ItemTypes.RAW_PORK, ItemTypes.CRAB_MEAT, ItemTypes.BREAD:
			_draw_loaf(center, half, base)
		ItemTypes.RAW_CHICKEN:
			_draw_drumstick(center, half, base)
		ItemTypes.RAW_FISH:
			_draw_fish(center, half, base)
		ItemTypes.RAW_SHRIMP:
			_draw_shrimp(center, half, base)
		ItemTypes.WHEAT:
			_draw_wheat(center, half, base)
		ItemTypes.BONE:
			_draw_bone(center, half, base)
		ItemTypes.STRING:
			_draw_string(center, half, base)
		ItemTypes.EMERALD, ItemTypes.CRYSTAL:
			_draw_gem(center, half, base)
		ItemTypes.HIDE:
			_draw_loaf(center, half, base)
		ItemTypes.FEATHER:
			_draw_feather(center, half, base)
		ItemTypes.FANG:
			_draw_fang(center, half, base)
		ItemTypes.ARROW:
			_draw_arrow(center, half, base)
		_:
			_draw_ingot(center, half, base)


## 锭/图腾：梯形条 + 顶部高光。
func _draw_ingot(center: Vector2, half: float, base: Color) -> void:
	var w := half * 2.1
	var h := half * 1.15
	var ingot := PackedVector2Array([
		center + Vector2(-w * 0.5, h * 0.5),
		center + Vector2(-w * 0.4, -h * 0.5),
		center + Vector2(w * 0.4, -h * 0.5),
		center + Vector2(w * 0.5, h * 0.5),
	])
	draw_colored_polygon(ingot, base)
	draw_rect(Rect2(center - Vector2(w, h) * 0.5 + Vector2(w * 0.16, h * 0.16),
		Vector2(w * 0.28, h * 0.18)), base.lightened(0.35))


## 肉排/面包：圆角色块 + 浅色内里。
func _draw_loaf(center: Vector2, half: float, base: Color) -> void:
	var w := half * 2.2
	var h := half * 1.5
	_chip_style.bg_color = base
	_chip_style.border_color = base.darkened(0.2)
	_chip_style.set_corner_radius_all(int(maxf(4.0, half * 0.5)))
	draw_style_box(_chip_style, Rect2(center - Vector2(w, h) * 0.5, Vector2(w, h)))
	draw_rect(Rect2(center - Vector2(w * 0.3, h * 0.14), Vector2(w * 0.6, h * 0.24)),
		base.lightened(0.35))


## 鸡腿：白色骨柄 + 圆形肉块。
func _draw_drumstick(center: Vector2, half: float, base: Color) -> void:
	draw_line(center + Vector2(-half * 0.8, half * 0.75),
		center + Vector2(half * 0.2, -half * 0.15), Color(0.95, 0.93, 0.86), half * 0.32)
	draw_circle(center + Vector2(-half * 0.9, half * 0.85), half * 0.28, Color(0.95, 0.93, 0.86))
	draw_circle(center + Vector2(half * 0.45, -half * 0.4), half * 0.75, base)


## 鱼：椭圆身 + 三角尾 + 眼点。
func _draw_fish(center: Vector2, half: float, base: Color) -> void:
	var body := PackedVector2Array()
	for i in range(12):
		var a := TAU * float(i) / 12.0
		body.append(center + Vector2(cos(a) * half * 1.0, sin(a) * half * 0.52))
	draw_colored_polygon(body, base)
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(half * 0.8, 0.0),
		center + Vector2(half * 1.35, -half * 0.5),
		center + Vector2(half * 1.35, half * 0.5),
	]), base.darkened(0.2))
	draw_circle(center + Vector2(-half * 0.5, -half * 0.1), half * 0.13, Color(0.10, 0.10, 0.12))


## 虾：弯曲弓身 + 头点。
func _draw_shrimp(center: Vector2, half: float, base: Color) -> void:
	var pts := PackedVector2Array()
	for i in range(9):
		var t := float(i) / 8.0
		var a := PI * (1.0 - 0.7 * t)
		pts.append(center + Vector2(cos(a) * half * 0.85, -sin(a) * half * 0.95))
	draw_polyline(pts, base, half * 0.45)
	draw_circle(pts[0], half * 0.3, base.darkened(0.25))


## 小麦：三根麦秆 + 顶部麦粒。
func _draw_wheat(center: Vector2, half: float, base: Color) -> void:
	for k in range(3):
		var x := center.x + (float(k) - 1.0) * half * 0.6
		draw_line(Vector2(x, center.y + half * 0.9), Vector2(x, center.y - half * 0.6),
			base.darkened(0.2), half * 0.14)
		for j in range(3):
			draw_circle(Vector2(x, center.y - half * 0.55 + float(j) * half * 0.3),
				half * 0.17, base)


## 骨头：斜柄 + 两端圆头。
func _draw_bone(center: Vector2, half: float, base: Color) -> void:
	draw_line(center + Vector2(-half * 0.6, half * 0.55),
		center + Vector2(half * 0.55, -half * 0.5), base, half * 0.3)
	for end in [Vector2(-half * 0.7, half * 0.65), Vector2(half * 0.65, -half * 0.6)]:
		draw_circle(center + end + Vector2(-half * 0.16, half * 0.16), half * 0.3, base)
		draw_circle(center + end + Vector2(half * 0.16, -half * 0.16), half * 0.3, base)


## 线：波浪曲线。
func _draw_string(center: Vector2, half: float, base: Color) -> void:
	var pts := PackedVector2Array()
	for i in range(13):
		var t := float(i) / 12.0
		pts.append(Vector2(center.x - half + t * half * 2.0,
			center.y + sin(t * TAU * 1.5) * half * 0.55))
	draw_polyline(pts, base, half * 0.2)


## 绿宝石：菱形宝石 + 内部高光面。
func _draw_gem(center: Vector2, half: float, base: Color) -> void:
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(0.0, -half),
		center + Vector2(half * 0.8, 0.0),
		center + Vector2(0.0, half),
		center + Vector2(-half * 0.8, 0.0),
	]), base)
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(0.0, -half * 0.55),
		center + Vector2(half * 0.4, -half * 0.05),
		center + Vector2(0.0, -half * 0.05),
		center + Vector2(-half * 0.4, -half * 0.05),
	]), base.lightened(0.4))


## 羽毛：细羽轴 + 两侧羽片。
func _draw_feather(center: Vector2, half: float, base: Color) -> void:
	draw_line(center + Vector2(-half * 0.7, half * 0.9), center + Vector2(half * 0.5, -half * 0.95),
		base.darkened(0.25), half * 0.16)
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(-half * 0.55, half * 0.35),
		center + Vector2(half * 0.1, -half * 0.95),
		center + Vector2(half * 0.55, -half * 0.75),
		center + Vector2(-half * 0.05, half * 0.15),
	]), base)
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(-half * 0.62, half * 0.62),
		center + Vector2(-half * 0.05, -half * 0.5),
		center + Vector2(half * 0.2, -half * 0.3),
		center + Vector2(-half * 0.3, half * 0.8),
	]), base.lightened(0.10))


## 獠牙：弯曲的尖牙。
func _draw_fang(center: Vector2, half: float, base: Color) -> void:
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(-half * 0.7, -half * 0.9),
		center + Vector2(half * 0.25, -half * 0.6),
		center + Vector2(-half * 0.1, half * 0.95),
		center + Vector2(-half * 0.75, half * 0.1),
	]), base)
	draw_line(center + Vector2(-half * 0.55, -half * 0.5), center + Vector2(-half * 0.2, half * 0.4),
		base.darkened(0.25), half * 0.12)


## 箭：细杆 + 三角箭头 + 尾羽。
func _draw_arrow(center: Vector2, half: float, base: Color) -> void:
	draw_line(center + Vector2(-half * 0.95, half * 0.95), center + Vector2(half * 0.6, -half * 0.6),
		base.darkened(0.15), half * 0.18)
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(half * 0.35, -half * 0.85),
		center + Vector2(half * 1.05, -half * 1.05),
		center + Vector2(half * 0.75, -half * 0.35),
	]), base.lightened(0.35))
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(-half * 0.95, half * 0.95),
		center + Vector2(-half * 0.35, half * 0.35),
		center + Vector2(-half * 0.45, half * 0.95),
	]), Color(0.94, 0.94, 0.90))
