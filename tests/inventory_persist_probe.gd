extends Node
## 背包按存档槽落盘（D-092）无头验证：序列化往返 / 宽容读档 / 换槽隔离 / D-010。
##
## 探针场景方式运行（踩坑 #22：--script 不加载 Autoload，SaveGuard 依赖
## Progress / Profile 两个 Autoload），故配套 inventory_persist_probe.tscn。
##
## D-010 收尾顺序固定：① 拒写闸 Inventory.io_ok=false 最前（挡住退出期任何
## main._exit_tree / 防抖写盘；本探针不实例化 main，但静态闸仍要置位，保证与
## 回归基线的 D-010 契约一致）→ ② 删探针临时文件 TMP_PATH（不在 EXTRA_FILES
## 内，SaveGuard 覆盖不到）→ ③ SaveGuard.restore() 逐字节还原 user:// 存档树
## 与 Progress 内存态（EXTRA_FILES 已含 inventory.json）。

const TMP_PATH := "user://inv_probe_test.json"

var _pass: int = 0
var _fail: int = 0
var _restored: bool = false
## 开局 user:// 内全部 .json 路径快照，用于「新增文件里无 chunk/world/terrain」判定。
var _files_at_start: Array[String] = []
var _start_existed: bool = false
var _start_text: String = ""


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: " + msg)
		_pass += 1
	else:
		print("FAIL: " + msg)
		_fail += 1


func _ready() -> void:
	# 看门狗：脚本错误猝杀流程时强制退出，_exit_tree 才能走到 _restore()。
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		push_warning("inventory_persist_probe: 看门狗超时，强制退出")
		get_tree().quit(1))
	# D-010：快照必须先于任何写操作 / 早退分支。
	SaveGuard.snapshot()
	_files_at_start = _list_user_json()
	_start_existed = FileAccess.file_exists("user://inventory.json")
	if _start_existed:
		_start_text = FileAccess.get_file_as_string("user://inventory.json")
	_run()
	_finish()


func _finish() -> void:
	_restore()
	# D-010 可观测代理：还原后 user://inventory.json 与开局逐字节一致 ⇒
	# 回归脚本 diff -r 才能打 RESTORED_OK（零 DIFF）。
	_check(_inventory_restored(), "D5 RESTORED_OK：inventory.json 逐字节回到开局状态（零 DIFF）")
	print("INVENTORY_PERSIST_DONE pass=%d fails=%d" % [_pass, _fail])
	if _fail > 0:
		print("INVENTORY_PERSIST_PROBE_FAIL")
	else:
		print("INVENTORY_PERSIST_PROBE_OK")
	get_tree().quit(0 if _fail == 0 else 1)


## 幂等收尾（正常路径 / _exit_tree 安全网 / 看门狗三条路共用）。
func _restore() -> void:
	if _restored:
		return
	_restored = true
	# ① 拒写闸最前。
	Inventory.io_ok = false
	# ② 删探针临时文件（不在 EXTRA_FILES 内，SaveGuard 覆盖不到）。
	if FileAccess.file_exists(TMP_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PATH))
	# ③ SaveGuard 逐字节还原存档树 + Progress 内存态。
	SaveGuard.restore()


func _exit_tree() -> void:
	_restore()


func _inventory_restored() -> bool:
	var existed: bool = FileAccess.file_exists("user://inventory.json")
	if existed != _start_existed:
		return false
	if not existed:
		return true
	return FileAccess.get_file_as_string("user://inventory.json") == _start_text


# ────────────────────────── 断言组 ──────────────────────────

func _run() -> void:
	_run_roundtrip()
	_run_robustness()
	_run_slots()
	_run_d010()


func _run_roundtrip() -> void:
	var inv: Inventory = Inventory.new(Inventory.SLOT_COUNT, Inventory.COMMON_COUNT)
	inv.slots[0] = {"item": BlockTypes.Block.STONE, "count": 7, "durability": -1}
	inv.slots[1] = {"item": ItemTypes.STONE_PICKAXE, "count": 1, "durability": 13}
	inv.slots[8] = {"item": BlockTypes.Block.WOOD, "count": 3, "durability": -1}
	inv.assign_hotbar(0, 5)
	inv.assign_hotbar(1, 8)
	var payload: Dictionary = inv.to_dict()
	_check(int(payload.get("version", 0)) == 1, "A1 payload 含 version=1")
	_check(payload.size() == 4 and payload.has("slots")
		and payload.has("hotbar_map") and payload.has("fill_limit"),
		"A2 payload 只含 version/slots/hotbar_map/fill_limit 四键（无区块/地形字段）")
	var back: Inventory = Inventory.from_dict(payload)
	_check(_same_inventory(inv, back), "A3 序列化往返逐槽全等")
	_check(back.get_durability(1) == 13, "A4 工具磨旧耐久 13 保留（不回满）")
	_check(back.hotbar_map == inv.hotbar_map, "A5 hotbar_map 往返全等")
	_check(back.fill_limit == 27, "A6 fill_limit=27 往返保留")
	# save / load 往返 + 重复读取幂等
	_check(inv.save(TMP_PATH), "A7 save(tmp) 写入成功")
	var r1: Inventory = Inventory.load_or_new(TMP_PATH)
	var r2: Inventory = Inventory.load_or_new(TMP_PATH)
	_check(_same_inventory(r1, r2) and _same_inventory(inv, r1),
		"A8 重复读取幂等且等于原背包")
	# 拒写闸
	var before: String = FileAccess.get_file_as_string(TMP_PATH)
	Inventory.io_ok = false
	inv.slots[0]["count"] = 99
	_check(not inv.save(TMP_PATH), "A9 io_ok=false 时 save() 返回 false")
	_check(FileAccess.get_file_as_string(TMP_PATH) == before,
		"A10 io_ok=false 拒写：文件逐字节不变")
	Inventory.io_ok = true
	# 缺文件兜底
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PATH))
	var missing: Inventory = Inventory.load_or_new(TMP_PATH)
	_check(not FileAccess.file_exists(TMP_PATH),
		"A11 缺文件兜底：load_or_new 不新建文件（file_exists==false）")
	_check(_is_air_default(missing), "A12 缺文件兜底为 36 槽 AIR 默认")


func _run_robustness() -> void:
	_write_text(TMP_PATH, "{ 这不是合法 JSON ]]")
	_check(_is_air_default(Inventory.load_or_new(TMP_PATH)),
		"B1 损坏 JSON 退回 36 槽 AIR 默认")
	_write_text(TMP_PATH, "[1, 2, 3]")
	_check(_is_air_default(Inventory.load_or_new(TMP_PATH)),
		"B2 顶层非字典（Array）退回默认")
	var small: Dictionary = _valid_payload()
	var small_slots: Array = small["slots"] as Array
	small_slots.resize(10)
	_write_text(TMP_PATH, JSON.stringify(small))
	_check(_is_air_default(Inventory.load_or_new(TMP_PATH)),
		"B3 槽数不足（10）退回默认")
	var big: Dictionary = _valid_payload()
	var big_slots: Array = big["slots"] as Array
	for i in range(5):
		big_slots.append({"item": 0, "count": 0, "durability": -1})
	_write_text(TMP_PATH, JSON.stringify(big))
	_check(_is_air_default(Inventory.load_or_new(TMP_PATH)),
		"B4 槽数超量（41）退回默认")
	var bad_count: Dictionary = _valid_payload()
	var bad_count_slots: Array = bad_count["slots"] as Array
	bad_count_slots[0] = {"item": 3, "count": "七", "durability": -1}
	_write_text(TMP_PATH, JSON.stringify(bad_count))
	_check(_is_air_default(Inventory.load_or_new(TMP_PATH)),
		"B5 槽字段类型错（count 为字符串）退回默认")
	var bad_map: Dictionary = _valid_payload()
	var bad_map_arr: Array = bad_map["hotbar_map"] as Array
	bad_map_arr[0] = "zero"
	_write_text(TMP_PATH, JSON.stringify(bad_map))
	_check(_is_air_default(Inventory.load_or_new(TMP_PATH)),
		"B6 hotbar_map 元素类型错退回默认")
	var bad_fill: Dictionary = _valid_payload()
	bad_fill["fill_limit"] = "twenty-seven"
	_write_text(TMP_PATH, JSON.stringify(bad_fill))
	_check(_is_air_default(Inventory.load_or_new(TMP_PATH)),
		"B7 fill_limit 类型错退回默认")


func _run_slots() -> void:
	_reset_fs()
	Inventory._refresh_path()
	var id_a: String = Profile.create_slot("背包A")
	var id_b: String = Profile.create_slot("背包B")
	Progress.set_slot(id_a)
	Inventory._refresh_path()
	_check(Inventory.SAVE_PATH == "user://profiles/%s/inventory.json" % id_a,
		"C1 槽A inventory 路径落在 user://profiles/<A>/inventory.json")
	var inv_a: Inventory = Inventory.new(Inventory.SLOT_COUNT, Inventory.COMMON_COUNT)
	inv_a.slots[1] = {"item": ItemTypes.STONE_PICKAXE, "count": 1, "durability": 13}
	_check(inv_a.save(), "C2 槽A save() 写入含工具耐久的背包")
	Progress.set_slot(id_b)
	Inventory._refresh_path()
	_check(Inventory.SAVE_PATH == "user://profiles/%s/inventory.json" % id_b,
		"C3 槽B 路径与槽A 不同")
	var inv_b: Inventory = Inventory.load_or_new()
	_check(_is_air_default(inv_b), "C4 切B：背包全空（A 槽物品未串入）")
	Progress.set_slot(id_a)
	Inventory._refresh_path()
	var inv_back: Inventory = Inventory.load_or_new()
	_check(_same_inventory(inv_a, inv_back),
		"C5 切回A：逐槽全等（含工具磨旧耐久 13）")
	# 储物箱不产生新文件
	var before: Array[String] = _list_user_json()
	var box: Inventory = Inventory.new(36)
	box.add_item(BlockTypes.Block.STONE, 5)
	_check(_list_user_json() == before, "C6 储物箱 Inventory 不产生新文件")
	# user:// 内无 chunk/world/terrain 新文件
	var forbidden: bool = false
	for p: String in _list_user_json():
		if _files_at_start.has(p):
			continue
		var n: String = p.get_file()
		if n.contains("chunk") or n.contains("world") or n.contains("terrain"):
			forbidden = true
	_check(not forbidden, "C7 探针新增的 user:// 文件里无 chunk/world/terrain")
	_reset_fs()
	Inventory._refresh_path()


func _run_d010() -> void:
	# 故意污染默认路径，交给 _restore() 的 SaveGuard.restore() 逐字节还原。
	var dirty: Inventory = Inventory.new(Inventory.SLOT_COUNT, Inventory.COMMON_COUNT)
	dirty.slots[2] = {"item": BlockTypes.Block.DIRT, "count": 42, "durability": -1}
	Inventory._refresh_path()
	_check(dirty.save(), "D1 默认路径 user://inventory.json 可写（供 SaveGuard 还原验证）")
	var inv_src: String = _source_of("res://scripts/systems/inventory.gd")
	var guard_src: String = _source_of("res://tests/save_guard.gd")
	var main_src: String = _source_of("res://scripts/main.gd")
	_check(inv_src.contains("if not io_ok:"),
		"D2 Inventory.save() 开头有 io_ok 拒写闸")
	_check(guard_src.contains("\"user://inventory.json\"")
		and guard_src.contains("Inventory.io_ok = false"),
		"D3 SaveGuard 已登记 inventory.json 且 restore() 统一置拒写闸")
	_check(main_src.contains("func _exit_tree()") and main_src.contains("if _inv_dirty:"),
		"D4 main._exit_tree() 仅在标脏时补写")


# ────────────────────────── 辅助 ──────────────────────────

func _same_inventory(a: Inventory, b: Inventory) -> bool:
	if a.slots.size() != b.slots.size():
		return false
	for i: int in a.slots.size():
		if int(a.slots[i]["item"]) != int(b.slots[i]["item"]):
			return false
		if int(a.slots[i]["count"]) != int(b.slots[i]["count"]):
			return false
		if int(a.slots[i]["durability"]) != int(b.slots[i]["durability"]):
			return false
	if a.hotbar_map != b.hotbar_map:
		return false
	return a.fill_limit == b.fill_limit


func _is_air_default(inv: Inventory) -> bool:
	if inv.slots.size() != Inventory.SLOT_COUNT:
		return false
	for s: Dictionary in inv.slots:
		if int(s["item"]) != BlockTypes.Block.AIR or int(s["count"]) != 0 \
				or int(s["durability"]) != -1:
			return false
	if inv.hotbar_map.size() != Inventory.HOTBAR_SIZE:
		return false
	for i: int in inv.hotbar_map.size():
		if inv.hotbar_map[i] != i:
			return false
	return inv.fill_limit == Inventory.COMMON_COUNT


func _valid_payload() -> Dictionary:
	var inv: Inventory = Inventory.new(Inventory.SLOT_COUNT, Inventory.COMMON_COUNT)
	return inv.to_dict()


func _write_text(path: String, text: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()


func _source_of(res_path: String) -> String:
	var f: FileAccess = FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return ""
	var text: String = f.get_as_text()
	f.close()
	return text


func _list_user_json() -> Array[String]:
	var out: Array[String] = []
	_collect_json("user://", out)
	out.sort()
	return out


func _collect_json(dir_path: String, out: Array[String]) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var full: String = dir_path.path_join(entry)
			if dir.current_is_dir():
				_collect_json(full, out)
			elif entry.ends_with(".json"):
				out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


## 清空档案槽目录并复位 Profile 内存态（照 sailing_journal_probe 的 _reset_fs）。
## Profile.reload() 不 emit slot_changed，调用方必须显式 Inventory._refresh_path()。
func _reset_fs() -> void:
	_remove_dir_tree("user://profiles")
	Profile.reload()


func _remove_dir_tree(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var full: String = path.path_join(entry)
			if dir.current_is_dir():
				_remove_dir_tree(full)
			else:
				DirAccess.remove_absolute(ProjectSettings.globalize_path(full))
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
