extends Node
## 档案系统（多存档槽，M7.4）：每个「玩家档案」是一个独立存档槽，
## 进度数据落在 user://profiles/<id>/progress.json（各自隔离）。
##
## 向后兼容：在玩家通过档案选择器建立第一个槽之前，current 为空，
## 进度仍读写旧的 user://progress.json（与改版前完全一致——不惊动启动流程、
## 也不污染回归基线 user://）。建立首槽时若旧进度文件存在则迁移进首槽。
##
## 以路径形式注册为 Autoload「Profile」（不引入 class_name，避免
## global_script_class_cache 失配导致无头解析失败，见项目踩坑 #24），
## 必须排在 Progress 之前初始化，使 Progress._ready 读到的就是当前槽路径。

signal slot_changed(id: String)

const PROFILES_DIR := "user://profiles"
const INDEX_FILE := "user://profiles/index.json"
const LEGACY_FILE := "user://progress.json"
const DEFAULT_NAME := "玩家1"

var _slots: Array[Dictionary] = []   # 每项 {id:String, name:String, created:int}
var _current: String = ""            # 当前槽 id；"" 表示尚未选择（退回 legacy）


func _ready() -> void:
	_load_index()


func _load_index() -> void:
	if not FileAccess.file_exists(INDEX_FILE):
		return
	var f := FileAccess.open(INDEX_FILE, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data: Dictionary = parsed
	var loaded: Variant = data.get("slots", [])
	if typeof(loaded) == TYPE_ARRAY:
		for item: Variant in loaded:
			if typeof(item) == TYPE_DICTIONARY:
				_slots.append({"id": String(item.get("id", "")),
					"name": String(item.get("name", "")),
					"created": int(item.get("created", 0))})
	_current = String(data.get("current", ""))


## 清空内存态并从磁盘重新载入（供档案选择器刷新，或探针隔离运行后复位）。
func reload() -> void:
	_slots = []
	_current = ""
	_load_index()


func _save_index() -> void:
	var arr: Array = []
	for s: Dictionary in _slots:
		arr.append({"id": s["id"], "name": s["name"], "created": int(s["created"])})
	var data := {"slots": arr, "current": _current}
	var f := FileAccess.open(INDEX_FILE, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(data))


## 当前槽进度文件路径。current 为空（尚未建槽）时退回旧的单文件进度，
## 保证改版前的行为与回归基线不被惊动。
func slot_save_path() -> String:
	if _current.is_empty():
		return LEGACY_FILE
	return "%s/%s/progress.json" % [PROFILES_DIR, _current]


## 逐级创建目录（Godot 4 的 make_dir_recursive 是实例方法，需先 open）。
func _mkdir_recursive(abs_dir: String) -> void:
	var d := DirAccess.open("user://")
	if d != null:
		d.make_dir_recursive(abs_dir)


func list_slots() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s: Dictionary in _slots:
		out.append({"id": s["id"], "name": s["name"], "created": int(s["created"])})
	return out


func current_slot() -> String:
	return _current


func current_name() -> String:
	for s: Dictionary in _slots:
		if s["id"] == _current:
			return s["name"]
	return ""


## 是否需要玩家在启动界面选槽：多槽且尚未选定。
func needs_choice() -> bool:
	return _slots.size() > 1 and _current.is_empty()


## 新建槽，返回新槽 id（不自动选中，交给 UI 让用户确认进入）。
## 若是首个槽且旧进度文件存在，则把旧进度迁移进新槽（原地改名）。
func create_slot(name: String) -> String:
	var first := _slots.is_empty()
	var id := "slot_%d_%d" % [Time.get_unix_time_from_system(), randi() % 1000]
	_mkdir_recursive("%s/%s" % [PROFILES_DIR, id])
	var nm := name.strip_edges()
	if nm.is_empty():
		nm = "玩家%d" % (_slots.size() + 1)
	_slots.append({"id": id, "name": nm, "created": Time.get_unix_time_from_system()})
	if first and FileAccess.file_exists(LEGACY_FILE):
		DirAccess.rename_absolute(LEGACY_FILE, "%s/%s/progress.json" % [PROFILES_DIR, id])
	_save_index()
	slot_changed.emit(id)
	return id


## 选择槽（仅当存在时生效）。
func select_slot(id: String) -> bool:
	for s: Dictionary in _slots:
		if s["id"] == id:
			_current = id
			_save_index()
			slot_changed.emit(id)
			return true
	return false


## 删除槽：不允许删最后一个（至少保留一个档案）。
## 若删掉的是当前槽，回退到列表首个。
func delete_slot(id: String) -> bool:
	if _slots.size() <= 1:
		return false
	var idx := -1
	for i: int in _slots.size():
		if _slots[i]["id"] == id:
			idx = i
			break
	if idx < 0:
		return false
	var p := "%s/%s" % [PROFILES_DIR, id]
	DirAccess.remove_absolute("%s/progress.json" % p)
	DirAccess.remove_absolute(p)
	_slots.remove_at(idx)
	if _current == id:
		_current = _slots[0]["id"] if _slots.size() > 0 else ""
	_save_index()
	slot_changed.emit(_current)
	return true


## 显式迁移旧单文件进度到默认槽（无槽时调用，返回是否执行）。
## create_slot 已能在建首槽时自动迁移，本方法主要供探针与「恢复默认」路径使用。
func migrate_legacy() -> bool:
	if not _slots.is_empty():
		return false
	var id := "default"
	_mkdir_recursive("%s/%s" % [PROFILES_DIR, id])
	if FileAccess.file_exists(LEGACY_FILE):
		DirAccess.rename_absolute(LEGACY_FILE, "%s/%s/progress.json" % [PROFILES_DIR, id])
	_slots.append({"id": id, "name": DEFAULT_NAME, "created": Time.get_unix_time_from_system()})
	_current = id
	_save_index()
	slot_changed.emit(id)
	return true
