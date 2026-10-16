class_name InstrumentDial
extends Control
## 仪表盘控件（D-034 座舱 3D 面板用）：在 SubViewport 里以 2D 绘制，经
## ViewportTexture 贴到座舱仪表板平面上，得到「低头可见的 3D 仪表盘」。
##
## 四种模式：
##   circular —— 普通圆形刻度（空速 / 高度 / 转速等）
##   attitude  —— 姿态仪（人工地平线：俯仰上下移、横滚转地平线、固定飞机符号）
##   hsi       —— 航道罗盘（北固定罗盘环 + 指向当前航向的指针 + CDI 垂直偏差条）
##   bar       —— 线性条（备用，襟翼/起落架档位条等）
##
## 纯 2D 绘制，无字体资产依赖（数字用 Control 自带默认字体 Label 叠加），
## 颜色编码绿/黄/红（儿童友好）：绿=正常、黄=注意、红=警告。

enum Mode { CIRCULAR, ATTITUDE, HSI, BAR }

const COL_BG := Color(0.04, 0.06, 0.09, 0.92)
const COL_RING := Color(0.55, 0.62, 0.72, 0.95)
const COL_TEXT := Color(0.92, 0.96, 1.0)
const COL_GREEN := Color(0.30, 0.85, 0.40)
const COL_YELLOW := Color(0.95, 0.82, 0.25)
const COL_RED := Color(0.95, 0.32, 0.28)
const COL_NEEDLE := Color(1.0, 0.92, 0.45)
const COL_SKY := Color(0.20, 0.48, 0.85)
const COL_GROUND := Color(0.55, 0.42, 0.24)

@export var mode: int = Mode.CIRCULAR
@export var title: String = ""
## 当前读数（bar/circular/attitude/hsi 各自取用）。
var value := 0.0
var min_val := 0.0
var max_val := 100.0
var unit := ""
## 姿态仪：俯仰角（度，抬头正）、横滚角（度，右滚正）。
var pitch_deg := 0.0
var roll_deg := 0.0
## HSI：当前航向（度）、直飞偏差（度，正=目标在右）、到目标距离（m）。
var heading_deg := 0.0
var deviation_deg := 0.0
var distance_m := 0.0
## 正常/警告绿区与红区（归一化 0..1，仅 circular）：区间外着色提示。
var green_from := 0.0
var green_to := 1.0
var red_from := -1.0
var red_to := -1.0
## 是否处于警告态（整体描边变红闪）。
var warning := false

var _title_label: Label


func _ready() -> void:
	_title_label = Label.new()
	_title_label.add_theme_color_override("font_color", COL_TEXT)
	_title_label.add_theme_font_size_override("font_size", 18)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_title_label.offset_top = 4.0
	add_child(_title_label)
	_title_label.text = title


## 设置标题（标题与模式无关，可在构建后改）。
func set_title(t: String) -> void:
	title = t
	if _title_label != null:
		_title_label.text = t


## 圆形/线性/姿态/HSI 读数批量刷新（座舱面板每帧从 FlightInstruments 喂入）。
func set_reading(v: float, mn: float, mx: float, u := "") -> void:
	value = v
	min_val = mn
	max_val = mx
	unit = u
	queue_redraw()


func set_attitude(pitch: float, roll: float) -> void:
	pitch_deg = pitch
	roll_deg = roll
	queue_redraw()


func set_hsi(heading: float, dev: float, dist: float) -> void:
	heading_deg = heading
	deviation_deg = dev
	distance_m = dist
	queue_redraw()


func _draw() -> void:
	match mode:
		Mode.CIRCULAR: _draw_circular()
		Mode.ATTITUDE: _draw_attitude()
		Mode.HSI: _draw_hsi()
		Mode.BAR: _draw_bar()


func _radius() -> float:
	return minf(size.x, size.y) * 0.42


func _draw_circular() -> void:
	var c := size * 0.5
	var r := _radius()
	# 表盘底。
	draw_circle(c, r, COL_BG)
	# 绿区 / 红区弧。
	_draw_zone(r, c)
	# 刻度环。
	draw_arc(c, r, 0.0, TAU, 64, COL_RING, 3.0, true)
	# 主刻度（每 10% 一格）。
	for i in range(11):
		var a := deg_to_rad(135.0 + i * 27.0)
		var p1 := c + Vector2(cos(a), sin(a)) * r
		var p2 := c + Vector2(cos(a), sin(a)) * (r - 8.0)
		draw_line(p1, p2, COL_RING, 2.0)
	# 指针。
	var frac := clampf((value - min_val) / maxf(max_val - min_val, 1e-6), 0.0, 1.0)
	var na := deg_to_rad(135.0 + frac * 270.0)
	var np := c + Vector2(cos(na), sin(na)) * (r - 10.0)
	draw_line(c, np, COL_NEEDLE, 4.0)
	draw_circle(c, 6.0, COL_NEEDLE)
	# 数值。
	_draw_value_text("%d" % int(value), c + Vector2(0.0, r * 0.45))
	_queue_title()


func _draw_zone(r: float, c: Vector2) -> void:
	if green_to > green_from:
		_draw_arc_zone(c, r - 4.0, green_from, green_to, COL_GREEN)
	if red_to > red_from and red_from >= 0.0:
		_draw_arc_zone(c, r - 4.0, red_from, red_to, COL_RED)


func _draw_arc_zone(center: Vector2, r: float, f0: float, f1: float, col: Color) -> void:
	var a0 := deg_to_rad(135.0 + f0 * 270.0)
	var a1 := deg_to_rad(135.0 + f1 * 270.0)
	draw_arc(center, r, a0, a1, 48, col, 6.0, true)


func _draw_attitude() -> void:
	var c := size * 0.5
	var r := _radius()
	# 底圈。
	draw_circle(c, r, COL_SKY)
	# 人工地平线：横滚旋转地平线、俯仰平移。
	var roll := deg_to_rad(roll_deg)
	var m := Transform2D().rotated(roll)
	# 抬头（pitch>0）地平线下沉（视觉下移）：hy 在 center 下方。
	var pitch_px := clampf(pitch_deg, -90.0, 90.0) / 90.0 * r
	var hy := pitch_px
	var dy := hy   # 相对 center.y 的偏移
	var under := r * r - dy * dy
	if under < 0.0:
		under = 0.0
	var half := sqrt(under)
	# 下半段（地面）多边形：左交点 → 沿下弧到右交点 → 闭合。
	var pts := PackedVector2Array()
	pts.append(m * Vector2(-half, dy) + c)
	var steps := 32
	for i in range(steps + 1):
		var a := PI + (float(i) / float(steps)) * PI   # 180°→360°（下半弧）
		# 弧点相对 center：cos/sin，再叠加 pitch 平移与横滚旋转。
		var arc := Vector2(cos(a) * r, sin(a) * r) + Vector2(0.0, dy)
		pts.append(m * arc + c)
	pts.append(m * Vector2(half, dy) + c)
	draw_colored_polygon(pts, COL_GROUND)
	# 地平线白线（随姿态旋转/平移）。
	var l1 := m * Vector2(-half, dy) + c
	var l2 := m * Vector2(half, dy) + c
	draw_line(l1, l2, Color(1.0, 1.0, 1.0), 2.0)
	# 固定飞机符号（黄）：横滚/俯仰参考，居中不动。
	draw_line(c + Vector2(-26.0, 0.0), c + Vector2(-10.0, 0.0), COL_YELLOW, 4.0)
	draw_line(c + Vector2(10.0, 0.0), c + Vector2(26.0, 0.0), COL_YELLOW, 4.0)
	draw_line(c + Vector2(-10.0, 0.0), c + Vector2(0.0, -8.0), COL_YELLOW, 4.0)
	draw_line(c + Vector2(10.0, 0.0), c + Vector2(0.0, -8.0), COL_YELLOW, 4.0)
	draw_circle(c, 3.0, COL_YELLOW)
	draw_arc(c, r, 0.0, TAU, 64, COL_RING, 3.0, true)
	_queue_title()


func _draw_hsi() -> void:
	var c := size * 0.5
	var r := _radius()
	draw_circle(c, r, COL_BG)
	draw_arc(c, r, 0.0, TAU, 64, COL_RING, 3.0, true)
	# 罗盘环：北/东/南/西标记（北固定朝上）。
	for card in [["N", 0.0], ["E", 90.0], ["S", 180.0], ["W", 270.0]]:
		var a := deg_to_rad(float(card[1]) - 90.0)  # 北朝上 = -90°
		var p := c + Vector2(cos(a), sin(a)) * (r - 14.0)
		draw_string(ThemeDB.fallback_font, p - Vector2(7.0, -6.0), String(card[0]),
			HORIZONTAL_ALIGNMENT_CENTER, -1, 16, COL_TEXT)
	# 航向指针：从中心指向当前航向方向（北朝上基准）。
	var ha := deg_to_rad(heading_deg - 90.0)
	var hp := c + Vector2(cos(ha), sin(ha)) * (r - 18.0)
	draw_line(c, hp, COL_NEEDLE, 4.0)
	draw_circle(c, 5.0, COL_NEEDLE)
	# CDI 垂直偏差条：目标在右偏右、在左偏左，满偏 ±1。
	var dev := clampf(deviation_deg / 30.0, -1.0, 1.0)
	var bx := c.x + dev * (r - 24.0)
	var by0 := c.y - 26.0
	var by1 := c.y + 26.0
	draw_line(Vector2(bx, by0), Vector2(bx, by1), COL_YELLOW, 4.0)
	# 中心竖参考线。
	draw_line(Vector2(c.x, by0), Vector2(c.x, by1), Color(1.0, 1.0, 1.0, 0.5), 1.5)
	# 距离数字。
	_draw_value_text("%.0f m" % distance_m, c + Vector2(0.0, r * 0.55))
	_queue_title()


func _draw_bar() -> void:
	var c := size * 0.5
	var w := size.x - 24.0
	var h := 18.0
	var x0 := 12.0
	var y0 := c.y - h * 0.5
	var bg := Rect2(x0, y0, w, h)
	draw_rect(bg, COL_BG, true)
	draw_rect(bg, COL_RING, false, 2.0)
	var frac := clampf((value - min_val) / maxf(max_val - min_val, 1e-6), 0.0, 1.0)
	var col := COL_GREEN if frac >= 0.2 else COL_RED
	draw_rect(Rect2(x0, y0, w * frac, h), col, true)
	_draw_value_text("%d" % int(value), c + Vector2(0.0, -h))


func _draw_value_text(t: String, at: Vector2) -> void:
	draw_string(ThemeDB.fallback_font, at - Vector2(t.length() * 5.0, -8.0), t,
		HORIZONTAL_ALIGNMENT_CENTER, -1, 22, COL_TEXT)


func _queue_title() -> void:
	if _title_label != null:
		_title_label.text = title
