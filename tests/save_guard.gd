class_name SaveGuard
## 探针存档隔离助手（D-010 铁律 3）：快照 / 还原 user:// 存档 + Progress 内存态。
##
## 用法（探针 _run() 开局快照、_finish()/quit 前还原，OK/FAIL 两条退出路径都要过）：
##   func _run() -> void:
##       SaveGuard.snapshot()          # 必须在实例化 main.tscn 之前——暖机帧也可能
##                                     # 触发 Events（region_entered 等）
##       var main_scene: Node = load("res://scenes/main.tscn").instantiate()
##       ...
##   func _finish() -> void:
##       SaveGuard.restore()           # quit 前还原，否则 _exit_tree 的 _save() 覆盖
##       get_tree().quit(0 if _failed == 0 else 1)
##
## 为什么内存态必须一并还原：Progress._exit_tree 退出时会 _save() 把内存态写盘，
## 只还原文件会被它覆盖（flight_probe 实测教训：只写文件后 flew 107→119，还原失效）。
##
## 快照内容与 flight_probe / life_probe / flight_e2e_shot / flight_view_probe 的
## 内联实现完全一致（progress + settings 文本 + counters/states/quiz 内存态）；
## 那四个探针保留各自验证过的内联范式，新探针统一走本助手，别再各抄一份。
## 竞速相关三份（records / replay / teaching）也纳入快照：竞速探针会真实完赛写盘。

## 除 progress/settings 外，还需原样备份的 user:// 文本文件（竞速探针用）。
const EXTRA_FILES := [
	"user://race_records.json",
	"user://race_replay.jsonl",
	"user://race_teaching.json",
]

static var _progress := ""
static var _settings := ""
static var _extra: Dictionary = {}
static var _counters: Dictionary = {}
static var _states: Dictionary = {}
static var _quiz := 0


## 跑 gameplay 前调用：存档文本 + 进度内存态原样快照。
static func snapshot() -> void:
	_progress = _read_user_text("user://progress.json")
	_settings = _read_user_text("user://settings.json")
	_extra = {}
	for path: String in EXTRA_FILES:
		_extra[path] = _read_user_text(path)
	_counters = Progress.counters.duplicate()
	_states = Progress.states.duplicate()
	_quiz = Progress._quiz_correct_since_reward


## quit 前调用：user:// 存档文件写回快照原样，Progress 内存态一并还原。
## 空串 = 原文件不存在，还原即删除（避免「探针凭空建了个新存档」的污染）。
static func restore() -> void:
	_write_user_text("user://progress.json", _progress)
	_write_user_text("user://settings.json", _settings)
	for path: String in EXTRA_FILES:
		_write_user_text(path, String(_extra.get(path, "")))
	Progress.counters = _counters.duplicate()
	Progress.states = _states.duplicate()
	Progress._quiz_correct_since_reward = _quiz


## 读 user:// 文本文件；不存在或打不开返回空串（还原即删除）。
static func _read_user_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


## 写 user:// 文本文件；空串表示原文件不存在，还原即删除。
static func _write_user_text(path: String, text: String) -> void:
	if text == "":
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()
