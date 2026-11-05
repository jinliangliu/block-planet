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
##
## D-086：本探针追加「8 份玩家状态按槽派生 + 换槽内存态重载」的验收入口。
## 日常回归脚本把真实 profiles/ 整体移出，探针跑在**无槽态**，动态路径恰好
## 逐字节等于旧根路径——所以分槽逻辑只能靠本探针自己建槽覆盖，别被全绿误导。

var _pass := 0
var _fail := 0
## D-010：OK / FAIL / 脚本错误 / 看门狗超时四条退出路径都必须走到 SaveGuard.restore()。
var _restored := false

## 8 份玩家状态的旧根路径（const → var 后的「反向对照」基线）：无槽时
## Profile.slot_file() 必须逐字节产出这 8 个字符串。顺序与 _collect_paths() 一致。
const LEGACY_PATHS: Array[String] = [
	"user://fishing_journal.json",
	"user://boats.json",
	"user://race_records.json",
	"user://flight_teaching.json",
	"user://race_replay.jsonl",
	"user://race_teaching.json",
	"user://blueprint.json",
	"user://unlocks.json",
]


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: " + msg)
		_pass += 1
	else:
		print("FAIL: " + msg)
		_fail += 1


func _ready() -> void:
	# 看门狗：脚本错误猝杀流程时强制退出，_exit_tree 才能走到 SaveGuard.restore()。
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		push_warning("profile_slot_probe: 看门狗超时，强制退出")
		get_tree().quit())
	_run()
	print("PROFILE_SLOT_TEST_DONE fails=%d" % _fail)
	if _fail > 0:
		print("PROFILE_SLOT_TEST_FAILED")
	else:
		print("PROFILE_SLOT_TEST_OK")
	get_tree().quit(0 if _fail == 0 else 1)


## D-010 安全网：_run() 中途抛错 / 看门狗触发时，_exit_tree 兜底还原。
func _exit_tree() -> void:
	if not _restored:
		_restored = true
		SaveGuard.restore()


## 递归删掉一个目录（含任意文件名）。D-086 起槽目录里不止 progress.json，
## 还有 8 份按槽派生的玩家状态，DirAccess.remove_absolute 只能删空目录。
func _remove_dir_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var full := path.path_join(entry)
			if dir.current_is_dir():
				_remove_dir_tree(full)
			else:
				DirAccess.remove_absolute(ProjectSettings.globalize_path(full))
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## 清掉 user:// 下与档案系统相关的全部文件痕迹，并复位 Profile 内存态，
## 让每次测试段从干净状态开始。利用 Profile.list_slots() 逐个槽删文件→删空目录。
func _reset_fs() -> void:
	# D-086：槽目录里现在有 8 份状态文件，不再逐个删 progress.json + 删空目录。
	_remove_dir_tree("user://profiles")
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
	_remove_dir_tree("user://profiles")
	if _snap_legacy_had:
		var f := FileAccess.open("user://progress.json", FileAccess.WRITE)
		if f != null:
			f.store_string(_snap_legacy_content)
	elif FileAccess.file_exists("user://progress.json"):
		DirAccess.remove_absolute("user://progress.json")


func _run() -> void:
	# D-010：必须在任何文件/内存态改动之前整树快照，四条退出路径共用一份。
	SaveGuard.snapshot()
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

	# ── D-086：8 份玩家状态的按槽路径 + 换槽内存态隔离 ──
	_reset_fs()
	_check_legacy_paths()
	var id_sa := Profile.create_slot("隔离A")
	var id_sb := Profile.create_slot("隔离B")
	# create_slot 不自动选中；必须经 select_slot（Progress.set_slot 内部会调它）
	# 才会 emit slot_changed，三个 Autoload 才会重载内存态。
	Progress.set_slot(id_sa)
	var paths_a := _collect_paths()
	_check(_all_in_slot(paths_a, id_sa), "D1 槽A：8 份路径全部落在 user://profiles/<A>/")
	_check(_all_differ(paths_a, LEGACY_PATHS), "D2 槽A：8 份路径均不同于旧根路径")
	_write_slot_state("clownfish", "race_start", "fishing_boat")
	var a_fish := FishingSystem.discovered_count()
	var a_wins := int(RaceSystem.entry_of("desert_ring")["wins"])
	_check(a_fish == 1, "D3 槽A：钓鱼图鉴写入 1 条")
	_check(a_wins == 1, "D4 槽A：竞速记录写入 1 胜")
	_check(BoatSystem.owns("fishing_boat"), "D5 槽A：小渔船已拥有")
	var a_events := RaceReplayLog.read_events()
	_check(a_events.size() == 1, "D6 槽A：回放日志 1 条")
	# 缓存 A 槽 journal 的子字典引用，供换槽后验证「整体替换」语义。
	var stale: Dictionary = FishingSystem.record_of("clownfish")

	Progress.set_slot(id_sb)
	var paths_b := _collect_paths()
	_check(_all_in_slot(paths_b, id_sb), "D7 槽B：8 份路径全部落在 user://profiles/<B>/")
	_check(_all_differ(paths_b, paths_a), "D8 槽B：8 份路径与槽A 全不相同")
	_check(FishingSystem.discovered_count() == 0, "D9 切B：钓鱼图鉴归零")
	_check(int(RaceSystem.entry_of("desert_ring")["wins"]) == 0, "D10 切B：竞速记录归零")
	_check(not BoatSystem.owns("fishing_boat"), "D11 切B：A 的小渔船未串入")
	_check(not RaceSystem.is_unlocked("wins:1"), "D12 切B：wins:1 未解锁")
	_check(RaceReplayLog.read_events().is_empty(), "D13 切B：回放日志为空")

	_write_slot_state("tuna", "race_finish", "speedboat")
	Progress.set_slot(id_sa)
	_check(FishingSystem.discovered_count() == a_fish, "D14 切回A：图鉴恢复")
	_check(int(RaceSystem.entry_of("desert_ring")["wins"]) == a_wins, "D15 切回A：竞速记录恢复")
	_check(BoatSystem.owns("fishing_boat"), "D16 切回A：小渔船仍在")
	_check(not BoatSystem.owns("speedboat"), "D17 切回A：B 的快艇未串入")
	var back_events := RaceReplayLog.read_events()
	_check(back_events.size() == a_events.size(), "D18 切回A：回放条数不变")
	var action_ok := false
	if back_events.size() > 0:
		action_ok = String((back_events[0] as Dictionary).get("action", "")) == "race_start"
	_check(action_ok, "D19 切回A：回放内容仍是 A 的事件（B 未串入）")

	# 换槽后 journal 被整体替换的反向对照：改动新对象不能影响旧缓存引用。
	var fresh: Dictionary = FishingSystem.record_of("clownfish")
	fresh["catch_count"] = 99
	_check(int(stale.get("catch_count", 0)) == 1,
		"D20 换槽后 record_of() 返回新对象（旧缓存引用已失效）")
	fresh["catch_count"] = 1

	# 还原 user:// 到运行前状态，避免污染共享回归基线。
	_restore_snapshot()
	# D-010：OK / FAIL 两条路径都要过 SaveGuard.restore()；递归兜底清掉槽目录里
	# 8 份状态文件与临时文件，Progress 内存态一并还原。
	SaveGuard.restore()
	_restored = true


## D-086：把 8 份路径变量统一重算一次并快照。三个 Autoload 靠 slot_changed
## 自动重算；其余 5 个无 _ready() 的静态类在各自 IO 入口重算。这里显式各调一次，
## 保证断言读到的是「当前槽」这一刻的值，不受前面调用顺序影响。
func _collect_paths() -> Array[String]:
	FishingSystem._refresh_path()
	BoatSystem._refresh_path()
	RaceSystem._refresh_path()
	FlightTeaching._refresh_path()
	RaceReplayLog._refresh_path()
	RaceTeachingUI._refresh_path()
	BuildScreen._refresh_path()
	PartUnlocks._refresh_path()
	var out: Array[String] = [
		FishingSystem.JOURNAL_PATH,
		BoatSystem.JOURNAL_PATH,
		RaceSystem.RECORDS_PATH,
		FlightTeaching.SAVE_PATH,
		RaceReplayLog.PATH,
		RaceTeachingUI.SAVE_PATH,
		BuildScreen.BLUEPRINT_PATH,
		PartUnlocks.SAVE_PATH,
	]
	return out


func _check_legacy_paths() -> void:
	var paths := _collect_paths()
	for i: int in LEGACY_PATHS.size():
		_check(paths[i] == LEGACY_PATHS[i],
			"D0 无槽回退：%s 逐字节等于旧根路径" % LEGACY_PATHS[i].get_file())


func _all_in_slot(paths: Array[String], id: String) -> bool:
	var prefix := "user://profiles/%s/" % id
	for p: String in paths:
		if not p.begins_with(prefix):
			return false
	return true


func _all_differ(a: Array[String], b: Array[String]) -> bool:
	if a.size() != b.size():
		return true
	for i: int in a.size():
		if a[i] == b[i]:
			return false
	return true


## 往「当前槽」写四份代表性状态。刻意走各系统自己的落盘入口，覆盖
## fishing_journal.json / race_records.json / boats.json / race_replay.jsonl
## 四条写入链；不调 RaceSystem.submit_result()，那会广播 Events.race_finished
## 牵动 Progress，纯逻辑 apply + save 已足够且无副作用。
func _write_slot_state(fish_id: String, action: String, boat_id: String) -> void:
	var records: Variant = FishingSystem.journal.get("records", {})
	if typeof(records) != TYPE_DICTIONARY:
		records = {}
		FishingSystem.journal["records"] = records
	(records as Dictionary)[fish_id] = {"catch_count": 1}
	FishingSystem._save_journal()
	RaceRecords.apply(RaceSystem.records(), "desert_ring", "tricycle", 1, 30.0, 90.0,
		"2026-01-01T00:00:00")
	RaceSystem.save_records()
	BoatSystem.grant_boat(boat_id)
	RaceReplayLog.append(1, action, "desert_ring", "tricycle", Vector3.ZERO, "小方块")
