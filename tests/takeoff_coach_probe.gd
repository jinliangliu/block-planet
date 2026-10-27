extends Node
## 起飞教练 Gap A 回归探针（D-074）：验证离地后 15~40 m 区间不再诱导降落
## （旧文案「慢慢落」会让新手在谷地渐变带威胁区提前下降 → 重演装山），
## 改为「继续爬升到安全高度（40 m）」并持续提醒，直到 ≥40 m 才收起教练区。
##
## 纯逻辑：直接 new TakeoffCoach，bind 一个假机体（仅满足非 null 守卫），
## 喂合成 snapshot 调 step_for，断言返回字典的 text/sub。
##
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/takeoff_coach_probe.tscn

var _failed := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	SaveGuard.snapshot()
	_build_and_check()
	SaveGuard.restore()
	_finish()


## 合成一份「已点火、空中、水平巡航」的快照，按 alt_agl 调整高度读数。
func _air_snap(alt_agl: float) -> Dictionary:
	return {
		"on_ground": false,
		"engine": true,
		"altitude_agl": alt_agl,
		"kmh": 80.0,
		"stall_speed": 13.0,
		"throttle": 1.0,
		"stalled": false,
		"stall_warning": false,
	}


func _coach() -> TakeoffCoach:
	var tc := TakeoffCoach.new()
	tc.bind(FakeCraft.new())
	return tc


func _build_and_check() -> void:
	# ① 离地 20 m（介于 15 与 40 之间）：早庆祝过后应持续「继续爬升」，
	#    绝不返回诱导降落的「慢慢落」。
	var tc := _coach()
	# 先喂一次大 delta 触发「起飞成功」并落定 _success_at。
	var r0 := tc.step_for(_air_snap(20.0), 4.0)
	_check(r0.has("text") and "起飞成功" in r0.get("text", ""),
		"① 首次过 15 m 播「起飞成功」（text=%s）" % r0.get("text", ""))
	# 再喂一次大 delta 越过 SUCCESS_HOLD（3.5 s）→ 进入持续爬升提醒。
	var r1 := tc.step_for(_air_snap(20.0), 4.0)
	_check(r1.has("text") and "继续爬升" in r1.get("text", ""),
		"① 20 m 持续提醒「继续爬升」（text=%s）" % r1.get("text", ""))
	var sub1: String = r1.get("sub", "")
	_check("别急着下降" in sub1, "① sub 提示保持上升（sub=%s）" % sub1)
	_check(sub1.find("慢慢落") == -1,
		"① 绝不诱导降落：sub 不含「慢慢落」（sub=%s）" % sub1)

	# ② 离地 50 m（≥ 安全高度）：早庆祝过后应收起教练区（空字典）。
	var tc2 := _coach()
	tc2.step_for(_air_snap(50.0), 4.0)
	var r2 := tc2.step_for(_air_snap(50.0), 4.0)
	_check(not r2.has("text"),
		"② ≥40 m 收起教练区（返回空字典，text 缺失；实际 keys=%s）" % str(r2.keys()))

	# ③ 回归闸：任何诱导降落的措辞均不可出现（钉死 Gap A 修复）。
	_check(r1.get("sub", "").find("慢慢落") == -1,
		"③ 回归闸：诱导降落的「慢慢落」在任何高度都不可出现")


func _finish() -> void:
	if _failed == 0:
		print("TAKEOFF_COACH_PROBE_OK")
		get_tree().quit(0)
	else:
		print("TAKEOFF_COACH_PROBE_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)


## 假机体：仅满足 TakeoffCoach.bind 的非 null 类型约束；step_for 只用它做
## null 守卫，不调用其任何方法（同 fd_yield_probe 的 FakeCraft 思路）。
class FakeCraft extends Aircraft:
	pass
