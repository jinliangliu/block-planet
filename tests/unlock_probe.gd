extends Node

## 无头验证 PartUnlocks 的绿宝石解锁逻辑（纯逻辑，不依赖世界/库存 UI）。
## 覆盖：默认套件零件开局解锁、进阶零件锁定、余额不足购买失败、奖励并入余额后
## 购买成功并扣费、已解锁再购免费。

var _pass := 0
var _fail := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("PASS: " + msg)
	else:
		_fail += 1
		print("FAIL: " + msg)


func _ready() -> void:
	GameState.needs_region_pick = false
	_run_unlock_checks()
	print("UNLOCK_PROBE_DONE fails=%d" % _fail)
	if _fail > 0:
		print("UNLOCK_PROBE_FAIL")
		get_tree().quit(1)
	else:
		print("UNLOCK_PROBE_OK")
		get_tree().quit(0)


func _run_unlock_checks() -> void:
	var u := PartUnlocks.new()

	# 默认套件零件开局即解锁。
	for p in PartRegistry.default_loadout():
		_check(u.is_unlocked(p.data.id),
			"默认套件零件「%s」开局解锁" % p.data.id)
		_check(u.cost_of(p.data.id) == 0,
			"默认套件零件「%s」解锁价为 0" % p.data.id)

	# 进阶零件初始锁定，且有正解锁价。
	_check(not u.is_unlocked("turbine"), "涡轮发动机初始锁定")
	_check(u.cost_of("turbine") == 30, "涡轮发动机解锁价 30 绿宝石")
	_check(not u.is_unlocked("long_wing"), "长航程机翼初始锁定")
	_check(u.cost_of("long_wing") == 20, "长航程机翼解锁价 20 绿宝石")

	# 余额不足：一次任务奖励(5)不足以买涡轮(30)。
	var balance := PartUnlocks.reward_to_balance(0, 5)
	var r1 := u.purchase("turbine", balance)
	_check(not r1["ok"], "余额 5 不足以解锁涡轮(30) → 失败")
	_check(int(r1["remaining"]) == 5, "购买失败余额不变（仍为 5）")
	_check(not u.is_unlocked("turbine"), "购买失败后涡轮仍锁定")

	# 攒够绿宝石：再领两笔奖励（30 + 30）后余额 65。
	balance = PartUnlocks.reward_to_balance(balance, 30)
	balance = PartUnlocks.reward_to_balance(balance, 30)
	_check(balance == 65, "累计奖励后余额 65 绿宝石")

	# 购买涡轮：成功、扣 30、剩 35、解锁。
	var r2 := u.purchase("turbine", balance)
	_check(r2["ok"], "余额充足解锁涡轮成功")
	_check(int(r2["spent"]) == 30, "解锁涡轮扣 30 绿宝石")
	_check(int(r2["remaining"]) == 35, "解锁涡轮后余额剩 35")
	balance = int(r2["remaining"])
	_check(u.is_unlocked("turbine"), "涡轮现已解锁")
	_check(u.cost_of("turbine") == 0, "涡轮解锁后价变 0")

	# 再购涡轮：已解锁视为免费。
	var r3 := u.purchase("turbine", balance)
	_check(r3["ok"] and int(r3["spent"]) == 0, "已解锁零件再购免费")

	# 买长航程机翼(20)：余额 35 足够 → 成功、剩 15。
	var r4 := u.purchase("long_wing", balance)
	_check(r4["ok"] and int(r4["spent"]) == 20 and int(r4["remaining"]) == 15,
		"解锁长航程机翼(20)，余额 35→15")
	_check(u.is_unlocked("long_wing"), "长航程机翼现已解锁")

	# 未知零件购买：安全失败。
	var r5 := u.purchase("nonexistent", 99)
	_check(not r5["ok"] and r5["reason"] == "unknown_part",
		"未知零件购买安全失败")
