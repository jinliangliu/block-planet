extends Node
## 我的航海记录（D-089 阶段 2）无头验证：里程语义反例 + 按槽持久化 + D-010。
##
## 确定性构造（不实例化 main.tscn，物理不确定）：Boat.new() + raft（无发动机 ⇒
## _emit_readings():209 不额外写盘）+ set_physics_process(false)，手动打
## _emit_readings(0.1) 节拍。_readings_timer 初值 0.0，每次调用恰好通过一次
## :211 早退（0.0 - 0.1 = -0.1 → 不 return → 复位 0.1 → 采样 → emit）。
##
## 核心反例：累计里程 = 相邻两拍 XZ 位移之和，**不是离港距离累加**。停泊 30 拍
## 若按离港距离累加会得到 30×200=6000 m；正确实现 Δtotal_m≈0。
##
## D-010 三层闭合（**两个** Autoload 都做，缺一不可）：BoatSystem._exit_tree()
## （:91-92）与 FishingSystem._exit_tree()（:149-150）都无条件 _save_journal()，
## 唯一闸门是各自的 journal_ok；两者 _load_journal() 在文件不存在时也会把
## journal_ok 置 true。SaveGuard.restore() 覆盖不到 fishing_journal.json（始终不在
## EXTRA_FILES 内），也覆盖不到有槽态的 boats.json；BoatSystem 新增的 _process()
## 1.5 s 防抖在 _run() 期间就有写盘能力。故收尾顺序固定：① 拒写闸最前（两个
## journal_ok=false，挡住防抖与两个 _exit_tree）→ ② 按开局快照的 JOURNAL_PATH
## 逐字节回写 / 删除两份文本 → ③ 最后 SaveGuard.restore()。两份快照必须先于
## 任何早退分支。竞速侧「无 _exit_tree 不调即不写」不对称，别套错。

var _pass: int = 0
var _fail: int = 0
var _restored: bool = false
## 两份根状态文件按「开局路径 + 原文本 + 是否存在」逐字节快照（D-010）。
var _fish_path_at_start: String = ""
var _fish_text: String = ""
var _fish_existed: bool = false
var _boat_path_at_start: String = ""
var _boat_text: String = ""
var _boat_existed: bool = false
var _boat: Boat = null


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
		push_warning("sailing_journal_probe: 看门狗超时，强制退出")
		get_tree().quit(1))
	# 快照必须先于任何早退 / 断言分支：_exit_tree 无条件走 _restore()，
	# 空静态快照会删掉真实存档（D-088 §2 第 4 条）。
	SaveGuard.snapshot()
	# 两份根状态文件按开局路径逐字节快照；必须先于 _setup_boat() / _run()
	# （此二者会真实改写 journal），也先于任何早退（_exit_tree 必走 _restore）。
	_fish_path_at_start = FishingSystem.JOURNAL_PATH
	if FileAccess.file_exists(_fish_path_at_start):
		_fish_existed = true
		var ff: FileAccess = FileAccess.open(_fish_path_at_start, FileAccess.READ)
		if ff != null:
			_fish_text = ff.get_as_text()
			ff.close()
	_boat_path_at_start = BoatSystem.JOURNAL_PATH
	if FileAccess.file_exists(_boat_path_at_start):
		_boat_existed = true
		var bf: FileAccess = FileAccess.open(_boat_path_at_start, FileAccess.READ)
		if bf != null:
			_boat_text = bf.get_as_text()
			bf.close()
	_reset_fs()
	BoatSystem._refresh_path()
	_setup_boat()
	_run()
	_finish()


func _finish() -> void:
	_restore()
	print("SAILING_JOURNAL_DONE pass=%d fails=%d" % [_pass, _fail])
	if _fail > 0:
		print("SAILING_JOURNAL_PROBE_FAIL")
	else:
		print("SAILING_JOURNAL_PROBE_OK")
	get_tree().quit(0 if _fail == 0 else 1)


## 幂等收尾（正常路径 / _exit_tree 安全网 / 看门狗三条路共用）。
## 顺序固定：① 拒写闸最前 → ② 按开局路径逐字节还原两份 → ③ SaveGuard.restore()。
func _restore() -> void:
	if _restored:
		return
	_restored = true
	if _boat != null and is_instance_valid(_boat):
		_boat.queue_free()
	# ① 拒写闸优先：挡住 BoatSystem._process() 防抖写盘与两个 _exit_tree()。
	FishingSystem.journal_ok = false
	BoatSystem.journal_ok = false
	# ② 按开局路径复原，并按开局存在性回写 / 删除（删除前 file_exists 守卫）。
	if not _fish_path_at_start.is_empty():
		FishingSystem.JOURNAL_PATH = _fish_path_at_start
		_restore_text(_fish_path_at_start, _fish_existed, _fish_text)
	if not _boat_path_at_start.is_empty():
		BoatSystem.JOURNAL_PATH = _boat_path_at_start
		_restore_text(_boat_path_at_start, _boat_existed, _boat_text)
	# ③ 最后还原 SaveGuard 覆盖的存档树与 Progress 内存态。
	SaveGuard.restore()


func _restore_text(path: String, existed: bool, text: String) -> void:
	if existed:
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(path.get_base_dir()))
		var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(text)
			f.close()
	elif FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _exit_tree() -> void:
	_restore()


# ────────────────────────── 确定性构造 ──────────────────────────

func _setup_boat() -> void:
	_boat = Boat.new()
	_boat.boat_id = "raft"
	add_child(_boat)
	_boat.set_physics_process(false)
	_boat.harbor_pos = Vector3(0.0, 0.0, -200.0)   # distance_to_harbor() = 200 m
	_boat.global_position = Vector3.ZERO
	_boat.set_piloted(true)


func _tick() -> void:
	_boat._emit_readings(0.1)


func _reset_sail() -> void:
	BoatSystem.journal = {
		"version": 2, "owned": ["raft"], "current": "raft", "fuel": {},
		"sail": {
			"total_m": 0.0, "farthest_m": 0.0,
			"bands": {"near": 0, "mid": 0, "far": 0}, "badges": {},
		},
	}
	BoatSystem.journal_ok = true
	BoatSystem._dirty = false
	BoatSystem._last_save_msec = Time.get_ticks_msec()
	_boat.harbor_pos = Vector3(0.0, 0.0, -200.0)
	_boat.global_position = Vector3.ZERO
	_boat.set_piloted(true)


func _sail() -> Dictionary:
	return BoatSystem.sail_state()


# ────────────────────────── 断言组 ──────────────────────────

func _run() -> void:
	_run_api_baseline()
	_run_mileage()
	_run_serialization()
	_run_debounce_slots()
	_run_d010()


func _run_api_baseline() -> void:
	_reset_sail()
	var s: Dictionary = _sail()
	s["total_m"] = 999.0
	_check(absf(float(_sail().get("total_m", -1.0))) < 0.001,
		"A1 sail_state() 返回拷贝，改它不污染内部 journal")
	_check(BoatSystem.band_of(100.0) == "near" and BoatSystem.band_of(100.01) == "mid",
		"A2 band_of 100 m 边界（<= 属 near）")
	_check(BoatSystem.band_of(250.0) == "mid" and BoatSystem.band_of(250.01) == "far",
		"A3 band_of 250 m 边界（<= 属 mid）")
	_check(BoatSystem.badge_of("nope") == 0 and not BoatSystem.claim_badge("nope"),
		"A4 非法徽章 key：badge_of==0、claim_badge==false")
	_check(not BoatSystem.claim_badge("sail_100"),
		"A5 里程未达标：claim_badge 返回 false（幂等闸门前置条件）")


func _run_mileage() -> void:
	# ① 停泊反例：位置恒 ZERO、距港恒 200 m，手动打 30 次节拍。
	_reset_sail()
	for i: int in range(30):
		_tick()
	var st: Dictionary = _sail()
	_check(float(st.get("total_m", -1.0)) < 0.001,
		"B1 停泊 30 拍 Δtotal_m<0.001（把离港距离当里程累加的实现 ≈6000 m 必 FAIL）")
	_check(absf(float(st.get("farthest_m", -1.0)) - 200.0) < 0.001,
		"B2 停泊仍记录 farthest_m==200.0（第二个鉴别器）")

	# ② 折返：z=0 ↔ z=2 交替 20 段（每步 2 m ≤ 5 m 地板护栏）回到起点。
	_reset_sail()
	_tick()   # 首次只播种
	for i: int in range(20):
		_boat.global_position = Vector3(0.0, 0.0, 2.0 if i % 2 == 0 else 0.0)
		_tick()
	var total_back: float = float(_sail().get("total_m", -1.0))
	_check(absf(total_back - 40.0) < 0.001,
		"B3 折返 20 段 × 2 m ⇒ Δtotal_m≈40.0（实测 %.2f）" % total_back)
	_check(total_back > 0.001,
		"B4 折返里程严格 > 起终点直线距离 0（不是净位移）")

	# 正方形绕圈：边长 2 m × 4 = 8 m，起终点相同。
	_reset_sail()
	_tick()
	var corners: Array[Vector3] = [
		Vector3(2.0, 0.0, 0.0), Vector3(2.0, 0.0, 2.0),
		Vector3(0.0, 0.0, 2.0), Vector3(0.0, 0.0, 0.0),
	]
	for c: Vector3 in corners:
		_boat.global_position = c
		_tick()
	var loop_total: float = float(_sail().get("total_m", -1.0))
	_check(absf(loop_total - 8.0) < 0.001 and loop_total > 0.0,
		"B5 正方形绕圈 4×2 m ⇒ Δtotal_m≈8.0 且 >0（实测 %.2f）" % loop_total)

	# ③ 登离船不含传送：离船 → 挪到 z=500 → 登船 → 首采样只播种 → 再走 2 m。
	_reset_sail()
	_tick()
	_boat.set_piloted(false)
	_boat.global_position = Vector3(0.0, 0.0, 500.0)
	_tick()                    # piloted=false 硬闸，不采样
	_boat.set_piloted(true)    # 清 prev
	_tick()                    # 首采样只播种，不写 farthest
	var seeded: Dictionary = _sail()
	_check(float(seeded.get("total_m", -1.0)) == 0.0,
		"B6a 传送本身不产生里程（total_m 仍 0）")
	_check(float(seeded.get("farthest_m", -1.0)) == 0.0,
		"B7 传送后首采样只播种，farthest_m 未被顶高（仍 0）")
	_boat.global_position = Vector3(0.0, 0.0, 502.0)
	_tick()
	var hop: Dictionary = _sail()
	_check(absf(float(hop.get("total_m", -1.0)) - 2.0) < 0.001,
		"B6 登离船后只走 2 m ⇒ Δtotal_m==2.0（不是 502）")

	# 传送护栏：保持 piloted 直接跳 6 m（> 5.0 m 地板），只更新 prev。
	_reset_sail()
	_tick()                                              # 播种
	_boat.global_position = Vector3(0.0, 0.0, 2.0)
	_tick()                                              # 有效采样：farthest=202
	var before_guard: Dictionary = _sail()
	_boat.global_position = Vector3(0.0, 0.0, 8.0)      # 6 m 跳转
	_tick()
	var after_guard: Dictionary = _sail()
	_check(float(after_guard.get("total_m", -1.0)) == float(before_guard.get("total_m", -1.0))
		and float(after_guard.get("farthest_m", -1.0)) == float(before_guard.get("farthest_m", -1.0)),
		"B8 6 m 跳转触发 5.0 m 地板护栏：total_m / farthest_m 均不变")

	# ⑨ 无港口：band 取 near、farthest_m 不更新。
	_reset_sail()
	_boat.harbor_pos = Vector3.ZERO
	_tick()
	_boat.global_position = Vector3(0.0, 0.0, 2.0)
	_tick()
	var no_harbor: Dictionary = _sail()
	var bands: Dictionary = no_harbor["bands"]
	_check(float(no_harbor.get("farthest_m", -1.0)) == 0.0
		and int(bands.get("near", 0)) >= 1,
		"B9 无港口（dist=-1）：farthest_m 不更新、band 取 near")
	_boat.harbor_pos = Vector3(0.0, 0.0, -200.0)

	# ① piloted 硬闸：无人船（含景观船漂流）不记里程。
	_reset_sail()
	_boat.set_piloted(false)
	_boat.global_position = Vector3(0.0, 0.0, 20.0)
	for i: int in range(10):
		_boat.global_position += Vector3(0.0, 0.0, 1.0)
		_tick()
	_check(float(_sail().get("total_m", -1.0)) == 0.0,
		"B10 piloted=false 硬闸：无人船 10 拍位移不产生里程")


func _run_serialization() -> void:
	# C1 序列化往返全等
	_reset_sail()
	BoatSystem.journal_ok = true
	BoatSystem.record_sail(120.0, 210.0, "mid")
	BoatSystem.claim_badge("sail_100")
	var before: Dictionary = _sail()
	BoatSystem._save_journal()
	BoatSystem._load_journal()
	_check(_same_sail(before, _sail()),
		"C1 序列化往返：total / farthest / bands / badges 全等")

	# C2/C3 旧档缺 sail 键：逐字段兜底 + 不写盘
	var path: String = BoatSystem.JOURNAL_PATH
	var legacy: Dictionary = {
		"version": 1, "owned": ["raft"], "current": "raft", "fuel": {},
	}
	var wf: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if wf != null:
		wf.store_string(JSON.stringify(legacy))
		wf.close()
	var legacy_text: String = FileAccess.get_file_as_string(path)
	BoatSystem._load_journal()
	var st: Dictionary = _sail()
	var bands: Dictionary = st["bands"]
	var badges: Dictionary = st["badges"]
	# badges 默认空字典，缺 key 时 .get(key, -1) 返回哨兵 -1（不是 0）；
	# 「旧档未领过徽章」的准确判据是「不含该 key」，别拿 -1 去和 0 比。
	_check(float(st.get("total_m", -1.0)) == 0.0
		and float(st.get("farthest_m", -1.0)) == 0.0
		and int(bands.get("near", -1)) == 0
		and not badges.has("sail_100"),
		"C2 version 1 旧档缺 sail 键：逐字段兜底为默认（不抛错，实测 %s）" % [str(st)])
	_check(FileAccess.get_file_as_string(path) == legacy_text,
		"C3 宽容读档不写盘（version 2 不需要迁移脚本）")

	# C4/C5 损坏 JSON：journal_ok=false 且后续拒写
	var bf: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if bf != null:
		bf.store_string("{broken")
		bf.close()
	BoatSystem._load_journal()
	_check(not BoatSystem.journal_ok,
		"C4 损坏 JSON → journal_ok=false（保护原档）")
	var broken_text: String = FileAccess.get_file_as_string(path)
	BoatSystem.record_sail(1.0, 10.0, "near")
	BoatSystem._save_journal()
	_check(FileAccess.get_file_as_string(path) == broken_text,
		"C5 journal_ok=false 拒写：record_sail 后原档逐字节不变")

	# C6 缺文件绝不新建（_load_journal 只置 journal_ok=true 后 return）
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	BoatSystem._load_journal()
	_check(BoatSystem.journal_ok and not FileAccess.file_exists(path),
		"C6 缺文件：_load_journal() 不新建文件、journal_ok=true")


func _run_debounce_slots() -> void:
	# D1/D2 防抖合并
	_reset_sail()
	BoatSystem.journal_ok = true
	BoatSystem._save_journal()
	var path: String = BoatSystem.JOURNAL_PATH
	var text_before: String = FileAccess.get_file_as_string(path)
	BoatSystem._last_save_msec = Time.get_ticks_msec()
	for i: int in range(5):
		BoatSystem.record_sail(1.0, 200.0, "mid")
	_check(BoatSystem._dirty, "D1a 多次 record_sail() 只标脏")
	_check(FileAccess.get_file_as_string(path) == text_before,
		"D1b 1.5 s 防抖窗口内不落盘")
	BoatSystem._last_save_msec = Time.get_ticks_msec() - 2000
	BoatSystem._process(0.0)
	_check(FileAccess.get_file_as_string(path) != text_before and not BoatSystem._dirty,
		"D2 窗口到期后合并落一次盘、脏位清零")

	# D3 claim_badge 幂等
	_reset_sail()
	BoatSystem.journal_ok = true
	BoatSystem.record_sail(1200.0, 300.0, "far")
	_check(BoatSystem.claim_badge("sail_100"), "D3a 达标后首次领取成功")
	_check(not BoatSystem.claim_badge("sail_100"), "D3b 重复领取返回 false（幂等闸门）")
	_check(BoatSystem.badge_of("sail_100") == 1, "D3c badge_of==1，不累加到 2")

	# D4 换槽 A→B→A 数据隔离
	_reset_fs()
	BoatSystem._refresh_path()
	var id_a: String = Profile.create_slot("航海A")
	var id_b: String = Profile.create_slot("航海B")
	Progress.set_slot(id_a)
	_reset_sail()
	BoatSystem.journal_ok = true
	BoatSystem.record_sail(30.0, 220.0, "mid")
	BoatSystem._save_journal()
	Progress.set_slot(id_b)
	_check(absf(float(_sail().get("total_m", -1.0))) < 0.001,
		"D4a 切到 B 槽：里程归零（按槽隔离）")
	Progress.set_slot(id_a)
	_check(absf(float(_sail().get("total_m", -1.0)) - 30.0) < 0.001,
		"D4b 切回 A 槽：里程恢复为 30.0 m")

	# D5/D6 slot_changed 回调里 journal 文本不变（禁 save）、脏位清空
	BoatSystem.journal_ok = true
	BoatSystem._save_journal()
	var cb_path: String = BoatSystem.JOURNAL_PATH
	var cb_text: String = FileAccess.get_file_as_string(cb_path)
	BoatSystem.record_sail(3.0, 200.0, "mid")
	BoatSystem._on_slot_changed("probe")
	_check(FileAccess.get_file_as_string(cb_path) == cb_text,
		"D5 slot_changed 回调不写盘（journal 文本逐字节不变）")
	_check(not BoatSystem._dirty,
		"D6 回调后脏位已清（下一帧不会补写、回调幂等）")

	# D7 按槽重载复位后 JOURNAL_PATH 回到开局路径：_restore() 正是按开局路径
	# 逐字节还原两份 journal，这条是 D-010 收尾成立的前提。
	_reset_fs()
	BoatSystem._refresh_path()
	_check(BoatSystem.JOURNAL_PATH == _boat_path_at_start,
		"D7 按槽重载复位后 JOURNAL_PATH 回到开局路径（D-010 收尾前提）")


func _run_d010() -> void:
	var src: String = _source_of("res://tests/sailing_journal_probe.gd")
	_check(not _restored and _boat_path_at_start.begins_with("user://")
		and _fish_path_at_start.begins_with("user://"),
		"E1 开局快照已执行：BoatSystem / FishingSystem 两份 JOURNAL_PATH 均已记录")
	_check(src.contains("SaveGuard.restore()") and src.contains("func _exit_tree()")
		and src.contains("FishingSystem.journal_ok = false")
		and src.contains("BoatSystem.journal_ok = false"),
		"E2 收尾含 SaveGuard.restore() + 两个拒写闸 + _exit_tree 安全网")
	# D-010 反向对照：本机基线 boats.json 是 version 1，若退出期无条件写盘，
	# 内存里的 version 2 升级态会覆盖 SaveGuard.restore() 还原好的文件，整段
	# 回归必然 DIFF。这两条把修复钉在进入仓库的探针里（回归脚本本身不入库）。
	var boat_src: String = _source_of("res://scripts/systems/boat_system.gd")
	var guard_src: String = _source_of("res://tests/save_guard.gd")
	_check(boat_src.contains("if _dirty:") and boat_src.contains("func _exit_tree()"),
		"E3 退出期只在标脏时补写：v1 旧档不被内存升级态覆写")
	_check(guard_src.contains("FishingSystem.journal_ok = false")
		and guard_src.contains("BoatSystem.journal_ok = false"),
		"E4 SaveGuard.restore() 统一置两个拒写闸，挡住引擎关停期二次写盘")


# ────────────────────────── 辅助 ──────────────────────────

func _same_sail(a: Dictionary, b: Dictionary) -> bool:
	if absf(float(a.get("total_m", -1.0)) - float(b.get("total_m", -2.0))) > 0.001:
		return false
	if absf(float(a.get("farthest_m", -1.0)) - float(b.get("farthest_m", -2.0))) > 0.001:
		return false
	var ba: Dictionary = a["bands"]
	var bb: Dictionary = b["bands"]
	for key: String in BoatSystem.SAIL_BANDS:
		if int(ba.get(key, -1)) != int(bb.get(key, -2)):
			return false
	var ga: Dictionary = a["badges"]
	var gb: Dictionary = b["badges"]
	return int(ga.get("sail_100", -1)) == int(gb.get("sail_100", -2))


func _source_of(res_path: String) -> String:
	var f: FileAccess = FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return ""
	var text: String = f.get_as_text()
	f.close()
	return text


## 清空档案槽目录并复位 Profile 内存态（照 fishing_collection_probe 的 _reset_fs）。
## Profile.reload() 不 emit slot_changed，调用方必须显式 BoatSystem._refresh_path()。
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
