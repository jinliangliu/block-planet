class_name MapSelector
extends Control
## 地图选择器（全屏覆盖，三页流程）：
##   地球页：拖动旋转地球、悬停显示区域名、点击进入该区域介绍；
##          右侧竖排提供「生存 / 创造 / 探索」模式三选一；
##   介绍页：区域名 + 地理介绍 + 三张知识卡 + 本区地标（点开看科普一句话，
##           「去这里」= 进入该地标所属区域，见 _go_to_landmark 的取舍说明）；
##   加载页：逐条揭示该区域的植被/生物/气候/风貌，进度满后可开始探索。
## 完成后发出 region_entered(region_id)，由 Main 记录并重载主场景生效。

signal region_entered(region_id: int)
signal closed
## 在介绍页请求跳去看该区域的动植物图鉴（由 HUD 关闭本窗口后打开图鉴）。
signal bestiary_requested(region_id: int)
## 在介绍页请求去钓鱼（四大洋）：HUD 关掉本窗口后打开钓具界面。
signal fishing_requested(region_id: int)
## 在「地图页」请求去赛车：HUD 关掉本窗口后打开赛道选择器。
## 与竞速无关区域——赛道自带主题，不绑定地理区域，故在地球页全局可见，
## 不像钓鱼那样只在有钓点的介绍页出现。
signal race_requested

enum Page {
	GLOBE,
	INTRO,
	LOADING,
}

## 视口（地球）尺寸与拖动判定阈值（像素）。
const VIEW_SIZE := 520.0
## 卡片插画种类（对应 RegionAtlas.REGION_CARDS 的 art 字段）。
## 单列一张清单，是为了让「卡片写了 art 却没有画法」当场报警，
## 而不是静默画成一块空白——life_probe 阶段 R 会对照 RegionAtlas 逐张校验。
const ART_KINDS := [
	"mountain", "wave", "storm", "rift", "reef", "ice", "forest", "aurora",
	"waterfall", "trench", "sun", "rock", "polar_bear", "penguin", "panda",
	"lion", "kangaroo", "dune",
]

## 模式竖排栏：按钮宽与距屏幕右缘、上下留白（地球居中，右侧这片空白正好容纳）。
const MODE_COLUMN_WIDTH := 188.0
const MODE_COLUMN_MARGIN := 40.0
const MODE_COLUMN_HEIGHT := 140.0
## 小于该位移视为点击而非拖动。
const CLICK_SLOP := 6.0
## 加载页时长（秒）与各段落揭示进度。
const LOAD_DURATION := 2.6
const STEP_REVEAL := [0.12, 0.36, 0.6, 0.84]
## 地标分区：按三列排，限高后交给竖向滚动（亚洲有 11 条，
## 摊平会把介绍页挤爆，限高 + 滚动才是稳定的排法）。
const LANDMARK_COLUMNS := 3
const LANDMARK_SCROLL_HEIGHT := 130.0
## 地标 kind 的中文名（介绍页详情卡里用一句话点出「这是什么地貌」）。
## 取值必须与 RegionAtlas.REGION_LANDMARKS 的 kind 一一对应，
## 漏一个就会在详情卡上显示成英文 key。
const LANDMARK_KIND_NAMES := {
	"mountain": "山",
	"river": "江河 / 洋流",
	"gorge": "峡谷 / 海沟",
	"plateau": "高原 / 冰原",
	"lake": "湖",
	"reef": "珊瑚礁",
	"monolith": "巨岩 / 石像",
}

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
var _card_row: HBoxContainer
var _card_detail: Control
var _detail_panel: PanelContainer
var _detail_art: Control
var _detail_title: Label
var _detail_text: Label
var _detail_cards: Array = []
var _detail_index := 0
var _loading_panel: PanelContainer
var _loading_title: Label
var _loading_bar: ProgressBar
var _loading_enter: Button
var _step_labels: Array[Label] = []
var _steps: Array[Dictionary] = []
var _selected := -1
var _mode_buttons: Array[Button] = []
var _mode_caption: Label
var _fishing_button: Button
## 介绍页地标分区与地标详情浮层（中国地标特性）。
## _landmark_owner 记的是「正在看的那张卡属于哪个区域」，可能 ≠ _selected
## （例如从地球上的图钉直接点开一张跨区域卡），决定是否要给「切换区域」提示。
var _landmark_grid: GridContainer
var _landmark_scroll: ScrollContainer
var _landmark_detail: Control
var _landmark_detail_title: Label
var _landmark_detail_kind: Label
var _landmark_detail_text: Label
var _landmark_detail_note: Label
var _landmark_detail_go: Button
var _landmark_owner := -1
var _landmark_index := -1
## 🏁 赛道竞速入口按钮：提为成员以便按模式显隐（D-041，仅探索模式显示）。
var _race_button: Button
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
	_refresh_mode_row()
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
				# 先判地标图钉：它钉在球面上，目标小而明确，
				# 命中了就打开该地标的科普卡（会顺带切到它所属区域的介绍页）；
				# 没命中才退回「点区域进介绍」，既有行为一字未改。
				var landmark := _pick_landmark()
				if landmark >= 0:
					var hit := _globe.landmark_entry(landmark)
					if not hit.is_empty():
						open_landmark(int(hit["region"]), int(hit["index"]))
				else:
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
	if RegionAtlas.has_airport(region_id):
		_intro_body.text += "\n\n本区域建有带跑道的机场——出生点就在跑道旁，落地即可起飞。"
	elif RegionAtlas.has_landing_field(region_id):
		_intro_body.text += "\n\n本区域在岛上/冰面上整备有一座简易降落场——出生点就在跑道旁，落地即可起飞。"
	# 有钓点的区域（当前是四大洋）补一句：看完介绍可以直接下竿。
	if not FishingSystem.get_spots_for_atlas(region_id).is_empty():
		_intro_body.text += "\n\n这片海域开放了钓点——带上钓具，看看能钓上什么。"
	_intro_body.text += _bounds_sentence(region_id)
	_fishing_button.visible = not FishingSystem.get_spots_for_atlas(region_id).is_empty()
	_detail_cards = RegionAtlas.cards_of(region_id)
	for child in _card_row.get_children():
		child.queue_free()
	for i in range(_detail_cards.size()):
		_card_row.add_child(_make_card(_detail_cards[i], i))
	_close_card_detail()
	_populate_landmarks(region_id)
	_show_page(Page.INTRO)


## 一句「这里大致在地球的哪一片」：取 GeoProjection 近似包围盒的中心点，
## 直接写带符号的度数并标注是近似值——
## 掩码本身 5° 一格，拿它做精确判读会把小朋友带沟里。
func _bounds_sentence(region_id: int) -> String:
	var box := GeoProjection.region_bounds(region_id)
	var lat_mid := (float(box["lat_min"]) + float(box["lat_max"])) * 0.5
	var lon_mid := (float(box["lon_min"]) + float(box["lon_max"])) * 0.5
	if lon_mid > 180.0:
		lon_mid -= 360.0
	return "\n\n地球上的大致位置：纬度 %.0f°，经度 %.0f°（游戏内的近似画法，北纬东经为正）" % [
		lat_mid, lon_mid,
	]


## 介绍页地标分区：列在 3 张知识卡之后，是该区域的地标清单。
## ── 为什么是「清单 + 详情卡」而不是设计文档的悬停全息面板 ──
## 文档要求在球面上悬停弹出全息卡片（需要 camera.unproject_position 逐帧
## 重算屏幕坐标 + 一套 CanvasLayer 绘制）。本作球面上已经挤了 11 条区域名、
## 11 枚小飞机、4 条小鱼，再加悬浮面板会彻底糊成一团；而介绍页本来就是
## 「讲清一个地方」的地方，把地标卡放在这里信息密度最合适，
## 也无需引入逐帧 2D 覆盖层的第二条渲染/布局链路。
func _populate_landmarks(region_id: int) -> void:
	if _landmark_grid == null:
		return
	for child in _landmark_grid.get_children():
		child.queue_free()
	var marks := RegionAtlas.landmarks_of(region_id)
	for i in range(marks.size()):
		var entry: Dictionary = marks[i]
		_landmark_grid.add_child(_make_landmark_chip(entry, i, region_id))
	_landmark_scroll.visible = not marks.is_empty()
	_close_landmark_detail()


## 地标分区里的一枚：kind 色块 + 标题。点开弹出详情卡。
## 用 PanelContainer + gui_input 而不是 Button——Button 不是容器，
## 塞不进「色块 + 文字」两个子节点（与 _make_card 保持同一种写法）。
func _make_landmark_chip(entry: Dictionary, index: int, region_id: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(150, 34)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.99, 0.97, 0.90)
	style.border_color = PANEL_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(4)
	panel.add_theme_stylebox_override("panel", style)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	panel.add_child(hbox)

	var kind: String = String(entry["kind"])
	var chip := ColorRect.new()
	chip.color = MapGlobe.LANDMARK_COLORS.get(kind, MapGlobe.LANDMARK_COLORS["mountain"])
	chip.custom_minimum_size = Vector2(12, 12)
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(chip)

	var name_label := Label.new()
	name_label.text = String(entry["title"])
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.add_theme_color_override("font_color", TEXT_DARK)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(name_label)

	panel.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_open_landmark_detail(region_id, index)
	)
	return panel


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
	subtitle.text = "拖动旋转地球 · 点击七大洲或四大洋查看地理介绍；球面上游着小鱼的海域可以钓鱼；切到「探索」模式才显示小飞机（红=机场 / 琥珀=降落场）与 🏁 赛道竞速"
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
	_build_mode_row(_globe_page)
	_build_race_entry(_globe_page)
	# 模式列建造时 _race_button 尚不存在，这里补一次：初始模式（默认生存）
	# 下两个载具门牌一起收起；若启动时已是探索模式则一起显示。
	_refresh_vehicle_entries()


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
		# 有钓点的海域在图例里挂 🎣，与介绍页按钮同一个判据。
		name_label.text = RegionAtlas.title_of(region_id) \
			+ (" 🎣" if not FishingSystem.get_spots_for_atlas(region_id).is_empty() else "")
		name_label.add_theme_font_size_override("font_size", 15)
		name_label.add_theme_color_override("font_color", Color(0.80, 0.87, 0.96))
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(name_label)


## 模式三选一：贴地球页右侧竖排，选完地图顺手定模式，不给流程多添一步。
## 点选即写入 GameState——与 HUD 的模式按钮一样即时生效。
## 竖排的理由：按钮文字只有两个字，横排会拉成一条细长条，还容易和地球下方的
## 悬停提示抢位置；地球居中、左栏已被图例占住，右侧这片留白正好容一列开关。
func _build_mode_row(parent: Control) -> void:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 10)
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	box.offset_left = -(MODE_COLUMN_WIDTH + MODE_COLUMN_MARGIN)
	box.offset_right = -MODE_COLUMN_MARGIN
	box.offset_top = -MODE_COLUMN_HEIGHT
	box.offset_bottom = MODE_COLUMN_HEIGHT
	parent.add_child(box)

	_mode_buttons.clear()
	for choice: Dictionary in _mode_choices():
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(MODE_COLUMN_WIDTH, 44)
		btn.focus_mode = Control.FOCUS_NONE
		btn.toggle_mode = true
		btn.add_theme_font_size_override("font_size", 17)
		btn.pressed.connect(_select_mode.bind(int(choice["mode"])))
		box.add_child(btn)
		_mode_buttons.append(btn)

	_mode_caption = Label.new()
	_mode_caption.add_theme_font_size_override("font_size", 14)
	_mode_caption.add_theme_color_override("font_color", Color(0.72, 0.80, 0.92))
	_mode_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 竖栏只有 188px 宽，一句说明必然折行，交给自动换行而不是手写断句。
	_mode_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mode_caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_mode_caption)

	_refresh_mode_row()


## 三选一的选项表：枚举值 + 标题。说明文案复用 GameState.mode_hint()，
## 保证地图页、HUD、说明书三处措辞不会各写一套而漂移。
func _mode_choices() -> Array:
	return [
		{"mode": GameState.Mode.SURVIVAL, "title": "生存"},
		{"mode": GameState.Mode.CREATIVE, "title": "创造"},
		{"mode": GameState.Mode.EXPLORE, "title": "探索"},
	]


## 选定模式。真正的行为差异要等进入世界后才体现（Main 会按需重载场景），
## 但这里立即写入 GameState，HUD 状态标签也会同步。
func _select_mode(mode: int) -> void:
	GameState.set_mode(mode)
	_refresh_mode_row()


func _refresh_mode_row() -> void:
	var choices := _mode_choices()
	if _mode_caption != null:
		_mode_caption.text = "模式：%s —— %s" % [GameState.mode_name(), GameState.mode_hint()]
	for i in range(_mode_buttons.size()):
		var active: bool = int(choices[i]["mode"]) == int(GameState.mode)
		_mode_buttons[i].button_pressed = active
		_mode_buttons[i].text = ("✓ " if active else "") + String(choices[i]["title"])
	_refresh_vehicle_entries()


## 载具门牌显隐（D-041）：飞行标记（地球上的红/琥珀小飞机，D-044 由小旗改）与 🏁 赛道竞速
## 入口都是「载具玩法」的门牌，只在探索模式显示——生存/创造模式下玩家
## 还没有载具，挂着只会误导。判据统一走 GameState.is_explore()，
## 由 _refresh_mode_row() 在选模式与 open() 时调用，切模式当帧同步。
func _refresh_vehicle_entries() -> void:
	var show: bool = GameState.is_explore()
	if _race_button != null:
		_race_button.visible = show
	if _globe != null:
		_globe.set_flight_flags_visible(show)


## 当前选中的模式（探针据此断言三选一已写入 GameState）。
func selected_mode() -> int:
	return int(GameState.mode)


## 竞速入口：贴在左栏图例下方（图例只占中段竖排，左下角这片留白正好放一枚
## 全宽按钮）。赛道不绑地理区域，故与地球页同显、不随选中区域变化；
## 但只在探索模式显示（D-041）——与地球上的飞行小飞机同一判据，见
## _refresh_vehicle_entries()。
func _build_race_entry(parent: Control) -> void:
	var btn := Button.new()
	btn.text = "🏁 赛道竞速"
	btn.custom_minimum_size = Vector2(170, 48)
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 18)
	btn.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	btn.offset_left = 24.0
	btn.offset_right = 194.0
	btn.offset_top = -76.0
	btn.offset_bottom = -28.0
	btn.pressed.connect(func(): race_requested.emit())
	parent.add_child(btn)
	_race_button = btn


func _build_intro_panel() -> void:
	_intro_panel = _make_panel(Vector2(520, 0))
	_intro_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_intro_panel.offset_left = -260.0
	_intro_panel.offset_right = 260.0
	_intro_panel.offset_top = -290.0
	_intro_panel.offset_bottom = 290.0
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

	# 地理知识卡片横滚区：每张卡 = 程序化剪影插图 + 标题 + 短句。
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 186)
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	_card_row = HBoxContainer.new()
	_card_row.add_theme_constant_override("separation", 10)
	scroll.add_child(_card_row)

	_build_landmark_section(vbox)

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

	# 介绍页是「地理」与「生物」的交汇点：看完地形介绍，
	# 顺手就能翻到这片地方的动植物图鉴，两套内容由同一个区域号串起来。
	var bestiary := Button.new()
	bestiary.text = "看看这里的生物"
	bestiary.custom_minimum_size = Vector2(150, 44)
	bestiary.focus_mode = Control.FOCUS_NONE
	bestiary.pressed.connect(func():
		if _selected >= 0:
			bestiary_requested.emit(_selected)
	)
	row.add_child(bestiary)

	# 「去钓鱼」只在有钓点的区域出现（数据决定，不是写死四大洋）：
	# 图例与介绍页共用同一个判据，加新钓点不用改两处。
	_fishing_button = Button.new()
	_fishing_button.text = "🎣 去钓鱼"
	_fishing_button.custom_minimum_size = Vector2(130, 44)
	_fishing_button.focus_mode = Control.FOCUS_NONE
	_fishing_button.visible = false
	_fishing_button.pressed.connect(func():
		if _selected >= 0:
			fishing_requested.emit(_selected)
	)
	row.add_child(_fishing_button)

	var enter := Button.new()
	enter.text = "进入"
	enter.custom_minimum_size = Vector2(130, 44)
	enter.focus_mode = Control.FOCUS_NONE
	enter.pressed.connect(_start_loading)
	row.add_child(enter)

	_build_card_detail()
	_build_landmark_detail()


## 介绍页地标分区：标题 + 三列网格（限高 + 竖向滚动）。
## 放在知识卡之后、按钮之前：先了解这片地方，再看这里有什么著名的山川河流。
func _build_landmark_section(parent: Node) -> void:
	var caption := Label.new()
	caption.text = "这里的地标"
	caption.add_theme_font_size_override("font_size", 18)
	caption.add_theme_color_override("font_color", TEXT_DARK)
	parent.add_child(caption)

	_landmark_scroll = ScrollContainer.new()
	_landmark_scroll.custom_minimum_size = Vector2(0, LANDMARK_SCROLL_HEIGHT)
	_landmark_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(_landmark_scroll)
	_landmark_grid = GridContainer.new()
	_landmark_grid.columns = LANDMARK_COLUMNS
	_landmark_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_landmark_grid.add_theme_constant_override("h_separation", 6)
	_landmark_grid.add_theme_constant_override("v_separation", 6)
	_landmark_scroll.add_child(_landmark_grid)


## 地标详情浮层：标题 + 地貌类型 + 科普一句话 + 「去这里」/关闭。
## 与知识卡详情浮层同款遮罩写法，z_index 更高一层以免两者叠着时被压住。
func _build_landmark_detail() -> void:
	_landmark_detail = Control.new()
	_landmark_detail.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_landmark_detail.mouse_filter = Control.MOUSE_FILTER_STOP
	_landmark_detail.visible = false
	_landmark_detail.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed:
			_close_landmark_detail()
	)
	add_child(_landmark_detail)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.05, 0.10, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_landmark_detail.add_child(dim)

	var panel := _make_panel(Vector2(420, 0))
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -210.0
	panel.offset_right = 210.0
	panel.offset_top = -150.0
	panel.offset_bottom = 150.0
	_landmark_detail.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	_landmark_detail_title = Label.new()
	_landmark_detail_title.add_theme_font_size_override("font_size", 22)
	_landmark_detail_title.add_theme_color_override("font_color", TEXT_DARK)
	vbox.add_child(_landmark_detail_title)

	_landmark_detail_kind = Label.new()
	_landmark_detail_kind.add_theme_font_size_override("font_size", 14)
	_landmark_detail_kind.add_theme_color_override("font_color", Color(0.45, 0.36, 0.22))
	vbox.add_child(_landmark_detail_kind)

	_landmark_detail_text = Label.new()
	_landmark_detail_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_landmark_detail_text.custom_minimum_size = Vector2(380, 0)
	_landmark_detail_text.add_theme_font_size_override("font_size", 15)
	_landmark_detail_text.add_theme_color_override("font_color", TEXT_BODY)
	vbox.add_child(_landmark_detail_text)

	# 跨区域时的提示行：正常情况下（点本区地标）不占位、不显示。
	_landmark_detail_note = Label.new()
	_landmark_detail_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_landmark_detail_note.add_theme_font_size_override("font_size", 13)
	_landmark_detail_note.add_theme_color_override("font_color", Color(0.62, 0.38, 0.18))
	_landmark_detail_note.visible = false
	vbox.add_child(_landmark_detail_note)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 12)
	vbox.add_child(buttons)

	_landmark_detail_go = Button.new()
	_landmark_detail_go.custom_minimum_size = Vector2(140, 42)
	_landmark_detail_go.focus_mode = Control.FOCUS_NONE
	_landmark_detail_go.add_theme_font_size_override("font_size", 16)
	_landmark_detail_go.pressed.connect(_go_to_landmark)
	buttons.add_child(_landmark_detail_go)

	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(96, 42)
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(_close_landmark_detail)
	buttons.add_child(close)


## 打开某区域某张地标卡。地球页点图钉、介绍页点地标块都汇到这里。
func open_landmark(region_id: int, index: int) -> void:
	var marks := RegionAtlas.landmarks_of(region_id)
	if index < 0 or index >= marks.size():
		return
	if _selected != region_id or get_page() != Page.INTRO:
		_show_intro(region_id)
	_open_landmark_detail(region_id, index)


func _open_landmark_detail(region_id: int, index: int) -> void:
	var marks := RegionAtlas.landmarks_of(region_id)
	if index < 0 or index >= marks.size():
		return
	_landmark_owner = region_id
	_landmark_index = index
	var entry: Dictionary = marks[index]
	var kind: String = String(entry["kind"])
	var title: String = String(entry["title"])
	var owner_name := RegionAtlas.title_of(region_id)
	_landmark_detail_title.text = title
	_landmark_detail_kind.text = "地貌：%s" % LANDMARK_KIND_NAMES.get(kind, kind)
	_landmark_detail_text.text = String(entry["text"])
	# 「去这里」必须诚实：本作世界里没有地标建筑，也不存在「降落在泰山」这条链路。
	# 按钮文案一律写成「去<区域>看看」——点下去是进入该地标所属区域。
	if region_id == _selected:
		_landmark_detail_note.visible = false
		_landmark_detail_go.text = "去%s看看" % owner_name
	else:
		_landmark_detail_note.visible = true
		_landmark_detail_note.text = "%s在%s，要切换区域才能去。" % [title, owner_name]
		_landmark_detail_go.text = "切换到%s" % owner_name
	_landmark_detail.visible = true
	_landmark_detail.z_index = 12


func _close_landmark_detail() -> void:
	if _landmark_detail != null:
		_landmark_detail.visible = false
	_landmark_index = -1


## 当前打开的地标卡索引（-1 表示没打开），探针断言用。
func open_landmark_index() -> int:
	if _landmark_detail == null or not _landmark_detail.visible:
		return -1
	return _landmark_index


## 当前打开的地标卡所属区域（-1 表示没打开），探针断言「跨区域切换」用。
func open_landmark_region() -> int:
	if _landmark_detail == null or not _landmark_detail.visible:
		return -1
	return _landmark_owner


## 【去这里】：进入该地标所属区域（发既有 region_entered 链路，落在现成的
## 机场/降落场），**不是**传送到地标精确坐标。
## ── 为什么不做「传送到地标」 ──
## 世界是程序化生成的方块平面，原点附近数百米才是玩家够得着的范围；
## 按真实经纬度换算出的落点既没有地形（区块不加载）也没有建筑（全库零地标实现）。
## 把泰山写成一个 128km 外的坐标只会让玩家进去发现一片空地，比不做更糟。
## 因此「快速旅行」的语义收敛为：进入地标所属区域。
func _go_to_landmark() -> void:
	if _landmark_owner < 0:
		return
	var target := _landmark_owner
	_close_landmark_detail()
	_selected = target
	region_entered.emit(target)


## 鼠标位置 → 球面地标索引（-1 为未命中）。换算方式与 _pick_region 完全一致，
## 只是把最后一步换成 MapGlobe.landmark_at_world_ray。
func _pick_landmark() -> int:
	if _globe == null or _viewport == null or _camera == null or _stage == null:
		return -1
	var vp_pos := _viewport_pos_from_global(get_global_mouse_position())
	var view := Vector2(_viewport.size)
	if vp_pos.x < 0.0 or vp_pos.y < 0.0 or vp_pos.x > view.x or vp_pos.y > view.y:
		return -1
	var origin := _camera.project_ray_origin(vp_pos)
	var dir := _camera.project_ray_normal(vp_pos)
	return _globe.landmark_at_world_ray(origin, dir)


## 知识卡详情浮层：全屏半透明遮罩 + 居中大图面板，点遮罩或按钮关闭。
func _build_card_detail() -> void:
	_card_detail = Control.new()
	_card_detail.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_card_detail.mouse_filter = Control.MOUSE_FILTER_STOP
	_card_detail.visible = false
	_card_detail.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed:
			_close_card_detail()
	)
	add_child(_card_detail)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.05, 0.10, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_detail.add_child(dim)

	_detail_panel = _make_panel(Vector2(420, 0))
	_detail_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_detail_panel.offset_left = -210.0
	_detail_panel.offset_right = 210.0
	_detail_panel.offset_top = -178.0
	_detail_panel.offset_bottom = 178.0
	_card_detail.add_child(_detail_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_detail_panel.add_child(vbox)

	_detail_art = Control.new()
	_detail_art.custom_minimum_size = Vector2(0, 170)
	_detail_art.clip_contents = true
	_detail_art.draw.connect(func(): _draw_art(_detail_art, _detail_art_kind(), _detail_art_tint()))
	vbox.add_child(_detail_art)

	_detail_title = Label.new()
	_detail_title.add_theme_font_size_override("font_size", 22)
	_detail_title.add_theme_color_override("font_color", TEXT_DARK)
	vbox.add_child(_detail_title)

	_detail_text = Label.new()
	_detail_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_text.add_theme_font_size_override("font_size", 15)
	_detail_text.add_theme_color_override("font_color", TEXT_BODY)
	vbox.add_child(_detail_text)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	var prev := Button.new()
	prev.text = "上一张"
	prev.custom_minimum_size = Vector2(96, 40)
	prev.focus_mode = Control.FOCUS_NONE
	prev.pressed.connect(func(): _open_card_detail((_detail_index - 1 + _detail_cards.size()) % _detail_cards.size()))
	row.add_child(prev)

	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(96, 40)
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(_close_card_detail)
	row.add_child(close)

	var next := Button.new()
	next.text = "下一张"
	next.custom_minimum_size = Vector2(96, 40)
	next.focus_mode = Control.FOCUS_NONE
	next.pressed.connect(func(): _open_card_detail((_detail_index + 1) % _detail_cards.size()))
	row.add_child(next)


func _detail_art_kind() -> String:
	if _detail_cards.is_empty():
		return "wave"
	return String(_detail_cards[_detail_index]["art"])


func _detail_art_tint() -> Color:
	if _detail_cards.is_empty():
		return Color(0.4, 0.5, 0.6)
	return _detail_cards[_detail_index]["tint"]


## 介绍页卡片横滚区内的一张知识卡。
func _make_card(card: Dictionary, index: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(156, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.99, 0.97, 0.90)
	style.border_color = PANEL_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(6)
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	var art := Control.new()
	art.custom_minimum_size = Vector2(0, 84)
	art.clip_contents = true
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var kind: String = card["art"]
	var tint: Color = card["tint"]
	art.draw.connect(func(): _draw_art(art, kind, tint))
	vbox.add_child(art)

	var title := Label.new()
	title.text = String(card["title"])
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", TEXT_DARK)
	vbox.add_child(title)

	var text := Label.new()
	text.text = String(card["text"])
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_theme_font_size_override("font_size", 11)
	text.add_theme_color_override("font_color", TEXT_BODY)
	vbox.add_child(text)

	panel.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_open_card_detail(index)
	)
	return panel


func _open_card_detail(index: int) -> void:
	_detail_index = index
	var card: Dictionary = _detail_cards[index]
	_detail_title.text = String(card["title"])
	_detail_text.text = String(card["text"])
	_detail_art.queue_redraw()
	# 卡片 gui_input / 上一张 / 下一张 三个入口都汇到这里，统一记一笔阅读量。
	# 去重：同一区域的同一张卡只记一次（跨重开持久化），cls_cards3 因此变成「读满 3 张不同卡片」。
	var read_key: String = "cards_read_%d_%d" % [_selected, index]
	if int(Progress.counters.get(read_key, 0)) == 0:
		Progress.counters[read_key] = 1
		Progress.notify("cards_read")
	_card_detail.visible = true
	_card_detail.z_index = 10


func _close_card_detail() -> void:
	if _card_detail != null:
		_card_detail.visible = false


## 程序化剪影插图：按 kind 分派，背景铺 tint 亮色，剪影用 tint 暗色；
## 动物类使用固有色，不随 tint 变化。
func _draw_art(art: Control, kind: String, tint: Color) -> void:
	if not ART_KINDS.has(kind):
		push_warning("区域卡片插画缺少画法：%s" % kind)
	var w := art.size.x
	var h := art.size.y
	if w <= 0.0 or h <= 0.0:
		return
	var bg := tint.lightened(0.62)
	var fg := tint.darkened(0.25)
	art.draw_rect(Rect2(Vector2.ZERO, art.size), bg)
	var cx := w * 0.5
	var cy := h * 0.5
	match kind:
		"mountain":
			art.draw_colored_polygon(PackedVector2Array([
				Vector2(cx - w * 0.34, h * 0.82), Vector2(cx - w * 0.10, h * 0.30), Vector2(cx + w * 0.12, h * 0.82),
			]), fg)
			art.draw_colored_polygon(PackedVector2Array([
				Vector2(cx - w * 0.06, h * 0.82), Vector2(cx + w * 0.22, h * 0.18), Vector2(cx + w * 0.46, h * 0.82),
			]), fg)
			art.draw_colored_polygon(PackedVector2Array([
				Vector2(cx + w * 0.16, h * 0.30), Vector2(cx + w * 0.22, h * 0.18), Vector2(cx + w * 0.28, h * 0.30),
			]), Color(0.96, 0.97, 1.0))
			art.draw_rect(Rect2(0.0, h * 0.82, w, h * 0.18), fg.darkened(0.2))
		"dune":
			art.draw_circle(Vector2(cx - w * 0.30, h * 0.18), h * 0.09, Color(1.0, 0.95, 0.75))
			art.draw_circle(Vector2(cx - w * 0.22, h * 1.02), h * 0.62, fg)
			art.draw_circle(Vector2(cx + w * 0.30, h * 1.08), h * 0.74, fg.lightened(0.12))
			art.draw_circle(Vector2(cx + w * 0.72, h * 0.96), h * 0.48, fg.darkened(0.12))
		"forest":
			for tree_x: float in [cx - w * 0.28, cx, cx + w * 0.28]:
				art.draw_rect(Rect2(tree_x - 2.5, h * 0.62, 5.0, h * 0.26), fg.darkened(0.35))
				art.draw_colored_polygon(PackedVector2Array([
					Vector2(tree_x - w * 0.13, h * 0.66), Vector2(tree_x, h * 0.16), Vector2(tree_x + w * 0.13, h * 0.66),
				]), fg)
			art.draw_rect(Rect2(0.0, h * 0.86, w, h * 0.14), fg.darkened(0.4))
		"wave":
			for i in range(3):
				var points := PackedVector2Array()
				var base_y := h * (0.34 + 0.22 * i)
				for step in range(25):
					var px := w * 0.08 + w * 0.84 * step / 24.0
					points.append(Vector2(px, base_y + sin(step * 1.4 + i * 2.0) * h * 0.055))
				art.draw_polyline(points, fg.darkened(0.1 * (2 - i)), 3.0, true)
		"ice":
			art.draw_colored_polygon(PackedVector2Array([
				Vector2(cx - w * 0.36, h * 0.84), Vector2(cx - w * 0.16, h * 0.24), Vector2(cx + w * 0.02, h * 0.52), Vector2(cx + w * 0.18, h * 0.16), Vector2(cx + w * 0.38, h * 0.84),
			]), Color(0.94, 0.97, 1.0))
			art.draw_rect(Rect2(0.0, h * 0.84, w, h * 0.16), tint.lightened(0.35))
		"aurora":
			for i in range(3):
				var band := Color(0.35 + 0.15 * i, 0.85, 0.55 + 0.1 * i, 0.55)
				art.draw_arc(Vector2(cx - w * 0.10 + i * w * 0.14, h * 1.05), h * 0.85, PI + 0.25, PI + 0.85, 24, band, 9.0)
			art.draw_rect(Rect2(0.0, h * 0.88, w, h * 0.12), Color(0.10, 0.14, 0.24))
		"storm":
			art.draw_circle(Vector2(cx - w * 0.12, h * 0.38), h * 0.16, fg)
			art.draw_circle(Vector2(cx + w * 0.06, h * 0.32), h * 0.20, fg)
			art.draw_circle(Vector2(cx + w * 0.24, h * 0.40), h * 0.14, fg)
			for i in range(4):
				var rx := cx - w * 0.18 + i * w * 0.13
				art.draw_line(Vector2(rx, h * 0.58), Vector2(rx - w * 0.03, h * 0.76), fg.darkened(0.15), 2.5)
		"rift":
			art.draw_colored_polygon(PackedVector2Array([
				Vector2(0.0, h * 0.50), Vector2(cx - w * 0.10, h * 0.44), Vector2(cx - w * 0.06, h * 0.86), Vector2(0.0, h * 0.90),
			]), fg)
			art.draw_colored_polygon(PackedVector2Array([
				Vector2(w, h * 0.52), Vector2(cx + w * 0.08, h * 0.46), Vector2(cx + w * 0.05, h * 0.88), Vector2(w, h * 0.92),
			]), fg.lightened(0.12))
			art.draw_line(Vector2(cx - w * 0.08, h * 0.45), Vector2(cx + w * 0.06, h * 0.87), tint.darkened(0.45), 3.0)
		"reef":
			art.draw_rect(Rect2(0.0, h * 0.80, w, h * 0.20), fg.darkened(0.4))
			for i in range(3):
				var bx := cx - w * 0.22 + i * w * 0.22
				art.draw_line(Vector2(bx, h * 0.80), Vector2(bx, h * 0.44), fg, 4.0)
				art.draw_line(Vector2(bx, h * 0.58), Vector2(bx - w * 0.07, h * 0.42), fg, 3.0)
				art.draw_line(Vector2(bx, h * 0.52), Vector2(bx + w * 0.06, h * 0.36), fg, 3.0)
				art.draw_circle(Vector2(bx + w * 0.06, h * 0.36), 3.0, Color(1.0, 0.85, 0.85))
		"waterfall":
			art.draw_rect(Rect2(0.0, 0.0, w * 0.30, h * 0.62), fg.darkened(0.3))
			art.draw_rect(Rect2(w * 0.70, 0.0, w * 0.30, h * 0.62), fg.darkened(0.3))
			art.draw_rect(Rect2(w * 0.30, 0.0, w * 0.40, h * 0.16), fg)
			for i in range(4):
				art.draw_rect(Rect2(w * (0.33 + 0.09 * i), h * 0.16, 4.0, h * 0.56), Color(0.88, 0.95, 1.0))
			art.draw_rect(Rect2(0.0, h * 0.74, w, h * 0.26), fg.darkened(0.15))
		"rock":
			art.draw_circle(Vector2(cx, h * 0.95), h * 0.62, fg)
			art.draw_arc(Vector2(cx, h * 0.95), h * 0.62, PI, TAU, 24, fg.darkened(0.2), 3.0)
			art.draw_rect(Rect2(0.0, h * 0.88, w, h * 0.12), fg.darkened(0.4))
		"trench":
			art.draw_colored_polygon(PackedVector2Array([
				Vector2(0.0, h * 0.30), Vector2(cx - w * 0.30, h * 0.30), Vector2(cx - w * 0.06, h * 0.88), Vector2(0.0, h * 0.88),
			]), fg)
			art.draw_colored_polygon(PackedVector2Array([
				Vector2(w, h * 0.30), Vector2(cx + w * 0.30, h * 0.30), Vector2(cx + w * 0.06, h * 0.88), Vector2(w, h * 0.88),
			]), fg.lightened(0.1))
			art.draw_rect(Rect2(cx - w * 0.06, h * 0.30, w * 0.12, h * 0.58), tint.darkened(0.45))
			for i in range(3):
				var wy := h * (0.20 + 0.05 * i)
				art.draw_line(Vector2(w * 0.10, wy), Vector2(w * 0.90, wy), Color(0.85, 0.92, 1.0, 0.7), 2.0)
		"sun":
			art.draw_circle(Vector2(cx, cy - h * 0.04), h * 0.18, fg)
			for i in range(8):
				var angle := TAU * i / 8.0
				var inner := Vector2(cx, cy - h * 0.04) + Vector2(cos(angle), sin(angle)) * h * 0.24
				var outer := Vector2(cx, cy - h * 0.04) + Vector2(cos(angle), sin(angle)) * h * 0.34
				art.draw_line(inner, outer, fg, 3.0)
			art.draw_rect(Rect2(0.0, h * 0.84, w, h * 0.16), fg.darkened(0.35))
		"panda":
			art.draw_circle(Vector2(cx, cy + h * 0.08), h * 0.30, Color(0.96, 0.96, 0.94))
			art.draw_circle(Vector2(cx - h * 0.20, cy - h * 0.16), h * 0.09, Color(0.12, 0.12, 0.12))
			art.draw_circle(Vector2(cx + h * 0.20, cy - h * 0.16), h * 0.09, Color(0.12, 0.12, 0.12))
			art.draw_circle(Vector2(cx - h * 0.09, cy - h * 0.02), h * 0.06, Color(0.12, 0.12, 0.12))
			art.draw_circle(Vector2(cx + h * 0.09, cy - h * 0.02), h * 0.06, Color(0.12, 0.12, 0.12))
			art.draw_circle(Vector2(cx, cy + h * 0.04), h * 0.035, Color(0.12, 0.12, 0.12))
			art.draw_rect(Rect2(cx - h * 0.26, cy + h * 0.14, h * 0.11, h * 0.22), Color(0.12, 0.12, 0.12))
			art.draw_rect(Rect2(cx + h * 0.15, cy + h * 0.14, h * 0.11, h * 0.22), Color(0.12, 0.12, 0.12))
			art.draw_rect(Rect2(cx - h * 0.06, cy - h * 0.06, h * 0.12, h * 0.30), Color(0.12, 0.12, 0.12))
		"penguin":
			art.draw_colored_polygon(PackedVector2Array([
				Vector2(cx - h * 0.20, cy + h * 0.36), Vector2(cx - h * 0.13, cy - h * 0.30), Vector2(cx + h * 0.13, cy - h * 0.30), Vector2(cx + h * 0.20, cy + h * 0.36),
			]), Color(0.15, 0.17, 0.22))
			art.draw_colored_polygon(PackedVector2Array([
				Vector2(cx - h * 0.11, cy + h * 0.32), Vector2(cx - h * 0.08, cy - h * 0.22), Vector2(cx + h * 0.08, cy - h * 0.22), Vector2(cx + h * 0.11, cy + h * 0.32),
			]), Color(0.96, 0.96, 0.94))
			art.draw_circle(Vector2(cx - h * 0.055, cy - h * 0.16), h * 0.028, Color(0.05, 0.05, 0.05))
			art.draw_circle(Vector2(cx + h * 0.055, cy - h * 0.16), h * 0.028, Color(0.05, 0.05, 0.05))
			art.draw_colored_polygon(PackedVector2Array([
				Vector2(cx - h * 0.05, cy - h * 0.10), Vector2(cx + h * 0.05, cy - h * 0.10), Vector2(cx, cy - h * 0.04),
			]), Color(0.95, 0.62, 0.20))
			art.draw_rect(Rect2(cx - h * 0.16, cy + h * 0.34, h * 0.12, h * 0.05), Color(0.95, 0.62, 0.20))
			art.draw_rect(Rect2(cx + h * 0.04, cy + h * 0.34, h * 0.12, h * 0.05), Color(0.95, 0.62, 0.20))
		"kangaroo":
			art.draw_circle(Vector2(cx - h * 0.06, cy - h * 0.02), h * 0.24, fg)
			art.draw_circle(Vector2(cx - h * 0.26, cy - h * 0.22), h * 0.12, fg)
			art.draw_colored_polygon(PackedVector2Array([
				Vector2(cx - h * 0.34, cy - h * 0.28), Vector2(cx - h * 0.26, cy - h * 0.34), Vector2(cx - h * 0.24, cy - h * 0.20),
			]), fg)
			art.draw_arc(Vector2(cx + h * 0.42, cy + h * 0.10), h * 0.40, PI * 0.75, PI * 1.45, 20, fg, 7.0)
			art.draw_rect(Rect2(cx - h * 0.10, cy + h * 0.14, h * 0.22, h * 0.08), fg.darkened(0.15))
		"lion":
			art.draw_circle(Vector2(cx, cy), h * 0.32, Color(0.80, 0.55, 0.20))
			art.draw_circle(Vector2(cx, cy + h * 0.02), h * 0.21, Color(0.90, 0.72, 0.40))
			art.draw_circle(Vector2(cx - h * 0.08, cy - h * 0.02), h * 0.03, Color(0.15, 0.12, 0.08))
			art.draw_circle(Vector2(cx + h * 0.08, cy - h * 0.02), h * 0.03, Color(0.15, 0.12, 0.08))
			art.draw_circle(Vector2(cx, cy + h * 0.07), h * 0.035, Color(0.15, 0.12, 0.08))
			art.draw_arc(Vector2(cx, cy - h * 0.30), h * 0.07, PI * 0.9, PI * 2.1, 16, Color(0.80, 0.55, 0.20), 4.0)
		"polar_bear":
			art.draw_circle(Vector2(cx + h * 0.02, cy + h * 0.08), h * 0.30, Color(0.95, 0.96, 0.98))
			art.draw_circle(Vector2(cx - h * 0.26, cy - h * 0.10), h * 0.17, Color(0.95, 0.96, 0.98))
			art.draw_circle(Vector2(cx - h * 0.36, cy - h * 0.24), h * 0.06, Color(0.95, 0.96, 0.98))
			art.draw_circle(Vector2(cx - h * 0.20, cy - h * 0.26), h * 0.06, Color(0.95, 0.96, 0.98))
			art.draw_circle(Vector2(cx - h * 0.30, cy - h * 0.10), h * 0.025, Color(0.10, 0.10, 0.12))
			art.draw_rect(Rect2(cx - h * 0.16, cy + h * 0.28, h * 0.09, h * 0.14), Color(0.88, 0.90, 0.94))
			art.draw_rect(Rect2(cx + h * 0.10, cy + h * 0.28, h * 0.09, h * 0.14), Color(0.88, 0.90, 0.94))
		_:
			art.draw_circle(Vector2(cx, cy), h * 0.26, fg)


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
