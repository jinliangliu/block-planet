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
## 7 行增量清单（只放四角没有的读数，U-5）+ 始终显示小地图。
##
## 警告：六类警告按优先级取最高级，闪烁横幅 + 蜂鸣/语音呼号（AlertBeeper）。
## 注册的 3D 视图（座舱 3D 面板 / 世界标注）每帧也收到同一份 FlightInstruments。
##
## 飞行指引十字（D-054）：第一人称另有一枚 `FlightDirector` 覆盖层——中心白
## 准星是「机头现在指哪」，指引十字是「机头该指哪」，玩家把准星套进十字即
## 沿正确航径飞（起飞爬升角 / 进近 3° 下滑道 / 巡航航向）。它复用 HSI/CDI
## 的导航目标，与 3D 引导（箭头 + 下滑道双轨）互补：3D 引导只在追尾看得见，
## 十字段补的是座舱里缺失的那一层「当前偏了多少」。

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
## 飞行指引十字（D-054）：仅第一人称可见的航径指令标记（准星该往哪挪）。
var _fd: FlightDirector
## 失速教案激活中（D-071）：由 hud.gd 每帧推送。失速改出是安全关键指令，
## 指引的文字指令（「掉头」「抬头」）与教案实时冲突——「掉头」教孩子在失速
## 中坡，进近段的「抬头」更可能与「低头」字面相反。故教案激活时指引**整体
## 退场**（同帧生效，改出成功即刻恢复），refresh 仍继续跑（切换零重建成本，
## 且 _mode 状态不丢）。UI/UX 评估结论：儿童一次只听一个声音。
var _stall_coach_active := false
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
	# 飞行指引十字（D-054）：后加入 → 画在仪表簇之上（两者不重叠，但十字
	# 是「往哪飞」的即时指令，层级上应当最靠前）。
	_fd = FlightDirector.new()
	add_child(_fd)
	_fd.visible = false
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
	_instruments.reset_altitude_callouts()


func set_beeper(beeper: AlertBeeper) -> void:
	_beeper = beeper


## 整层收起（下机 / 坠机弹射 / 死亡退机，D-056）：tick 只在驾驶中驱动，
## 不显式隐藏的话座舱仪表簇会冻结在屏上——用户实测「坠机后人物没挂，
## 界面停留在驾驶舱画面」。再次登机由 tick 的 _apply_visibility 按视角恢复。
func hide_all() -> void:
	_hide_all()


func register_view(view: Node) -> void:
	if view != null and not _views.has(view):
		_views.append(view)


func unregister_view(view: Node) -> void:
	_views.erase(view)


func instruments_ref() -> FlightInstruments:
	return _instruments


func set_navigation(target: Vector3, name: String = "") -> void:
	_instruments.set_navigation(target, name)
	# 飞行指引十字吃同一份导航目标（D-054）：不另开注入口，HSI/CDI/3D 标注
	# 与本十字永远指向同一个点，不会出现「仪表指 A、指引指 B」。
	if _fd != null:
		_fd.set_guide(target)


func clear_navigation() -> void:
	_instruments.clear_navigation()
	if _fd != null:
		_fd.clear_guide()


## 失速教案激活状态（D-071）：hud.gd 每帧推送。见 _stall_coach_active 注释。
func set_stall_coach_active(active: bool) -> void:
	_stall_coach_active = active


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
	# 进近高度呼号（U-10）：独立通道，不被警告的「只播最高级」合并。
	var callouts := _instruments.take_altitude_callouts()
	if not callouts.is_empty() and FlightSettings.current().beeper_enabled and _beeper != null:
		for _h in callouts:
			_beeper.play_cue(FlightInstruments.BEEP_CODES["alt_call"])
	for h in callouts:
		Events.notice.emit("📢 %d 米" % int(h))
	var mode := AircraftCamera.ViewMode.CHASE
	if _camera != null and _camera.has_method("current_mode"):
		mode = _camera.current_mode()
	_apply_visibility(mode)
	_refresh_chase()
	if _cockpit.visible:
		_cockpit.refresh(_instruments)
	# 飞行指引十字（D-054）：与座舱同视角。必须先 refresh 再判可见——mode
	# 由 refresh 依空速/离地高度/距离算出，无目标或停机时它是 OFF。
	# D-071：失速教案激活时整体退场（只锁 visible，refresh 照跑）——文字指令
	# 与教案实时冲突，且「掉头」教失速中坡度有真实风险；恢复由 hud 推送
	# false 自动完成。HSI/CDI/小地图/3D 标注不退场（无文字指令、无冲突），
	# 玩家仍知道目标在哪，改出成功后指引即刻归位。
	if _fd != null:
		if _cockpit.visible and _craft != null:
			_fd.refresh(_craft.global_position, _instruments)
		_fd.visible = (_cockpit.visible
			and not _stall_coach_active
			and _fd.current_mode() != FlightDirector.Mode.OFF)
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
	# D-049：座舱视角下隐藏 7 行增量清单——座舱仪表簇（地平仪/ALT/航向带/
	# SPD）就是座舱面板本身，文字清单与它大面积重复且抢注意力；追尾/后视/
	# 环顾等「机体在屏外」的视角才需要文字增量读数。地图/回放同样不显示。
	_panel.visible = detail and not map_like and not fp
	# 警告横幅：有警告且非地图/回放时显示（_refresh_warn 再细化内容）。
	# U-6 / D-069：失速类走 banner_alerts() 排除——权威文字通道是 hud.gd 教练区
	# 里的 StallCoach 状态机文案（带【↓】的改出教案），本横幅对失速让位、
	# 只报其余警告。（原「卡片失速行」已随 U-8 删除，勿再按旧名寻找。）
	var has_alerts := not _instruments.banner_alerts().is_empty()
	_warn.visible = has_alerts and not map_like
	# 横幅位置（D-052）：座舱视角卡片已挪到左上，横幅回到顶部中央（最醒目
	# 且不挡视野）；追尾视角卡片占顶部中央 y16~221（含教练区），横幅必须
	# 压在它下沿之下——首版固定 y150..190 与卡片直接对穿，实测「发动机
	# 运转」和「失速了！推杆低头」叠成一团。
	_warn.offset_top = 16.0 if fp else 240.0
	_warn.offset_bottom = _warn.offset_top + 40.0


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
	if _fd != null:
		_fd.visible = false


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


# ── 详细清单（追尾等机体在屏外视角的增量读数，U-5 后为 7 行）──
# U-5 / D-069：原 12 行「全读」与追尾四角信息大面积重复，现只保留四角没有的
# 增量读数（失速余量 / 姿态 / 离地 / 转弯率 / 导航 CDI / 转速 / 襟翼·起落架）。
func _build_panel() -> void:
	_panel = Control.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.anchor_left = 0.0; _panel.anchor_top = 0.0
	_panel.anchor_right = 0.0; _panel.anchor_bottom = 1.0
	_panel.offset_left = 16.0
	_panel.offset_right = 280.0
	# U-5：面板顶边从 y120 下移到 y200——让出左上角空速/航向角（y120..184，
	# 与本面板同一条 x16 左缘）。D-046 遗留①：_panel 是 _chase 的后置兄弟节点，
	# 两处文字互相叠画；生命/饥饿读数块占 y16~100，本面板只在 H 详细模式出现，
	# 非详细模式四角位置不受影响。
	_panel.offset_top = 200.0
	_panel.offset_bottom = -190.0
	add_child(_panel)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 2)
	_panel.add_child(box)
	# U-5：12 行全读数 → 7 行增量清单。空速/航向/MSL 高度/升降率/燃油与追尾
	# 四角同文（_refresh_chase），雷达高度与离地本是同一个 altitude_agl 合并
	# 为一行，警告行与全宽横幅同源同文（横幅是警告权威通道，U-6）。文案由静态
	# 纯函数 panel_row_texts() 生成——无头探针直接断言，节点层只上屏。
	var titles := [
		"失速余量", "姿态（俯仰/坡度）", "离地高度",
		"转弯率 / 协调", "导航 CDI", "转速", "襟翼 / 起落架",
	]
	for t in titles:
		var l := _mk_label(box, 15, COL_NORMAL)
		l.text = t + "：—"
		_panel_rows.append(l)


## 详细清单 7 行文案（U-5）：静态纯函数——无头探针直接断言，节点层只上屏。
## 定位「四角没有的增量信息」：空速/航向/MSL 高度/升降率/燃油已在追尾四角
## （_refresh_chase）；雷达高度与离地本是同一个 altitude_agl，合并为一行；
## 警告行与全宽横幅同源同文，整体撤掉（横幅是警告权威通道，见 U-6）。
static func panel_row_texts(fi: FlightInstruments) -> Array[String]:
	var out: Array[String] = []
	# U-5 后续项（D-069 目检）：地面滑速必低于失速速度，负余量是物理事实而非
	# 预警——常显「-20 km/h」会让儿童以为马上要掉下来。离地前给「—（地面）」，
	# 越过 AIRBORNE_AGL（2 m）后才给数值（is_airborne 同口径）。
	if fi.is_airborne():
		out.append("失速余量：%+.0f km/h" % fi.airspeed_margin_kmh)
	else:
		out.append("失速余量：—（地面）")
	out.append("姿态：俯仰 %+.0f°  坡度 %+.0f°" % [fi.pitch_deg, fi.roll_deg])
	out.append("离地：%d m" % int(fi.altitude_agl))
	out.append("转弯率：%+.1f°/s（标准率 %s）" % [fi.turn_rate_deg_s,
		"●" if fi.standard_rate else "○"])
	if fi.nav_active:
		out.append("CDI：%+.0f°（%s）" % [fi.nav_dev_deg,
			"TO" if fi.nav_to_flag else "FROM"])
	else:
		out.append("CDI：—")
	out.append("转速：%d rpm（%d%%）" % [int(fi.rpm), int(fi.rpm_pct * 100.0)])
	out.append("襟翼：%d 档   起落架：%s" % [fi.flaps,
		"放下↓" if fi.gear_down else "收起"])
	return out


func _refresh_panel() -> void:
	if not _panel.visible:
		return
	var fi := _instruments
	var texts := panel_row_texts(fi)
	for i in texts.size():
		_panel_rows[i].text = texts[i]
	# 第 0 行是清单里唯一的状态行：失速/超速时整行变红（原 r0 行为保留）。
	_panel_rows[0].add_theme_color_override("font_color",
		COL_WARN if (fi.overspeed or fi.stalled) else COL_NORMAL)


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
	# U-6 / D-069：banner_alerts() 已剔除失速类（StallCoach 经教练区渲染的
	# 改出教案是权威文字通道；原「卡片失速行」已随 U-8 删除）。
	var al := _instruments.banner_alerts()
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
