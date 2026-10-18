class_name FlightInstrumentHUD
extends Control
## 屏幕飞行仪表 HUD（D-034）：把 FlightInstruments 的加工读数呈现为屏幕覆盖层。
##
## 视角分发（按 AircraftCamera.current_mode）：
##   第一人称座舱 → 中心准星 + 座舱仪表簇（地平仪/高度计/航向仪，D-047 的
##      CockpitInstruments；D-034 的玻璃三行文字带被它替换）
##   第三人称追尾/后视/环顾 → 屏幕四角 HUD（速度/高度/油门 + 目标）+ 小地图
##   地图(M)/回放(R) → 由战术地图/回放覆盖层接管，本 HUD 隐藏
##
## 简单/详细模式（FlightSettings.hud_detail，H 键切换落盘）：详细模式追加左侧
## 12 仪表全清单 + 始终显示小地图。
##
## 警告：六类警告按优先级取最高级，闪烁横幅 + 蜂鸣/语音呼号（AlertBeeper）。
## 注册的 3D 视图（座舱 3D 面板 / 世界标注）每帧也收到同一份 FlightInstruments。

const COL_NORMAL := Color(1.0, 1.0, 1.0, 0.95)
const COL_WARN := Color(1.0, 0.42, 0.36)
const COL_CAUTION := Color(0.98, 0.82, 0.30)
const COL_GOOD := Color(0.45, 0.95, 0.55)

var _craft: Aircraft = null
var _camera: AircraftCamera = null
var _beeper: AlertBeeper = null
var _instruments := FlightInstruments.new()
var _views: Array[Node] = []

# ── 屏幕节点 ──
var _glass: Control
var _chase: Control
var _panel: Control
var _warn: Control
var _minimap: _Minimap
## 座舱仪表簇（D-047）：仅第一人称可见的地平仪/高度计/航向仪。
var _cockpit: CockpitInstruments
# 追尾四角
var _c_tl: Label
var _c_tr: Label
var _c_bl: Label
var _c_br: Label
# 详细清单行
var _panel_rows: Array[Label] = []
# 警告横幅
var _warn_label: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_glass()
	_build_chase()
	_build_panel()
	_build_warn()
	# 座舱仪表簇（D-047）：第一人称才显形，数据在 tick 里喂。
	_cockpit = CockpitInstruments.new()
	add_child(_cockpit)
	_minimap = _Minimap.new()
	_minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_minimap.custom_minimum_size = Vector2(160.0, 160.0)
	_minimap.size = Vector2(160.0, 160.0)
	# 右下角固定尺寸（四锚全 1 + 负偏移）：锚点漏设 left/top 会把矩形撑成全屏。
	_minimap.anchor_left = 1.0
	_minimap.anchor_top = 1.0
	_minimap.anchor_right = 1.0
	_minimap.anchor_bottom = 1.0
	_minimap.offset_left = -176.0
	_minimap.offset_top = -176.0
	_minimap.offset_right = -16.0
	_minimap.offset_bottom = -16.0
	add_child(_minimap)
	_hide_all()


func setup(craft: Aircraft, camera: AircraftCamera) -> void:
	_craft = craft
	_camera = camera
	_instruments.reset_voice_cues()


func set_beeper(beeper: AlertBeeper) -> void:
	_beeper = beeper


func register_view(view: Node) -> void:
	if view != null and not _views.has(view):
		_views.append(view)


func unregister_view(view: Node) -> void:
	_views.erase(view)


func instruments_ref() -> FlightInstruments:
	return _instruments


func set_navigation(target: Vector3, name: String = "") -> void:
	_instruments.set_navigation(target, name)


func clear_navigation() -> void:
	_instruments.clear_navigation()


## 每帧驱动：读快照 → 加工 → 蜂鸣 → 按视角分发 → 刷视图 → 刷 3D 视图。
func tick(delta: float) -> void:
	if _craft == null or not is_instance_valid(_craft):
		_hide_all()
		return
	var snap := _craft.snapshot()
	var basis := _craft.global_transform.basis
	_instruments.update(snap, basis, delta)
	# 蜂鸣：始终消费提示以维持重播计时，仅在开关开启时真正播放。
	var cues := _instruments.take_voice_cues(delta)
	if FlightSettings.current().beeper_enabled and _beeper != null:
		for cue in cues:
			_beeper.play_cue(cue["beep"])
	var mode := AircraftCamera.ViewMode.CHASE
	if _camera != null and _camera.has_method("current_mode"):
		mode = _camera.current_mode()
	_apply_visibility(mode)
	_refresh_chase()
	if _cockpit.visible:
		_cockpit.refresh(_instruments)
	if _panel.visible:
		_refresh_panel()
	_refresh_minimap(mode)
	_refresh_warn()
	for v in _views:
		if v != null and v.has_method("refresh_instruments"):
			v.refresh_instruments(_instruments)


func _apply_visibility(mode: int) -> void:
	var fp := mode == AircraftCamera.ViewMode.FIRST_PERSON
	var chase := mode in [AircraftCamera.ViewMode.CHASE, AircraftCamera.ViewMode.REAR,
		AircraftCamera.ViewMode.FREE_LOOK]
	var map_like := mode in [AircraftCamera.ViewMode.MAP, AircraftCamera.ViewMode.REPLAY]
	_glass.visible = fp
	_chase.visible = chase
	_cockpit.visible = fp
	_minimap.visible = chase
	var detail := FlightSettings.current().hud_detail
	_panel.visible = detail and not map_like
	# 警告横幅：有警告且非地图/回放时显示（_refresh_warn 再细化内容）。
	var has_alerts := not _instruments.alerts().is_empty()
	_warn.visible = has_alerts and not map_like


func _hide_all() -> void:
	if _glass != null:
		_glass.visible = false
	if _chase != null:
		_chase.visible = false
	if _panel != null:
		_panel.visible = false
	if _minimap != null:
		_minimap.visible = false
	if _warn != null:
		_warn.visible = false
	if _cockpit != null:
		_cockpit.visible = false


# ── 第一人称座舱：中心准星（D-047 起文字读数交给座舱仪表簇）──
func _build_glass() -> void:
	_glass = Control.new()
	_glass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glass.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_glass)
	# 中心准星（两道细条）。D-034 原有的底部三行文字读数（速度/高度/航向）
	# 已由 D-047 的座舱仪表簇（地平仪 + 高度计 + 航向仪 + SPD 框）接管，
	# 不再重复显示；准星是瞄点参考，保留。
	var h := ColorRect.new()
	h.color = Color(1.0, 1.0, 1.0, 0.6)
	h.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	h.offset_left = -18.0; h.offset_right = 18.0
	h.offset_top = -1.5; h.offset_bottom = 1.5
	_glass.add_child(h)
	var v := ColorRect.new()
	v.color = Color(1.0, 1.0, 1.0, 0.6)
	v.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	v.offset_left = -1.5; v.offset_right = 1.5
	v.offset_top = -18.0; v.offset_bottom = 18.0
	_glass.add_child(v)


# ── 第三人称四角 HUD ──
func _build_chase() -> void:
	_chase = Control.new()
	_chase.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chase.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_chase)
	# TL 下移避让左上角的生命/饥饿读数（约 90 px 高）。
	_c_tl = _mk_corner(_chase, 0, 120.0)
	_c_tr = _mk_corner(_chase, 1, 16.0)
	_c_bl = _mk_corner(_chase, 2, 16.0)
	_c_br = _mk_corner(_chase, 3, 16.0)


func _refresh_chase() -> void:
	if not _chase.visible:
		return
	_c_tl.text = "空速  %d km/h\n航向  %03d°" % [
		int(_instruments.airspeed_kmh), int(_instruments.heading_deg)]
	var aw := _instruments.overspeed or _instruments.stalled
	_c_tl.add_theme_color_override("font_color", COL_WARN if aw else COL_NORMAL)
	_c_tr.text = "高度  %d m\n升降  %+.1f m/s" % [
		int(_instruments.altitude_msl), _instruments.vertical_speed]
	_c_bl.text = "油门  %d%%\n燃油  %d%%" % [
		int(_instruments.throttle * 100.0), int(_instruments.fuel_ratio * 100.0)]
	_c_bl.add_theme_color_override("font_color",
		COL_CAUTION if _instruments.fuel_low else COL_NORMAL)
	if _instruments.nav_active:
		_c_br.text = "目标  %03d°\n%.0f m" % [
			int(_instruments.nav_bearing_deg), _instruments.nav_distance_m]
	else:
		_c_br.text = "目标  —"


# ── 详细清单（左侧 12 仪表全读）──
func _build_panel() -> void:
	_panel = Control.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.anchor_left = 0.0; _panel.anchor_top = 0.0
	_panel.anchor_right = 0.0; _panel.anchor_bottom = 1.0
	_panel.offset_left = 16.0
	_panel.offset_right = 280.0
	# 与 _c_tl 共用同一条让位线（120）：左上角生命/饥饿读数块（姓名 + 爱心 + 饥饿）
	# 占 y16~100，飞行中不再隐藏，故左上角一切元素统一从 y120 起，留出 20 px 间隙。
	# 本面板与读数块同为 offset_left=16，横向完全重合，间距不足会直接贴脸。
	_panel.offset_top = 120.0
	_panel.offset_bottom = -190.0
	add_child(_panel)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 2)
	_panel.add_child(box)
	var titles := [
		"空速 / 失速余量", "姿态（俯仰/坡度）", "高度 MSL / 离地",
		"转弯率 / 协调", "航向", "升降率", "HSI 方位 / CDI",
		"雷达高度", "发动机转速", "燃油", "襟翼 / 起落架", "警告",
	]
	for t in titles:
		var l := _mk_label(box, 14, COL_NORMAL)
		l.text = t + "：—"
		_panel_rows.append(l)


func _refresh_panel() -> void:
	if not _panel.visible:
		return
	var r := _panel_rows
	var fi := _instruments
	r[0].text = "空速 / 失速余量：%d km/h（余 %+.0f）" % [
		int(fi.airspeed_kmh), fi.airspeed_margin_kmh]
	r[0].add_theme_color_override("font_color",
		COL_WARN if (fi.overspeed or fi.stalled) else COL_NORMAL)
	r[1].text = "姿态：俯仰 %+.0f°  坡度 %+.0f°" % [fi.pitch_deg, fi.roll_deg]
	r[2].text = "高度：MSL %d m / 离地 %d m" % [int(fi.altitude_msl), int(fi.altitude_agl)]
	r[3].text = "转弯率：%+.1f°/s（标准率 %s）" % [fi.turn_rate_deg_s,
		"●" if fi.standard_rate else "○"]
	r[4].text = "航向：%03d°" % int(fi.heading_deg)
	r[5].text = "升降率：%+.1f m/s" % fi.vertical_speed
	r[6].text = "HSI：方位 %03d°  CDI %+.0f°（%s）" % [
		int(fi.nav_bearing_deg), fi.nav_dev_deg, "TO" if fi.nav_to_flag else "FROM"]
	r[7].text = "雷达高度：%d m" % int(fi.altitude_agl)
	r[8].text = "转速：%d rpm（%d%%）" % [int(fi.rpm), int(fi.rpm_pct * 100.0)]
	r[9].text = "燃油：%d / %d L（%d%%）" % [
		int(fi.fuel_liters), int(fi.fuel_capacity), int(fi.fuel_ratio * 100.0)]
	r[9].add_theme_color_override("font_color",
		COL_CAUTION if fi.fuel_low else (COL_WARN if fi.fuel_empty else COL_NORMAL))
	r[10].text = "襟翼：%d 档   起落架：%s" % [fi.flaps, "放下↓" if fi.gear_down else "收起"]
	var al := fi.alerts()
	r[11].text = "警告：" + (al[0]["text"] if not al.is_empty() else "无")
	r[11].add_theme_color_override("font_color",
		COL_WARN if (not al.is_empty() and al[0]["level"] == FlightInstruments.AlertLevel.WARNING)
		else (COL_CAUTION if not al.is_empty() else COL_GOOD))


# ── 警告横幅 ──
func _build_warn() -> void:
	_warn = Control.new()
	_warn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_warn.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_warn.offset_top = 150.0
	_warn.offset_bottom = 190.0
	add_child(_warn)
	_warn_label = Label.new()
	_warn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_warn_label.add_theme_font_size_override("font_size", 22)
	_warn_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	_warn_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_warn.add_child(_warn_label)


func _refresh_warn() -> void:
	var al := _instruments.alerts()
	if al.is_empty():
		_warn.visible = false
		return
	_warn.visible = true
	var top: Dictionary = al[0]
	_warn_label.text = "⚠ " + String(top["text"])
	var is_warn := int(top["level"]) == FlightInstruments.AlertLevel.WARNING
	var base := COL_WARN if is_warn else COL_CAUTION
	# 闪烁：600ms 周期。
	var phase := fmod(Time.get_ticks_msec(), 600.0) / 600.0
	var blink := 0.45 + 0.55 * absf(sin(phase * PI))
	_warn_label.add_theme_color_override("font_color",
		Color(base.r, base.g, base.b, blink))


func _refresh_minimap(mode: int) -> void:
	if not _minimap.visible:
		return
	_minimap._heading = _instruments.heading_deg
	_minimap._nav_active = _instruments.nav_active
	_minimap._nav_bearing = _instruments.nav_bearing_deg
	_minimap._nav_dist = _instruments.nav_distance_m
	_minimap.queue_redraw()


func _mk_label(parent: Control, size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)
	return l


func _mk_corner(parent: Control, corner: int, margin: float) -> Label:
	# corner: 0=TL 1=TR 2=BL 3=BR。固定尺寸框贴角，文字左/右对齐。
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", COL_NORMAL)
	l.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	l.add_theme_constant_override("outline_size", 4)
	var w := 230.0
	var h := 64.0
	if corner == 0:  # 左上
		l.anchor_left = 0.0; l.anchor_top = 0.0; l.anchor_right = 0.0; l.anchor_bottom = 0.0
		l.offset_left = margin; l.offset_top = margin
		l.offset_right = margin + w; l.offset_bottom = margin + h
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	elif corner == 1:  # 右上
		l.anchor_left = 1.0; l.anchor_top = 0.0; l.anchor_right = 1.0; l.anchor_bottom = 0.0
		l.offset_right = -margin; l.offset_top = margin
		l.offset_left = -margin - w; l.offset_bottom = margin + h
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	elif corner == 2:  # 左下
		l.anchor_left = 0.0; l.anchor_top = 1.0; l.anchor_right = 0.0; l.anchor_bottom = 1.0
		l.offset_left = margin; l.offset_bottom = -margin
		l.offset_right = margin + w; l.offset_top = -margin - h
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	else:  # 右下
		l.anchor_left = 1.0; l.anchor_top = 1.0; l.anchor_right = 1.0; l.anchor_bottom = 1.0
		l.offset_right = -margin; l.offset_bottom = -margin
		l.offset_left = -margin - w; l.offset_top = -margin - h
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	parent.add_child(l)
	return l


## 小地图（北朝上）：中心三角 = 本机（指向航向），外圈 = 机场/导航目标方位点。
class _Minimap extends Control:
	var _heading := 0.0
	var _nav_active := false
	var _nav_bearing := 0.0
	var _nav_dist := 0.0

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.46
		draw_circle(c, r, Color(0.04, 0.06, 0.09, 0.55))
		draw_arc(c, r, 0.0, TAU, 48, Color(0.7, 0.8, 0.9, 0.6), 2.0, true)
		# 北标记。
		draw_string(ThemeDB.fallback_font, c + Vector2(-5.0, -r + 14.0), "N",
			HORIZONTAL_ALIGNMENT_CENTER, -1, 16, Color(0.9, 0.95, 1.0))
		# 本机三角（机头指向航向；北朝上，故屏幕角 = 航向 - 90°）。
		var a := deg_to_rad(_heading - 90.0)
		var tip := c + Vector2(cos(a), sin(a)) * (r - 12.0)
		var left := c + Vector2(cos(a + 2.6), sin(a + 2.6)) * 9.0
		var right := c + Vector2(cos(a - 2.6), sin(a - 2.6)) * 9.0
		draw_colored_polygon(PackedVector2Array([tip, left, right]), Color(1.0, 0.85, 0.3))
		# 导航/机场方位点（北朝上，同换算）。
		if _nav_active:
			var na := deg_to_rad(_nav_bearing - 90.0)
			var p := c + Vector2(cos(na), sin(na)) * (r - 14.0)
			draw_circle(p, 7.0, Color(0.4, 0.9, 0.5))
