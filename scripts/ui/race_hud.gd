class_name RaceHUD
extends CanvasLayer
## 比赛中的 HUD：圈数 / 排名 / 车速 / 当前圈时间 / 最快圈 / 燃油 / 打滑提示 +
## 倒计时与过线播报。只读 RaceSession 的快照，不持有任何规则。
##
## 触屏（手机/Android）额外建一层操控：左下转向、右下刹车+手刹、右上重开/退出，
## 通过 touch_input() 以「输入快照」交给 race_scene 消费。**没有触摸屏时这一层
## 完全不建**，键盘/手柄玩家看到的界面与旧版逐像素一致。

## 触屏层向外抛出的动作请求（消费端：race_scene.gd 接这两个信号）。
## 退出是必需品：Android 上根本没有 race_exit 这个键，没有它触屏玩家会被困在比赛里。
signal touch_exit_requested
signal touch_restart_requested

const PANEL_BG := Color(0.06, 0.08, 0.12, 0.62)
const TEXT := Color(0.96, 0.97, 0.99)
const DIM := Color(0.78, 0.82, 0.88)
const GOOD := Color(0.45, 0.92, 0.55)
const WARN := Color(1.0, 0.82, 0.30)
const BAD := Color(1.0, 0.42, 0.38)

# ── 触屏操控层度量（1280×720 基准、canvas_items 拉伸下的逻辑像素） ──
## 到屏幕边缘的留白。手机横屏握持时拇指自然落点离边角一段距离，不能贴边。
const TOUCH_MARGIN := 24.0
## 相邻按钮间距：两个 132 宽按钮挨太近会一次按到两个。
const TOUCH_GAP := 12.0
const TOUCH_STEER_SIZE := 132.0
const TOUCH_BRAKE_SIZE := 132.0
const TOUCH_HANDBRAKE_SIZE := 104.0
const TOUCH_ACTION_SIZE := Vector2(96, 56)
const TOUCH_BTN_BG := Color(0.10, 0.13, 0.20, 0.74)
const TOUCH_BTN_BG_BRAKE := Color(0.82, 0.26, 0.24, 0.82)
const TOUCH_BTN_BG_HANDBRAKE := Color(0.95, 0.70, 0.22, 0.82)
const TOUCH_BTN_EDGE := Color(1.0, 1.0, 1.0, 0.34)


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

# 触屏面板留位用：这几块面板的位置在触屏版要上移，避开按钮。
var _panel_tr: PanelContainer
var _panel_bl: PanelContainer
var _panel_br: PanelContainer

## 无头探针开关：无头环境没有触摸屏，把这里置 true 才能建出触屏层去验契约。
## 必须在 add_child() 之前设置（_ready 里只判定一次）。
var force_touch := false

var _touch_layer: Control = null
var _steer_left: Button = null
var _steer_right: Button = null
var _btn_brake: Button = null
var _btn_handbrake: Button = null
var _touch_steer := 0.0
var _touch_brake := false
var _touch_handbrake := false
## 原始触摸兜底用：touch index → 命中的按钮标识（见 _input 注释）。
var _raw_owns: Dictionary = {}
## 当前按在屏幕上的 touch index 集合：用来识别「抬指事件丢了」。
var _down_touches: Dictionary = {}


func _ready() -> void:
	layer = 5
	_build()
	# 只在真有触摸屏时才建触屏层（键盘/手柄玩家看到的界面一个像素都不变）。
	if force_touch or DisplayServer.is_touchscreen_available():
		_build_touch()


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
	_panel_tr = _corner(Control.PRESET_TOP_RIGHT, Control.GROW_DIRECTION_BEGIN,
		Control.GROW_DIRECTION_END, Vector2(-16, 14))
	var tr_box := VBoxContainer.new()
	tr_box.alignment = BoxContainer.ALIGNMENT_END
	tr_box.add_theme_constant_override("separation", 2)
	_panel_tr.add_child(tr_box)
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
	_panel_bl = _corner(Control.PRESET_BOTTOM_LEFT, Control.GROW_DIRECTION_END,
		Control.GROW_DIRECTION_BEGIN, Vector2(16, -14))
	var bl_box := VBoxContainer.new()
	bl_box.add_theme_constant_override("separation", 4)
	_panel_bl.add_child(bl_box)
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
	_panel_br = _corner(Control.PRESET_BOTTOM_RIGHT, Control.GROW_DIRECTION_BEGIN,
		Control.GROW_DIRECTION_BEGIN, Vector2(-16, -14))
	_hint_label = _label("W 油门 · S 刹车 · A/D 转向\n空格 手刹 · C 车灯 · F 喇叭\nEsc 退出赛道 · R 重跑",
		16, DIM)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_panel_br.add_child(_hint_label)

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


## ───────────────────────── 触屏操控层（移动端） ─────────────────────────
## 只在有触摸屏时构建。布局全部走锚点 + custom_minimum_size，不写死坐标：
## 手机横屏从 16:9 到 20:9 都要能摆对。
func _build_touch() -> void:
	_touch_layer = Control.new()
	_touch_layer.name = "TouchPad"
	_touch_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 容器自身不吃输入：只有下面那几个按钮命中。否则铺满全屏的这层会吃掉
	# 中央的点击，还会挡住将来的其它 UI。
	_touch_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 最后 add_child → 在 _root 的子节点里排最上层。
	_root.add_child(_touch_layer)
	# _input 里要收原始多点触摸（见 _input 注释），显式开一次。
	set_process_input(true)

	# ── 左下：转向（左拇指区，横排） ──
	var steer_row := HBoxContainer.new()
	steer_row.name = "SteerRow"
	steer_row.add_theme_constant_override("separation", int(TOUCH_GAP))
	steer_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_touch_layer.add_child(steer_row)
	_place_corner(steer_row, Control.PRESET_BOTTOM_LEFT, Vector2(TOUCH_MARGIN, -TOUCH_MARGIN))

	_steer_left = _touch_button("SteerLeft", "◀",
		Vector2(TOUCH_STEER_SIZE, TOUCH_STEER_SIZE), TOUCH_BTN_BG, 54)
	_steer_right = _touch_button("SteerRight", "▶",
		Vector2(TOUCH_STEER_SIZE, TOUCH_STEER_SIZE), TOUCH_BTN_BG, 54)
	steer_row.add_child(_steer_left)
	steer_row.add_child(_steer_right)
	# 按住语义：必须用 button_down/button_up。用 pressed 会变成「点一下」，
	# 孩子按住不放车就不会一直转——这是移动端操纵最容易做错的一点。
	_steer_left.button_down.connect(func() -> void: _set_steer_axis(-1.0))
	_steer_left.button_up.connect(func() -> void: _set_steer_axis(0.0))
	_steer_right.button_down.connect(func() -> void: _set_steer_axis(1.0))
	_steer_right.button_up.connect(func() -> void: _set_steer_axis(0.0))

	# ── 右下：刹车（大热区）+ 其左上方的手刹/漂移 ──
	_btn_brake = _touch_button("Brake", "刹车",
		Vector2(TOUCH_BRAKE_SIZE, TOUCH_BRAKE_SIZE), TOUCH_BTN_BG_BRAKE, 34)
	_touch_layer.add_child(_btn_brake)
	_place_corner(_btn_brake, Control.PRESET_BOTTOM_RIGHT, Vector2(-TOUCH_MARGIN, -TOUCH_MARGIN))
	_btn_brake.button_down.connect(func() -> void: _set_brake(true))
	_btn_brake.button_up.connect(func() -> void: _set_brake(false))

	_btn_handbrake = _touch_button("Handbrake", "手刹",
		Vector2(TOUCH_HANDBRAKE_SIZE, TOUCH_HANDBRAKE_SIZE), TOUCH_BTN_BG_HANDBRAKE, 26)
	_touch_layer.add_child(_btn_handbrake)
	var hb_offset := TOUCH_MARGIN + TOUCH_BRAKE_SIZE + TOUCH_GAP
	_place_corner(_btn_handbrake, Control.PRESET_BOTTOM_RIGHT, Vector2(-hb_offset, -hb_offset))
	_btn_handbrake.button_down.connect(func() -> void: _set_handbrake(true))
	_btn_handbrake.button_up.connect(func() -> void: _set_handbrake(false))

	# ── 右上：重开 / 退出（横排，自右向左生长，否则会溢出屏幕右边缘） ──
	var action_row := HBoxContainer.new()
	action_row.name = "ActionRow"
	action_row.add_theme_constant_override("separation", int(TOUCH_GAP))
	action_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_touch_layer.add_child(action_row)
	_place_corner(action_row, Control.PRESET_TOP_RIGHT, Vector2(-TOUCH_MARGIN, TOUCH_MARGIN))
	var restart := _touch_button("RestartBtn", "↻ 重开", TOUCH_ACTION_SIZE, TOUCH_BTN_BG, 22)
	var exit_btn := _touch_button("ExitBtn", "✕ 退出", TOUCH_ACTION_SIZE, TOUCH_BTN_BG, 22)
	action_row.add_child(restart)
	action_row.add_child(exit_btn)
	# 这两个是「点一下」语义，用 pressed（按住语义只给驾驶按钮）。
	# 注意：_input 的多指兜底**不接管**它们——pressed 重复触发会重开两次。
	restart.pressed.connect(func() -> void: touch_restart_requested.emit())
	exit_btn.pressed.connect(func() -> void: touch_exit_requested.emit())
	# ── 面板让位 ──
	# 按钮占了底部两角与右上角，而键盘版面把这些面板正好摆在那里：油表/打滑在
	# 左下（=转向按钮）、本圈/最快圈在右上（=重开退出）。不挪的话比赛的圈速与
	# 油量会被按钮整块盖住，孩子看不到还剩几圈。
	_panel_bl.offset_bottom = -(TOUCH_MARGIN + TOUCH_STEER_SIZE + TOUCH_GAP)
	_panel_tr.offset_top = TOUCH_MARGIN + TOUCH_ACTION_SIZE.y + TOUCH_GAP
	_panel_tr.offset_bottom = _panel_tr.offset_top
	# 右下原本是键盘按键说明：触屏上换成触屏说明，并抬到手刹按钮之上。
	_hint_label.text = "◀ ▶ 转向　·　右下 刹车 / 手刹\n右上 重开 · 退出"
	_panel_br.offset_bottom = -(TOUCH_MARGIN + TOUCH_BRAKE_SIZE + TOUCH_GAP
		+ TOUCH_HANDBRAKE_SIZE + TOUCH_GAP)


## 把一个控件贴到屏幕角：margin 是到边缘的距离（右/下用负数）。控件按自己的
## custom_minimum_size 从锚点往里长（右/下贴边 → 向左/向上生长）。
func _place_corner(c: Control, preset: int, margin: Vector2) -> void:
	c.set_anchors_preset(preset)
	c.grow_horizontal = Control.GROW_DIRECTION_BEGIN if margin.x < 0.0 else Control.GROW_DIRECTION_END
	c.grow_vertical = Control.GROW_DIRECTION_BEGIN if margin.y < 0.0 else Control.GROW_DIRECTION_END
	c.offset_left = margin.x
	c.offset_right = margin.x
	c.offset_top = margin.y
	c.offset_bottom = margin.y


## 触屏按钮：圆角、半透明底、按下变亮。热区由 custom_minimum_size 决定
## （最小 96×56，主力按钮 132×132 —— 6~12 岁的手指没那么准）。
func _touch_button(node_name: String, text: String, min_size: Vector2, bg: Color,
		font_size: int) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.custom_minimum_size = min_size
	# 触屏按钮不给键盘焦点：手指一按就点亮焦点框，还会抢走手柄的焦点链。
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	b.add_theme_constant_override("outline_size", 6)
	var radius := int(minf(min_size.x, min_size.y) * 0.28)
	b.add_theme_stylebox_override("normal", _touch_style(bg, radius))
	b.add_theme_stylebox_override("hover", _touch_style(bg.lightened(0.10), radius))
	# 按下变亮：手指挡住按钮时，靠颜色变化告诉孩子「按到了」。
	b.add_theme_stylebox_override("pressed", _touch_style(bg.lightened(0.32), radius))
	b.add_theme_stylebox_override("disabled", _touch_style(bg, radius))
	return b


func _touch_style(bg: Color, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_border_width_all(2)
	s.border_color = TOUCH_BTN_EDGE
	s.set_content_margin_all(4.0)
	return s


## 触屏输入快照。active=false 表示没有触屏层（消费端走键盘路径）。
## steer: -1（左）~ +1（右），松手回 0；throttle 是**自动油门**（见下）。
func touch_input() -> Dictionary:
	var active := _touch_layer != null
	var throttle := 0.0
	var brake := 0.0
	if active:
		# 自动油门：手机上孩子只按左右就能开车（儿童向卡丁车的通行做法）。
		# 踩刹车时油门归零，避免「油门满 + 刹车满」两个满值同时喂给物理层。
		if _touch_brake:
			brake = 1.0
		else:
			throttle = 1.0
	return {
		"active": active,
		"steer": _touch_steer if active else 0.0,
		"throttle": throttle,
		"brake": brake,
		"handbrake": active and _touch_handbrake,
	}


## 转向轴（-1/0/+1）。没有触屏层时是空操作：键盘路径不该被这些调用影响。
func _set_steer_axis(v: float) -> void:
	if _touch_layer == null:
		return
	_touch_steer = clampf(v, -1.0, 1.0)


func _set_brake(on: bool) -> void:
	if _touch_layer == null:
		return
	_touch_brake = on


func _set_handbrake(on: bool) -> void:
	if _touch_layer == null:
		return
	_touch_handbrake = on


## 清空触屏输入状态。重开一场、切后台、或发现抬指事件丢失时调一次：
## 抬指事件被模态面板/系统面板吃掉后状态会残留，那辆车从这一刻起一直在刹车。
func clear_touch_input() -> void:
	_clear_touch_state()
	_down_touches.clear()


func _clear_touch_state() -> void:
	_touch_steer = 0.0
	_touch_brake = false
	_touch_handbrake = false
	_raw_owns.clear()


## 切后台/失焦时触摸序列一定是断的（Android 通知栏、来电、Home 键），
## 抬指事件不会再来——不清的话回来时车还在刹车。
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			if _touch_layer != null:
				clear_touch_input()


## 多点触控兜底：Godot 的 `emulate_mouse_from_touch`（默认开）只把**第一根**手指
## 翻译成鼠标事件，其余手指能不能到 Button 取决于 GUI 的触摸路由（不同版本/平台
## 表现不一）。「左拇指按住转向 + 右拇指点刹车」是这台车上最常用的组合，不能赌，
## 所以这里从 _input 拿原始触摸按 index 自己维护一份状态。
## 与按钮自身的 button_down/button_up 幂等（两边都只是把同一个状态量置位），
## 同一根手指被两条路径各处理一次也不会出错。重开/退出不参与（它们走 pressed，
## 重复触发会重开两次）——那两个按钮仍然是单指可用的。
##
## 抬指事件丢失的自愈（比赛途中的教学弹窗、切后台、别的节点 set_input_as_handled）：
##   ① 同一 index 又按下来 = 上一次抬指丢了（Android 复用 pointer id）→ 先清残留；
##   ② 一根手指都不在屏幕上时状态必须是零 → 硬清零；
##   ③ 失焦（_notification）→ 全清。
## 三条都不会误伤：状态只可能由「按下」置位，没有手指在屏幕上就一定是残留。
##
## ⚠ 这里**全程不调** `set_input_as_handled()`，以后也别加：`_input` 也收键鼠事件，
## 标记已处理会连带截断键盘的 race_exit/race_restart/race_lights/race_horn
## （带触屏的 Windows 平板/ChromeOS 上 ESC 与 R 会莫名失效），还会吃掉按钮的
## 按下视觉（Button 靠 GUI 那份事件）。真要防误触，只能在本分支内、且确实
## 消费掉某根手指时才调。
func _input(event: InputEvent) -> void:
	if _touch_layer == null:
		return
	var touch := event as InputEventScreenTouch
	if touch == null:
		return
	if touch.pressed:
		if _down_touches.has(touch.index):
			clear_touch_input()
		_down_touches[touch.index] = true
		var hit := _touch_hit(touch.position)
		if hit.is_empty():
			return
		_raw_owns[touch.index] = hit
		_apply_touch(hit, true)
		return
	_down_touches.erase(touch.index)
	if _raw_owns.has(touch.index):
		var owned := String(_raw_owns[touch.index])
		_raw_owns.erase(touch.index)
		_apply_touch(owned, false)
	if _down_touches.is_empty():
		_clear_touch_state()


## 命中测试：这个点落在哪个驾驶按钮上（重开/退出不参与，见 _input）。
func _touch_hit(pos: Vector2) -> String:
	if _steer_left != null and _steer_left.get_global_rect().has_point(pos):
		return "left"
	if _steer_right != null and _steer_right.get_global_rect().has_point(pos):
		return "right"
	if _btn_brake != null and _btn_brake.get_global_rect().has_point(pos):
		return "brake"
	if _btn_handbrake != null and _btn_handbrake.get_global_rect().has_point(pos):
		return "handbrake"
	return ""


func _apply_touch(hit: String, down: bool) -> void:
	match hit:
		"left":
			_set_steer_axis(-1.0 if down else 0.0)
		"right":
			_set_steer_axis(1.0 if down else 0.0)
		"brake":
			_set_brake(down)
		"handbrake":
			_set_handbrake(down)


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
	if r.car.slip_deg() > 9.0:
		# 触屏是自动油门，孩子没有「松一点油门」这个动作，得指一个做得到的。
		_slip_label.text = "打滑！点一下刹车" if _touch_layer != null else "打滑！松一点油门"
	else:
		_slip_label.text = ""


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
