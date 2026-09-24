class_name EntryCard
extends Button
## 图鉴条目卡：网格里的一格。中文名 + 学名两行，描边取所属界的主色，
## 游戏里真能遇见的物种额外标一行「游戏内可遇见」。
##
## 卡片自带子控件（而不是只用 Button.text），是因为 Button 只有一个字号：
## 中文名要 16px、学名要 11px 才读得出层次。子标签全部 mouse_filter = IGNORE，
## 点击仍然落在 Button 自己身上，pressed 信号照常可用。

const CARD_SIZE := Vector2(178.0, 88.0)

const BG_COLOR := Color(0.90, 0.86, 0.76)
const BG_HOVER := Color(0.95, 0.92, 0.84)
const BG_SELECTED := Color(0.98, 0.90, 0.70)
const NAME_COLOR := Color(0.28, 0.19, 0.08)
const LATIN_COLOR := Color(0.44, 0.36, 0.24)
const GAME_TAG_COLOR := Color(0.30, 0.52, 0.20)

var entry_id: String = ""

var _name_label: Label
var _latin_label: Label
var _game_label: Label
var _tint := Color(0.62, 0.47, 0.27)
var _selected := false


func _init() -> void:
	custom_minimum_size = CARD_SIZE
	autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	clip_text = true
	focus_mode = Control.FOCUS_NONE
	tooltip_text = ""

	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.offset_left = 9.0
	column.offset_right = -9.0
	column.offset_top = 7.0
	column.offset_bottom = -7.0
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 1)
	add_child(column)

	_name_label = Label.new()
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_label.add_theme_font_size_override("font_size", 16)
	_name_label.add_theme_color_override("font_color", NAME_COLOR)
	column.add_child(_name_label)

	_latin_label = Label.new()
	_latin_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_latin_label.add_theme_font_size_override("font_size", 11)
	_latin_label.add_theme_color_override("font_color", LATIN_COLOR)
	_latin_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_latin_label.clip_text = true
	_latin_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_latin_label)

	_game_label = Label.new()
	_game_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_game_label.text = "● 游戏内可遇见"
	_game_label.add_theme_font_size_override("font_size", 11)
	_game_label.add_theme_color_override("font_color", GAME_TAG_COLOR)
	_game_label.visible = false
	column.add_child(_game_label)

	_refresh_style()


## 填充一条图鉴条目。`tint` 取界或类的主色，`in_game` 表示游戏世界里真有这物种。
func set_entry(entry: Dictionary, tint: Color, in_game: bool) -> void:
	entry_id = String(entry.get("id", ""))
	_tint = tint
	var name_zh := String(entry.get("name_zh", ""))
	_name_label.text = name_zh
	var latin := String(entry.get("scientific", ""))
	if latin.is_empty():
		latin = String(entry.get("name_en", ""))
	_latin_label.text = latin
	_game_label.visible = in_game
	tooltip_text = "%s / %s\n%s\n%s" % [
		name_zh,
		String(entry.get("name_en", "")),
		BestiaryData.category_name(String(entry.get("category", ""))),
		String(entry.get("region_name_zh", "")),
	]
	_refresh_style()


func set_selected(selected: bool) -> void:
	_selected = selected
	_refresh_style()


func is_selected() -> bool:
	return _selected


func _refresh_style() -> void:
	var bg := BG_SELECTED if _selected else BG_COLOR
	add_theme_stylebox_override("normal", _style(bg))
	add_theme_stylebox_override("hover", _style(BG_HOVER))
	add_theme_stylebox_override("pressed", _style(BG_SELECTED))
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())


## 卡片底色 + 主色描边。描边宽度随选中态变化：选中时更厚，一眼看出当前条目。
func _style(bg: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = _tint
	style.set_border_width_all(3 if _selected else 1)
	style.set_corner_radius_all(8)
	return style
