class_name CockpitPanel
extends Node3D
## 第一人称座舱 3D 仪表盘（D-034 / L2 反转，feature_cockpit_3d §6）：
## 12 项仪表画进一个 SubViewport，再经 ViewportTexture 贴到座舱仪表板平面上。
##
## L2 反转：第一人称下**不再隐藏**。正视时这块板的投影精确落在 2D 座舱仪表簇
## 的 dash 板内、被那块不透明的像素板完全盖住（「重合」= 同一位置同一块板，
## 玩家看不到第二套读数）；自由观察时 2D 簇由 flight_instrument_hud 自动隐藏
## （_cockpit.visible = fp），这块板就是世界里的仪表台——L2 的兑现点。
## 第一人称相机与面板同属机体坐标系 ⇒ 相对位姿恒定，投影与飞机姿态无关，
## 所以「对齐」是一次性静态标定，不是逐帧跟踪。
##
## 可见性只剩一道闸门：蓝图机契约（blueprint_built 无座舱罩，不建几何、隐藏）。
## 旧的「内视即隐藏」层（D-050 的 _interior_view / set_interior_view）已删。
##
## 无光照（unshaded）直出 albedo 贴图：座舱里不靠外部光，即便背光也清晰可读
## （相当于原「自发光」语义，且少一遍光照计算）。

# ── 面板物理落位（唯一事实源：geo3d 的 CockpitInterior 直接引用这四个常量）──
## 0.98×0.215 m = 4.56:1，不是随手放大的：4.56:1 的板在 34° 斜视（眼位→面板
## 28.07° + 座舱视线上仰 6.26°）下纵向被压约一成，投影约 3.9:1，正好对上 2D
## dash 带（636×181.3 @1280×720，见 CockpitInstruments.metrics()）的可见区；
## 若沿用旧 0.32×0.20（1.6:1）等比放大，会在 dash 上下溢出。
const PANEL_W := 0.98
const PANEL_H := 0.215
## 机体局部位置：眼位 (0, 1.15, -3.4) 前方 0.75 m、下方 0.40 m（aircraft_camera.gd:29）。
const PANEL_POS := Vector3(0.0, 0.75, -4.15)
## 绕 X 轴倾角：法线指向眼位（atan(0.40/0.75)=28.07°，取 -27.8° 与反解投影一致）。
## 于是自由观察低头约 28° 时面板正对且居中——「读仪表」的自然姿态。
const PANEL_TILT_DEG := -27.8

## SubViewport 768×168（4.57:1）——与 PANEL_W/H 匹配。旧的 1024×640 是 1.6:1，
## 与 dash 带对不上；且反转后面板常显，768×168 的像素量只有它的五分之一。
const VP_SIZE := Vector2i(768, 168)
## 重绘节流 30 Hz：指针与数字以 0.03 s 步进肉眼无停顿；常显时省下 60 Hz 的
## 7 盘 4 条重绘与一次离屏渲染（中低端 Android 的帧预算）。
const RENDER_INTERVAL_MS := 33

# ── 768×168 内容布局（内容与贴图 1:1，唯一事实源）──────────────────
## 7 盘一行：92 px 盘径（屏上约 60 px，瞥读够用；精读归 2D 簇——D-053 纪律）。
const DIAL_SZ := 92.0
const DIAL_STEP := 110.0   # 盘宽 + 18 px 间距
const DIAL_X0 := 8.0
const DIAL_Y := 10.0
## 4 数字条一行：48 px 高 = 标题 14 px + 数值 20 px（字号不低于 14 的儿童向下限）。
const LCD_W := 175.0
const LCD_H := 48.0
const LCD_STEP := 191.0    # 格宽 + 16 px 间距
const LCD_X0 := 10.0
const LCD_Y := 108.0

var _dials := {}
var _lcds := {}
var _subviewport: SubViewport = null
var _dashboard_material: StandardMaterial3D = null
## 基础可见性（蓝图机契约 = false：无座舱罩几何，setup 早退不建任何节点）。
## L2 反转后这是唯一闸门——「内视即隐藏」层已删，非蓝图机恒显。
var _base_visible := true
## 上次重绘时刻（ms）。初值 -1000 保证第一次 refresh 必定渲染一帧。
var _last_render_ms := -1000
## 贴图是否已在首帧渲染后重绑过一次（白屏修复的保险 ③，见 _build_cluster）。
var _tex_rebound := false


func setup(craft: Node) -> void:
	# 蓝图机无座舱罩几何：按契约隐藏、不建任何节点。
	if craft != null and "blueprint_built" in craft and bool(craft.get("blueprint_built")):
		_base_visible = false
		visible = false
		return
	_build_cluster()
	# L2 反转：非蓝图机在第一人称也显示——正视被 2D dash 盖住，自由观察即世界仪表台。
	visible = _base_visible


func _build_cluster() -> void:
	_subviewport = SubViewport.new()
	_subviewport.size = VP_SIZE
	# 不透明底：板面铺满，材质也就用不透明——Mobile 上省 alpha 混合与透明排序，
	# 也避免与风挡玻璃 / 机身透明层抢排序。
	_subviewport.transparent_bg = false
	_subviewport.name = "CockpitSubViewport"
	add_child(_subviewport)
	# 更新模式必须在**进树之后**设：未进树时设，某些版本会在首次渲染前被重置。
	# 平时 DISABLED；refresh_instruments 每 33 ms 唤醒一次 UPDATE_ONCE（渲染一帧
	# 后自动回 DISABLED），本函数末尾另敲一次首帧，保证首帧就有内容。
	_subviewport.render_target_update_mode = SubViewport.UPDATE_DISABLED

	var cluster := Control.new()
	cluster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cluster.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_subviewport.add_child(cluster)

	# 板面先铺底：仪表画在其上（视觉上「嵌在金属板里」，与 2D dash 同语言）。
	var plate := _Plate.new()
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cluster.add_child(plate)

	# 7 盘一行。标题只留中文短名：「空速 km/h」这类带单位的标题在 92 px 的盘上
	# 会贴边（InstrumentDial 的标题字号固定 18 px，不能逐实例调）；单位信息由
	# 2D 簇承担——它才是精读层。
	var dial_keys: Array[String] = [
		"airspeed", "attitude", "altitude", "heading", "turn", "vsi", "hsi"]
	var dial_modes: Array[int] = [
		InstrumentDial.Mode.CIRCULAR, InstrumentDial.Mode.ATTITUDE,
		InstrumentDial.Mode.CIRCULAR, InstrumentDial.Mode.CIRCULAR,
		InstrumentDial.Mode.CIRCULAR, InstrumentDial.Mode.CIRCULAR,
		InstrumentDial.Mode.HSI]
	var dial_titles: Array[String] = [
		"空速", "姿态", "高度", "航向", "转弯率", "升降率", "HSI"]
	for i in range(dial_keys.size()):
		var d := InstrumentDial.new()
		d.mode = dial_modes[i]
		d.set_title(dial_titles[i])
		d.custom_minimum_size = Vector2(DIAL_SZ, DIAL_SZ)
		d.size = Vector2(DIAL_SZ, DIAL_SZ)
		d.position = Vector2(DIAL_X0 + float(i) * DIAL_STEP, DIAL_Y)
		cluster.add_child(d)
		_dials[dial_keys[i]] = d

	# 4 数字条（LCD）：离地 / 转速 / 燃油 / 襟翼·起落架。
	var lcd_keys: Array[String] = ["radar", "rpm", "fuel", "flaps"]
	var lcd_titles: Array[String] = ["离地 m", "转速 rpm", "燃油 %", "襟翼/起落架"]
	for i in range(lcd_keys.size()):
		var lcd := _make_lcd(lcd_titles[i])
		lcd.position = Vector2(LCD_X0 + float(i) * LCD_STEP, LCD_Y)
		lcd.size = Vector2(LCD_W, LCD_H)
		cluster.add_child(lcd)
		_lcds[lcd_keys[i]] = lcd

	# 仪表板平面（贴 ViewportTexture，unshaded 直出）。
	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.orientation = PlaneMesh.FACE_Z
	pm.size = Vector2(PANEL_W, PANEL_H)
	plane.mesh = pm
	plane.position = PANEL_POS
	# 法线朝 +Z（机体后方、朝飞行员）：-27.8° 让板面正对眼位。
	plane.rotation.x = deg_to_rad(PANEL_TILT_DEG)
	plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	# **无光照（unshaded）+ albedo 贴图直出**，不走 emission 通道。
	# 上一版是「黑 albedo + emission 贴图」，窗口实测整块纯白：探针查明
	# SubViewport 内容确实是对的深色（get_image 读到盘面 0.047 / 板面 0.086）、
	# 材质对象也对，但画面没采样到那张图——而 emission 一旦没采样到纹理就退化
	# 成 emission_color × energy = (1,1,1) × 1.0 = **纯白**，正是看到的白板。
	# 三处保险一起上，任一处生效即可：
	#   ① 不走发光通道（unshaded 直出 albedo 贴图；座舱内不靠外部光，等价于原
	#      「自发光」语义，还省一遍光照计算）；
	#   ② 材质**带着纹理一次性成形**后才挂到网格——避开「先编译无纹理变体、
	#      后补纹理」这条路径（最可能的根因）；
	#   ③ 首帧渲染后再重绑一次贴图（refresh_instruments 里的 _tex_rebound），
	#      兜「SubViewport 的 RT 在首次渲染时才建立、纹理 RID 晚于材质成形」。
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 1.0, 1.0)
	mat.albedo_texture = _subviewport.get_texture()
	plane.set_surface_override_material(0, mat)
	plane.name = "Dashboard"
	add_child(plane)
	_dashboard_material = mat
	# 首帧必绘：SubViewport 从未渲染过时纹理内容未初始化（采样可退化成白）。
	# 敲一次 UPDATE_ONCE 保证第一张 HUD tick 之前板面就有内容。
	_subviewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_last_render_ms = Time.get_ticks_msec()   # 这一笔算首帧，30 Hz 节流从此刻起算


func _make_lcd(title: String) -> Control:
	var box := Control.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := ColorRect.new()
	# 不透明底（材质已改 OPAQUE）：透明底会让整块板在 Mobile 上走 alpha 混合。
	bg.color = Color(0.04, 0.06, 0.09, 1.0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_child(bg)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 14)     # 字号下限（儿童向可读）
	t.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	t.position = Vector2(6.0, 1.0)
	box.add_child(t)
	var v := Label.new()
	v.add_theme_font_size_override("font_size", 20)
	v.add_theme_color_override("font_color", Color(0.40, 0.95, 0.55))
	v.position = Vector2(6.0, 20.0)
	box.add_child(v)
	box.set_meta("value", v)
	return box


## 每帧从 FlightInstruments 喂数据（由 FlightInstrumentHUD.tick 经 register_view
## 调用，flight_instrument_hud.gd:169-171）。方法名与签名不能变：main.gd:249
## 注册、HUD 每帧按名调用。
func refresh_instruments(fi: FlightInstruments) -> void:
	if not visible or _dials.is_empty():
		return
	# 30 Hz 全链路节流（喂数 + 控件重绘 + 离屏渲染一起节）：反转后面板常显，
	# 60 Hz 喂 7 盘 4 条是白烧；30 Hz 下指针与数字步进 0.03 s，肉眼无停顿。
	var now := Time.get_ticks_msec()
	if now - _last_render_ms < RENDER_INTERVAL_MS:
		return
	_last_render_ms = now
	_subviewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	# 保险 ③（白屏修复）：SubViewport 的 RT 在**首次渲染时**才建立，纹理 RID
	# 可能晚于材质成形——此处在已经渲染过至少一帧之后重绑一次，成本为零。
	# 若日后确认根因是「材质成形顺序」（保险 ②）而这条无用，删这三行即可，
	# 窗口图能立刻分辨（lead 用来 A/B 定根因）。
	if not _tex_rebound:
		_tex_rebound = true
		_dashboard_material.albedo_texture = _subviewport.get_texture()
	var warn := fi.overspeed or fi.stalled
	# 圆形盘。
	var as_d: InstrumentDial = _dials["airspeed"]
	as_d.set_reading(fi.airspeed_kmh, 0.0, 300.0)
	as_d.warning = warn
	(_dials["attitude"] as InstrumentDial).set_attitude(fi.pitch_deg, fi.roll_deg)
	var alt_d: InstrumentDial = _dials["altitude"]
	alt_d.set_reading(fi.altitude_msl, 0.0, 400.0)
	(_dials["heading"] as InstrumentDial).set_reading(fi.heading_deg, 0.0, 360.0)
	(_dials["turn"] as InstrumentDial).set_reading(fi.turn_rate_deg_s, -4.0, 4.0)
	var vsi_d: InstrumentDial = _dials["vsi"]
	vsi_d.set_reading(fi.vertical_speed, -15.0, 15.0)
	(_dials["hsi"] as InstrumentDial).set_hsi(
		fi.heading_deg, fi.nav_dev_deg, fi.nav_distance_m)
	# LCD 数字条（数据项与 D-034 一致，不增减）。
	_set_lcd("radar", "%.0f" % fi.altitude_agl)
	_set_lcd("rpm", "%.0f" % fi.rpm)
	_set_lcd("fuel", "%.0f" % (fi.fuel_ratio * 100.0))
	var flaps_txt := "襟翼 %d" % fi.flaps
	if fi.gear_down:
		flaps_txt += " 起落架↓"
	_set_lcd("flaps", flaps_txt)


func _set_lcd(key: String, text: String) -> void:
	var box: Control = _lcds.get(key)
	if box == null:
		return
	var v: Label = box.get_meta("value")
	if v != null:
		v.text = text


## 板面（L2 反转）：一块不透明金属板，配色与 2D dash 同源
## （CockpitInstruments.COL_DASH / _HI / _LO），让自由观察时看到的 3D 板读起来
## 是「第一人称那块 2D 板」的延续——视觉连续靠同色同结构，不靠贴图复刻
## （复刻需要重构 cockpit_instruments.gd 的内部类，碰 D-053 红线）。
## 3D 封板盒体已由 L1 砍掉（面板占满板面），其语义由这里的板面 / 螺钉承担。
class _Plate extends Control:
	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), CockpitInstruments.COL_DASH, true)
		# 顶沿受光条**内收 8 px**（不是贴在板沿）：第一人称满油门时镜头抖动
		# （±36.6 px，tan 基）会让面板上沿在峰值帧露出 dash 带约 3 px——内收后
		# 露出的那几行是对齐 2D dash 底色的暗金属（COL_DASH），与 dash 上沿同色，
		# 不折出一条发光亮线；底沿暗边仍贴边（它在屏外，露出也无所谓）。
		draw_rect(Rect2(0.0, 8.0, size.x, 3.0), CockpitInstruments.COL_DASH_HI, true)
		draw_rect(Rect2(0.0, size.y - 3.0, size.x, 3.0),
			CockpitInstruments.COL_DASH_LO, true)
		# 拉丝横纹：每 7 px 一道 alpha 0.028 白线（与 2D dash 同参数）。
		var y := 10.0
		while y < size.y - 6.0:
			draw_rect(Rect2(2.0, y, size.x - 4.0, 1.0),
				Color(1.0, 1.0, 1.0, 0.028), true)
			y += 7.0
		# 四角螺钉：与 L1 板上 6 颗 3D 螺钉呼应，读作「屏嵌在板里」。
		var corners: Array[Vector2] = [
			Vector2(6.0, 6.0), Vector2(size.x - 10.0, 6.0),
			Vector2(6.0, size.y - 10.0), Vector2(size.x - 10.0, size.y - 10.0)]
		for p: Vector2 in corners:
			draw_rect(Rect2(p, Vector2(4.0, 4.0)),
				CockpitInstruments.COL_DASH_LO, true)
			draw_rect(Rect2(p, Vector2(2.0, 2.0)),
				CockpitInstruments.COL_DASH_HI, true)
