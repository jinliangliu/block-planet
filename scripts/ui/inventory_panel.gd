class_name InventoryPanel
extends Control
## 背包窗口（B 键唤出）：常用区 27 格（9 格一行）+ 待售区 9 格 + 快捷栏 1~9 管理行。
## 支持拖拽搬运、数量加减与待售区一键售卖（兑换绿宝石）。配色与储物箱同色系。
## 快捷栏为背包槽的视图映射：拖入背包物品即把该槽指派到对应快捷位。

signal closed
## 一键售卖完成后发出，携带 sell_all() 的结算结果。
signal sold(result: Dictionary)

const PANEL_BG := Color(0.95, 0.92, 0.84)
const PANEL_BORDER := Color(0.62, 0.47, 0.27)
const TEXT_DARK := Color(0.20, 0.15, 0.08)
const TEXT_BODY := Color(0.34, 0.26, 0.15)
const TEXT_MUTED := Color(0.48, 0.40, 0.28)
const ACCENT := Color(0.62, 0.42, 0.12)
const SLOT_SIZE := 50.0
const SLOT_GAP := 8.0
const COMMON_COLUMNS := 9

## 可拖拽物品格：携带来源分区与索引，由面板统一结算落点。
class Cell extends ItemSlot:
	var panel: InventoryPanel
	var zone := "common"
	var index := 0

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if panel == null or panel.item_at(zone, index) == BlockTypes.Block.AIR:
			return null
		var preview := Label.new()
		preview.text = " %s ×%d " % [
			ItemTypes.item_name(panel.item_at(zone, index)),
			panel.count_at(zone, index),
		]
		preview.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
		preview.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0))
		preview.add_theme_constant_override("outline_size", 6)
		set_drag_preview(preview)
		return {
			"zone": zone,
			"index": index,
			"amount": panel.drag_amount(zone, index),
		}

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		return panel != null and panel.can_drop(data, zone, index)

	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		if panel != null:
			panel.handle_drop(data, zone, index)


var _inv: Inventory
var _open := false

var _common_cells: Array[Cell] = []
var _sell_cells: Array[Cell] = []
var _hotbar_cells: Array[Cell] = []
var _emerald_label: Label
var _amount_label: Label
var _selection_label: Label
var _report_label: Label
var _amount := 1
var _selected_zone := ""
var _selected_index := -1


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	visible = false


## 绑定玩家背包（HUD 在 setup 时调用）。
func setup(inventory: Inventory) -> void:
	_inv = inventory
	if _inv != null and not _inv.changed.is_connected(_refresh):
		_inv.changed.connect(_refresh)
	_refresh()


func open() -> void:
	visible = true
	_open = true
	_refresh()


func close() -> void:
	visible = false
	_open = false
	closed.emit()


func is_open() -> bool:
	return _open


## 当前选中的格子（探针断言用）：zone 为空表示未选择。
func selection() -> Dictionary:
	return {"zone": _selected_zone, "index": _selected_index, "amount": _amount}


## 设置搬运数量（探针断言用，自动钳制到 1~该格数量）。
func set_amount(value: int) -> void:
	_amount = maxi(1, value)
	_clamp_amount()
	_amount_label.text = "%d" % _amount


func item_at(zone: String, index: int) -> int:
	if _inv == null:
		return BlockTypes.Block.AIR
	if zone == "hotbar":
		return _inv.hotbar_item(index)
	return _inv.get_item(index)


func count_at(zone: String, index: int) -> int:
	if _inv == null:
		return 0
	if zone == "hotbar":
		return _inv.hotbar_count(index)
	return _inv.get_count(index)


## 拖动时携带的数量：选中格用搬运数量，其余格整栈搬运。
func drag_amount(zone: String, index: int) -> int:
	if zone == _selected_zone and index == _selected_index:
		return _amount
	return maxi(1, count_at(zone, index))


func can_drop(data: Variant, target_zone: String, target_index: int) -> bool:
	if not (data is Dictionary) or _inv == null:
		return false
	var source: Dictionary = data
	if not source.has("zone"):
		return false
	return not (String(source["zone"]) == target_zone and int(source["index"]) == target_index)


## 结算一次拖放：拖到快捷栏行 = 指派映射；快捷栏拖到背包 = 反向指派；其余为搬运/互换。
func handle_drop(data: Variant, target_zone: String, target_index: int) -> void:
	if not (data is Dictionary) or _inv == null:
		return
	var source: Dictionary = data
	var source_zone := String(source["zone"])
	var source_index := int(source["index"])
	var amount := int(source.get("amount", 1))

	if target_zone == "hotbar":
		if source_zone == "hotbar":
			_inv.swap_hotbar(source_index, target_index)
			_report("快捷栏 %d 号位 ↔ 快捷栏 %d 号位" % [source_index + 1, target_index + 1])
		elif _inv.assign_hotbar(target_index, source_index):
			_report("已指派到快捷栏 %d 号位" % (target_index + 1))
	elif source_zone == "hotbar":
		if _inv.assign_hotbar(source_index, target_index):
			_report("快捷栏 %d 号位 → 背包第 %d 格" % [source_index + 1, target_index + 1])
	else:
		if _inv.move_between(source_index, target_index, amount):
			_report("搬运 %s ×%d" % [ItemTypes.item_name(_inv.get_item(target_index)),
				mini(amount, BlockTypes.STACK_SIZE)])
		else:
			_report("这两格无法直接交换，试试先腾出一个空格")
	_refresh()


## 一键售卖待售区：兑换绿宝石并写入结算报告。
func sell_sell_zone() -> Dictionary:
	if _inv == null:
		return {}
	var result := _inv.sell_all()
	if int(result.get("sold", 0)) <= 0:
		_report("待售区没有可售出的物品")
	else:
		var text := "售出 %d 件，获得绿宝石 ×%d" % [int(result["sold"]), int(result["emeralds"])]
		if int(result.get("leftover", 0)) > 0:
			text += "（背包已满，%d 枚未入包）" % int(result["leftover"])
		_report(text)
	sold.emit(result)
	_refresh()
	return result


func _build() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -300.0
	panel.offset_right = 300.0
	panel.offset_top = -300.0
	panel.offset_bottom = 300.0
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(4)
	style.set_corner_radius_all(14)
	style.content_margin_left = 22.0
	style.content_margin_right = 22.0
	style.content_margin_top = 16.0
	style.content_margin_bottom = 16.0
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	vbox.add_child(_build_header())
	vbox.add_child(_make_section_title("常用物品（%d 格）" % Inventory.COMMON_COUNT))
	_common_cells = _build_grid(vbox, Inventory.COMMON_COUNT, COMMON_COLUMNS, 0, "common")
	vbox.add_child(_build_sell_header())
	_sell_cells = _build_grid(vbox, Inventory.SELL_COUNT, Inventory.SELL_COUNT,
		Inventory.COMMON_COUNT, "sell")
	vbox.add_child(_make_section_title("快捷栏 1-9（拖入背包物品即可指派，左起为 1 号位）"))
	_hotbar_cells = _build_grid(vbox, Inventory.HOTBAR_SIZE, Inventory.HOTBAR_SIZE, 0, "hotbar")
	vbox.add_child(_build_amount_row())

	_report_label = Label.new()
	_report_label.add_theme_font_size_override("font_size", 15)
	_report_label.add_theme_color_override("font_color", TEXT_MUTED)
	_report_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_report_label.custom_minimum_size = Vector2(514.0, 0.0)
	vbox.add_child(_report_label)


func _build_header() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var title := Label.new()
	title.text = "背包"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", TEXT_DARK)
	row.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	_emerald_label = Label.new()
	_emerald_label.add_theme_font_size_override("font_size", 18)
	_emerald_label.add_theme_color_override("font_color", ACCENT)
	row.add_child(_emerald_label)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.add_theme_font_size_override("font_size", 22)
	close_btn.add_theme_color_override("font_color", TEXT_BODY)
	close_btn.pressed.connect(close)
	row.add_child(close_btn)
	return row


func _build_sell_header() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var title := _make_section_title("待售物品（9 格，可整体卖给交易中心）")
	row.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var sell := Button.new()
	sell.text = "一键售卖 → 绿宝石"
	sell.focus_mode = Control.FOCUS_NONE
	sell.add_theme_font_size_override("font_size", 16)
	sell.pressed.connect(sell_sell_zone)
	row.add_child(sell)
	return row


func _build_amount_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var caption := Label.new()
	caption.text = "搬运数量"
	caption.add_theme_font_size_override("font_size", 16)
	caption.add_theme_color_override("font_color", TEXT_BODY)
	row.add_child(caption)

	var minus := Button.new()
	minus.text = "−"
	minus.custom_minimum_size = Vector2(44.0, 32.0)
	minus.focus_mode = Control.FOCUS_NONE
	minus.pressed.connect(_on_amount_step.bind(-1))
	row.add_child(minus)

	_amount_label = Label.new()
	_amount_label.custom_minimum_size = Vector2(46.0, 0.0)
	_amount_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_amount_label.add_theme_font_size_override("font_size", 18)
	_amount_label.add_theme_color_override("font_color", TEXT_DARK)
	row.add_child(_amount_label)

	var plus := Button.new()
	plus.text = "+"
	plus.custom_minimum_size = Vector2(44.0, 32.0)
	plus.focus_mode = Control.FOCUS_NONE
	plus.pressed.connect(_on_amount_step.bind(1))
	row.add_child(plus)

	var all := Button.new()
	all.text = "全部"
	all.custom_minimum_size = Vector2(64.0, 32.0)
	all.focus_mode = Control.FOCUS_NONE
	all.pressed.connect(_on_amount_all)
	row.add_child(all)

	_selection_label = Label.new()
	_selection_label.add_theme_font_size_override("font_size", 15)
	_selection_label.add_theme_color_override("font_color", TEXT_MUTED)
	row.add_child(_selection_label)
	return row


func _make_section_title(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", ACCENT)
	return label


func _build_grid(parent: Control, count: int, columns: int, offset: int, zone: String) -> Array[Cell]:
	var grid := GridContainer.new()
	grid.columns = columns
	grid.add_theme_constant_override("h_separation", int(SLOT_GAP))
	grid.add_theme_constant_override("v_separation", int(SLOT_GAP))
	parent.add_child(grid)

	var cells: Array[Cell] = []
	for i in range(count):
		var cell := Cell.new()
		cell.panel = self
		cell.zone = zone
		cell.index = offset + i
		cell.toggle_mode = true
		cell.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
		cell.pressed.connect(_on_cell_pressed.bind(zone, offset + i))
		grid.add_child(cell)
		cells.append(cell)
	return cells


func _on_cell_pressed(zone: String, index: int) -> void:
	if _inv == null:
		return
	if item_at(zone, index) == BlockTypes.Block.AIR:
		_clear_selection()
		return
	_selected_zone = zone
	_selected_index = index
	_amount = maxi(1, count_at(zone, index))
	_report("已选中 %s ×%d（%s）" % [
		ItemTypes.item_name(item_at(zone, index)),
		count_at(zone, index),
		"快速栏 %d 号位" % (index + 1) if zone == "hotbar" else "背包第 %d 格" % (index + 1),
	])
	_refresh()


func _on_amount_step(step: int) -> void:
	_amount = maxi(1, _amount + step)
	_clamp_amount()
	_refresh()


func _on_amount_all() -> void:
	_amount = maxi(1, count_at(_selected_zone, _selected_index))
	_refresh()


func _clamp_amount() -> void:
	var cap := count_at(_selected_zone, _selected_index)
	if cap > 0:
		_amount = clampi(_amount, 1, cap)


func _clear_selection() -> void:
	_selected_zone = ""
	_selected_index = -1
	_selection_label.text = ""


func _report(text: String) -> void:
	if _report_label != null:
		_report_label.text = text


func _refresh() -> void:
	if _inv == null:
		return
	_clamp_amount()
	if _emerald_label != null:
		_emerald_label.text = "绿宝石 ×%d" % _inv.count_item(ItemTypes.EMERALD)
	if _amount_label != null:
		_amount_label.text = "%d" % _amount
	if _selection_label != null:
		if _selected_index >= 0:
			_selection_label.text = "当前：%s ×%d" % [
				ItemTypes.item_name(item_at(_selected_zone, _selected_index)),
				count_at(_selected_zone, _selected_index),
			]
		else:
			_selection_label.text = "点选一个格子后可拖拽或调数量"
	for cell: Cell in _common_cells:
		cell.set_slot(_inv.slots[cell.index])
		cell.button_pressed = cell.zone == _selected_zone and cell.index == _selected_index
	for cell: Cell in _sell_cells:
		cell.set_slot(_inv.slots[cell.index])
		cell.button_pressed = cell.zone == _selected_zone and cell.index == _selected_index
	for cell: Cell in _hotbar_cells:
		var slot := _inv.hotbar_slot(cell.index)
		cell.set_slot(_inv.slots[slot] if slot >= 0 else {"item": 0, "count": 0, "durability": -1})
		cell.button_pressed = cell.zone == _selected_zone and cell.index == _selected_index
