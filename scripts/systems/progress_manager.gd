extends Node

## 全局进度核心（Autoload：Progress）。
## 监听 Events 信号桥累计行为计数器，驱动任务与成就状态机，
## 并把进度持久化到 user://progress.json（跨区域重载与重启均存活）。

signal progress_bumped
signal quest_completed(id: String)
signal quest_claimed(id: String, reward: Dictionary)
signal achievement_unlocked(id: String)
signal quiz_answered(correct: bool)
signal quiz_reward_earned(item: int, count: int)

enum State { ACTIVE, DONE, CLAIMED }

const SAVE_PATH := "user://progress.json"

var counters: Dictionary = {}
var states: Dictionary = {}          # id -> State（仅记录已解锁条目）
var _quiz_correct_since_reward := 0


func _ready() -> void:
	_load()
	Events.block_broken.connect(_on_block_broken)
	Events.block_placed.connect(_on_block_placed)
	Events.mob_killed.connect(_on_mob_killed)
	Events.craft_done.connect(_on_craft_done)
	Events.smelt_done.connect(_on_smelt_done)
	Events.player_died.connect(_on_player_died)
	Events.region_entered.connect(_on_region_entered)
	Events.mob_grown.connect(_on_mob_grown)
	Events.aircraft_took_off.connect(_on_aircraft_took_off)
	Events.aircraft_altitude.connect(_on_aircraft_altitude)
	Events.aircraft_distance.connect(_on_aircraft_distance)
	_reevaluate()


func _exit_tree() -> void:
	_save()


## 行为计数入口：所有任务/成就的判定数据源。
func notify(key: String, amount: int = 1) -> void:
	counters[key] = int(counters.get(key, 0)) + amount
	_reevaluate()
	progress_bumped.emit()
	_save()


## 知识问答作答：答对计入计数器，每满 QUIZ_REWARD_EVERY 题发一次奖励。
func answer_quiz(correct: bool) -> void:
	if not correct:
		quiz_answered.emit(false)
		return
	_quiz_correct_since_reward += 1
	notify("quiz_correct")
	quiz_answered.emit(true)
	if _quiz_correct_since_reward >= QuestData.QUIZ_REWARD_EVERY:
		_quiz_correct_since_reward = 0
		quiz_reward_earned.emit(QuestData.QUIZ_REWARD_ITEM, QuestData.QUIZ_REWARD_COUNT)


## 条目当前是否可见（任务链：前序领奖后解锁；成就恒可见）。
func is_visible(entry: Dictionary) -> bool:
	var prereq := String(entry.get("prerequisite", ""))
	if prereq.is_empty():
		return true
	return int(states.get(prereq, State.ACTIVE)) == State.CLAIMED


func state_of(id: String) -> int:
	return int(states.get(id, State.ACTIVE))


## 目标进度 [当前值, 目标值]（供面板进度条使用）。
func goal_progress(goal: Dictionary) -> Vector2i:
	var target := int(goal["count"])
	match String(goal["type"]):
		"regions":
			return Vector2i(_count_prefix("regions_"), target)
		"distinct_mined":
			return Vector2i(_count_prefix("mined_"), target)
		"quests_done":
			return Vector2i(_count_claimed_quests(), target)
		_:
			return Vector2i(mini(int(counters.get(String(goal["key"]), 0)), target), target)


func is_complete(entry: Dictionary) -> bool:
	var cur := goal_progress(entry["goal"])
	return cur.x >= cur.y


## 领取已达成条目的奖励，返回奖励字典（发放由 HUD 监听 quest_claimed 执行）。
func claim(id: String) -> Dictionary:
	if state_of(id) != State.DONE:
		return {}
	var entry := QuestData.entry_by_id(id)
	if entry.is_empty():
		return {}
	states[id] = State.CLAIMED
	_save()
	_reevaluate()
	quest_claimed.emit(id, entry["reward"])
	return entry["reward"]


func _reevaluate() -> void:
	for entry in QuestData.quests():
		_check_entry(entry, false)
	for entry in QuestData.achievements():
		_check_entry(entry, true)


func _check_entry(entry: Dictionary, is_achievement: bool) -> void:
	var id := String(entry["id"])
	if not is_visible(entry) or state_of(id) != State.ACTIVE:
		return
	if is_complete(entry):
		states[id] = State.DONE
		if is_achievement:
			achievement_unlocked.emit(id)
		else:
			quest_completed.emit(id)


func _count_prefix(prefix: String) -> int:
	var total := 0
	for key: String in counters:
		if key.begins_with(prefix) and int(counters[key]) > 0:
			total += 1
	return total


func _count_claimed_quests() -> int:
	var total := 0
	for entry in QuestData.quests():
		if state_of(String(entry["id"])) == State.CLAIMED:
			total += 1
	return total


func _on_block_broken(block_id: int, _cell: Vector3i) -> void:
	notify("mined_%d" % block_id)
	notify("mined_any")


func _on_block_placed(block_id: int, _cell: Vector3i) -> void:
	notify("placed_%d" % block_id)
	notify("placed_any")


func _on_mob_killed(mob_type: int) -> void:
	notify("killed_%d" % mob_type)
	notify("killed_any")
	if not Mob.is_passive(mob_type):
		notify("killed_hostile")


func _on_craft_done(item_id: int) -> void:
	notify("crafted_%d" % item_id)
	notify("crafted_any")


func _on_smelt_done(_item_id: int) -> void:
	notify("smelted")


func _on_player_died() -> void:
	notify("died")


func _on_region_entered(region_id: int) -> void:
	notify("regions_%d" % region_id)


## 亲眼看到生物长大一个阶段（「小小饲养员」类成就）。
func _on_mob_grown(mob_type: int, stage: int) -> void:
	notify("grown_%d" % mob_type)
	notify("grown_any")
	if stage >= 1:
		notify("grown_stage_%d" % stage)


## 飞行器起飞一次（「展翅高飞」）。
func _on_aircraft_took_off() -> void:
	notify("flew")


## 飞行器到达新的离地高度里程碑（每 20 m 一档，「冲上云霄」盯 60 m 档）。
func _on_aircraft_altitude(altitude: float) -> void:
	notify("flew_alt_%d" % int(altitude))


## 飞行器累计飞行距离每满 100 m 一段（「空中漫游」累计 1000 m）。
func _on_aircraft_distance(meters: float) -> void:
	notify("flew_distance", int(meters))


func _save() -> void:
	var data := {"counters": counters, "states": states,
		"quiz_streak": _quiz_correct_since_reward}
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(data))


func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data: Dictionary = parsed
	var loaded_counters: Variant = data.get("counters", {})
	if typeof(loaded_counters) == TYPE_DICTIONARY:
		for key: String in loaded_counters:
			counters[key] = int(loaded_counters[key])
	var loaded_states: Variant = data.get("states", {})
	if typeof(loaded_states) == TYPE_DICTIONARY:
		for key: String in loaded_states:
			states[key] = int(loaded_states[key])
	_quiz_correct_since_reward = int(data.get("quiz_streak", 0))
