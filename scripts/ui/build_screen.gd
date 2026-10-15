class_name BuildScreen
extends Control

## 工坊台建造界面（D-032 Phase 4a）：把 Phase 2 建造数据层接到玩家操作上。
##
## 布局：全屏 3D 预览（SubViewport，背景层）+ 左零件面板 + 右信息面板 + 底栏按钮。
## 预览根节点以蓝图重心为原点，轨道相机环绕；BuildVisualizer 画重心/升力中心/推力线。
##
## 操作（键鼠）：
##   鼠标移动      —— 网格光标（幽灵盒）跟随，红=占用 绿=空闲
##   左键点击      —— 在光标格放置选中零件（对称开启时同步镜像）
##   右键点击      —— 删除光标格零件（含镜像件）
##   左键拖拽      —— 环绕相机
##   滚轮          —— 缩放
##   R / T         —— 旋转光标格零件 / 切换轴对称
##   [ ]           —— 建造层下移 / 上移（多层零件编辑）
##   F             —— 试飞（校验通过则生成蓝图飞机并登机）
##   V / Esc       —— 关闭界面
##
## 持久化：蓝图存 user://blueprint.json，每次打开自动加载、关闭自动保存。
## 经济：进阶零件花绿宝石解锁（PartUnlocks + 玩家库存，D-032 Phase 3c）。
signal test_fly_requested(blueprint: Blueprint)

const BLUEPRINT_PATH := "user://blueprint.json"
const LAYER_RANGE := 4          ## 建造层可调范围 [-4, 4]
const PLATFORM_CELLS := 16      ## 平台半径（格）
const ORBIT_MIN := 6.0
const ORBIT_MAX := 30.0

const PANEL_BG := Color(0.95, 0.92, 0.84)
const BORDER := Color(0.62, 0.47, 0.27)
const TITLE_COLOR := Color(0.36, 0.26, 0.13)
const BODY_COLOR := Color(0.42, 0.32, 0.18)
const SEL_COLOR := Color(0.85, 0.68, 0.30)
const GOOD_COLOR := Color(0.30, 0.55, 0.15)
const BAD_COLOR := Color(0.70, 0.25, 0.18)

var editor := BuildEditor.new()
var _player: Player
var _unlocks := PartUnlocks.new()
## HUD 引用（main 接线）：模态互斥——已有面板打开时 V 键不响应（P2-1）。
var _hud: HUD

var _selected_id := "fuselage"
var _mirror := true
var _build_layer := 0

# 3D 预览
var _viewport: SubViewport
var _cam: Camera3D
var _parts_root: Node3D
var _markers: BuildVisualizer
var _ghost: MeshInstance3D
var _orbit_yaw := deg_to_rad(35.0)
var _orbit_pitch := deg_to_rad(52.0)
var _orbit_dist := 13.0
var _cursor := Vector3i.ZERO
var _cursor_valid := false

# 输入拖拽判定
var _dragging := false
var _drag_dist := 0.0
var _press_pos := Vector2.ZERO

# UI 引用
var _palette: VBoxContainer
var _info: Label
var _status: Label
var _layer_label: Label


func setup(player: Player) -> void:
	_player = player


## 注入 main 持有的持久化解锁实例（user://unlocks.json 读出的那个）——
## 购买/解锁状态跨会话保留。未注入时退回面板自建的临时实例（探针场景）。
func set_unlocks(unlocks: PartUnlocks) -> void:
	if unlocks != null:
		_unlocks = unlocks


## 注入 HUD（main 接线）：模态互斥查询用——HUD 已有面板打开时 V 键不响应。
func set_hud(hud: HUD) -> void:
	_hud = hud


func _ready() -> void:
	# 默认隐藏：V 键唤出。Control 默认 visible=true，必须先置否，
	# 否则 open() 的 visible 守卫会早退、界面也会常驻遮挡游戏画面。
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func open() -> void:
	if visible:
		return
	# 读档：没有存档则从默认可飞套件开局（与解锁种子一致）。
	var bp := Blueprint.load(BLUEPRINT_PATH)
	if bp == null or bp.parts.is_empty():
		bp = Blueprint.new()
		bp.parts = PartRegistry.default_loadout()
	editor.blueprint = bp
	_selected_id = "fuselage"
	_build_layer = 0
	_mirror = true
	_build_ui()
	visible = true
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _player != null:
		_player.input_locked = true
	_refresh()


func close() -> void:
	if not visible:
		return
	# P2-14：保存失败必须让玩家知道（静默丢失 = 儿童用户「我的飞机没了」）。
	if not editor.save(BLUEPRINT_PATH):
		_set_status("自动保存失败：无法写入存档文件。", true)
	visible = false
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _player != null:
		_player.input_locked = false


## ── UI 构建 ────────────────────────────────────────────
func _build_ui() -> void:
	if _palette != null:
		return  # 已构建
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 3D 预览铺满全屏（UI 面板浮在上面，鼠标事件经面板过滤后落到 _unhandled_input）。
	var container := SubViewportContainer.new()
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)
	_viewport = SubViewport.new()
	_viewport.size = Vector2(1152, 648)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.transparent_bg = false
	container.add_child(_viewport)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.19, 0.24)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.58, 0.65)
	env.environment = e
	_viewport.add_child(env)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, 35.0, 0.0)
	light.light_energy = 1.2
	_viewport.add_child(light)

	_parts_root = Node3D.new()
	_viewport.add_child(_parts_root)
	_markers = BuildVisualizer.new()
	_viewport.add_child(_markers)

	_cam = Camera3D.new()
	_cam.fov = 60.0
	_viewport.add_child(_cam)
	_update_camera()

	_build_platform()
	_build_ghost()
	_build_palette()
	_build_info_panel()
	_build_bottom_bar()


func _build_platform() -> void:
	var plat := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(PLATFORM_CELLS * PartData.GRID_METERS, 0.1, PLATFORM_CELLS * PartData.GRID_METERS)
	plat.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.33, 0.38)
	plat.material_override = mat
	plat.position = Vector3(0.0, -0.05, 0.0)
	_viewport.add_child(plat)
	# 网格线（每 2 格 = 1 m 一条，薄片贴平台顶面）。
	var line_mat := StandardMaterial3D.new()
	line_mat.albedo_color = Color(0.45, 0.48, 0.55)
	var half := PLATFORM_CELLS / 2
	for i in range(-half, half + 1, 2):
		for along in [true, false]:
			var line := MeshInstance3D.new()
			var lb := BoxMesh.new()
			if along:
				lb.size = Vector3(PLATFORM_CELLS * PartData.GRID_METERS, 0.012, 0.02)
				line.position = Vector3(0.0, 0.006, i * PartData.GRID_METERS)
			else:
				lb.size = Vector3(0.02, 0.012, PLATFORM_CELLS * PartData.GRID_METERS)
				line.position = Vector3(i * PartData.GRID_METERS, 0.006, 0.0)
			line.mesh = lb
			line.material_override = line_mat
			_viewport.add_child(line)


func _build_ghost() -> void:
	_ghost = MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.4, 1.0, 0.5, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ghost.material_override = mat
	_ghost.visible = false
	_viewport.add_child(_ghost)


func _panel(title: String, at_left: bool) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = BORDER
	style.set_border_width_all(3)
	style.set_corner_radius_all(10)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 12.0
	style.content_margin_bottom = 12.0
	panel.add_theme_stylebox_override("panel", style)
	if at_left:
		panel.anchor_left = 0.0
		panel.anchor_right = 0.0
		panel.anchor_top = 0.0
		panel.anchor_bottom = 0.0
		panel.offset_left = 16.0
		panel.offset_top = 16.0
		panel.grow_horizontal = Control.GROW_DIRECTION_END
	else:
		panel.anchor_left = 1.0
		panel.anchor_right = 1.0
		panel.anchor_top = 0.0
		panel.anchor_bottom = 0.0
		panel.offset_left = -300.0
		panel.offset_top = 16.0
		panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.custom_minimum_size = Vector2(240, 0)
	add_child(panel)
	var title_l := Label.new()
	title_l.text = title
	title_l.add_theme_font_size_override("font_size", 20)
	title_l.add_theme_color_override("font_color", TITLE_COLOR)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.add_child(title_l)
	panel.add_child(v)
	return panel


func _build_palette() -> void:
	var panel := _panel("零件（点击选用）", true)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(240, 420)
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.get_child(0).add_child(scroll)
	_palette = VBoxContainer.new()
	_palette.add_theme_constant_override("separation", 4)
	scroll.add_child(_palette)
	for data in PartRegistry.all():
		var btn := Button.new()
		btn.text = "%s  %.0fkg" % [data.display, data.mass]
		btn.focus_mode = Control.FOCUS_NONE
		btn.add_theme_font_size_override("font_size", 16)
		btn.add_theme_color_override("font_color", BODY_COLOR)
		btn.pressed.connect(_on_part_button.bind(data.id))
		btn.name = "part_%s" % data.id
		_palette.add_child(btn)


func _build_info_panel() -> void:
	var panel := _panel("工坊台", false)
	var v := panel.get_child(0) as VBoxContainer
	_info = Label.new()
	_info.add_theme_font_size_override("font_size", 15)
	_info.add_theme_color_override("font_color", BODY_COLOR)
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.custom_minimum_size = Vector2(260, 0)
	v.add_child(_info)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 14)
	_status.add_theme_color_override("font_color", GOOD_COLOR)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(260, 0)
	v.add_child(_status)


func _build_bottom_bar() -> void:
	var bar := HBoxContainer.new()
	bar.anchor_left = 0.5
	bar.anchor_right = 0.5
	bar.anchor_top = 1.0
	bar.anchor_bottom = 1.0
	bar.offset_left = -230.0
	bar.offset_top = -72.0
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.custom_minimum_size = Vector2(460, 0)
	bar.add_theme_constant_override("separation", 10)
	bar.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(bar)
	_layer_label = Label.new()
	_layer_label.add_theme_font_size_override("font_size", 16)
	_layer_label.add_theme_color_override("font_color", TITLE_COLOR)
	_layer_label.custom_minimum_size = Vector2(110, 0)
	_layer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bar.add_child(_layer_label)
	bar.add_child(_make_bar_button("试飞 (F)", _on_test_fly))
	bar.add_child(_make_bar_button("保存蓝图", _on_save_clicked))
	bar.add_child(_make_bar_button("关闭 (V)", close))


func _make_bar_button(text: String, handler: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(110, 40)
	btn.add_theme_font_size_override("font_size", 16)
	btn.add_theme_color_override("font_color", TITLE_COLOR)
	btn.pressed.connect(handler)
	return btn


## ── 输入 ───────────────────────────────────────────────
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		# 模态栈只允许一层：HUD 已有面板/窗口打开时让位（P2-1）。
		# 驾驶飞行器中 V 让位给自由观察（D-033）：不拦这里，建造界面会在
		# 飞行中被 V 唤出（BuildScreen 比 HUD 更早收到输入，HUD 消费拦不住）。
		if event.is_action_pressed("toggle_build") \
				and (_hud == null or not _hud.is_any_panel_open()) \
				and not (_player != null and _player.is_riding()):
			open()
		return

	if event.is_action_pressed("toggle_build") or event.is_action_pressed("ui_cancel"):
		close()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			_rotate_cursor()
		elif event.keycode == KEY_T:
			_mirror = not _mirror
			_set_status("轴对称：%s" % ("开" if _mirror else "关"))
			_refresh()
		elif event.keycode == KEY_BRACKETLEFT:
			_build_layer = clampi(_build_layer - 1, -LAYER_RANGE, LAYER_RANGE)
			_refresh()
		elif event.keycode == KEY_BRACKETRIGHT:
			_build_layer = clampi(_build_layer + 1, -LAYER_RANGE, LAYER_RANGE)
			_refresh()
		elif event.is_action_pressed("aircraft_exit"):  # X 试飞（D-033：F 改为发动机）
			_on_test_fly()

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_orbit_dist = clampf(_orbit_dist - 1.5, ORBIT_MIN, ORBIT_MAX)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_orbit_dist = clampf(_orbit_dist + 1.5, ORBIT_MIN, ORBIT_MAX)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = true
				_drag_dist = 0.0
				_press_pos = event.position
			else:
				if _dragging and _drag_dist < 5.0:
					_place_cursor()
				_dragging = false
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_delete_cursor()
	elif event is InputEventMouseMotion:
		if _dragging:
			_drag_dist += event.relative.length()
			_orbit_yaw -= event.relative.x * 0.01
			_orbit_pitch = clampf(_orbit_pitch - event.relative.y * 0.01, 0.15, 1.45)
			_update_camera()
		_update_cursor(event.position)


## 鼠标世界射线 → 与建造层水平面求交 → 光标格。
func _update_cursor(mouse_pos: Vector2) -> void:
	if _cam == null:
		return
	var from := _cam.project_ray_origin(mouse_pos)
	var dir := _cam.project_ray_normal(mouse_pos)
	var plane_y := float(_build_layer + 1) * PartData.GRID_METERS
	if absf(dir.y) < 0.0001:
		_cursor_valid = false
		_ghost.visible = false
		return
	var t := (plane_y - from.y) / dir.y
	if t <= 0.0:
		_cursor_valid = false
		_ghost.visible = false
		return
	var hit := from + dir * t
	var cell := Vector3i(
		int(floor(hit.x / PartData.GRID_METERS)),
		_build_layer,
		int(floor(hit.z / PartData.GRID_METERS)))
	var limit := PLATFORM_CELLS / 2 - 2
	if absi(cell.x) > limit or absi(cell.z) > limit:
		_cursor_valid = false
		_ghost.visible = false
		return
	_cursor = cell
	_cursor_valid = true
	var data := PartRegistry.by_id(_selected_id)
	if data == null:
		_ghost.visible = false
		return
	# 放置时旋转恒 0，footprint 即 size 本身；对称镜像占 X=0 另一侧同跨度。
	var occupied_cells: Dictionary = editor.occupied()
	var free := true
	for dx in range(data.size.x):
		for dy in range(data.size.y):
			for dz in range(data.size.z):
				if occupied_cells.has(Vector3i(cell.x + dx, cell.y + dy, cell.z + dz)):
					free = false
	if _mirror:
		var m_anchor := Vector3i(-(cell.x + data.size.x - 1), cell.y, cell.z)
		for dx in range(data.size.x):
			for dy in range(data.size.y):
				for dz in range(data.size.z):
					if occupied_cells.has(Vector3i(m_anchor.x + dx, cell.y + dy, cell.z + dz)):
						free = false
	var mesh := _ghost.mesh as BoxMesh
	if mesh == null:
		mesh = BoxMesh.new()
		_ghost.mesh = mesh
	mesh.size = Vector3(data.size) * PartData.GRID_METERS
	_ghost.position = Vector3(
		(cell.x + data.size.x * 0.5) * PartData.GRID_METERS,
		(cell.y + data.size.y * 0.5) * PartData.GRID_METERS,
		(cell.z + data.size.z * 0.5) * PartData.GRID_METERS)
	_ghost.rotation_degrees = Vector3.ZERO
	var mat := _ghost.material_override as StandardMaterial3D
	mat.albedo_color = Color(0.4, 1.0, 0.5, 0.35) if free else Color(1.0, 0.35, 0.3, 0.35)
	_ghost.visible = true


func _place_cursor() -> void:
	if not _cursor_valid:
		return
	var data := PartRegistry.by_id(_selected_id)
	if data == null:
		return
	# 完整 footprint 冲突判定（锚格 + 全部占格 + 镜像占格）。
	var occ: Dictionary = editor.occupied()
	for dx in range(data.size.x):
		for dy in range(data.size.y):
			for dz in range(data.size.z):
				if occ.has(Vector3i(_cursor.x + dx, _cursor.y + dy, _cursor.z + dz)):
					_set_status("这格已有零件。", true)
					return
	if _mirror:
		var m := Vector3i(-(_cursor.x + data.size.x - 1), _cursor.y, _cursor.z)
		for dx in range(data.size.x):
			for dy in range(data.size.y):
				for dz in range(data.size.z):
					if occ.has(Vector3i(m.x + dx, m.y + dy, m.z + dz)):
						_set_status("镜像位置已有零件。", true)
						return
	if not _unlocks.is_unlocked(data.id):
		_set_status("%s 未解锁（%d 绿宝石）。" % [data.display, _unlocks.cost_of(data.id)], true)
		return
	editor.place(data, _cursor, 0, _mirror)
	_refresh()


func _delete_cursor() -> void:
	if not _cursor_valid:
		return
	editor.remove_at(_cursor, _mirror)
	_refresh()


func _rotate_cursor() -> void:
	if not _cursor_valid:
		return
	editor.rotate_at(_cursor, _mirror)
	_refresh()


## ── 按钮回调 ───────────────────────────────────────────
func _on_part_button(id: String) -> void:
	if not _unlocks.is_unlocked(id):
		_try_buy(id)
		return
	_selected_id = id
	_refresh()


func _try_buy(id: String) -> void:
	var data := PartRegistry.by_id(id)
	if data == null:
		return
	var balance := _emeralds()
	var res: Dictionary = _unlocks.purchase(id, balance)
	if bool(res.get("ok", false)):
		if _player != null:
			_player.inventory.consume_item(ItemTypes.EMERALD, int(res.get("spent", 0)))
		_selected_id = id
		# P2-14：解锁落盘失败要提示——否则玩家重启后发现还得再买一次。
		if not _unlocks.save():
			_set_status("解锁保存失败：重启后可能需要重新购买。", true)
		_set_status("已解锁 %s！" % data.display)
	else:
		var reason := String(res.get("reason", ""))
		if reason == "insufficient":
			_set_status("绿宝石不足：%s 需要 %d，你有 %d。" % [data.display, data.cost, balance], true)
	_refresh()


func _emeralds() -> int:
	if _player == null or _player.inventory == null:
		return 0
	return _player.inventory.count_item(ItemTypes.EMERALD)


func _on_save_clicked() -> void:
	if not editor.save(BLUEPRINT_PATH):
		_set_status("保存失败：无法写入存档文件。", true)
		return
	_set_status("蓝图已保存。")


func _on_test_fly() -> void:
	var v: Dictionary = editor.validate()
	if not bool(v.get("ok", false)):
		var errors: Array = v.get("errors", [])
		var first := String(errors[0]) if errors.size() > 0 else "未知"
		_set_status("飞机不完整（%s）：%s" % [first, _hint_for(first)], true)
		return
	if not editor.save(BLUEPRINT_PATH):
		_set_status("保存失败：无法写入存档文件，本次试飞不会保留蓝图。", true)
	close()
	test_fly_requested.emit(editor.blueprint)

func _hint_for(error_code: String) -> String:
	if error_code == "no_fuselage":
		return "必须有机身。"
	if error_code.begins_with("orphan:"):
		return "有零件没连到机身上，检查缝隙。"
	if error_code == "empty":
		return "蓝图是空的。"
	return ""


## ── 刷新 ───────────────────────────────────────────────
func _refresh() -> void:
	if _parts_root == null:
		return
	# 零件外观：以重心为原点，方便相机环绕。
	for c in _parts_root.get_children():
		_parts_root.remove_child(c)
		c.queue_free()
	var com := editor.blueprint.center_of_gravity()
	for p in editor.blueprint.parts:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(p.data.size) * PartData.GRID_METERS
		mi.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = _category_color(p.data.category)
		mat.metallic = 0.1
		mat.roughness = 0.7
		mi.material_override = mat
		mi.position = p.local_pos() - com
		mi.rotation_degrees = Vector3(0.0, float(p.rot) * 90.0, 0.0)
		_parts_root.add_child(mi)
	_markers.rebuild(editor.blueprint)
	_refresh_palette()
	_refresh_info()


func _refresh_palette() -> void:
	if _palette == null:
		return
	for btn in _palette.get_children():
		var b := btn as Button
		var id := String(b.name).trim_prefix("part_")
		var data := PartRegistry.by_id(id)
		if data == null:
			continue
		var unlocked := _unlocks.is_unlocked(id)
		var text := "%s  %.0fkg" % [data.display, data.mass]
		if not unlocked:
			text += "  🔒%d" % _unlocks.cost_of(id)
		b.text = text
		b.add_theme_color_override("font_color",
			BODY_COLOR if unlocked else Color(0.55, 0.45, 0.40))
		if id == _selected_id and unlocked:
			b.add_theme_color_override("font_color", SEL_COLOR)
			b.add_theme_font_size_override("font_size", 17)


func _refresh_info() -> void:
	if _info == null:
		return
	var af := editor.blueprint.aggregate()
	var v: Dictionary = editor.validate()
	var lines: Array[String] = []
	lines.append("零件数：%d" % editor.blueprint.parts.size())
	lines.append("总质量：%.0f kg" % af.mass)
	lines.append("翼面积：%.1f m²" % af.wing_area)
	lines.append("推力：%.0f N" % af.thrust_max)
	var com := editor.blueprint.center_of_gravity()
	lines.append("重心：(%.1f, %.1f, %.1f) m" % [com.x, com.y, com.z])
	lines.append("失速速度：%.1f km/h" % (AircraftFlight.stall_speed(AircraftFlight.SEA_LEVEL_DENSITY, af) * AircraftFlight.MPS_TO_KMH))
	if bool(v.get("ok", false)):
		lines.append("结构：✔ 合法可飞")
	else:
		lines.append("结构：✘ %s" % String((v.get("errors", []) as Array)[0] if (v.get("errors", []) as Array).size() > 0 else "?"))
	lines.append("绿宝石：%d" % _emeralds())
	lines.append("")
	lines.append("左键放置 / 右键删除 / R 旋转")
	lines.append("T 轴对称：%s" % ("开" if _mirror else "关"))
	lines.append("拖拽环绕 / 滚轮缩放")
	lines.append("F 试飞 · V 关闭")
	_info.text = "\n".join(lines)
	if _layer_label != null:
		_layer_label.text = "建造层 %d [ ]" % _build_layer


func _set_status(text: String, bad: bool = false) -> void:
	if _status == null:
		return
	_status.text = text
	_status.add_theme_color_override("font_color", BAD_COLOR if bad else GOOD_COLOR)


func _update_camera() -> void:
	if _cam == null:
		return
	var cp := cos(_orbit_pitch)
	_cam.position = Vector3(
		sin(_orbit_yaw) * cp * _orbit_dist,
		sin(_orbit_pitch) * _orbit_dist,
		cos(_orbit_yaw) * cp * _orbit_dist)
	_cam.look_at(Vector3.ZERO, Vector3.UP)


## 零件类别配色（与 Aircraft._category_color 同源，界面层不依赖机体私有函数）。
static func _category_color(cat: int) -> Color:
	match cat:
		PartData.Category.FUSELAGE:  return Color(0.75, 0.78, 0.82)
		PartData.Category.WING:      return Color(0.30, 0.55, 0.85)
		PartData.Category.TAIL:      return Color(0.45, 0.65, 0.90)
		PartData.Category.ENGINE:    return Color(0.35, 0.35, 0.40)
		PartData.Category.PROPELLER: return Color(0.20, 0.20, 0.22)
		PartData.Category.GEAR:      return Color(0.55, 0.50, 0.30)
		PartData.Category.FUEL_TANK: return Color(0.80, 0.55, 0.25)
		_:                           return Color(0.70, 0.70, 0.70)
