extends Node
## 鱼类收集册 + 四大洋集齐奖励（D-087）无头验证。18 条断言，全部可断言。
##
## 覆盖：数据分组（region_id，不用 spot_ids）/ 空档不误发 / 只集齐 3-4 不误发 /
## 奖励幂等 / 换槽隔离（切 B 归零、切回 A 标记恢复为 1）/ record_of() 旧引用
## 反向对照 / UI 现取渲染 / 按钮状态机 / first_caught_spot 转译 / 两个小丑鱼区分 /
## 两处欠账文案 / SaveGuard 不污染存档。
##
## D-010：claim_bundle() 会 _save_journal() 写 user://fishing_journal.json
## （有槽时落在 user://profiles/<id>/），换槽还会经 _on_slot_changed 整体重载
## 内存态。故开局 SaveGuard.snapshot()（含 profiles/ 整树），并单独快照开局
## JOURNAL_PATH 的原文本；收尾按**开局记录的那个路径**逐字节还原（不能按换槽
## 后的动态路径还原），再置 journal_ok = false 关掉 _exit_tree 的补写闸，
## 最后 SaveGuard.restore()。_exit_tree 与看门狗都挂同一份 _restore()。
##
## _inject() 注入 records 只改内存态 journal["records"]（不写盘、不发信号），是纯
## 逻辑；但 claim_bundle() 会 _save_journal() 真实落盘，故断言 8/9 走真实 Profile
## 槽切换链路（Progress.set_slot → Profile.select_slot → slot_changed →
## _on_slot_changed → _refresh_path + _load_journal 整体重载）验证按槽持久化。
## A/B 两槽均为探针新建、收尾由 SaveGuard.restore() 清理，真实存档里有什么都不
## 影响结论。

const CollectionScript := preload("res://scripts/ui/fishing_collection_ui.gd")

var _pass := 0
var _fail := 0
var _restored := false
## 开局 JOURNAL_PATH 的原文本快照与「当时的路径」。换槽后 JOURNAL_PATH 会变，
## 还原必须用这份记录，否则会把 A 槽文本写到 B 槽路径（D-010 违例）。
var _journal_path_at_start := ""
var _journal_text := ""
var _journal_existed := false

## 收集册脚本无 class_name，必须无类型持有（Variant），否则对 _ui.badge_text()
## 这类自定义方法会触发「Cannot find member in base Control」静态错误。
## 与 hud.gd 里 `var _profile_picker = null` 同范式。
var _ui = null


func _check(cond, msg: String) -> void:
	if cond:
		print("PASS: " + msg)
		_pass += 1
	else:
		print("FAIL: " + msg)
		_fail += 1


func _ready() -> void:
	# 看门狗：脚本错误猝杀流程时强制退出，_exit_tree 才能走到 _restore()。
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		push_warning("fishing_collection_probe: 看门狗超时，强制退出")
		get_tree().quit(1))
	SaveGuard.snapshot()
	_journal_path_at_start = FishingSystem.JOURNAL_PATH
	if FileAccess.file_exists(_journal_path_at_start):
		_journal_existed = true
		var jf := FileAccess.open(_journal_path_at_start, FileAccess.READ)
		_journal_text = jf.get_as_text()
		jf.close()
	_run()
	_finish()


func _finish() -> void:
	_restore()
	print("FISHING_COLLECTION_DONE pass=%d fails=%d" % [_pass, _fail])
	if _fail > 0:
		print("FISHING_COLLECTION_PROBE_FAIL")
	else:
		print("FISHING_COLLECTION_PROBE_OK")
	get_tree().quit(0 if _fail == 0 else 1)


## 幂等收尾（正常路径 / _exit_tree 安全网 / 看门狗三条路共用）。
func _restore() -> void:
	if _restored:
		return
	_restored = true
	if _ui != null and is_instance_valid(_ui):
		_ui.queue_free()
	# 先把动态 JOURNAL_PATH 拨回开局路径，再按它逐字节还原。
	FishingSystem.JOURNAL_PATH = _journal_path_at_start
	if _journal_existed:
		var jf := FileAccess.open(_journal_path_at_start, FileAccess.WRITE)
		if jf != null:
			jf.store_string(_journal_text)
			jf.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_journal_path_at_start))
	# 拒写闸：_exit_tree 的 _save_journal() 不得再把探针改乱的日志写回盘。
	FishingSystem.journal_ok = false
	SaveGuard.restore()


func _exit_tree() -> void:
	_restore()


# ────────────────────────── 辅助 ──────────────────────────

## 清成一份确定的空 journal（只动内存，不落盘、不发信号）。
func _reset_journal() -> void:
	FishingSystem.journal = {
		"version": 1, "records": {}, "gear": [], "lessons_seen": [],
		"replay": [], "stats": {},
	}


## 给 fish_id 注入一条「钓到过」的记录（含 first_caught_spot，供转译断言）。
func _inject(fish_id: String, spot_id: String) -> void:
	var records: Dictionary = FishingSystem.journal["records"]
	records[fish_id] = {
		"catch_count": 1,
		"max_weight_kg": 0.42,
		"first_caught_spot": spot_id,
		"first_caught_at": "2026-01-01 00:00:00",
	}
	FishingSystem.journal["records"] = records


func _inject_region(region_id: String) -> void:
	var ids := FishingSystem.bundle_ids(region_id)
	for id in ids:
		_inject(id, "pacific_coast")


# ────────────────────────── 18 条断言 ──────────────────────────

func _run() -> void:
	# ── 1 数据基线：20 种、4 组各 5 ──
	_check(FishingSystem.fish_list.size() == 20,
		"1a fish_list 恰好 20 种鱼")
	var groups_ok := true
	for region_id in FishingSystem.BUNDLE_REGIONS:
		if FishingSystem.bundle_ids(region_id).size() != 5:
			groups_ok = false
	_check(groups_ok and FishingSystem.BUNDLE_REGIONS.size() == 4,
		"1b 按 region_id 恰好 4 个海域、每组 5 种")

	# ── 2 bundle_ids 精确等于 region_id 分组，绝不用 spot_ids 反推 ──
	var pac := FishingSystem.bundle_ids("pacific_ocean")
	var expected_pac: Array[String] = [
		"pacific_clownfish", "pacific_salmon", "great_white_shark",
		"pacific_mackerel", "pacific_marlin",
	]
	_check(pac == expected_pac,
		"2a bundle_ids(pacific_ocean) 精确等于 region_id 分组的 5 个 id")
	# 反证：great_white_shark 在 fish.json 的 spot_ids 声明近岸，但实际只在远海
	# fish_pool——若按 spot_ids 反推会把它算进岸钓组。这里钉住它属于 pacific_ocean。
	_check(pac.has("great_white_shark"),
		"2b 大白鲨归入 pacific_ocean（不受 spot_ids 12 处不一致影响）")

	# ── 3 空 journal：不误发 ──
	_reset_journal()
	var all_false := true
	for region_id in FishingSystem.BUNDLE_REGIONS:
		if FishingSystem.bundle_complete(region_id):
			all_false = false
	_check(all_false and FishingSystem.discovered_count() == 0,
		"3a 空 journal：4 海域 bundle_complete 全 false、discovered_count==0")
	_check(FishingSystem.claim_bundle("pacific_ocean").is_empty() \
		and FishingSystem.claim_bundle("all").is_empty(),
		"3b 空 journal：claim_bundle(单海域/all) 都返回空字典")

	# ── 4 注入 1 组：分组隔离 ──
	_reset_journal()
	_inject_region("pacific_ocean")
	_check(FishingSystem.bundle_complete("pacific_ocean"),
		"4a 注入 5 条 pacific_ocean 记录后该海域 complete==true")
	_check(not FishingSystem.bundle_complete("atlantic_ocean") \
		and not FishingSystem.bundle_complete("indian_ocean") \
		and not FishingSystem.bundle_complete("arctic_ocean"),
		"4b 其余 3 海域仍 false（分组隔离）")

	# ── 5 只集齐 3/4：全收集大奖不误发 ──
	_reset_journal()
	_inject_region("pacific_ocean")
	_inject_region("atlantic_ocean")
	_inject_region("indian_ocean")
	_check(FishingSystem.bundle_complete("arctic_ocean") == false \
		and FishingSystem.all_bundles_complete() == false,
		"5a 只集齐 3/4 海域：all_bundles_complete()==false")
	_check(FishingSystem.claim_bundle("all").is_empty(),
		"5b 只集齐 3/4：claim_bundle(all) 返回空字典（不误发 8 绿宝石大奖）")

	# ── 6 奖励幂等 ──
	_reset_journal()
	_inject_region("pacific_ocean")
	var first := FishingSystem.claim_bundle("pacific_ocean")
	_check(not first.is_empty() and int(first.get("item", -1)) == ItemTypes.EMERALD,
		"6a claim_bundle 首次返回非空且 item==ItemTypes.EMERALD")
	_check(FishingSystem.claim_bundle("pacific_ocean").is_empty(),
		"6b 第二次 claim_bundle 返回空字典（幂等闸门）")
	_check(FishingSystem.stat_of("bundle_pacific_ocean") == 1 \
		and FishingSystem.bundle_claimed("pacific_ocean"),
		"6c stat_of(bundle_pacific_ocean)==1（不累加到 2）、bundle_claimed==true")

	# ── 7 奖励形状 ──
	_check(int(first.get("count", -1)) == FishingSystem.BUNDLE_REWARD_SINGLE \
		and FishingSystem.BUNDLE_REWARD_SINGLE == 3,
		"7a 单海域奖励 count==3")
	_check(String(first.get("title", "")).length() > 0 \
		and not first.has("rod") and not first.has("gear"),
		"7b title 非空、字典不含任何钓具条目")
	# 全收集大奖：集齐 4 组后 count==8
	_reset_journal()
	for region_id in FishingSystem.BUNDLE_REGIONS:
		_inject_region(region_id)
	var all_reward := FishingSystem.claim_bundle("all")
	_check(not all_reward.is_empty() \
		and int(all_reward.get("count", -1)) == FishingSystem.BUNDLE_REWARD_ALL \
		and FishingSystem.BUNDLE_REWARD_ALL == 8,
		"7c 全 4 海域集齐：claim_bundle(all) 返回 count==8")

	# ── 8 换槽：不串档 + 标记自然归零 ──
	# 用真实 Profile 槽切换（emit slot_changed → FishingSystem 整体重载 journal）。
	# SaveGuard.snapshot() 已快照 profiles/ 整树，收尾 restore 会清理新建的槽。
	_reset_fs()
	var id_a := Profile.create_slot("收集册A")
	var id_b := Profile.create_slot("收集册B")
	Progress.set_slot(id_a)
	_reset_journal()
	_inject_region("pacific_ocean")
	FishingSystem.claim_bundle("pacific_ocean")
	_check(FishingSystem.discovered_count() == 5 \
		and FishingSystem.bundle_claimed("pacific_ocean"),
		"8a A 槽：5 条记录、bundle_pacific_ocean 已领取")
	Progress.set_slot(id_b)
	_check(FishingSystem.discovered_count() == 0 \
		and not FishingSystem.bundle_complete("pacific_ocean") \
		and FishingSystem.stat_of("bundle_pacific_ocean") == 0,
		"8b 切到 B 槽：记录/完成度/已领标记全部归零（按槽隔离）")

	# ── 9 切回 A 槽：按槽落盘的标记重载生效且不重复发奖 ──
	Progress.set_slot(id_a)
	_check(FishingSystem.discovered_count() == 5 \
		and FishingSystem.bundle_complete("pacific_ocean"),
		"9a 切回 A 槽：5 条记录恢复")
	# claim_bundle() 内 _save_journal() 已把 stats.bundle_pacific_ocean=1 写进
	# A 槽 JOURNAL_PATH（journal_ok 为 true 时真实落盘）；_on_slot_changed() 整体
	# 重载后该标记随槽恢复，幂等闸门仍生效。这里钉的是「按槽持久化 + 不重发」，
	# 不再假设「只改内存未落盘」，也不只重复查一次记录数。
	_check(FishingSystem.stat_of("bundle_pacific_ocean") == 1 \
		and FishingSystem.bundle_claimed("pacific_ocean") \
		and FishingSystem.claim_bundle("pacific_ocean").is_empty(),
		"9b 切回 A 槽：已领标记随槽恢复为 1，重复 claim 仍返回空字典（不重发）")

	# ── 10 record_of() 新对象反向对照（钉 journal 整体替换语义） ──
	Progress.set_slot(id_a)
	_reset_journal()
	_inject("clownfish", "pacific_coast")
	var stale: Dictionary = FishingSystem.record_of("clownfish")   # A 槽旧引用
	var stale_count := int(stale.get("catch_count", 0))
	# 模拟换槽导致 journal 整体替换（正是 _load_journal():766 做的事）
	FishingSystem.journal = {
		"version": 1, "records": {}, "gear": [], "lessons_seen": [],
		"replay": [], "stats": {},
	}
	_check(int(FishingSystem.record_of("clownfish").get("catch_count", 0)) == 0,
		"10a 整体替换后：新的 record_of() 读不到旧记录（新对象生效）")
	_check(int(stale.get("catch_count", 0)) == stale_count and stale_count == 1,
		"10b 旧引用仍指向 A 槽旧 Dictionary 且内容未变——钉死「缓存会静默失效」")

	# ── 11/12/13/14/15 UI 现取与按钮状态机 ──
	_setup_ui()
	# 现场造一份 A 槽式的 5 条记录（只注入 pacific_ocean 组）。
	_reset_journal()
	_inject_region("pacific_ocean")
	_ui.open()
	_check(_ui.badge_text() == "5 / 20" and _ui.cell_count() == 20,
		"11a 打开收集册：徽标 5 / 20、20 个格子全部建好")
	# 不关闭界面，直接模拟换槽（整体替换 journal）+ refresh()
	FishingSystem.journal = {
		"version": 1, "records": {}, "gear": [], "lessons_seen": [],
		"replay": [], "stats": {},
	}
	_ui.refresh()
	_check(_ui.badge_text() == "0 / 20",
		"11b 不关界面直接换槽 + refresh：徽标 5/20→0/20（若缓存 journal 引用必失败）")
	_check(_ui.cell_dimmed("pacific_clownfish"),
		"11c 换槽后 20 格全部灰化（未解锁态）")
	var all_disabled := true
	for region_id in FishingSystem.BUNDLE_REGIONS:
		if not bool(_ui.claim_state(region_id).get("disabled", false)):
			all_disabled = false
	_check(all_disabled,
		"11d 换槽后 4 个领取按钮全部 disabled")

	# 12 成员无玩家态容器缓存：静态检查源码里的成员声明
	var ui_src := _source_of("res://scripts/ui/fishing_collection_ui.gd")
	_check(not _member_caches_player_data(ui_src),
		"12 UI 成员声明不持有 journal/record 类玩家态容器（静态源码检查）")

	# 13 领奖按钮状态机（未集齐 / 集齐未领 / 已领）
	_reset_journal()
	_ui.refresh()
	var st_unready: Dictionary = _ui.claim_state("pacific_ocean")
	_check(bool(st_unready.get("disabled", false)) \
		and String(st_unready.get("text", "")).contains("还差"),
		"13a 未集齐：disabled 且文案含「还差」")
	_inject_region("pacific_ocean")
	_ui.refresh()
	var st_ready: Dictionary = _ui.claim_state("pacific_ocean")
	_check(not bool(st_ready.get("disabled", true)),
		"13b 集齐未领：按钮可点")
	FishingSystem.claim_bundle("pacific_ocean")
	_ui.refresh()
	var st_claimed: Dictionary = _ui.claim_state("pacific_ocean")
	_check(bool(st_claimed.get("disabled", false)) \
		and String(st_claimed.get("text", "")).contains("已领取"),
		"13c 已领取：disabled 且文案含「已领取」")

	# 14 first_caught_spot 经 get_spot().name_zh 转译，不是裸 id
	_reset_journal()
	_inject("pacific_clownfish", "pacific_coast")
	_ui.refresh()
	var cell: String = _ui.cell_text("pacific_clownfish")
	_check(cell.contains("太平洋近岸") and not cell.contains("pacific_coast"),
		"14 cell 显示转译后的「太平洋近岸」，不含裸 spot_id")

	# 15 两个「小丑鱼」格必须可区分（带海域前缀）
	_reset_journal()
	_inject("pacific_clownfish", "pacific_coast")
	_inject("clownfish", "indian_reef")
	_ui.refresh()
	_check(_ui.cell_text("pacific_clownfish") != _ui.cell_text("clownfish"),
		"15 两个同名小丑鱼格文本不同（海域前缀区分）")

	# ── 16 SaveGuard 不污染存档 ──
	# 走到这里的所有写盘都被 SaveGuard.snapshot() 覆盖；此处钉「收尾函数存在且
	# journal_ok 拒写闸会用上」。真正逐字节校验由回归脚本 diff -r 完成。
	_check(_restored == false and _journal_path_at_start.begins_with("user://"),
		"16a 开局 SaveGuard.snapshot() 已执行、开局 JOURNAL_PATH 已记录")
	_check(_source_of("res://tests/fishing_collection_probe.gd").contains("SaveGuard.restore()") \
		and _source_of("res://tests/fishing_collection_probe.gd").contains("journal_ok = false"),
		"16b 收尾路径含 SaveGuard.restore() + journal_ok 拒写闸（_exit_tree 安全网）")

	# ── 17 模态互斥 ──
	var hud_src := _source_of("res://scripts/ui/hud.gd")
	_check(hud_src.contains("or (_fishing_collection != null and _fishing_collection.is_open())"),
		"17a _any_overlay_open() 已纳入收集册（关闭后鼠标不会被提前收回）")
	# 17b 只认「钓具 ESC 分支之前」这段前缀里存在收集册分支，不依赖全局 find()
	# 命中哪一处：早退链 :343 与 _any_overlay_open() :2930 的表达式是一模一样的，
	# 用 find() 取第一个命中虽当前正确，但一旦日后 _any_overlay_open 上移就会误判。
	var i_gear_branch := hud_src.find("_fishing_gear.close()")
	var head := hud_src.substr(0, i_gear_branch) if i_gear_branch > 0 else ""
	_check(i_gear_branch > 0 \
		and head.contains("_fishing_collection != null and _fishing_collection.is_open()") \
		and head.contains("close_fishing_collection()"),
		"17b 收集册 ESC 分支（含 close_fishing_collection）排在钓具分支之前")
	_check(hud_src.contains("_fishing_gear._close()"),
		"17c 入口走 _close() emit（不叠加模态 + 解冻回调不跳过）")

	# ── 18 两处欠账 ──
	var fi_src := _source_of("res://scripts/ui/fishing_ui.gd")
	_check(fi_src.contains("（用下方按钮调整）") and fi_src.contains("_drag_hint()") \
		and fi_src.count("_drag_hint()") >= 3,
		"18a 触屏卸力文案抽成 _drag_hint()，:450 与 :303 共用（不再被每帧冲掉）")
	_check(not fi_src.contains("已收入生物图鉴") \
		and not hud_src.contains("已收入生物图鉴") \
		and fi_src.contains("已记入鱼类收集册（钓具界面可查看）") \
		and hud_src.contains("已记入鱼类收集册（钓具界面可查看）"),
		"18b 两处解锁文案均改为「已记入鱼类收集册」，静态图鉴空头支票已撤")


# ────────────────────────── 辅助：UI / 源码 / 槽 ──────────────────────────

func _setup_ui() -> void:
	_ui = CollectionScript.new()
	add_child(_ui)


func _source_of(res_path: String) -> String:
	var f := FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


## 静态检查：UI 顶层成员声明里不得把 journal / record 缓存进 Dictionary/Array。
## 只认行首顶格的 `var `（GDScript 类成员声明）；函数体内的局部变量带 Tab 缩进，
## 必须跳过——否则 strip_edges() 会把 _apply_cell() 里现取现用的
## `var r := FishingSystem.record_of(id)` 变成顶格，命中 `= FishingSystem.record_of`
## 子串，导致断言 12 假失败。控件引用表成员（_cells / _group_titles / ...）放行。
func _member_caches_player_data(src: String) -> bool:
	for line in src.split("\n"):
		if line.begins_with("\t") or line.begins_with(" "):
			continue
		if not line.begins_with("var "):
			continue
		if line.contains("= FishingSystem.journal") \
			or line.contains("= FishingSystem.record_of") \
			or line.contains("journal[\"records\"]"):
			return true
	return false


## 清空档案槽目录并复位 Profile 内存态（照 profile_slot_probe._reset_fs）。
func _reset_fs() -> void:
	_remove_dir_tree("user://profiles")
	Profile.reload()


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
