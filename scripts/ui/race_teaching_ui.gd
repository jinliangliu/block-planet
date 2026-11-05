class_name RaceTeachingUI
extends CanvasLayer
## 竞速教学弹窗（首次比赛 / 首次过检查点 / 首次完圈时各弹一次）。
## 已读进度落盘 user://race_teaching.json —— 教学只打扰一次，之后安静让位。

## D-086：按槽派生。每场由 race_scene 新建、_ready() 重读盘 → 只需路径派生，
## 不必连 slot_changed（弹窗活不过一场比赛，不可能跨槽存活）。
static var SAVE_PATH: String = "user://race_teaching.json"

## 关掉后不再排队/弹出任何教学（无头探针与自检用，避免弹窗冻结比赛）。
var enabled := true

var _seen: Dictionary = {}
var _queue: Array = []
var _root: Control
var _title: Label
var _body: Label
var _built := false


## D-086：读写入口现算路径；无槽时逐字节等于旧根路径。
static func _refresh_path() -> void:
	if Profile != null:
		SAVE_PATH = Profile.slot_file("race_teaching.json")


func _ready() -> void:
	_refresh_path()
	layer = 12
	visible = false
	_seen = _load_seen()
	# 开局时把「首次开赛」类教学先排上（不给 trigger 的话这里不排）。
	if enabled and RaceSystem != null:
		enqueue("first_race_start")


func _load_seen() -> Dictionary:
	_refresh_path()
	if not FileAccess.file_exists(SAVE_PATH):
		return {}
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _save_seen() -> void:
	_refresh_path()
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_seen))
	f.close()


func has_seen(id: String) -> bool:
	return bool(_seen.get(id, false))


## 把某个触发点尚未读过的教学条目排进队列。
func enqueue(trigger: String) -> void:
	if not enabled:
		return
	for item: Variant in RaceSystem.teachings_for(trigger):
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var id := String(d.get("id", ""))
		if id.is_empty() or has_seen(id):
			continue
		if _queue.any(func(q: Dictionary) -> bool: return String(q.get("id", "")) == id):
			continue
		_queue.append(d)
	_show_next()


func is_showing() -> bool:
	return visible


## 彻底关掉教学（无头探针/自检）：不再排队、清空队列并收起弹窗。
func suppress() -> void:
	enabled = false
	_queue.clear()
	visible = false


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.04, 0.07, 0.45)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)
	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.98, 0.96, 0.90)
	style.set_corner_radius_all(14)
	style.content_margin_left = 26.0
	style.content_margin_right = 26.0
	style.content_margin_top = 18.0
	style.content_margin_bottom = 18.0
	card.add_theme_stylebox_override("panel", style)
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.position = Vector2(-240, -120)
	card.custom_minimum_size = Vector2(480, 240)
	_root.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	card.add_child(box)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 26)
	_title.add_theme_color_override("font_color", Color(0.12, 0.12, 0.16))
	box.add_child(_title)
	_body = Label.new()
	_body.add_theme_font_size_override("font_size", 18)
	_body.add_theme_color_override("font_color", Color(0.24, 0.24, 0.30))
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size = Vector2(420, 90)
	box.add_child(_body)
	var ok := Button.new()
	ok.text = "知道啦"
	ok.custom_minimum_size = Vector2(120, 40)
	ok.focus_mode = Control.FOCUS_NONE
	UiKit.apply_warm_style(ok)
	ok.pressed.connect(_advance)
	box.add_child(ok)


func _show_next() -> void:
	if _queue.is_empty():
		visible = false
		return
	_ensure_built()
	visible = true
	var item: Dictionary = _queue[0]
	_title.text = String(item.get("title", ""))
	_body.text = String(item.get("body", ""))


func _advance() -> void:
	if _queue.is_empty():
		visible = false
		return
	var item: Dictionary = _queue.pop_front()
	_seen[String(item.get("id", ""))] = true
	_save_seen()
	if _queue.is_empty():
		visible = false
	else:
		_show_next()
