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


## ── 持久化（user://unlocks.json）─────────────────────────
## 解锁状态跨会话保留：任务赚的绿宝石买的零件，下次进游戏还在。
## 真实游戏里由 main 持有唯一实例并传入 build_screen；探针用临时路径验证往返。

const SAVE_PATH := "user://unlocks.json"


## 当前已解锁集合的零件 id 列表（默认套件恒含；供探针与序列化）。
func unlocked_ids() -> Array:
	_seed_defaults()
	var ids: Array = []
	for id in _unlocked.keys():
		ids.append(String(id))
	ids.sort()
	return ids


func to_dict() -> Dictionary:
	return {"unlocked": unlocked_ids()}


static func from_dict(d: Dictionary) -> PartUnlocks:
	var u := PartUnlocks.new()
	var ids: Array = d.get("unlocked", [])
	for id in ids:
		u._unlocked[String(id)] = true
	u._seed_defaults()
	return u


## 写入 JSON；失败（只读/磁盘满）返回 false，不抛异常。
func save(path: String = SAVE_PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict()))
	f.close()
	return true


## 读档：文件不存在 / 损坏时安全退回「仅默认套件解锁」的新实例。
static func load_or_new(path: String = SAVE_PATH) -> PartUnlocks:
	if not FileAccess.file_exists(path):
		return PartUnlocks.new()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PartUnlocks.new()
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) == TYPE_DICTIONARY:
		return from_dict(parsed)
	return PartUnlocks.new()
