class_name PartUnlocks
extends RefCounted

## 零件解锁状态（MVP 绿宝石经济）。
##
## 设计（D-032 Phase 3c）：货币复用绿宝石（ItemTypes.EMERALD = 204），不建平行经济。
## 默认套件（PartRegistry.default_loadout）的零件开局即解锁；其余零件需花绿宝石解锁。
## 余额由调用方持有（真实游戏里是玩家绿宝石库存计数），本类只管「解锁集合」与
## 「扣费判定」——这样它保持纯逻辑、易于无头探针验证，也能直接接到库存 API 上。
##
## 解锁后该零件即可在建造编辑器（Phase 2 数据层）的零件面板里选用，闭合
## 「任务奖励 → 绿宝石 → 解锁新零件 → 改造飞机」循环。

var _unlocked: Dictionary = {}   # part_id -> true（已解锁）


func _seed_defaults() -> void:
	if not _unlocked.is_empty():
		return
	for p in PartRegistry.default_loadout():
		_unlocked[p.data.id] = true


## 是否已解锁（默认套件恒为 true）。
func is_unlocked(id: String) -> bool:
	_seed_defaults()
	return _unlocked.has(id)


## 当前解锁价（已解锁为 0；未知零件为 -1）。
func cost_of(id: String) -> int:
	var part := PartRegistry.by_id(id)
	if part == null:
		return -1
	_seed_defaults()
	if _unlocked.has(id):
		return 0
	return int(part.cost)


## 购买解锁：余额充足则解锁并扣费。返回 {ok, spent, remaining, reason}。
## 已解锁零件视为免费（spent=0）；零件不存在 / 余额不足则失败。
func purchase(id: String, emeralds: int) -> Dictionary:
	var part := PartRegistry.by_id(id)
	if part == null:
		return {"ok": false, "spent": 0, "remaining": emeralds, "reason": "unknown_part"}
	_seed_defaults()
	if _unlocked.has(id):
		return {"ok": true, "spent": 0, "remaining": emeralds}
	var cost := int(part.cost)
	if emeralds < cost:
		return {"ok": false, "spent": 0, "remaining": emeralds, "reason": "insufficient"}
	_unlocked[id] = true
	return {"ok": true, "spent": cost, "remaining": emeralds - cost}


## 任务奖励结算：把奖励绿宝石并入余额（纯加法，库存读写由调用方负责）。
static func reward_to_balance(balance: int, reward: int) -> int:
	return balance + reward
