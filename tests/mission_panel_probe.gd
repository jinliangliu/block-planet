extends Node

## 无头验证 MissionPanel 的界面逻辑与任务闭环（不依赖世界/地形）：
## 开/关、三任务卡、开始→喂遥测→成功→奖励信号、失败后喂帧安全、放弃、
## 奖励防刷（P2-9：二次完成零奖励 + 卡片已领取标注）、关闭信号。
## 注意 GDScript 4.6 闭包捕获变量重赋值不向外传递——结果用共享字典持有。

const DT := 0.1

var _pass := 0
var _fail := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("PASS: " + msg)
	else:
		_fail += 1
		print("FAIL: " + msg)


## 递归收集子树内全部 Label / Button 文案（任务卡断言用：防刷标注与按钮态）。
func _collect_texts(node: Node, out: Array[String]) -> void:
	for child in node.get_children():
		if child is Label:
			out.append((child as Label).text)
		elif child is Button:
			out.append((child as Button).text)
		_collect_texts(child, out)


func _ready() -> void:
	GameState.needs_region_pick = false
	var panel := MissionPanel.new()
	add_child(panel)
	await get_tree().process_frame

	# 初始隐藏 + 三任务预设。
	_check(not panel.is_open(), "面板初始隐藏")
	_check(panel._missions.size() == 3, "载入 MVP 三任务（实际 %d）" % panel._missions.size())

	# 打开后可见。
	panel.open()
	_check(panel.is_open(), "open() 后面板可见")
	_check(not panel.is_running(), "打开时无任务进行中")

	# 开始起飞任务 → 喂合格遥测 → 成功 + 奖励信号（共享字典接收）。
	var box := {"reward": -1, "success": false, "count": 0}
	panel.mission_reward.connect(func(emeralds: int, success: bool, _r: Dictionary):
		box["reward"] = emeralds
		box["success"] = success
		box["count"] += 1)
	panel.start_mission(0)
	_check(panel.is_running(), "开始任务后进入 RUNNING")
	panel.feed(DT, {
		"altitude_agl": 40.0, "speed": 50.0, "position": Vector3.ZERO,
		"on_ground": false, "vertical_speed": 1.0, "wrecked": false,
	})
	_check(not panel.is_running(), "达标遥测后任务结束")
	_check(box["success"] == true and box["reward"] == 5,
		"起飞成功发放奖励 5 绿宝石（收到 %s）" % str(box["reward"]))
	_check(box["count"] == 1, "奖励信号只发一次（实际 %d）" % box["count"])
	_check(panel._result_label.text.contains("任务成功"),
		"结果行显示任务成功（「%s」）" % panel._result_label.text)

	# 结束后继续喂帧：应安全忽略、状态不再变。
	panel.feed(DT, {
		"altitude_agl": 5.0, "speed": 0.0, "position": Vector3.ZERO,
		"on_ground": true, "vertical_speed": 0.0, "wrecked": false,
	})
	_check(not panel.is_running(), "任务结束后喂帧被安全忽略")

	# 绕点任务 → 放弃 → 失败且原因正确。
	var fail_box := {"reason": ""}
	panel._mm.mission_result.connect(func(_s: bool, r: Dictionary):
		fail_box["reason"] = String(r.get("reason", "")))
	panel.start_mission(1)
	_check(panel.is_running(), "绕点任务开始")
	panel.feed(DT, {
		"altitude_agl": 50.0, "speed": 80.0, "position": Vector3(0, 0, 150),
		"on_ground": false, "vertical_speed": 0.0, "wrecked": false,
	})
	panel.abandon_mission()
	_check(not panel.is_running(), "放弃后任务结束")
	_check(fail_box["reason"] == "主动放弃", "放弃原因为「主动放弃」（实际「%s」）" % fail_box["reason"])

	# 防刷（P2-9）：二次完成同一任务——仍成功、奖励归零、结果行注明、卡片标注已领取。
	var anti_box := {"reward": -1, "count": 0, "repeat": true}
	panel.mission_reward.connect(func(emeralds: int, _s: bool, r: Dictionary):
		anti_box["reward"] = emeralds
		anti_box["count"] += 1
		anti_box["repeat"] = bool(r.get("repeat", false)))
	panel.start_mission(0)
	_check(panel.is_running(), "防刷：已完成的任务可再次开始")
	panel.feed(DT, {
		"altitude_agl": 40.0, "speed": 50.0, "position": Vector3.ZERO,
		"on_ground": false, "vertical_speed": 1.0, "wrecked": false,
	})
	_check(not panel.is_running(), "防刷：二次达标后任务结束")
	_check(anti_box["count"] == 1 and anti_box["reward"] == 0 and anti_box["repeat"],
		"防刷：二次完成奖励归零且带 repeat 标记（reward=%s）" % str(anti_box["reward"]))
	_check(panel._result_label.text.contains("不再发放"),
		"防刷：结果行注明本次不再发放（「%s」）" % panel._result_label.text)

	# 任务卡：已领取标注 + 按钮变「再次挑战」；未完成任务仍显示原奖励。
	var texts: Array[String] = []
	_collect_texts(panel._content, texts)
	var claimed_shown := false
	var replay_shown := false
	var other_reward_shown := false
	for t in texts:
		if t.contains("奖励：已领取"):
			claimed_shown = true
		if t.contains("再次挑战"):
			replay_shown = true
		if t.contains("奖励：绿宝石 ×5"):
			other_reward_shown = true
	_check(claimed_shown, "防刷：已完成任务卡标注「奖励：已领取」")
	_check(replay_shown, "防刷：已完成任务按钮变「再次挑战（无奖励）」")
	_check(other_reward_shown, "防刷：未完成任务卡仍显示「奖励：绿宝石 ×5」")

	# 关闭：隐藏 + closed 信号。
	var closed_box := {"n": 0}
	panel.closed.connect(func(): closed_box["n"] += 1)
	panel.close()
	_check(not panel.is_open(), "close() 后面板隐藏")
	_check(closed_box["n"] == 1, "close() 发出 closed 信号")

	print("MISSION_PANEL_DONE fails=%d" % _fail)
	if _fail > 0:
		print("MISSION_PANEL_FAIL")
	else:
		print("MISSION_PANEL_OK")
	get_tree().quit()
