class_name CockpitPanel
extends Node3D
## 第一人称座舱 3D 仪表盘（D-034）：把 12 项仪表画进一个 SubViewport，再经
## ViewportTexture 贴到座舱仪表板平面上——低头即可看到会转动的指针。
##
## 仪表布局（1024×640 的 2D 仪表簇）：
##   上排 4 圆形盘：空速 / 姿态仪 / 高度 / 航向
##   下排 3 圆 形盘：转弯协调仪 / 垂直速度 / HSI（含 CDI 偏差条）
##   底部 4 数字条（LCD）：雷达高度 / 发动机转速 / 燃油 / 襟翼·起落架
##
## 蓝图试飞机（blueprint_built）无座舱罩，按契约不建几何、直接隐藏本节点。
##
## 自发光（emission 用同一张纹理）：座舱内即便背光也清晰可读，儿童向不靠外部光。

const PANEL_W := 0.32
const PANEL_H := 0.20

var _dials := {}
var _lcds := {}
var _subviewport: SubViewport = null
## 基础可见性（蓝图机契约 = false：无座舱罩几何，setup 早退不建任何节点）。
## 座舱内视（D-050）在其之上再压一层：visible = _base_visible and not _interior。
var _base_visible := true
var _interior_view := false


func setup(craft: Node) -> void:
	# 蓝图机无座舱罩几何：按契约隐藏、不建任何节点。
	if craft != null and "blueprint_built" in craft and bool(craft.get("blueprint_built")):
		_base_visible = false
		visible = false
		return
	_build_cluster()


## 座舱内视开关（D-050）：第一人称下隐藏——读数已由 2D 座舱仪表簇接管
## （CockpitInstruments），且机体外观一并隐藏后 3D 面板悬在半空只会突兀。
## 蓝图机的 _base_visible=false 契约在此之上仍然成立（内视退出也不会显形）。
func set_interior_view(active: bool) -> void:
	_interior_view = active
	visible = _base_visible and not active


func _build_cluster() -> void:
	_subviewport = SubViewport.new()
	_subviewport.size = Vector2i(1024, 640)
	_subviewport.transparent_bg = true
	_subviewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_subviewport.name = "CockpitSubViewport"
	add_child(_subviewport)

	var cluster := Control.new()
	cluster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cluster.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_subviewport.add_child(cluster)

	# 上排 4 圆形盘。
	var top := ["airspeed", "attitude", "altitude", "heading"]
	var top_modes := [InstrumentDial.Mode.CIRCULAR, InstrumentDial.Mode.ATTITUDE,
		InstrumentDial.Mode.CIRCULAR, InstrumentDial.Mode.CIRCULAR]
	var top_titles := ["空速 km/h", "姿态", "高度 m", "航向°"]
	for i in range(4):
		var d := InstrumentDial.new()
		d.mode = top_modes[i]
		d.set_title(top_titles[i])
		d.custom_minimum_size = Vector2(230, 230)
		d.size = Vector2(230, 230)
		d.position = Vector2(40 + i * 250, 20)
		cluster.add_child(d)
		_dials[top[i]] = d

	# 下排 3 圆形盘。
	var bot := ["turn", "vsi", "hsi"]
	var bot_modes := [InstrumentDial.Mode.CIRCULAR, InstrumentDial.Mode.CIRCULAR,
		InstrumentDial.Mode.HSI]
	var bot_titles := ["转弯率", "升降 m/s", "HSI/CDI"]
	for i in range(3):
		var d := InstrumentDial.new()
		d.mode = bot_modes[i]
		d.set_title(bot_titles[i])
		d.custom_minimum_size = Vector2(230, 230)
		d.size = Vector2(230, 230)
		d.position = Vector2(140 + i * 250, 270)
		cluster.add_child(d)
		_dials[bot[i]] = d

	# 底部 4 数字条（LCD）。
	var lcd_names := ["radar", "rpm", "fuel", "flaps"]
	var lcd_titles := ["离地 m", "转速 rpm", "燃油 %", "襟翼/起落架"]
	for i in range(4):
		var lcd := _make_lcd(lcd_titles[i])
		lcd.position = Vector2(40 + i * 245, 560)
		lcd.size = Vector2(230, 70)
		cluster.add_child(lcd)
		_lcds[lcd_names[i]] = lcd

	# 仪表板平面（贴 ViewportTexture，自发光）。
	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.orientation = PlaneMesh.FACE_Z
	pm.size = Vector2(PANEL_W, PANEL_H)
	plane.mesh = pm
	plane.position = Vector3(0.0, -0.35, -1.7)
	# 面板法线朝 +Z（机体后方，即朝飞行员）；再上仰约 25° 让低头更顺眼。
	plane.rotation.x = deg_to_rad(-25.0)
	plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = null   # _ready 里绑定（此时 SubViewport 已在树中）
	mat.emission_enabled = true
	mat.emission = Color(1.0, 1.0, 1.0)
	mat.emission_energy_multiplier = 1.0
	mat.metallic = 0.0
	mat.roughness = 1.0
	plane.set_surface_override_material(0, mat)
	plane.name = "Dashboard"
	add_child(plane)
	_dashboard_material = mat
	# SubViewport 已在本节点（已在场景中）之下，路径稳定，立即绑定纹理。
	var tex := ViewportTexture.new()
	tex.viewport_path = _subviewport.get_path()
	_dashboard_material.albedo_texture = tex
	_dashboard_material.emission_texture = tex


var _dashboard_material: StandardMaterial3D = null


func _make_lcd(title: String) -> Control:
	var box := Control.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.06, 0.09, 0.92)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_child(bg)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 16)
	t.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	t.position = Vector2(8.0, 4.0)
	box.add_child(t)
	var v := Label.new()
	v.add_theme_font_size_override("font_size", 28)
	v.add_theme_color_override("font_color", Color(0.40, 0.95, 0.55))
	v.position = Vector2(8.0, 30.0)
	box.add_child(v)
	box.set_meta("value", v)
	return box


## 每帧从 FlightInstruments 喂数据（由 FlightInstrumentHUD.tick 经 register_view 调用）。
func refresh_instruments(fi: FlightInstruments) -> void:
	if not visible or _dials.is_empty():
		return
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
	(_dials["hsi"] as InstrumentDial).set_hsi(fi.heading_deg, fi.nav_dev_deg, fi.nav_distance_m)
	# LCD 数字条。
	_set_lcd("radar", "%.0f" % fi.altitude_agl)
	_set_lcd("rpm", "%.0f" % fi.rpm)
	_set_lcd("fuel", "%.0f" % (fi.fuel_ratio * 100.0))
	var flaps_txt := "襟翼 %d" % fi.flaps
	if fi.gear_down:
		flaps_txt += " 起落架↓"
	_set_lcd("flaps", flaps_txt)


func _set_lcd(name: String, text: String) -> void:
	var box: Control = _lcds.get(name)
	if box == null:
		return
	var v: Label = box.get_meta("value")
	if v != null:
		v.text = text
