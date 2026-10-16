class_name FishingTeaching
extends RefCounted
## 钓鱼引导教学的内容层：解析 `data/fishing/teaching.json`，按 trigger 取课。
##
## 内容（讲什么、讲几句）与进度（看过没有）分开：看过没有记在
## FishingSystem 的日志里（user://fishing_journal.json 的 lessons_seen），
## 本类只读内容、不做状态，换存档不残留。

const DATA_PATH := "res://data/fishing/teaching.json"

var lessons: Array = []
var problems: PackedStringArray = PackedStringArray()


func _init() -> void:
	load_data()


func load_data() -> void:
	problems = PackedStringArray()
	lessons = []
	var data := _read_json(DATA_PATH)
	if data.is_empty():
		_problem("teaching.json 读取失败：" + DATA_PATH)
		return
	var raw: Variant = data.get("lessons", [])
	if typeof(raw) != TYPE_ARRAY:
		_problem("lessons 不是数组")
		return
	for item_value: Variant in raw:
		if typeof(item_value) != TYPE_DICTIONARY:
			_problem("lessons 里有条目不是对象")
			continue
		var lesson: Dictionary = item_value
		var lesson_id := String(lesson.get("id", ""))
		if lesson_id.is_empty():
			_problem("有一课缺 id")
			continue
		if lesson_by_id(lesson_id) != null:
			_problem("课程 id 重复：%s" % lesson_id)
			continue
		if String(lesson.get("title_zh", "")).is_empty():
			_problem("课程 %s 缺标题" % lesson_id)
		var steps_value: Variant = lesson.get("steps", [])
		if typeof(steps_value) != TYPE_ARRAY or (steps_value as Array).is_empty():
			_problem("课程 %s 没有步骤文案" % lesson_id)
		lessons.append(lesson)


func lesson_by_id(lesson_id: String) -> Variant:
	for item_value: Variant in lessons:
		var lesson: Dictionary = item_value
		if String(lesson.get("id", "")) == lesson_id:
			return lesson
	return null


## 触发时机对应的那一课（没有就返回空字典：该时机不讲课）。
func lesson_for_trigger(trigger: String) -> Dictionary:
	for item_value: Variant in lessons:
		var lesson: Dictionary = item_value
		if String(lesson.get("trigger", "")) == trigger:
			return lesson
	return {}


func title_of(lesson_id: String) -> String:
	var found: Variant = lesson_by_id(lesson_id)
	if found == null:
		return ""
	var lesson: Dictionary = found
	return String(lesson.get("title_zh", ""))


func steps_of(lesson_id: String) -> PackedStringArray:
	var found: Variant = lesson_by_id(lesson_id)
	if found == null:
		return PackedStringArray()
	var lesson: Dictionary = found
	var out := PackedStringArray()
	var raw: Variant = lesson.get("steps", [])
	if typeof(raw) != TYPE_ARRAY:
		return out
	for step_value: Variant in raw:
		out.append(String(step_value))
	return out


## 还没看过的一课（按课程表顺序取第一条）；全看过返回空字典。
## `seen` 由调用方（FishingSystem）传入，本类不持有状态。
func next_unseen(seen: Array) -> Dictionary:
	for item_value: Variant in lessons:
		var lesson: Dictionary = item_value
		if not seen.has(String(lesson.get("id", ""))):
			return lesson
	return {}


func count() -> int:
	return lessons.size()


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		_problem("文件不存在：" + path)
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_problem("无法打开：" + path)
		return {}
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		_problem("JSON 解析失败（%s 第 %d 行）" % [path, json.get_error_line()])
		return {}
	if typeof(json.data) != TYPE_DICTIONARY:
		_problem("顶层不是对象：" + path)
		return {}
	var data: Dictionary = json.data
	return data


func _problem(text: String) -> void:
	problems.append(text)
	push_error("fishing_teaching: " + text)
