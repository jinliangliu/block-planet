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
##
## D-078 起本槽还承载「世界设置」 world.json（当前只有 peaceful 一键），并为
## GameState 提供 push 式灌值——GameState 排在 Profile 之前，它不能反查这里。

signal slot_changed(id: String)

const PROFILES_DIR := "user://profiles"
const INDEX_FILE := "user://profiles/index.json"
const LEGACY_FILE := "user://progress.json"
## 槽内的世界设置文件名（D-078）：落在槽目录里，与 progress.json 同槽隔离。
const SLOT_WORLD_FILE := "world.json"
const DEFAULT_NAME := "玩家1"

var _slots: Array[Dictionary] = []   # 每项 {id:String, name:String, created:int}
var _current: String = ""            # 当前槽 id；"" 表示尚未选择（退回 legacy）


func _ready() -> void:
	_load_index()
	# 把本槽的世界设置灌给 GameState（D-078）。push 而非 pull：GameState 排在
	# Profile 之前初始化，它若反过来读 Profile 会撞上空 current。
	_push_world_settings()


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


## 当前槽目录。刻意从 slot_save_path() 派生而非重写 _current.is_empty() 判定——
## 一路复用同一处 legacy 回退：无槽时得到 user://（世界设置退化为 user://world.json，
## 与改版前「一切都落在 user://」的形态一致），不会出现两套判据各自漂移。
##
## ⚠️ get_base_dir() 对 "user://progress.json" 返回 **"user://"**（保留双斜线），
## 不是 "user:/"！因此下游绝不能再用 "%s/%s" % [slot_dir(), filename] 拼接，
## 否则会产出三斜线的 "user:///xxx.json"——字符串上不等于改版前的
## "user://xxx.json"（Godot 虽会归一化到同一物理文件，但路径契约、探针快照
## 与 D-010 逐字节比对全部会偏）。统一走 slot_file() 的 path_join()。
func slot_dir() -> String:
	return slot_save_path().get_base_dir()


## 当前槽的世界设置文件路径（D-078：和平模式开关存在这里）。
## 与 8 份玩家状态共用同一处派生，避免三斜线拼接各自漂移。
func slot_world_path() -> String:
	return slot_file(SLOT_WORLD_FILE)


## 当前槽内一份「玩家状态文件」的路径（D-086）。八份玩法状态（钓鱼图鉴 /
## 船只 / 记录 / 回放 / 教学 / 蓝图 / 解锁）共用这一处派生，避免各系统自造
## 路径工具、各自漂移。刻意做成实例方法而非 static：通过 Autoload 单例名
## 调用 static 函数会触发 STATIC_CALLED_ON_INSTANCE 警告（本项目警告即错误）。
##
## 无槽时 slot_dir() == "user://"，path_join 产出 "user://<filename>"，
## 逐字节等于改版前的旧根路径；有槽时为 "user://profiles/<id>/<filename>"。
## 用 path_join 而非 "%s/%s"：前者在目录已带尾斜线时不再补第二个斜线，
## 是这里唯一能同时满足「无槽逐字节兼容」与「有槽路径正确」的拼法。
func slot_file(filename: String) -> String:
	return slot_dir().path_join(filename)


## 读当前槽的世界设置：文件不存在 / JSON 损坏一律返回空字典，由调用方各自取
## 默认值（与 FlightSettings.load_or_new 的兜底风格一致）。
## ⚠️ 只读路径绝不写文件——默认关的和平模式在整局游戏中都不会被脚本触碰，
## 探针跑完不该多出 world.json（D-010 铁律 3）。
func read_slot_settings() -> Dictionary:
	if not FileAccess.file_exists(slot_world_path()):
		return {}
	var f := FileAccess.open(slot_world_path(), FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var data: Dictionary = parsed
	return data


## 整份写回当前槽的世界设置；失败（只读 / 磁盘满 / 目录不存在）返回 false，
## 不抛异常——调用方据此 push_warning，游戏本进程继续可用。
## 只在「玩家主动切换」时调用（设置面板），读路径一律不写。
func write_slot_settings(d: Dictionary) -> bool:
	var f := FileAccess.open(slot_world_path(), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(d))
	f.close()
	return true


## 把槽内世界设置灌给 GameState（D-078）。autoload 顺序决定了只能是 Profile
## 主动 push；这里同时进行键名→语义的一次映射，GameState 不必认识 JSON 结构。
func _push_world_settings() -> void:
	var settings := read_slot_settings()
	GameState._hydrate_peaceful(bool(settings.get("peaceful", false)))


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
			# 换槽 = 换一套世界设置：重新灌值（同样静默，不弹 Toast）。
			_push_world_settings()
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
