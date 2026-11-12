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

## 档案槽目录（D-077 多存档槽起）。玩家建过槽之后，Progress 的落盘路径由
## Profile.slot_save_path() 决定，指向 user://profiles/<id>/progress.json；
## 只快照 legacy 的 user://progress.json 会漏掉真正的写盘目标。后果有两层：
##   1. 探针会把玩家的真实档案槽写脏（D-010 铁律直接违反，且玩家感知得到）；
##   2. 「没有槽时才落 legacy 路径」的断言（life_probe「进度已持久化到 user://」）
##      在有槽的机器上必然失败——2026-10-31 实测就是这样被发现的。
## 因此 profiles/ 整棵树的文本文件都纳入快照。
const PROFILES_DIR := "user://profiles"

## 除 progress/settings 外，还需原样备份的 user:// 文本文件（竞速探针用）。
const EXTRA_FILES := [
	"user://race_records.json",
	"user://race_replay.jsonl",
	"user://race_teaching.json",
	# U-9：飞行一次性教学提示进度（座舱「低头看 3D 仪表台」）。任何会真实
	# 起飞到 15 m 以上的探针都可能触发它并新建本文件，必须纳入隔离。
	"user://flight_teaching.json",
	# D-086：racing_probe 的临时记录文件。原先既不在 EXTRA_FILES 也不在回归
	# 兜底清单里，rc=139 崩在 :236-239 之间就会留残 file → 下一次 diff -r 报假
	# DIFF。登记在此（按 D-010 逐字节还原），回归脚本另有不枚举文件名的兜底。
	# 注意：不改 racing_probe.gd 本身。
	"user://race_records_probe.json",
	# D-089：BoatSystem._exit_tree() 无条件 _save_journal()。有槽时由
	# snapshot_profiles() 覆盖整树，但日常回归跑无槽态会落 legacy 根文件；
	# 不登记则退出期凭空留文件 → 下次 diff -r 假 DIFF（同 D-088 §2 的四步）。
	"user://boats.json",
	# D-092：main._exit_tree() 在 _inv_dirty 为真时补写 inventory.json，无槽态
	# 落 legacy 根文件；不登记则退出期凭空留文件 → 下次 diff -r 假 DIFF（同 D-089）。
	"user://inventory.json",
]

static var _progress := ""
static var _settings := ""
static var _extra: Dictionary = {}
static var _profiles: Dictionary = {}
static var _profiles_existed := false
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
	snapshot_profiles()
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
	restore_profiles()
	Progress.counters = _counters.duplicate()
	Progress.states = _states.duplicate()
	Progress._quiz_correct_since_reward = _quiz
	# D-089：FishingSystem / BoatSystem 的 _exit_tree() 在引擎关停期（本函数返回
	# 之后）还会调一次 _save_journal()，把刚逐字节还原的文件覆盖成内存态——
	# version 1 的 boats.json 就是这样被升级成 version 2、导致 D-010 假 DIFF。
	# journal_ok=false 是生产侧既有的拒写闸（同 D-088 §2），在此统一置位，凡
	# 走本助手的探针退出期一律不写盘；boats.json 已登记在 EXTRA_FILES 内。
	FishingSystem.journal_ok = false
	BoatSystem.journal_ok = false
	# D-092：Inventory.save() 由 main._exit_tree() 在关停期触发（仅 _inv_dirty 时），
	# 会把刚逐字节还原的 inventory.json 覆盖回内存态。io_ok=false 是生产侧
	# 拒写闸（同上面两个 journal_ok），在此统一置位；inventory.json 已登记在
	# EXTRA_FILES 内。7 个保留内联快照范式的旧探针不走本函数，它们各自在还原
	# 函数里单独置位（等价闸，缺一即整段回归假 DIFF）。
	Inventory.io_ok = false


## 档案槽目录（user://profiles/）快照 / 还原。单独暴露一对，是给那些保留
## 内联快照范式的老探针（life_probe 等）补上这一层，不必整体改写成 SaveGuard。
static func snapshot_profiles() -> void:
	_profiles_existed = DirAccess.dir_exists_absolute(
		ProjectSettings.globalize_path(PROFILES_DIR))
	_profiles = _read_tree(PROFILES_DIR)


static func restore_profiles() -> void:
	# 先删探针新建的槽（快照里没有的），再写回快照内容，最后按需清空目录。
	var now := _read_tree(PROFILES_DIR)
	for key in now.keys():
		var path := String(key)
		if not _profiles.has(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	for key in _profiles.keys():
		var path := String(key)
		_write_user_text(path, String(_profiles[path]))
	if not _profiles_existed:
		_remove_tree(PROFILES_DIR)


## 递归读取目录下全部文本文件（路径 -> 文本）。存档都是小 JSON，量级几十份。
## D-086：槽目录里同样会有 race_replay.jsonl（JSON Lines）与 *.tmp 中间文件；
## 本函数按纯文本整文件读写、不解析也不改行尾，JSONL 因此也是逐字节还原。
static func _read_tree(dir_path: String) -> Dictionary:
	var out: Dictionary = {}
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var full := dir_path.path_join(entry)
			if dir.current_is_dir():
				out.merge(_read_tree(full))
			else:
				out[full] = _read_user_text(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out


## 递归删除整个目录（含子目录），用于「快照时本不存在」的 profiles/ 兜底清理。
static func _remove_tree(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	var files: PackedStringArray = []
	var subdirs: PackedStringArray = []
	while entry != "":
		if entry != "." and entry != "..":
			if dir.current_is_dir():
				subdirs.append(entry)
			else:
				files.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	var abs_dir := ProjectSettings.globalize_path(dir_path)
	for f: String in files:
		DirAccess.remove_absolute(abs_dir.path_join(f))
	for d: String in subdirs:
		_remove_tree(dir_path.path_join(d))
	DirAccess.remove_absolute(abs_dir)


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
