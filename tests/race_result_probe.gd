extends Node
## P0-1 竞速结算屏留存闭环探针（无头，纯逻辑 + 纯 UI）。
##
## 不实例化 main.tscn；不新增 user:// 文件；走 SaveGuard 快照/还原保证 D-010 零 DIFF
## （submit_result() 会写既有 race_records.json，已被 EXTRA_FILES / profiles 快照覆盖）。
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/race_result_probe.tscn

const TOKEN_UNLOCK := "race_result_probe|unlock"
const TOKEN_IDEMPOTENT := "race_result_probe|idempotent"

var _failed := 0
var _passed := 0
var _restored := false
var _race_events: Array = []
var _ui: RaceResultUI = null
var _records_path_at_start := ""


func _ready() -> void:
	await _run()


func _run() -> void:
	SaveGuard.snapshot()
	_records_path_at_start = RaceSystem.RECORDS_PATH
	Events.race_finished.connect(_on_race_finished)
	# 让 Autoload 完成首帧暖机；也令 _run() 成为真正协程，_ready() 的 await 不冗余。
	await get_tree().process_frame

	_test_unlock_diff_and_view()
	_test_legacy_fallback()
	_test_all_unlocked_and_leaderboard()
	_test_data_idempotency()
	_test_ui_and_idempotency()

	Events.race_finished.disconnect(_on_race_finished)
	_finish()


func _finish() -> void:
	SaveGuard.restore()
	_restored = true
	print("RACE_RESULT_TEST_DONE pass=%d fails=%d" % [_passed, _failed])
	if _failed == 0:
		print("RACE_RESULT_TEST_OK")
		get_tree().quit(0)
	else:
		print("RACE_RESULT_TEST_FAILED count=%d" % _failed)
		get_tree().quit(1)


## D-010 安全网：脚本错误 / 看门狗猝杀流程时，_exit_tree 兜底还原。
func _exit_tree() -> void:
	if not _restored:
		_restored = true
		SaveGuard.restore()


## 直接改 RaceSystem._records 的引用（不落盘），给每组用例一个确定的初始态。
func _seed(tracks: Dictionary) -> void:
	var store := RaceSystem.records()
	store.clear()
	store["version"] = 1
	store["tracks"] = tracks


# ── ③ ④ ⑤ ⑥ ②：解锁差集 / 文案保护 / 原 4 键 / 结算视图 ──
func _test_unlock_diff_and_view() -> void:
	_seed({"desert_ring": {"wins": 2, "total_races": 2, "best_lap_time": 30.0}})
	_check(RaceSystem.unlock_progress_text("wins:3") == "还差 1 场",
		"③ 2 胜时 unlock_progress_text('wins:3') == '还差 1 场'")
	_check(RaceSystem.unlock_hint("wins:1") == "赢 1 场后解锁"
		and RaceSystem.unlock_hint("default") == "已解锁",
		"④ unlock_hint() 逐字节不变（racing_probe 基线）")

	_race_events.clear()
	var outcome := RaceSystem.submit_result("city_circuit", "tricycle", 1,
		42.0, 130.0, true, 3, TOKEN_UNLOCK)
	_check(outcome.has("broke_lap") and outcome.has("broke_race")
		and outcome.has("entry") and outcome.has("first_race"),
		"⑥ submit_result() 保留原 4 键")
	var raw_unlocked: Variant = outcome.get("unlocked_now", [])
	var unlocked: Array = []
	if raw_unlocked is Array:
		unlocked = raw_unlocked as Array
	_check(unlocked.size() == 1 and String(unlocked[0]) == "mountain_road",
		"⑤ 2 胜→夺冠恰好新解锁 mountain_road，不含 wins:1/2 已解锁项")
	_check(_race_events.size() == 1, "⑤b 本场 Events.race_finished 广播一次")
	_check(RaceSystem.unlock_progress_text("wins:3") == "已解锁",
		"③b 3 胜后 unlock_progress_text('wins:3') == '已解锁'")

	var view := RaceSystem.build_result_view("city_circuit", outcome)
	_check(int(view["races_total"]) >= 1 and int(view["unlocked_count"]) >= 4
		and int(view["track_count"]) == 9,
		"② view 含参与场次 / 解锁数 / 9 条赛道")
	var goal: Dictionary = view["next_goal"]
	_check(not goal.is_empty() and int(goal["remaining"]) == 1,
		"②b 下一目标 remaining == 1（canyon_hairpin wins:4）")


# ── ⑦：旧存档缺字段兜底 ──
func _test_legacy_fallback() -> void:
	_seed({"desert_ring": {"total_races": 2}})
	var entry := RaceSystem.entry_of("desert_ring")
	_check(entry.size() == 9 and float(entry["best_lap_time"]) == 0.0,
		"⑦ 旧存档缺字段由 entry_of() 补齐 9 字段")
	var view := RaceSystem.build_result_view("desert_ring", {})
	_check(String(view["best_lap_text"]) == "--:--.--",
		"⑦b 缺圈速显示 --:--.-- 且不抛异常")
	var raw_unlocked: Variant = view.get("unlocked_now", [])
	_check(raw_unlocked is Array and (raw_unlocked as Array).is_empty(),
		"⑦c 空 outcome 时 unlocked_now 为空数组")


# ── ⑧ ⑭：全部解锁 / 圈速榜排序与截断 ──
func _test_all_unlocked_and_leaderboard() -> void:
	_seed({
		"desert_ring": {"wins": 9, "total_races": 9, "best_lap_time": 30.0},
		"city_circuit": {"wins": 0, "total_races": 2, "best_lap_time": 25.0},
		"forest_trail": {"wins": 0, "total_races": 1, "best_lap_time": 40.0},
		"wetland_cross": {"wins": 0, "total_races": 1, "best_lap_time": 20.0},
		"mountain_road": {"wins": 0, "total_races": 0, "best_lap_time": 10.0},
	})
	var view := RaceSystem.build_result_view("desert_ring", {})
	var goal: Dictionary = view["next_goal"]
	_check(goal.is_empty() and bool(view["all_unlocked"]),
		"⑧ 全部解锁时 next_goal == {} 且 all_unlocked == true")
	var raw_board: Variant = view.get("leaderboard", [])
	var board: Array = []
	if raw_board is Array:
		board = raw_board as Array
	_check(board.size() == 3,
		"⑭ 圈速榜最多 3 行，且排除 total_races==0 的赛道")
	var lap_texts := PackedStringArray()
	for item: Variant in board:
		if item is Dictionary:
			lap_texts.append(String((item as Dictionary).get("best_lap_text", "")))
	_check(lap_texts.size() == 3 and lap_texts[0] == "00:20.00"
		and lap_texts[1] == "00:25.00" and lap_texts[2] == "00:30.00",
		"⑭b 圈速榜按最快圈速升序 20 < 25 < 30")


# ── ⑩：数据层结算幂等（同一 race_token 不重复写盘 / 不重复广播）──
func _test_data_idempotency() -> void:
	_seed({"desert_ring": {"wins": 1, "total_races": 1, "best_lap_time": 30.0}})
	_race_events.clear()
	var before_races := int(RaceSystem.entry_of("city_circuit")["total_races"])
	var first := RaceSystem.submit_result("city_circuit", "tricycle", 4,
		45.0, 140.0, false, 3, TOKEN_IDEMPOTENT)
	var second := RaceSystem.submit_result("city_circuit", "tricycle", 4,
		45.0, 140.0, false, 3, TOKEN_IDEMPOTENT)
	_check(int(RaceSystem.entry_of("city_circuit")["total_races"]) == before_races + 1,
		"⑩ 同一 race_token 两次提交 total_races 只 +1")
	_check(_race_events.size() == 1,
		"⑩b 同一 race_token 两次提交 Events.race_finished 只广播一次")
	var first_raw: Variant = first.get("unlocked_now", [])
	var second_raw: Variant = second.get("unlocked_now", [])
	_check(first_raw is Array and second_raw is Array
		and (first_raw as Array).size() == (second_raw as Array).size(),
		"⑩c 两次返回值的 unlocked_now 一致（缓存生效）")


# ── ① ② ⑨ ⑪ ⑬ ⑭ ⑮：结算屏渲染 / 幂等 / 三按钮 / 无第四 CanvasLayer ──
func _test_ui_and_idempotency() -> void:
	_seed({"desert_ring": {"wins": 1, "total_races": 1, "best_lap_time": 30.0}})
	Progress.counters["race_finished_any"] = 1
	_ui = RaceResultUI.new()
	add_child(_ui)

	var track_def := {"id": "desert_ring", "name_zh": "沙丘环线"}
	var rows_lose: Array[Dictionary] = []
	var rows_win: Array[Dictionary] = []
	for i in range(4):
		var base := {
			"rank": i + 1,
			"display": "玩家" if i == 3 else "机器人%d" % (i + 1),
			"best_lap": 30.0 + float(i),
			"finish_time": 100.0 + float(i) * 10.0,
		}
		var lose := base.duplicate()
		lose["is_player"] = i == 3
		rows_lose.append(lose)
		var win := base.duplicate()
		win["is_player"] = i == 0
		rows_win.append(win)

	# ① 第 4 名也有收获，且文案无惩罚性字眼
	_ui.show_results(rows_lose, track_def, {})
	var lose_text := "\n".join(_all_labels(_ui))
	_check(lose_text.contains("🎁 完成第 1 场比赛"),
		"① 第 4 名也有参与奖文案")
	_check(not lose_text.contains("失败") and not lose_text.contains("输")
		and not lose_text.contains("淘汰"),
		"①b 输局文案不含「失败 / 输 / 淘汰」")

	# ⑨ UI 幂等：重复 show_results() 不叠加行、不计数、不广播
	var before_events := _race_events.size()
	var before_counter := int(Progress.counters.get("race_finished_any", 0))
	var n1 := _ui._body.get_child_count()
	_ui.show_results(rows_lose, track_def, {})
	var n2 := _ui._body.get_child_count()
	_check(n1 == n2 and n1 > 0, "⑨ 重复 show_results() 子节点数不变（%d）" % n1)
	_check(int(Progress.counters.get("race_finished_any", 0)) == before_counter
		and _race_events.size() == before_events,
		"⑨b 重复 show_results() 不发计数 / 不广播")

	# ② 第 1 名同样有五元素
	_ui.show_results(rows_win, track_def, {})
	var win_text := "\n".join(_all_labels(_ui))
	_check(lose_text.contains("🔓 已解锁") and win_text.contains("🎁 完成第 1 场比赛")
		and win_text.contains("🔓 已解锁"),
		"② 第 1 名与第 4 名都有参与奖 / 解锁进度")

	# ⑪ 破纪录行仍由 outcome 三个布尔位控制
	_ui.show_results(rows_lose, track_def,
		{"broke_lap": true, "broke_race": false, "first_race": false})
	_check("\n".join(_all_labels(_ui)).contains("⚡ 打破最快圈速记录！"),
		"⑪ broke_lap 为真时显示破圈速纪录文案")
	_ui.show_results(rows_lose, track_def, {})
	_check(not "\n".join(_all_labels(_ui)).contains("⚡ 打破最快圈速记录！"),
		"⑪b 未破纪录时不显示该文案")

	# ⑬ 三个按钮 + 没有第四个 CanvasLayer
	var nodes: Array = []
	_collect_nodes(_ui, nodes)
	var buttons := 0
	var canvas_layers := 0
	var size_ok := true
	var focus_ok := true
	var board_btn: Button = null
	for n: Variant in nodes:
		if n is Button:
			buttons += 1
			var b := n as Button
			if b.custom_minimum_size.x < 140.0 or b.custom_minimum_size.y < 44.0:
				size_ok = false
			if b.focus_mode != Control.FOCUS_NONE:
				focus_ok = false
			if String(b.text).contains("最快圈速"):
				board_btn = b
		if n is CanvasLayer:
			canvas_layers += 1
	_check(buttons == 3 and size_ok and focus_ok,
		"⑬ 三个按钮（%d）尺寸 ≥140×44 且 focus_mode=NONE" % buttons)
	_check(canvas_layers == 0,
		"⑬b RaceResultUI 子节点里 CanvasLayer 数量 == 0（单层模态栈）")

	# ⑤ 圈速榜入口：屏内 toggle，不新建模态
	_check(board_btn != null, "⑤ 最快圈速榜按钮存在")
	if board_btn != null:
		board_btn.pressed.emit()
		var open_text := "\n".join(_all_labels(_ui))
		_check(open_text.contains("00:30.00") or open_text.contains("还没有圈速记录"),
			"⑤b 点击后在同一 _body 内展开圈速榜")
		var nodes_after: Array = []
		_collect_nodes(_ui, nodes_after)
		var layers_after := 0
		for n2node: Variant in nodes_after:
			if n2node is CanvasLayer:
				layers_after += 1
		_check(layers_after == 0, "⑤c 展开后仍无新增 CanvasLayer")

	# ⑮ 未新增 user:// 文件；写盘路径仍在 SaveGuard 覆盖范围内
	var path_now := RaceSystem.RECORDS_PATH
	var covered := SaveGuard.EXTRA_FILES.has(path_now) \
		or String(path_now).begins_with("user://profiles/")
	_check(path_now == _records_path_at_start and covered,
		"⑮ RECORDS_PATH 未变且被 SaveGuard 覆盖（D-010 零 DIFF）")


# ── 辅助 ──
func _collect_nodes(root: Node, out: Array) -> void:
	for child in root.get_children():
		out.append(child)
		_collect_nodes(child, out)


func _all_labels(root: Node) -> PackedStringArray:
	var out := PackedStringArray()
	var nodes: Array = []
	_collect_nodes(root, nodes)
	for n: Variant in nodes:
		if n is Label:
			out.append((n as Label).text)
	return out


func _on_race_finished(_track_id: String, _vehicle_id: String, _rank: int, _laps: int,
		_best_lap: float, _total_time: float, _clean: bool) -> void:
	_race_events.append({})


func _check(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
