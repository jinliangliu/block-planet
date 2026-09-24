extends CanvasLayer
class_name HUD
## 移动端触屏 HUD：左侧摇杆、右侧视角滑动、右下角动作按钮。
## 桌面环境显示键位提示。

var _player: Player
var _slot_group: ButtonGroup
var _slot_buttons: Array[Button] = []
var _hunger_label: Label
var _name_label: Label
var _hp_bar: ProgressBar
var _minimap: MiniMap
var _time_label: Label
var _mode_label: Label
var _day_night: DayNightCycle
var _craft_overlay: Control
var _craft_list: VBoxContainer
var _trade_overlay: Control
var _trade_list: VBoxContainer
var _box_overlay: Control
var _box_grid: GridContainer
var _box_player_grid: GridContainer
var _open_box_cell := Vector3i.ZERO
var _box_inventory: Inventory
var _smelt_overlay: Control
var _smelt_list: VBoxContainer
var _fly_button: Button
var _descend_button: Button
var _break_bar: ProgressBar
var _look_touch := -1


func setup(player: Player) -> void:
	InputActions.register()
	_player = player
	_player.selected_slot_changed.connect(_on_player_slot_changed)
	_player.health_changed.connect(_on_health_changed)
	_player.hunger_changed.connect(_on_hunger_changed)
	_player.inventory.changed.connect(_refresh_hotbar)
	GameState.mode_changed.connect(_on_mode_changed)
	Events.player_mode_changed.connect(_on_player_flying_changed)
	Events.request_trade.connect(set_trade_open.bind(true))
	_build()
	_on_mode_changed(GameState.mode)


func set_day_night(day_night: DayNightCycle) -> void:
	_day_night = day_night
	if day_night:
		day_night.time_changed.connect(_on_time_changed)
		_refresh_time()


func _build() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_build_stats(root)
	_build_crosshair(root)

	if DisplayServer.is_touchscreen_available():
		_build_joystick(root)
		_build_look_area(root)
		_build_action_buttons(root)
	else:
		_build_desktop_hint(root)

	_build_hotbar(root)
	_build_craft_panel(root)
	_build_trade_panel(root)
	_build_box_panel(root)
	_build_smelt_panel(root)
	_build_minimap(root)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.is_action_pressed("toggle_craft"):
			_toggle_craft_panel()
		elif event.is_action_pressed("toggle_mode"):
			_toggle_game_mode()
		elif event.is_action_pressed("toggle_trade"):
			_toggle_trade_panel()


func _process(_delta: float) -> void:
	if _player == null or _break_bar == null:
		return
	var breaking := _player.is_breaking()
	_break_bar.visible = breaking
	if breaking:
		_break_bar.value = _player.break_ratio()


## 屏幕中心准星 + 破坏进度条：破坏需按住左键，准星与进度提供必要反馈。
func _build_crosshair(root: Control) -> void:
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(overlay)

	var h := ColorRect.new()
	h.color = Color(1.0, 1.0, 1.0, 0.7)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	h.offset_left = -9.0
	h.offset_right = 9.0
	h.offset_top = -1.0
	h.offset_bottom = 1.0
	overlay.add_child(h)

	var v := ColorRect.new()
	v.color = Color(1.0, 1.0, 1.0, 0.7)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	v.offset_left = -1.0
	v.offset_right = 1.0
	v.offset_top = -9.0
	v.offset_bottom = 9.0
	overlay.add_child(v)

	_break_bar = ProgressBar.new()
	_break_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_break_bar.show_percentage = false
	_break_bar.max_value = 1.0
	_break_bar.custom_minimum_size = Vector2(64.0, 7.0)
	_break_bar.visible = false
	_break_bar.modulate = Color(1.0, 0.9, 0.5)
	_break_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_break_bar.offset_left = -32.0
	_break_bar.offset_right = 32.0
	_break_bar.offset_top = 18.0
	_break_bar.offset_bottom = 25.0
	overlay.add_child(_break_bar)


func _toggle_game_mode() -> void:
	if GameState.is_survival():
		GameState.set_mode(GameState.Mode.CREATIVE)
	else:
		GameState.set_mode(GameState.Mode.SURVIVAL)


func _build_joystick(root: Control) -> void:
	var stick := VirtualJoystick.new()
	root.add_child(stick)

	stick.anchor_left = 0.0
	stick.anchor_top = 1.0
	stick.anchor_right = 0.0
	stick.anchor_bottom = 1.0
	var s := stick.custom_minimum_size
	stick.offset_left = 32.0
	stick.offset_top = -(s.y + 32.0)
	stick.offset_right = 32.0 + s.x
	stick.offset_bottom = -32.0

	stick.value_changed.connect(_on_joystick_changed)


func _build_look_area(root: Control) -> void:
	var look := Control.new()
	look.anchor_left = 0.35
	look.anchor_top = 0.0
	look.anchor_right = 1.0
	look.anchor_bottom = 1.0
	look.mouse_filter = Control.MOUSE_FILTER_STOP
	look.gui_input.connect(_on_look_input)
	root.add_child(look)


func _build_action_buttons(root: Control) -> void:
	var jump := Button.new()
	jump.text = "跳"
	jump.custom_minimum_size = Vector2(92, 92)
	jump.focus_mode = Control.FOCUS_NONE
	jump.button_down.connect(_on_jump_down)
	_anchor_bottom_right(root, jump, 28.0, 28.0)

	_fly_button = Button.new()
	_fly_button.text = "飞"
	_fly_button.custom_minimum_size = Vector2(76, 76)
	_fly_button.focus_mode = Control.FOCUS_NONE
	_fly_button.button_down.connect(_on_fly_down)
	_fly_button.visible = GameState.is_creative()
	_anchor_bottom_right(root, _fly_button, 34.0, 138.0)

	var descend := Button.new()
	descend.text = "降"
	descend.custom_minimum_size = Vector2(76, 76)
	descend.focus_mode = Control.FOCUS_NONE
	descend.button_down.connect(_on_descend_down)
	descend.button_up.connect(_on_descend_up)
	descend.visible = GameState.is_creative()
	_anchor_bottom_right(root, descend, 120.0, 138.0)
	_descend_button = descend

	var break_button := Button.new()
	break_button.text = "挖"
	break_button.custom_minimum_size = Vector2(92, 92)
	break_button.focus_mode = Control.FOCUS_NONE
	break_button.button_down.connect(_on_break_down)
	break_button.button_up.connect(_on_break_up)
	_anchor_bottom_right(root, break_button, 136.0, 28.0)

	var place_button := Button.new()
	place_button.text = "放"
	place_button.custom_minimum_size = Vector2(92, 92)
	place_button.focus_mode = Control.FOCUS_NONE
	place_button.button_down.connect(_on_place_down)
	_anchor_bottom_right(root, place_button, 244.0, 28.0)

	var craft_button := Button.new()
	craft_button.text = "合成"
	craft_button.custom_minimum_size = Vector2(76, 76)
	craft_button.focus_mode = Control.FOCUS_NONE
	craft_button.pressed.connect(_toggle_craft_panel)
	_anchor_bottom_right(root, craft_button, 142.0, 138.0)

	var mode_button := Button.new()
	mode_button.text = "模式"
	mode_button.custom_minimum_size = Vector2(76, 76)
	mode_button.focus_mode = Control.FOCUS_NONE
	mode_button.pressed.connect(_toggle_game_mode)
	_anchor_bottom_right(root, mode_button, 228.0, 138.0)

	var trade_button := Button.new()
	trade_button.text = "交易"
	trade_button.custom_minimum_size = Vector2(76, 76)
	trade_button.focus_mode = Control.FOCUS_NONE
	trade_button.pressed.connect(_toggle_trade_panel)
	_anchor_bottom_right(root, trade_button, 314.0, 138.0)

	var smelt_button := Button.new()
	smelt_button.text = "冶炼"
	smelt_button.custom_minimum_size = Vector2(76, 76)
	smelt_button.focus_mode = Control.FOCUS_NONE
	smelt_button.pressed.connect(_toggle_smelt_panel)
	_anchor_bottom_right(root, smelt_button, 400.0, 138.0)


func _build_hotbar(root: Control) -> void:
	var blocks := BlockTypes.HOTBAR_BLOCKS
	var slot_size := 52.0
	var gap := 6.0
	var total := blocks.size() * slot_size + (blocks.size() - 1) * gap

	var bar := Control.new()
	bar.anchor_left = 0.5
	bar.anchor_top = 1.0
	bar.anchor_right = 0.5
	bar.anchor_bottom = 1.0
	bar.offset_left = -total / 2.0
	bar.offset_right = total / 2.0
	bar.offset_top = -(slot_size + 16.0)
	bar.offset_bottom = -16.0
	bar.mouse_filter = Control.MOUSE_FILTER_PASS
	root.add_child(bar)

	_slot_group = ButtonGroup.new()
	for i in range(blocks.size()):
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = _slot_group
		b.custom_minimum_size = Vector2(slot_size, slot_size)
		b.focus_mode = Control.FOCUS_NONE
		b.position = Vector2(i * (slot_size + gap), 0)
		b.pressed.connect(_on_slot_pressed.bind(i))
		_slot_buttons.append(b)
		bar.add_child(b)

	if not _slot_buttons.is_empty():
		_slot_buttons[0].button_pressed = true
	_refresh_hotbar()


## 左上角状态面板：头像 + 姓名 + 生命条 + 饥饿/时间/模式文本。
func _build_stats(root: Control) -> void:
	var row := HBoxContainer.new()
	row.position = Vector2(16, 16)
	row.add_theme_constant_override("separation", 10)
	root.add_child(row)

	var avatar := Control.new()
	avatar.custom_minimum_size = Vector2(48, 48)
	avatar.draw.connect(_draw_avatar.bind(avatar))
	row.add_child(avatar)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	row.add_child(box)

	_name_label = Label.new()
	_name_label.text = "小方块"
	_name_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.98))
	_name_label.add_theme_font_size_override("font_size", 20)
	box.add_child(_name_label)

	_hp_bar = ProgressBar.new()
	_hp_bar.min_value = 0
	_hp_bar.max_value = Player.MAX_HEALTH
	_hp_bar.show_percentage = false
	_hp_bar.custom_minimum_size = Vector2(150, 14)
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.12, 0.12, 0.14, 0.9)
	bar_bg.set_corner_radius_all(4)
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = Color(0.85, 0.25, 0.25)
	bar_fill.set_corner_radius_all(4)
	_hp_bar.add_theme_stylebox_override("background", bar_bg)
	_hp_bar.add_theme_stylebox_override("fill", bar_fill)
	box.add_child(_hp_bar)

	_hunger_label = Label.new()
	_hunger_label.add_theme_color_override("font_color", Color(1.0, 0.78, 0.35))
	_hunger_label.add_theme_font_size_override("font_size", 18)
	box.add_child(_hunger_label)

	_time_label = Label.new()
	_time_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.95))
	_time_label.add_theme_font_size_override("font_size", 18)
	box.add_child(_time_label)

	_mode_label = Label.new()
	_mode_label.add_theme_color_override("font_color", Color(0.6, 0.9, 1.0, 0.95))
	_mode_label.add_theme_font_size_override("font_size", 18)
	box.add_child(_mode_label)

	_refresh_stats()


## 块状像素头像：发/脸/眼/嘴，与方块世界风格一致。
func _draw_avatar(avatar: Control) -> void:
	var cell := avatar.size.x / 8.0
	if cell <= 0.0:
		return
	avatar.draw_rect(Rect2(Vector2.ZERO, avatar.size), Color(0.14, 0.14, 0.18))
	avatar.draw_rect(Rect2(Vector2(cell, 0), Vector2(cell * 6, cell * 2)), Color(0.36, 0.22, 0.12))
	avatar.draw_rect(Rect2(Vector2(cell, cell * 2), Vector2(cell * 6, cell * 5)), Color(0.94, 0.78, 0.62))
	avatar.draw_rect(Rect2(Vector2(cell * 2, cell * 3.4), Vector2(cell, cell * 0.8)), Color(0.10, 0.10, 0.14))
	avatar.draw_rect(Rect2(Vector2(cell * 5, cell * 3.4), Vector2(cell, cell * 0.8)), Color(0.10, 0.10, 0.14))
	avatar.draw_rect(Rect2(Vector2(cell * 3, cell * 5.6), Vector2(cell * 2, cell * 0.7)), Color(0.72, 0.40, 0.40))


func _anchor_bottom_right(root: Control, control: Control, right_margin: float, bottom_margin: float) -> void:
	root.add_child(control)
	control.anchor_left = 1.0
	control.anchor_top = 1.0
	control.anchor_right = 1.0
	control.anchor_bottom = 1.0
	var s := control.custom_minimum_size
	control.offset_left = -(right_margin + s.x)
	control.offset_top = -(bottom_margin + s.y)
	control.offset_right = -right_margin
	control.offset_bottom = -bottom_margin


func _build_desktop_hint(root: Control) -> void:
	var label := Label.new()
	label.text = "WASD 移动 · 鼠标视角 · 滚轮拉近/拉远(拉远看角色) · 左键按住破坏/左键攻击 · 右键放置/吃食物/开箱/冶炼 · 1-9 选方块 · E 合成 · M 切换模式 · 空格跳跃 · 双击空格飞行(创造) · Ctrl 下降 · Shift冲刺 · Esc释放鼠标"
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.9))
	label.add_theme_font_size_override("font_size", 18)
	label.position = Vector2(16, 12)
	root.add_child(label)


func _on_joystick_changed(value: Vector2) -> void:
	if _player:
		_player.virtual_move = Vector2(value.x, -value.y)


func _on_look_input(event: InputEvent) -> void:
	if _player == null:
		return
	if event is InputEventScreenTouch:
		if event.pressed and _look_touch == -1:
			_look_touch = event.index
		elif not event.pressed and event.index == _look_touch:
			_look_touch = -1
	elif event is InputEventScreenDrag and event.index == _look_touch:
		_player.virtual_look += event.relative


func _on_jump_down() -> void:
	if _player:
		_player.virtual_jump = true


func _on_break_down() -> void:
	if _player:
		_player.start_break_or_attack()


func _on_break_up() -> void:
	if _player:
		_player.break_held = false


func _on_place_down() -> void:
	if _player:
		_player.virtual_place = true


func _on_fly_down() -> void:
	if _player:
		_player.set_flying(not _player.flying)


func _on_descend_down() -> void:
	if _player:
		_player.virtual_descend = true


func _on_descend_up() -> void:
	if _player:
		_player.virtual_descend = false


func _on_player_flying_changed(flying: bool) -> void:
	if _fly_button:
		_fly_button.text = "走" if flying else "飞"


func _on_slot_pressed(slot: int) -> void:
	if _player:
		_player.selected_slot = slot


func _on_player_slot_changed(slot: int) -> void:
	if slot >= 0 and slot < _slot_buttons.size():
		_slot_buttons[slot].button_pressed = true


func _refresh_hotbar() -> void:
	if _player == null:
		return
	var blocks := BlockTypes.HOTBAR_BLOCKS
	for i in range(_slot_buttons.size()):
		var b := _slot_buttons[i]
		if GameState.is_creative():
			if i < blocks.size():
				b.text = BlockTypes.short_name(blocks[i])
		else:
			var item := _player.inventory.get_item(i)
			if item == BlockTypes.Block.AIR:
				b.text = "-"
			elif ItemTypes.is_tool_item(item):
				b.text = "%s %d" % [ItemTypes.item_short_name(item), _player.inventory.get_durability(i)]
			else:
				var count := _player.inventory.get_count(i)
				b.text = "%s×%d" % [BlockTypes.short_name(item), count]


func _build_craft_panel(root: Control) -> void:
	_craft_overlay = Control.new()
	_craft_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_craft_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_craft_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	_craft_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_craft_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(500, 480)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "合成台"
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	_craft_list = VBoxContainer.new()
	_craft_list.add_theme_constant_override("separation", 8)
	vbox.add_child(_craft_list)

	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, 44)
	close.pressed.connect(func(): set_craft_open(false))
	vbox.add_child(close)

	_craft_overlay.visible = false
	_refresh_craft_panel()


func _toggle_craft_panel() -> void:
	if _craft_overlay:
		set_craft_open(not _craft_overlay.visible)


func set_craft_open(open: bool) -> void:
	if _craft_overlay == null:
		return
	_craft_overlay.visible = open
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	if open:
		_refresh_craft_panel()


func _refresh_craft_panel() -> void:
	if _craft_list == null:
		return
	for child in _craft_list.get_children():
		_craft_list.remove_child(child)
		child.queue_free()

	for recipe in ItemTypes.RECIPES:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		_craft_list.add_child(row)

		var label := Label.new()
		label.text = _recipe_text(recipe)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		var button := Button.new()
		button.text = "制作"
		button.custom_minimum_size = Vector2(84, 40)
		button.focus_mode = Control.FOCUS_NONE
		button.disabled = not _can_craft(recipe)
		button.pressed.connect(_on_craft_pressed.bind(recipe))
		row.add_child(button)


func _recipe_text(recipe: Dictionary) -> String:
	var parts: Array[String] = []
	for ingredient in recipe["ingredients"]:
		parts.append("%s×%d" % [ItemTypes.item_short_name(ingredient), int(recipe["ingredients"][ingredient])])
	return "%s  →  %s" % [" + ".join(parts), ItemTypes.item_name(recipe["result"])]


func _can_craft(recipe: Dictionary) -> bool:
	if _player == null:
		return false
	return _player.inventory.can_craft(recipe)


func _on_craft_pressed(recipe: Dictionary) -> void:
	if _player == null:
		return
	if _player.inventory.craft(recipe):
		_refresh_craft_panel()
		_refresh_hotbar()


func _build_trade_panel(root: Control) -> void:
	_trade_overlay = Control.new()
	_trade_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_trade_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_trade_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	_trade_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_trade_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(500, 480)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "村庄交易（用绿宝石交换）"
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	_trade_list = VBoxContainer.new()
	_trade_list.add_theme_constant_override("separation", 8)
	vbox.add_child(_trade_list)

	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, 44)
	close.pressed.connect(func(): set_trade_open(false))
	vbox.add_child(close)

	_trade_overlay.visible = false
	_refresh_trade_panel()


func _toggle_trade_panel() -> void:
	if _trade_overlay:
		set_trade_open(not _trade_overlay.visible)


func set_trade_open(open: bool) -> void:
	if _trade_overlay == null:
		return
	_trade_overlay.visible = open
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	if open:
		_refresh_trade_panel()


func _refresh_trade_panel() -> void:
	if _trade_list == null:
		return
	for child in _trade_list.get_children():
		_trade_list.remove_child(child)
		child.queue_free()

	for trade in ItemTypes.TRADES:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		_trade_list.add_child(row)

		var label := Label.new()
		label.text = _trade_text(trade)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		var button := Button.new()
		button.text = "交换"
		button.custom_minimum_size = Vector2(84, 40)
		button.focus_mode = Control.FOCUS_NONE
		button.disabled = not _can_trade(trade)
		button.pressed.connect(_on_trade_pressed.bind(trade))
		row.add_child(button)


func _trade_text(trade: Dictionary) -> String:
	return "绿宝石×%d  →  %s×%d" % [
		int(trade["cost"]),
		ItemTypes.item_name(trade["result"]),
		int(trade["count"]),
	]


func _can_trade(trade: Dictionary) -> bool:
	if _player == null:
		return false
	var inv: Inventory = _player.inventory
	return inv.count_item(ItemTypes.EMERALD) >= int(trade["cost"]) \
		and inv.has_space_for(trade["result"])


func _on_trade_pressed(trade: Dictionary) -> void:
	if _player == null:
		return
	if _player.inventory.consume_item(ItemTypes.EMERALD, int(trade["cost"])):
		_player.inventory.add_item(trade["result"], int(trade["count"]))
		_refresh_trade_panel()
		_refresh_hotbar()


## 储物箱面板：上 27 格为箱内格子、下 9 格为玩家快捷栏。
## 点击任一格把该格整叠转移到另一侧（工具不可堆叠按容量截断）。
func _build_box_panel(root: Control) -> void:
	_box_overlay = Control.new()
	_box_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_box_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_box_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	_box_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(560, 540)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "储物箱"
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	var box_label := Label.new()
	box_label.text = "箱子（点击整叠取出）"
	box_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(box_label)

	_box_grid = GridContainer.new()
	_box_grid.columns = 9
	_box_grid.add_theme_constant_override("h_separation", 4)
	_box_grid.add_theme_constant_override("v_separation", 4)
	vbox.add_child(_box_grid)

	var player_label := Label.new()
	player_label.text = "背包（点击整叠存入）"
	player_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(player_label)

	_box_player_grid = GridContainer.new()
	_box_player_grid.columns = 9
	_box_player_grid.add_theme_constant_override("h_separation", 4)
	_box_player_grid.add_theme_constant_override("v_separation", 4)
	vbox.add_child(_box_player_grid)

	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, 44)
	close.pressed.connect(func(): set_box_open(false))
	vbox.add_child(close)

	for i in range(27):
		var b := Button.new()
		b.custom_minimum_size = Vector2(52, 52)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_on_box_slot_pressed.bind(i))
		_box_grid.add_child(b)
	for i in range(Inventory.SLOT_COUNT):
		var b := Button.new()
		b.custom_minimum_size = Vector2(52, 52)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_on_box_player_slot_pressed.bind(i))
		_box_player_grid.add_child(b)

	_box_overlay.visible = false
	Events.request_box_open.connect(_on_request_box_open)
	Events.block_broken.connect(_on_box_block_broken)


func _on_request_box_open(cell: Vector3i) -> void:
	if _player == null or _player.get_world() == null:
		return
	_open_box_cell = cell
	_box_inventory = _player.get_world().get_box(cell)
	set_box_open(true)


## 箱子被破坏时若面板正开着这只箱子，立即关闭（内容已散落）。
func _on_box_block_broken(block_id: int, cell: Vector3i) -> void:
	if block_id == BlockTypes.Block.CHEST and cell == _open_box_cell:
		set_box_open(false)


func set_box_open(open: bool) -> void:
	if _box_overlay == null:
		return
	_box_overlay.visible = open
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	if open:
		_refresh_box_panel()


func _refresh_box_panel() -> void:
	if _box_grid == null or _box_player_grid == null:
		return
	if _box_inventory == null or _player == null:
		return
	for i in range(27):
		var b := _box_grid.get_child(i) as Button
		_set_slot_text(b, _box_inventory.slots[i])
	for i in range(Inventory.SLOT_COUNT):
		var b := _box_player_grid.get_child(i) as Button
		_set_slot_text(b, _player.inventory.slots[i])


func _set_slot_text(b: Button, slot: Dictionary) -> void:
	var item: int = slot["item"]
	var count: int = slot["count"]
	if item == BlockTypes.Block.AIR or count <= 0:
		b.text = "-"
		return
	if ItemTypes.is_tool_item(item):
		b.text = "%s %d" % [ItemTypes.item_short_name(item), int(slot["durability"])]
	elif ItemTypes.is_plain_item(item):
		b.text = "%s×%d" % [ItemTypes.item_short_name(item), count]
	else:
		b.text = "%s×%d" % [BlockTypes.short_name(item), count]


func _on_box_slot_pressed(index: int) -> void:
	if _box_inventory == null or _player == null:
		return
	var slot: Dictionary = _box_inventory.slots[index]
	var item: int = slot["item"]
	var count: int = slot["count"]
	if item == BlockTypes.Block.AIR or count <= 0:
		return
	var remaining := _player.inventory.add_item(item, count)
	var moved := count - remaining
	if moved <= 0:
		return
	_box_inventory.remove_item(index, moved)
	_refresh_box_panel()
	_refresh_hotbar()


func _on_box_player_slot_pressed(index: int) -> void:
	if _box_inventory == null or _player == null:
		return
	var slot: Dictionary = _player.inventory.slots[index]
	var item: int = slot["item"]
	var count: int = slot["count"]
	if item == BlockTypes.Block.AIR or count <= 0:
		return
	var remaining := _box_inventory.add_item(item, count)
	var moved := count - remaining
	if moved <= 0:
		return
	_player.inventory.remove_item(index, moved)
	_refresh_box_panel()
	_refresh_hotbar()


## 冶炼炉面板：矿石炼锭、铜锡合青铜，材料齐备时按钮可用。
func _build_smelt_panel(root: Control) -> void:
	_smelt_overlay = Control.new()
	_smelt_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_smelt_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_smelt_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	_smelt_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_smelt_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(500, 320)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "冶炼炉"
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	_smelt_list = VBoxContainer.new()
	_smelt_list.add_theme_constant_override("separation", 8)
	vbox.add_child(_smelt_list)

	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, 44)
	close.pressed.connect(func(): set_smelt_open(false))
	vbox.add_child(close)

	_smelt_overlay.visible = false
	Events.request_smelt.connect(func(): set_smelt_open(true))


func _toggle_smelt_panel() -> void:
	if _smelt_overlay:
		set_smelt_open(not _smelt_overlay.visible)


func set_smelt_open(open: bool) -> void:
	if _smelt_overlay == null:
		return
	_smelt_overlay.visible = open
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	if open:
		_refresh_smelt_panel()


func _refresh_smelt_panel() -> void:
	if _smelt_list == null:
		return
	for child in _smelt_list.get_children():
		_smelt_list.remove_child(child)
		child.queue_free()

	for recipe in ItemTypes.SMELT_RECIPES:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		_smelt_list.add_child(row)

		var label := Label.new()
		label.text = _recipe_text(recipe)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		var button := Button.new()
		button.text = "冶炼"
		button.custom_minimum_size = Vector2(84, 40)
		button.focus_mode = Control.FOCUS_NONE
		button.disabled = not _can_smelt(recipe)
		button.pressed.connect(_on_smelt_pressed.bind(recipe))
		row.add_child(button)


func _can_smelt(recipe: Dictionary) -> bool:
	if _player == null:
		return false
	return _player.inventory.can_craft(recipe)


func _on_smelt_pressed(recipe: Dictionary) -> void:
	if _player == null:
		return
	if _player.inventory.craft(recipe):
		_refresh_smelt_panel()
		_refresh_hotbar()


## 右上角圆形小地图：以玩家为中心定时采样顶面着色，玩家所在格即圆心。
func _build_minimap(root: Control) -> void:
	_minimap = MiniMap.new()
	root.add_child(_minimap)
	_minimap.anchor_left = 1.0
	_minimap.anchor_top = 0.0
	_minimap.anchor_right = 1.0
	_minimap.anchor_bottom = 0.0
	_minimap.offset_left = -(MiniMap.SIZE + 20.0)
	_minimap.offset_top = 20.0
	_minimap.offset_right = -20.0
	_minimap.offset_bottom = 20.0 + MiniMap.SIZE
	_minimap.setup(_player, _player.get_world())


func _refresh_stats() -> void:
	if _player == null:
		return
	if _hp_bar:
		_hp_bar.value = _player.health
	if _hunger_label:
		_hunger_label.text = "饥饿 %d / %d" % [int(_player.hunger), _player.MAX_HUNGER]
	_refresh_time()


func _refresh_time() -> void:
	if _time_label == null:
		return
	if _day_night == null:
		_time_label.text = "白天 06:00"
	else:
		_time_label.text = ("白天 " if _day_night.is_day() else "夜晚 ") + _day_night.get_clock()


func _on_health_changed(_value: int) -> void:
	_refresh_stats()


func _on_hunger_changed(_value: int) -> void:
	_refresh_stats()


func _on_time_changed(_percent: float, _is_day: bool) -> void:
	_refresh_time()


func _on_mode_changed(_mode: int) -> void:
	if _mode_label:
		_mode_label.text = "模式：创造（无敌 · 飞行）" if GameState.is_creative() else "模式：生存"
	if _fly_button:
		_fly_button.visible = GameState.is_creative()
	if _descend_button:
		_descend_button.visible = GameState.is_creative()
	_refresh_hotbar()
	_refresh_stats()
