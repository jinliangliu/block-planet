extends Node

## 无头验证钓鱼玩法（FishingSystem Autoload + FishingGear 纯计算，不依赖世界）：
##   A 数据加载自检（钓点/鱼种/钓具/教学四份 JSON、岸边钓点过滤、默认钓具）；
##   B 纯计算（抛投距离公式、水层边界、饵适配度、坠惩罚、装配校验）；
##   C 收线三败局之「没鱼」：饵不对 → 匹配度不足直接判 no_bite，不进等待；
##   D 等咬钩超时：单帧 delta 跨过 2× 总时长（NO_BITE_FACTOR）判没鱼；
##   E 完整钓获：等咬钩 → 咬钩 → 收线 → 结算（单鱼种钓点 + 偏好饵 = 确定性），
##     验重量区间、日志 records/replay/stats、Progress 计数折算；
##   F 断线：大鱼 + 细线 + 卸力最大 → 张力涨满 line_broke；
##   G 跑鱼：卸力全松且不收线 → 逃逸度涨满 fish_escaped；
##   H 放生与教学（reset_lessons 后判 pending/mark，不依赖真实已看记录）；
##   I 状态机边界（坏钓点 / 缺渔轮 / 非等待态 / 非收线态）。
##
## D-010：try_catch 会写 user://fishing_journal.json 并折算 Progress 计数器，
## FishingSystem._exit_tree 还会再补写一次日志——故开局 SaveGuard.snapshot()
## （progress/settings/竞速三件套 + Progress 内存态，退出期 _save 覆盖问题的
## 既有对策），钓鱼日志单独快照原文本；收尾还原文本 + 把 journal_ok 置否
## （_save_journal 的拒写闸，否则退出期把探针改乱的日志再写一遍盘）。
## 断言全部用「基线差分」，真实存档里已有什么都不影响结论。

var _pass := 0
var _fail := 0
## user://fishing_journal.json 原文本快照（空串 = 原文件不存在，还原即删除）。
var _journal_text := ""
var _journal_existed := false
var _restored := false
## fishing_failed 信号累计（各流程共用，读 last / n）。
var fails := {"n": 0, "last": ""}


func _check(cond, msg) -> void:
	if cond:
		print("PASS: " + msg)
		_pass += 1
	else:
		print("FAIL: " + msg)
		_fail += 1


func _ready() -> void:
	# 看门狗：脚本错误猝杀协程时强制退出（否则进程挂起、还原不执行）。
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		push_warning("fishing_probe: 看门狗超时，强制退出")
		get_tree().quit())
	SaveGuard.snapshot()
	if FileAccess.file_exists(FishingSystem.JOURNAL_PATH):
		_journal_existed = true
		var jf := FileAccess.open(FishingSystem.JOURNAL_PATH, FileAccess.READ)
		_journal_text = jf.get_as_text()
		jf.close()
	FishingSystem.fishing_failed.connect(func(reason: String) -> void:
		fails["n"] += 1
		fails["last"] = reason)
	_run()
	_finish()


# ────────────────────────── A 数据加载自检 ──────────────────────────

func _run() -> void:
	_check(FishingSystem.load_problems.is_empty(),
		"四份数据加载无问题（实际 %d 条）" % FishingSystem.load_problems.size())
	_check(FishingSystem.spots.size() == 16, "钓点共 16 个（实际 %d）" % FishingSystem.spots.size())
	_check(FishingSystem.fish_list.size() == 20, "鱼种共 20 种（实际 %d）" % FishingSystem.fish_list.size())
	_check(FishingSystem.gear.problems.is_empty(), "钓具数据无问题")
	_check(FishingSystem.teaching.problems.is_empty(), "教学数据无问题")
	_check(FishingSystem.get_spots_for_atlas(0).size() == 4, "太平洋区域钓点 4 个（1 岸 + 3 出海）")
	var shore_ok := true
	for region in range(4):
		if FishingSystem.get_shore_spots_for_atlas(region).size() != 1:
			shore_ok = false
	_check(shore_ok, "四大洋岸边钓点各 1 个（地图页「去钓鱼」只列这些）")
	_check(not FishingSystem.get_fish("pacific_clownfish").is_empty()
		and FishingSystem.get_fish("no_such_fish").is_empty(), "鱼种查询（存在/不存在）")
	var pool_shallow: Array = FishingSystem.get_fish_pool("pacific_near", "live_shrimp", "shallow")
	var pool_mid: Array = FishingSystem.get_fish_pool("pacific_near", "live_shrimp", "mid")
	_check(pool_shallow.size() == 1 and pool_mid.is_empty(), "候选鱼按水层过滤（浅水 1 条 / 中层 0 条）")
	var default_missing: Array = []
	for gear_id in ["basic_sea_rod", "basic_reel", "nylon_line", "live_shrimp",
			"metal_lure", "sinker_10g", "sinker_30g", "sinker_60g"]:
		if not FishingSystem.owns(gear_id):
			default_missing.append(gear_id)
	_check(default_missing.is_empty(), "8 件默认钓具开局即拥有（缺失：%s）" % str(default_missing))

	# ────────────────────────── B 纯计算（FishingGear） ──────────────────────────
	var s10: Dictionary = FishingSystem.gear.sinker("sinker_10g")
	var s30: Dictionary = FishingSystem.gear.sinker("sinker_30g")
	var s60: Dictionary = FishingSystem.gear.sinker("sinker_60g")
	_check(is_equal_approx(FishingGear.cast_distance(s10, 1.0), 9.0), "10 克坠满力抛 9 m（4 + 1×5×1）")
	_check(is_equal_approx(FishingGear.cast_distance(s10, 0.0), 4.0), "零力度也有 4 m 保底")
	_check(is_equal_approx(FishingGear.cast_distance(s30, 0.5), 11.5), "30 克坠半力抛 11.5 m")
	_check(is_equal_approx(FishingGear.cast_distance(s60, 1.0), 29.0), "60 克坠满力抛 29 m，够深水")
	_check(FishingGear.band_of(9.99) == FishingGear.BAND_SHALLOW
		and FishingGear.band_of(10.0) == FishingGear.BAND_MID, "水层分界 10 m：<10 浅水，10 起中层")
	_check(FishingGear.band_of(19.99) == FishingGear.BAND_MID
		and FishingGear.band_of(20.0) == FishingGear.BAND_DEEP, "水层分界 20 m：<20 中层，20 起深水")
	_check(FishingGear.max_band_of(s10) == FishingGear.BAND_SHALLOW
		and FishingGear.max_band_of(s60) == FishingGear.BAND_DEEP, "坠的满力水层预告")
	var clownfish: Dictionary = FishingSystem.get_fish("pacific_clownfish")
	var shrimp: Dictionary = FishingSystem.gear.bait("live_shrimp")
	var metal: Dictionary = FishingSystem.gear.bait("metal_lure")
	_check(FishingGear.bait_match(shrimp, clownfish) == FishingGear.MATCH_PREFERRED, "活虾是小丑鱼偏好饵（满分）")
	_check(FishingGear.bait_match(metal, clownfish) == FishingGear.MATCH_POOR, "金属饵不对小丑鱼的路（最低档）")
	_check(FishingGear.sinker_factor(s60, FishingGear.BAND_SHALLOW) == FishingGear.SINKER_HEAVY_PENALTY,
		"重坠配浅水 = 掠过中上层（0.5 惩罚）")
	_check(FishingGear.sinker_factor(s10, FishingGear.BAND_DEEP) == FishingGear.SINKER_LIGHT_PENALTY,
		"轻坠配深水 = 够不到（0.35 惩罚）")
	_check(is_equal_approx(FishingGear.sinker_factor(s30, FishingGear.BAND_MID), 1.0), "中坠配中层无惩罚")
	var good_set := {"rod": "basic_sea_rod", "reel": "basic_reel", "line": "nylon_line"}
	_check(FishingSystem.gear.validate(good_set).is_empty(), "默认套装装配通过（竿线配）")
	var no_reel := {"rod": "basic_sea_rod", "line": "nylon_line"}
	_check(FishingSystem.gear.validate(no_reel).size() == 1, "缺渔轮被装配校验拦下")

	# ────────────────────────── C 没鱼（饵不对，匹配度不足） ──────────────────────────
	_check(FishingSystem.start_fishing("pacific_near", good_set), "pacific_near 开钓成功")
	FishingSystem.select_bait("metal_lure")   # 小丑鱼不吃金属饵
	FishingSystem.select_sinker("sinker_10g")
	var dist_nb := FishingSystem.cast_power(1.0)
	_check(is_equal_approx(dist_nb, 9.0), "落点 9 m（浅水）")
	_check(FishingSystem.state == FishingSystem.State.RESULT, "匹配度不足直接结算，不进等待阶段")
	_check(fails["last"] == "no_bite", "发出 no_bite（饵不对就是钓不到）")
	_check(FishingSystem.best_match("pacific_near", "metal_lure", "shallow", "sinker_10g")
		< FishingSystem.BITE_MIN_MATCH, "金属饵匹配度 %.2f 低于门槛" %
		FishingSystem.best_match("pacific_near", "metal_lure", "shallow", "sinker_10g"))
	_check(FishingSystem.best_match("pacific_near", "live_shrimp", "shallow", "sinker_10g")
		>= FishingSystem.BITE_MIN_MATCH, "活虾匹配度过门槛（同点位换饵就能钓）")

	# ────────────────────────── D 等咬钩超时（单帧跨过 2× 总时长） ──────────────────────────
	FishingSystem.start_fishing("pacific_near", good_set)
	FishingSystem.select_bait("live_shrimp")
	FishingSystem.select_sinker("sinker_10g")
	FishingSystem.cast_power(1.0)   # 9 m 浅水、匹配度足 → 等待（总时长 2.75 s）
	var wait_result := FishingSystem.update_wait(0.5)
	_check(wait_result == 0 and FishingSystem.state == FishingSystem.State.WAITING, "等待未满返回 0 且仍在等")
	var wait_over := FishingSystem.update_wait(100.0)   # 一步跨过 2× 总时长
	_check(wait_over == -1 and FishingSystem.state == FishingSystem.State.RESULT,
		"单帧 delta 跨过 2× 总时长判定没鱼（NO_BITE_FACTOR）")
	_check(fails["last"] == "no_bite", "超时同样发 no_bite")

	# ────────────────────────── E 完整钓获（单鱼种钓点 + 偏好饵 = 确定性） ──────────────────────────
	_check(FishingSystem.start_fishing("pacific_near", good_set), "再次开钓（状态机复位）")
	FishingSystem.select_bait("live_shrimp")
	FishingSystem.select_sinker("sinker_10g")
	var dist := FishingSystem.cast_power(1.0)
	_check(is_equal_approx(dist, 9.0) and FishingSystem.state == FishingSystem.State.WAITING, "抛 9 m 进等待")
	var info := FishingSystem.session_info()
	_check(info["distance_m"] == 9.0 and info["band"] == "shallow"
		and info["spot_name_zh"] == "太平洋近海" and info["bait_id"] == "live_shrimp",
		"session_info 上下文（距离/水层/钓点名/饵）")
	wait_result = FishingSystem.update_wait(0.5)
	var wait_guard := 0
	while wait_result == 0 and wait_guard < 50:
		wait_result = FishingSystem.update_wait(0.5)
		wait_guard += 1
	_check(wait_result == 1 and FishingSystem.state == FishingSystem.State.HOOKED,
		"等 2.75 s 后咬钩（%d 次半步长）" % (wait_guard + 1))
	var hooked: Dictionary = FishingSystem.hook_fish()
	_check(hooked.get("id") == "pacific_clownfish", "单鱼种池必中小丑鱼")
	_check(FishingSystem.state == FishingSystem.State.REELING, "咬钩后进收线")
	# 收线前先钉卸力夹取与收线可视状态。
	FishingSystem.set_drag(99.0)
	_check(is_equal_approx(FishingSystem.reel_state()["drag"], 2.0), "卸力上夹到 drag_max（2）")
	FishingSystem.set_drag(-1.0)
	_check(is_equal_approx(FishingSystem.reel_state()["drag"], 0.0), "卸力下夹到 0")
	FishingSystem.set_drag(1.0)   # 恢复默认半档
	var rs: Dictionary = FishingSystem.reel_state()
	_check(is_equal_approx(rs["safe_min"], 0.32) and is_equal_approx(rs["safe_max"], 0.68)
		and rs["fish_id"] == "pacific_clownfish", "收线状态：安全区 0.32~0.68 与鱼种")
	# 小丑鱼拉力 1、尼龙线拉力 2、卸力 1：张力与逃逸都不涨，纯收即上。
	var catches_base := FishingSystem.stat_of("catches")
	var discovered_base := FishingSystem.discovered_count()
	var prog_base: Dictionary = Progress.counters.duplicate()
	var caught := {"id": "", "spot": "", "n": 0}
	FishingSystem.fish_caught.connect(func(fish_id: String, spot_id: String, _gear: Dictionary) -> void:
		caught["id"] = fish_id
		caught["spot"] = spot_id
		caught["n"] += 1)
	var progress := 0.0
	var reel_guard := 0
	while FishingSystem.state == FishingSystem.State.REELING and reel_guard < 600:
		progress = FishingSystem.update_reel(0.1, 1.0)
		reel_guard += 1
	_check(progress >= 1.0, "持续收线进度满（实际 %.2f，%d 帧）" % [progress, reel_guard])
	_check(is_equal_approx(FishingSystem.reel_state()["tension"], 0.0), "小鱼收线张力始终为 0")
	var result := FishingSystem.try_catch()
	_check(not result.is_empty(), "进度满后结算返回钓获")
	_check(result["fish_id"] == "pacific_clownfish" and result["spot_id"] == "pacific_near",
		"结算鱼种与钓点正确")
	_check(result["weight_kg"] >= 0.05 and result["weight_kg"] <= 0.25,
		"重量落在区间 0.05~0.25 kg（实际 %.2f kg）" % result["weight_kg"])
	_check(result["depth"] == "shallow" and result["distance_m"] == 9.0
		and result["spot_name_zh"] == "太平洋近海", "结算带水层/距离/钓点名")
	_check(caught["n"] == 1 and caught["id"] == "pacific_clownfish"
		and caught["spot"] == "pacific_near", "fish_caught 信号（鱼种/钓点/一次）")
	_check(FishingSystem.catch_count("pacific_clownfish") == int(
		FishingSystem.record_of("pacific_clownfish").get("catch_count", 0)),
		"日志 catch_count 自洽")
	_check(FishingSystem.stat_of("catches") == catches_base + 1, "stats.catches +1")
	_check(FishingSystem.discovered_count() >= discovered_base, "图鉴记录不减少")
	var replay: Array = FishingSystem.replay_log()
	var last_two: Array = replay.slice(replay.size() - 2)
	var r0: Dictionary = last_two[0]
	var r1: Dictionary = last_two[1]
	_check(r0["action"] == "cast" and r1["action"] == "catch", "回放日志 cast → catch")
	_check(r1["spot"] == "pacific_near" and r1["player"] == "小方块" and r1["fish_id"] == "pacific_clownfish",
		"回放 catch 条目字段（钓点/玩家/鱼种）")
	_check(Progress.counters.get("fish_caught", 0) == int(prog_base.get("fish_caught", 0)) + 1,
		"Progress.fish_caught +1（任务计数器折算）")
	_check(Progress.counters.get("fished_region_0", 0) == int(prog_base.get("fished_region_0", 0)) + 1,
		"Progress.fished_region_0 +1")
	_check(Progress.counters.get("fish_rare", 0) == int(prog_base.get("fish_rare", 0))
		and Progress.counters.get("fish_deep", 0) == int(prog_base.get("fish_deep", 0)),
		"常见浅水种不记 fish_rare / fish_deep")

	# ────────────────────────── F 断线（大鱼 + 细线 + 卸力最大） ──────────────────────────
	# heavy_reel 是任务锁装备（quest:q_fish_five）：探针直接发放测机制，不验解锁流。
	# 选它是因为 drag_max=5 时逃逸速率归零——断线必然先于跑鱼，结论确定性。
	_check(not FishingSystem.grant_gear("heavy_reel") or FishingSystem.owns("heavy_reel"),
		"grant_gear 发放重型鼓轮")
	_check(not FishingSystem.grant_gear("heavy_reel"), "重复发放返回 false")
	var big_set := {"rod": "basic_sea_rod", "reel": "heavy_reel", "line": "nylon_line"}
	var escapes_base := FishingSystem.stat_of("escapes")
	_check(FishingSystem.start_fishing("pacific_far", big_set), "pacific_far（深水大鱼池）开钓")
	FishingSystem.select_bait("metal_lure")   # 大白鲨/枪鱼都偏好金属饵
	FishingSystem.select_sinker("sinker_60g")
	var dist_far := FishingSystem.cast_power(1.0)
	_check(is_equal_approx(dist_far, 29.0) and FishingSystem.state == FishingSystem.State.WAITING,
		"抛 29 m 进深水等待")
	wait_result = FishingSystem.update_wait(0.5)
	wait_guard = 0
	while wait_result == 0 and wait_guard < 50:
		wait_result = FishingSystem.update_wait(0.5)
		wait_guard += 1
	_check(wait_result == 1 and FishingSystem.state == FishingSystem.State.HOOKED, "大鱼咬钩")
	var big: Dictionary = FishingSystem.hook_fish()
	_check(int(big.get("fight_power", 0)) >= 8, "上钩的是大鱼（拉力 %d ≥ 8）" % int(big.get("fight_power", 0)))
	FishingSystem.set_drag(5.0)   # 卸力最大：逃逸归零、张力飙升 → 必断
	reel_guard = 0
	while FishingSystem.state == FishingSystem.State.REELING and reel_guard < 600:
		progress = FishingSystem.update_reel(0.1, 1.0)
		reel_guard += 1
	_check(FishingSystem.state == FishingSystem.State.RESULT and fails["last"] == "line_broke",
		"卸力最大 + 细线硬收 → 断线（line_broke）")
	_check(FishingSystem.reel_state()["tension"] >= 1.0, "断线时张力已涨满")
	_check(FishingSystem.stat_of("escapes") == escapes_base + 1, "stats.escapes +1（断线计入）")
	var replay_f: Array = FishingSystem.replay_log()
	var rf: Dictionary = replay_f[replay_f.size() - 1]
	_check(rf["action"] == "break", "回放日志记 break")

	# ────────────────────────── G 跑鱼（卸力全松且不收线） ──────────────────────────
	_check(FishingSystem.start_fishing("pacific_far", big_set), "再次开钓（状态机复位）")
	FishingSystem.select_bait("metal_lure")
	FishingSystem.select_sinker("sinker_60g")
	FishingSystem.cast_power(1.0)
	wait_result = FishingSystem.update_wait(0.5)
	wait_guard = 0
	while wait_result == 0 and wait_guard < 50:
		wait_result = FishingSystem.update_wait(0.5)
		wait_guard += 1
	FishingSystem.hook_fish()
	FishingSystem.set_drag(0.0)   # 卸力全松：逃逸速率 = 拉力 × 0.04，张力和进度都不涨
	reel_guard = 0
	while FishingSystem.state == FishingSystem.State.REELING and reel_guard < 600:
		progress = FishingSystem.update_reel(0.1, 0.0)
		reel_guard += 1
	_check(FishingSystem.state == FishingSystem.State.RESULT and fails["last"] == "fish_escaped",
		"卸力全松 + 不放线 → 跑鱼（fish_escaped）")
	_check(FishingSystem.reel_state()["escape"] >= 1.0, "跑鱼时逃逸度涨满")
	_check(is_equal_approx(FishingSystem.reel_state()["progress"], 0.0), "松放线进度不涨")
	_check(FishingSystem.stat_of("escapes") == escapes_base + 2, "stats.escapes 累计 +2")
	var replay_g: Array = FishingSystem.replay_log()
	var rg: Dictionary = replay_g[replay_g.size() - 1]
	_check(rg["action"] == "escape", "回放日志记 escape")

	# ────────────────────────── H 放生与教学 ──────────────────────────
	var released_base := int(FishingSystem.record_of("pacific_clownfish").get("released", 0))
	FishingSystem.release_fish("pacific_clownfish")
	_check(int(FishingSystem.record_of("pacific_clownfish").get("released", 0)) == released_base + 1,
		"放生计数 +1")
	_check(FishingSystem.record_of("pacific_clownfish").get("catch_count", 0) != 0,
		"放生不删图鉴钓获记录")
	var replay_h: Array = FishingSystem.replay_log()
	var rh: Dictionary = replay_h[replay_h.size() - 1]
	_check(rh["action"] == "release", "回放日志记 release")
	# 教学：先清空已看记录（journal 还原兜底），再验 pending/mark 幂等。
	FishingSystem.reset_lessons()
	var lesson: Dictionary = FishingSystem.pending_lesson("first_time_cast")
	_check(not lesson.is_empty() and lesson.get("id") == "lesson_cast", "清空后首课可弹（lesson_cast）")
	FishingSystem.mark_lesson_seen("lesson_cast")
	_check(FishingSystem.has_seen_lesson("lesson_cast"), "标记看过生效")
	_check(FishingSystem.pending_lesson("first_time_cast").is_empty(), "看过的课不再弹")

	# ────────────────────────── I 状态机边界 ──────────────────────────
	_check(not FishingSystem.start_fishing("no_such_spot", good_set), "不存在的钓点开钓失败")
	_check(fails["last"] == "spot_missing", "spot_missing 原因")
	_check(not FishingSystem.start_fishing("pacific_near", no_reel), "缺渔轮的装配开钓被拦")
	_check(fails["last"] == "还没选渔轮", "装配问题原文透传")
	FishingSystem.start_fishing("pacific_near", good_set)
	FishingSystem.select_bait("live_shrimp")
	FishingSystem.select_sinker("sinker_10g")
	FishingSystem.cast_power(1.0)
	FishingSystem.end_session()
	_check(FishingSystem.state == FishingSystem.State.IDLE, "收工回待机")
	_check(FishingSystem.update_wait(0.1) == 0, "非等待态 update_wait 返回 0")
	_check(is_equal_approx(FishingSystem.update_reel(0.1, 1.0), 0.0), "非收线态 update_reel 返回原进度")
	_check(FishingSystem.try_catch().is_empty(), "进度未满 try_catch 返回空")


## 收尾：还原钓鱼日志文本（不存在则删除）+ 关掉 _exit_tree 的补写闸，
## 再走 SaveGuard.restore()（progress/settings/竞速三件套 + Progress 内存态）。
func _finish() -> void:
	_restore_fishing()
	print("FISHING_DONE fails=%d" % _fail)
	if _fail > 0:
		print("FISHING_PROBE_FAIL")
	else:
		print("FISHING_PROBE_OK")
	get_tree().quit(0 if _fail == 0 else 1)


## 还原 user://fishing_journal.json（幂等；正常路径与 _exit_tree 安全网都走它）。
## journal_ok 置否 = 启用 _save_journal 的拒写闸：退出期 FishingSystem._exit_tree
## 再也不会把探针改乱的日志写回盘。
func _restore_fishing() -> void:
	if _restored:
		return
	_restored = true
	if _journal_existed:
		var jf := FileAccess.open(FishingSystem.JOURNAL_PATH, FileAccess.WRITE)
		jf.store_string(_journal_text)
		jf.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(FishingSystem.JOURNAL_PATH))
	FishingSystem.journal_ok = false
	SaveGuard.restore()


func _exit_tree() -> void:
	_restore_fishing()
