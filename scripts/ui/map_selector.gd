class_name MapSelector
extends Control
## 地图选择器（全屏覆盖，三页流程）：
##   地球页：拖动旋转地球、悬停显示区域名、点击进入该区域介绍；
##   介绍页：区域名 + 地理介绍 + 「进入」；
##   加载页：逐条揭示该区域的植被/生物/气候/风貌，进度满后可开始探索。
## 完成后发出 region_entered(region_id)，由 Main 记录并重载主场景生效。

signal region_entered(region_id: int)
signal closed

enum Page {
	GLOBE,
	INTRO,
	LOADING,
}

## 视口（地球）尺寸与拖动判定阈值（像素）。
const VIEW_SIZE := 520.0
## 小于该位移视为点击而非拖动。
const CLICK_SLOP := 6.0
## 加载页时长（秒）与各段落揭示进度。
const LOAD_DURATION := 2.6
const STEP_REVEAL := [0.12, 0.36, 0.6, 0.84]

const BACKDROP_COLOR := Color(0.03, 0.06, 0.14, 0.97)
const PANEL_BG := Color(0.95, 0.92, 0.84)
const PANEL_BORDER := Color(0.62, 0.47, 0.27)
const TEXT_DARK := Color(0.28, 0.19, 0.08)
const TEXT_BODY := Color(0.35, 0.27, 0.16)

var _page: Page = Page.GLOBE
var _globe: MapGlobe
var _stage: SubViewportContainer
var _viewport: SubViewport
var _camera: Camera3D
var _hover_label: Label
var _globe_page: Control
var _intro_panel: PanelContainer
var _intro_title: Label
var _intro_subtitle: Label
var _intro_body: Label
var _loading_panel: PanelContainer
var _loading_title: Label
var _loading_bar: ProgressBar
var _loading_enter: Button
var _step_labels: Array[Label] = []
var _steps: Array[Dictionary] = []
var _selected := -1
var _dragging := false
var _drag_distance := 0.0
var _loading_time := 0.0
var _loading := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 30
	visible = false
	_build_backdrop()
	_build_globe_page()
	_build_intro_panel()
	_build_loading_panel()
	_show_page(Page.GLOBE)


func _process(delta: float) -> void:
	if _page != Page.LOADING or not _loading:
		return
	_loading_time += delta
	var ratio := clampf(_loading_time / LOAD_DURATION, 0.0, 1.0)
	_loading_bar.value = ratio * 100.0
	for i in range(_step_labels.size()):
		if ratio >= float(STEP_REVEAL[i]):
			_step_labels[i].modulate.a = 1.0
	if ratio >= 1.0:
		_loading = false
		_loading_enter.disabled = false
		_loading_enter.text = "开始探索"


func open() -> void:
	visible = true
	_dragging = false
	_drag_distance = 0.0
	_show_page(Page.GLOBE)
	if _globe != null:
		_globe.set_view_angles(-30.0, 12.0)


func close() -> void:
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func get_page() -> Page:
	return _page


func _gui_input(event: InputEvent) -> void:
	if _page != Page.GLOBE:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_distance = 0.0
		else:
			if _dragging and _drag_distance < CLICK_SLOP:
				var region := _pick_region()
				if region >= 0:
					_show_intro(region)
			_dragging = false
	elif event is InputEventMouseMotion:
		if _dragging:
			_drag_distance += event.relative.length()
			_globe.rotate_view(event.relative)
		_refresh_hover()


## 鼠标位置 → 球面区域 ID（-1 为未命中）。
## 鼠标事件只到达本控件（stage 为 IGNORE 不转发 SubViewport），
## 故用全局鼠标坐标减去 stage 原点换算出视口内像素坐标，
## 再交给相机投影 API（该 API 接收像素坐标而非 NDC）。
func _pick_region() -> int:
	if _globe == null or _viewport == null or _camera == null or _stage == null:
		return -1
	var vp_pos := _viewport_pos_from_global(get_global_mouse_position())
	var view := Vector2(_viewport.size)
	if vp_pos.x < 0.0 or vp_pos.y < 0.0 or vp_pos.x > view.x or vp_pos.y > view.y:
		return -1
	var origin := _camera.project_ray_origin(vp_pos)
	var dir := _camera.project_ray_normal(vp_pos)
	return _globe.region_at_world_ray(origin, dir)


## 全局（canvas）坐标 → SubViewport 内像素坐标。纯换算，供探针断言。
func _viewport_pos_from_global(global_pos: Vector2) -> Vector2:
	return global_pos - _stage.get_global_rect().position


func _refresh_hover() -> void:
	if _hover_label == null:
		return
	var region := _pick_region()
	if region < 0:
		_hover_label.text = "移动鼠标到地球上，点击区域查看介绍"
		return
	var data := RegionAtlas.profile(region)
	_hover_label.text = "%s · %s" % [data["title"], data["subtitle"]]


func _show_page(page: Page) -> void:
	_page = page
	_globe_page.visible = page == Page.GLOBE
	_intro_panel.visible = page == Page.INTRO
	_loading_panel.visible = page == Page.LOADING


func _show_intro(region_id: int) -> void:
	_selected = region_id
	var data := RegionAtlas.profile(region_id)
	_intro_title.text = String(data["title"])
	_intro_subtitle.text = String(data["subtitle"])
	_intro_body.text = String(data["intro"])
	_show_page(Page.INTRO)


func _start_loading() -> void:
	if _selected < 0:
		return
	var data := RegionAtlas.profile(_selected)
	_loading_title.text = "正在生成：%s" % data["title"]
	_steps = [
		{"name": "植被", "text": data["vegetation"]},
		{"name": "生物", "text": data["creature"]},
		{"name": "气候", "text": data["climate"]},
		{"name": "风貌", "text": data["scenery"]},
	]
	for i in range(_step_labels.size()):
		_step_labels[i].text = String(_steps[i]["text"])
		_step_labels[i].modulate.a = 0.0
	_loading_bar.value = 0.0
	_loading_time = 0.0
	_loading = true
	_loading_enter.disabled = true
	_loading_enter.text = "正在加载…"
	_show_page(Page.LOADING)


func _enter_world() -> void:
	if _selected < 0:
		return
	region_entered.emit(_selected)


func _build_backdrop() -> void:
	var backdrop := ColorRect.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.color = BACKDROP_COLOR
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	var title := Label.new()
	title.text = "选择地图"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 18.0
	title.offset_bottom = 62.0
	add_child(title)

	var subtitle := Label.new()
	subtitle.text = "拖动旋转地球 · 点击七大洲或四大洋查看地理介绍"
	subtitle.add_theme_font_size_override("font_size", 16)
	subtitle.add_theme_color_override("font_color", Color(0.72, 0.80, 0.92))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	subtitle.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	subtitle.offset_top = 62.0
	subtitle.offset_bottom = 88.0
	add_child(subtitle)


## 地球页：球体视口（自身 World3D） + 悬停提示 + 区域图例。
func _build_globe_page() -> void:
	_globe_page = Control.new()
	_globe_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_globe_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_globe_page)

	var stage := SubViewportContainer.new()
	stage.stretch = true
	stage.custom_minimum_size = Vector2(VIEW_SIZE, VIEW_SIZE)
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	stage.offset_left = -VIEW_SIZE * 0.5
	stage.offset_top = -VIEW_SIZE * 0.5 + 14.0
	stage.offset_right = VIEW_SIZE * 0.5
	stage.offset_bottom = VIEW_SIZE * 0.5 + 14.0
	_globe_page.add_child(stage)
	_stage = stage

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.size = Vector2i(int(VIEW_SIZE), int(VIEW_SIZE))
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	stage.add_child(_viewport)

	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 0.0, 3.0)
	_camera.fov = 45.0
	_viewport.add_child(_camera)

	_globe = MapGlobe.new()
	_viewport.add_child(_globe)

	_hover_label = Label.new()
	_hover_label.text = "移动鼠标到地球上，点击区域查看介绍"
	_hover_label.add_theme_font_size_override("font_size", 18)
	_hover_label.add_theme_color_override("font_color", Color(0.86, 0.92, 1.0))
	_hover_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hover_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_hover_label.offset_top = -56.0
	_hover_label.offset_bottom = -26.0
	_globe_page.add_child(_hover_label)

	_build_legend(_globe_page)


## 区域图例：11 个色块 + 名称，界面左侧竖列排布。
func _build_legend(parent: Control) -> void:
	var grid := GridContainer.new()
	grid.columns = 1
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 8)
	grid.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	grid.offset_left = 24.0
	grid.offset_right = 154.0
	grid.offset_top = -160.0
	grid.offset_bottom = 160.0
	parent.add_child(grid)

	for region_id in RegionAtlas.COUNT:
		var cell := HBoxContainer.new()
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_theme_constant_override("separation", 6)
		grid.add_child(cell)

		var chip := ColorRect.new()
		chip.color = RegionAtlas.color_of(region_id)
		chip.custom_minimum_size = Vector2(14, 14)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(chip)

		var name_label := Label.new()
		name_label.text = RegionAtlas.title_of(region_id)
		name_label.add_theme_font_size_override("font_size", 15)
		name_label.add_theme_color_override("font_color", Color(0.80, 0.87, 0.96))
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(name_label)


func _build_intro_panel() -> void:
	_intro_panel = _make_panel(Vector2(520, 0))
	_intro_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_intro_panel.offset_left = -260.0
	_intro_panel.offset_right = 260.0
	_intro_panel.offset_top = -140.0
	_intro_panel.offset_bottom = 140.0
	add_child(_intro_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_intro_panel.add_child(vbox)

	_intro_title = Label.new()
	_intro_title.add_theme_font_size_override("font_size", 28)
	_intro_title.add_theme_color_override("font_color", TEXT_DARK)
	vbox.add_child(_intro_title)

	_intro_subtitle = Label.new()
	_intro_subtitle.add_theme_font_size_override("font_size", 16)
	_intro_subtitle.add_theme_color_override("font_color", Color(0.45, 0.36, 0.22))
	vbox.add_child(_intro_subtitle)

	vbox.add_child(HSeparator.new())

	_intro_body = Label.new()
	_intro_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_intro_body.custom_minimum_size = Vector2(480, 0)
	_intro_body.add_theme_font_size_override("font_size", 17)
	_intro_body.add_theme_color_override("font_color", TEXT_BODY)
	vbox.add_child(_intro_body)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	vbox.add_child(row)

	var back := Button.new()
	back.text = "返回地球"
	back.custom_minimum_size = Vector2(130, 44)
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(func(): _show_page(Page.GLOBE))
	row.add_child(back)

	var enter := Button.new()
	enter.text = "进入"
	enter.custom_minimum_size = Vector2(130, 44)
	enter.focus_mode = Control.FOCUS_NONE
	enter.pressed.connect(_start_loading)
	row.add_child(enter)


func _build_loading_panel() -> void:
	_loading_panel = _make_panel(Vector2(560, 0))
	_loading_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_loading_panel.offset_left = -280.0
	_loading_panel.offset_right = 280.0
	_loading_panel.offset_top = -220.0
	_loading_panel.offset_bottom = 220.0
	add_child(_loading_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	_loading_panel.add_child(vbox)

	_loading_title = Label.new()
	_loading_title.add_theme_font_size_override("font_size", 26)
	_loading_title.add_theme_color_override("font_color", TEXT_DARK)
	vbox.add_child(_loading_title)

	_loading_bar = ProgressBar.new()
	_loading_bar.min_value = 0.0
	_loading_bar.max_value = 100.0
	_loading_bar.value = 0.0
	_loading_bar.show_percentage = false
	_loading_bar.custom_minimum_size = Vector2(0, 18)
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.78, 0.74, 0.64)
	bar_bg.set_corner_radius_all(6)
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = Color(0.42, 0.66, 0.36)
	bar_fill.set_corner_radius_all(6)
	_loading_bar.add_theme_stylebox_override("background", bar_bg)
	_loading_bar.add_theme_stylebox_override("fill", bar_fill)
	vbox.add_child(_loading_bar)

	vbox.add_child(HSeparator.new())

	var names := ["植被", "生物", "气候", "风貌"]
	for i in range(names.size()):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		vbox.add_child(row)

		var tag := Label.new()
		tag.text = names[i]
		tag.custom_minimum_size = Vector2(52, 0)
		tag.add_theme_font_size_override("font_size", 17)
		tag.add_theme_color_override("font_color", Color(0.38, 0.50, 0.72))
		row.add_child(tag)

		var text := Label.new()
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.custom_minimum_size = Vector2(440, 0)
		text.add_theme_font_size_override("font_size", 16)
		text.add_theme_color_override("font_color", TEXT_BODY)
		row.add_child(text)
		_step_labels.append(text)

	_loading_enter = Button.new()
	_loading_enter.text = "正在加载…"
	_loading_enter.custom_minimum_size = Vector2(160, 46)
	_loading_enter.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_loading_enter.focus_mode = Control.FOCUS_NONE
	_loading_enter.disabled = true
	_loading_enter.pressed.connect(_enter_world)
	vbox.add_child(_loading_enter)


## 统一面板外观：与游戏内储物箱/合成台同款淡米色木纹质感。
func _make_panel(min_size: Vector2) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = min_size
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", style)
	return panel
