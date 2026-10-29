extends Node
## 档案系统多存档槽（M7.4，无头，纯逻辑）：钉死「多玩家档案互相隔离 + 旧进度迁移」契约。
##
## 探针场景方式运行（见项目踩坑 #22：--script 不加载 Autoload，场景方式才安全），
## 因此 Progress / Profile 两个 Autoload 均可用。
##
## 关键不变量：
##   A 槽隔离——写给槽 A 的计数绝不会出现在槽 B；切回 A 后原进度原样恢复。
##   B 槽 CRUD——建槽/删槽正确，且不允许删最后一个槽。
##   C 迁移——建首槽时旧 user://progress.json 被迁进首槽；显式 migrate_legacy 亦同。
##   D 路径——current 为空时落盘路径退回旧单文件（向后兼容，不惊动回归基线）。
##
## 末尾清理 user://，避免在本进程留下 profiles/ 干扰回归基线的 user:// 还原校验。

var _pass := 0
var _fail := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: " + msg)
		_pass += 1
	else:
		print("FAIL: " + msg)
		_fail += 1


func _ready() -> void:
	_run()
	print("PROFILE_SLOT_TEST_DONE fails=%d" % _fail)
	if _fail > 0:
		print("PROFILE_SLOT_TEST_FAILED")
	else:
		print("PROFILE_SLOT_TEST_OK")
	get_tree().quit(0 if _fail == 0 else 1)


## 清掉 user:// 下与档案系统相关的全部文件痕迹，并复位 Profile 内存态，
## 让每次测试段从干净状态开始。利用 Profile.list_slots() 逐个槽删文件→删空目录。
func _reset_fs() -> void:
	for s: Dictionary in Profile.list_slots():
		var id: String = s["id"]
		var slot_dir := "user://profiles/%s" % id
		if FileAccess.file_exists("%s/progress.json" % slot_dir):
			DirAccess.remove_absolute("%s/progress.json" % slot_dir)
		DirAccess.remove_absolute(slot_dir)
	if FileAccess.file_exists("user://profiles/index.json"):
		DirAccess.remove_absolute("user://profiles/index.json")
	DirAccess.remove_absolute("user://profiles")
	# 注意：不在此删 legacy progress.json（由 _restore_snapshot 负责还原/清理）。
	Profile.reload()


## 运行前快照：记下旧单文件进度是否存在及其内容，结束时还原，避免污染共享回归基线。
var _snap_legacy_had := false
var _snap_legacy_content := ""


func _snapshot() -> void:
	_snap_legacy_had = FileAccess.file_exists("user://progress.json")
	if _snap_legacy_had:
		var f := FileAccess.open("user://progress.json", FileAccess.READ)
		if f != null:
			_snap_legacy_content = f.get_as_text()


## 还原运行前的 user:// 状态：legacy 文件原样写回、profiles/ 整体移除。
func _restore_snapshot() -> void:
	if FileAccess.file_exists("user://profiles/index.json"):
		DirAccess.remove_absolute("user://profiles/index.json")
	for s: Dictionary in Profile.list_slots():
		var id: String = s["id"]
		var slot_dir := "user://profiles/%s" % id
		if FileAccess.file_exists("%s/progress.json" % slot_dir):
			DirAccess.remove_absolute("%s/progress.json" % slot_dir)
		DirAccess.remove_absolute(slot_dir)
	DirAccess.remove_absolute("user://profiles")
	if _snap_legacy_had:
		var f := FileAccess.open("user://progress.json", FileAccess.WRITE)
		if f != null:
			f.store_string(_snap_legacy_content)
	elif FileAccess.file_exists("user://progress.json"):
		DirAccess.remove_absolute("user://progress.json")


func _run() -> void:
	_snapshot()
	_reset_fs()
	# 启动态：无槽，current 为空。
	_check(Profile.list_slots().size() == 0, "启动无槽：list_slots 为空")
	_check(Profile.current_slot() == "", "启动 current 为空（退回 legacy）")
	_check(Profile.slot_save_path() == "user://progress.json",
		"D1 current 为空时落盘路径退回旧单文件（向后兼容）")

	# ── A 槽隔离 ──
	var idA := Profile.create_slot("测试A")
	var idB := Profile.create_slot("测试B")
	_check(Profile.list_slots().size() == 2, "A0 建两个槽后 list_slots==2")
	# 写槽 A
	Progress.set_slot(idA)
	Progress.notify("mined_1", 3)
	Progress._save()
	_check(Progress.counters.get("mined_1", 0) == 3, "A1 写入后槽A mined_1==3")
	# 切到槽 B：内存清空且 B 文件不存在 → 空
	Progress.set_slot(idB)
	_check(Progress.counters.get("mined_1", 0) == 0, "A2 切到槽B：mined_1 归零（隔离）")
	Progress.notify("mined_2", 9)
	Progress._save()
	# 切回槽 A：应恢复 3，不受 B 的 9 影响
	Progress.set_slot(idA)
	_check(Progress.counters.get("mined_1", 0) == 3, "A3 切回槽A：mined_1 仍是 3（未受槽B污染）")
	_check(Progress.counters.get("mined_2", 0) == 0, "A4 切回槽A：mined_2 仍为 0（B 的写入未串入）")

	# ── B 槽 CRUD ──
	var before := Profile.list_slots().size()
	var new_id := Profile.create_slot("临时")
	_check(Profile.list_slots().size() == before + 1, "B1 create_slot 后槽数 +1")
	_check(Profile.delete_slot(new_id), "B2 删除刚建的槽成功")
	_check(Profile.list_slots().size() == before, "B3 删除后槽数复原")
	# 不允许删最后一个：删 A 后仅剩 B，再删 B 必须被拒绝。
	_check(Profile.delete_slot(idA), "B4 删除 A 成功（仍剩 B）")
	_check(not Profile.delete_slot(idB), "B5 不允许删最后一个槽（拒绝返回 false）")

	# ── C 迁移 ──
	_reset_fs()
	_check(Profile.list_slots().size() == 0, "C0 复位后无槽")
	# 写一个旧进度文件
	var lf := FileAccess.open("user://progress.json", FileAccess.WRITE)
	lf.store_string(JSON.stringify({"counters": {"mined_1": 7}, "states": {}, "quiz_streak": 0}))
	lf.close()
	var ok := Profile.migrate_legacy()
	_check(ok, "C1 migrate_legacy 在无槽时执行成功")
	_check(Profile.current_slot() == "default", "C2 迁移后 current==default")
	_check(Profile.list_slots().size() == 1, "C3 迁移后恰好 1 个槽")
	_check(Profile.current_name() == "玩家1", "C4 默认槽名为「玩家1」")
	Progress.set_slot("default")
	_check(Progress.counters.get("mined_1", 0) == 7, "C5 迁移的旧进度被加载（mined_1==7）")
	_check(Profile.slot_save_path() == "user://profiles/default/progress.json",
		"C6 迁移后落盘路径指向槽目录")
	# 反向：有槽时 migrate_legacy 不应重复执行
	_check(not Profile.migrate_legacy(), "C7 已有槽时 migrate_legacy 返回 false（不重复）")

	# 还原 user:// 到运行前状态，避免污染共享回归基线。
	_restore_snapshot()
