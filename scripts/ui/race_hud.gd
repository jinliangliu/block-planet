class_name RaceHUD
extends CanvasLayer
## 比赛中的 HUD：圈数 / 排名 / 车速 / 当前圈时间 / 最快圈 / 燃油 / 打滑提示 +
## 倒计时与过线播报。只读 RaceSession 的快照，不持有任何规则。

const PANEL_BG := Color(0.06, 0.08, 0.12, 0.62)
const TEXT := Color(0.96, 0.97, 0.99)
const DIM := Color(0.78, 0.82, 0.88)
const GOOD := Color(0.45, 0.92, 0.55)
const WARN := Color(1.0, 0.82, 0.30)
const BAD := Color(1.0, 0.42, 0.38)

var _root: Control
var _lap_label: Label
var _rank_label: Label
var _speed_label: Label
var _cur_lap_label: Label
var _best_lap_label: Label
var _fuel_bar: ProgressBar
var _fuel_label: Label
var _slip_label: Label
var _terrain_label: Label
var _countdown_label: Label
var _banner: Label
var _hint_label: Label


func _ready() -> void:
	layer = 5
	_build()


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# 左上：圈数与排名
	var tl := _corner(Control.PRESET_TOP_LEFT, Control.GROW_DIRECTION_END,
		Control.GROW_DIRECTION_END, Vector2(16, 14))
	var tl_box := VBoxContainer.new()
	tl_box.add_theme_constant_override("separation", 2)
	tl.add_child(tl_box)
	_lap_label = _label("圈数 1/3", 26, TEXT)
	_rank_label = _label("排名 1/4", 22, WARN)
	tl_box.add_child(_lap_label)
	tl_box.add_child(_rank_label)

	# 右上：本圈与最快圈
	var tr := _corner(Control.PRESET_TOP_RIGHT, Control.GROW_DIRECTION_BEGIN,
		Control.GROW_DIRECTION_END, Vector2(-16, 14))
	var tr_box := VBoxContainer.new()
	tr_box.alignment = BoxContainer.ALIGNMENT_END
	tr_box.add_theme_constant_override("separation", 2)
	tr.add_child(tr_box)
	_cur_lap_label = _label("本圈 00:00.00", 22, TEXT)
	_best_lap_label = _label("最快 --:--.--", 20, GOOD)
	tr_box.add_child(_cur_lap_label)
	tr_box.add_child(_best_lap_label)

	# 底部中央：车速
	var bc := _corner(Control.PRESET_CENTER_BOTTOM, Control.GROW_DIRECTION_BOTH,
		Control.GROW_DIRECTION_BEGIN, Vector2(0, -14))
	var sp_box := VBoxContainer.new()
	sp_box.alignment = BoxContainer.ALIGNMENT_CENTER
	bc.add_child(sp_box)
	_speed_label = _label("0", 52, TEXT)
	_speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_terrain_label = _label("铺装路面", 18, DIM)
	_terrain_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sp_box.add_child(_speed_label)
	sp_box.add_child(_terrain_label)

	# 左下：燃油 + 打滑
	var bl := _corner(Control.PRESET_BOTTOM_LEFT, Control.GROW_DIRECTION_END,
		Control.GROW_DIRECTION_BEGIN, Vector2(16, -14))
	var bl_box := VBoxContainer.new()
	bl_box.add_theme_constant_override("separation", 4)
	bl.add_child(bl_box)
	_fuel_label = _label("燃油 100%", 18, DIM)
	_fuel_bar = ProgressBar.new()
	_fuel_bar.custom_minimum_size = Vector2(200, 14)
	_fuel_bar.max_value = 100.0
	_fuel_bar.value = 100.0
	_fuel_bar.show_percentage = false
	bl_box.add_child(_fuel_label)
	bl_box.add_child(_fuel_bar)
	_slip_label = _label("", 20, BAD)
	bl_box.add_child(_slip_label)

	# 右下：按键提示
	var br := _corner(Control.PRESET_BOTTOM_RIGHT, Control.GROW_DIRECTION_BEGIN,
		Control.GROW_DIRECTION_BEGIN, Vector2(-16, -14))
	_hint_label = _label("W 油门 · S 刹车 · A/D 转向\n空格 手刹 · C 车灯 · F 喇叭\nEsc 退出赛道 · R 重跑",
		16, DIM)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	br.add_child(_hint_label)

	# 中央：倒计时与播报
	_countdown_label = _label("", 120, Color(1.0, 0.92, 0.35))
	_countdown_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_countdown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_countdown_label)

	_banner = _label("", 40, GOOD)
	_root.add_child(_banner)
	_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.grow_vertical = Control.GROW_DIRECTION_END
	# 同 _corner：相对锚点（屏幕上方中点）用 offset，不能用父坐标系的 position。
	_banner.offset_left = 0.0
	_banner.offset_right = 0.0
	_banner.offset_top = 86.0
	_banner.offset_bottom = 86.0
	_banner.custom_minimum_size = Vector2(460, 56)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_banner.modulate.a = 0.0


## 把面板贴到某个屏幕角上：preset 定锚点，grow 决定它往哪个方向长大，
## margin 是到边缘的距离（右侧/底部用负数）。内容尺寸由容器自身算。
##
## 注意必须写 offset_* 而不是 position：`Control.position` 是**父坐标系**下的左上角，
## 贴右/下的面板一旦用 position = 负 margin 就会被摆到屏幕外（首版重赛 HUD 因此丢掉了
## 本圈/最快圈、油表与按键提示，只在左边缘露出一角）——offset 才是相对锚点的量。
func _corner(preset: int, grow_h: int, grow_v: int, margin: Vector2) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style())
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(p)
	p.set_anchors_preset(preset)
	p.grow_horizontal = grow_h
	p.grow_vertical = grow_v
	p.offset_left = margin.x
	p.offset_right = margin.x
	p.offset_top = margin.y
	p.offset_bottom = margin.y
	return p


func _style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = PANEL_BG
	s.set_corner_radius_all(10)
	s.content_margin_left = 14.0
	s.content_margin_right = 14.0
	s.content_margin_top = 8.0
	s.content_margin_bottom = 8.0
	return s


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 5)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## 每帧刷新（只读 session 快照）。
func update_view(session: RaceSession, terrain_name: String) -> void:
	if session == null:
		return
	var r: RaceSession.Racer = session.player()
	if r == null:
		return
	_lap_label.text = "圈数 %d/%d" % [mini(r.lap + 1, session.laps), session.laps]
	_rank_label.text = "排名 %d/%d" % [maxi(r.rank, 1), session.racer_count()]
	_cur_lap_label.text = "本圈 %s" % RaceSystem.format_time(session.elapsed - r.lap_start)
	_best_lap_label.text = "最快 %s" % RaceSystem.format_lap(r.best_lap)
	_speed_label.text = "%d" % int(round(r.car.kmh()))
	_terrain_label.text = terrain_name
	var ratio := r.car.fuel_ratio()
	_fuel_bar.value = ratio * 100.0
	_fuel_bar.modulate = WARN if ratio < 0.2 else Color.WHITE
	_fuel_label.text = "燃油 %d%%" % int(round(ratio * 100.0))
	_slip_label.text = "打滑！松一点油门" if r.car.slip_deg() > 9.0 else ""


## 倒计时大数字。
func set_countdown(seconds: float) -> void:
	_countdown_label.text = "%d" % maxi(int(ceil(seconds)), 1)
	_countdown_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.35))


func clear_countdown() -> void:
	_countdown_label.text = ""


## 中央横幅播报（出发、过圈、破纪录、冲线）。
func banner(text: String, color: Color) -> void:
	_banner.text = text
	_banner.add_theme_color_override("font_color", color)
	_banner.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(1.6)
	tw.tween_property(_banner, "modulate:a", 0.0, 0.6)
