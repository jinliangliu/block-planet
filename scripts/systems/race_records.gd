class_name RaceRecords
extends RefCounted
## 竞速记录的纯逻辑读写（与节点无关，可无头测试）。
##
## 存档：user://race_records.json
##   { "version": 1, "tracks": { "<track_id>": { ...见 blank_entry()... } } }
##
## 说明：文档里把 best_lap / best_time 也写进了 tracks.json，但那是只读的静态
## 定义文件——记录是玩家数据，全部落在 user://race_records.json，静态与动态分开。

const SAVE_VERSION := 1

## 一条赛道记录的空模板。时间一律用秒；0.0 表示「尚无记录」（不存在用时为 0 的一圈）。
static func blank_entry() -> Dictionary:
	return {
		"best_lap_time": 0.0,
		"best_lap_at": "",
		"best_lap_vehicle": "",
		"best_race_time": 0.0,
		"best_race_at": "",
		"total_races": 0,
		"wins": 0,
		"best_rank": 0,
		"last_rank": 0,
	}


static func blank_store() -> Dictionary:
	return {"version": SAVE_VERSION, "tracks": {}}


static func entry_of(store: Dictionary, track_id: String) -> Dictionary:
	var tracks: Dictionary = store.get("tracks", {})
	var raw: Variant = tracks.get(track_id, null)
	if raw is Dictionary:
		var entry := blank_entry()
		for key: String in entry.keys():
			if (raw as Dictionary).has(key):
				entry[key] = (raw as Dictionary)[key]
		return entry
	return blank_entry()


## 把一场比赛的结果并入 store（就地修改）。返回
## {broke_lap:bool, broke_race:bool, entry:Dictionary, first_race:bool}。
static func apply(
	store: Dictionary,
	track_id: String,
	vehicle_id: String,
	rank: int,
	best_lap: float,
	total_time: float,
	now_iso: String
) -> Dictionary:
	if not store.has("tracks"):
		store["tracks"] = {}
	var tracks: Dictionary = store["tracks"]
	var entry := entry_of(store, track_id)
	var first := int(entry["total_races"]) == 0
	var broke_lap := false
	var broke_race := false

	entry["total_races"] = int(entry["total_races"]) + 1
	if rank == 1:
		entry["wins"] = int(entry["wins"]) + 1
	if int(entry["best_rank"]) == 0 or rank < int(entry["best_rank"]):
		entry["best_rank"] = rank
	entry["last_rank"] = rank

	if best_lap > 0.0:
		var prev_lap := float(entry["best_lap_time"])
		if prev_lap <= 0.0 or best_lap < prev_lap:
			broke_lap = true
			entry["best_lap_time"] = best_lap
			entry["best_lap_at"] = now_iso
			entry["best_lap_vehicle"] = vehicle_id

	if total_time > 0.0:
		var prev_race := float(entry["best_race_time"])
		if prev_race <= 0.0 or total_time < prev_race:
			broke_race = true
			entry["best_race_time"] = total_time
			entry["best_race_at"] = now_iso

	tracks[track_id] = entry
	return {"broke_lap": broke_lap, "broke_race": broke_race, "entry": entry, "first_race": first}


## 全部赛道的胜场合计（解锁条件用）。
static func total_wins(store: Dictionary) -> int:
	var total := 0
	var tracks: Dictionary = store.get("tracks", {})
	for key: String in tracks:
		total += int((tracks[key] as Dictionary).get("wins", 0))
	return total


## 已产生过最快圈速记录的赛道数（解锁条件用）。
static func record_count(store: Dictionary) -> int:
	var total := 0
	var tracks: Dictionary = store.get("tracks", {})
	for key: String in tracks:
		if float((tracks[key] as Dictionary).get("best_lap_time", 0.0)) > 0.0:
			total += 1
	return total


static func load_from(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return blank_store()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return blank_store()
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is not Dictionary:
		return blank_store()
	var store: Dictionary = parsed
	if not store.has("tracks") or not (store["tracks"] is Dictionary):
		store["tracks"] = {}
	if not store.has("version"):
		store["version"] = SAVE_VERSION
	return store


static func save_to(path: String, store: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("RaceRecords.save_to: 无法写入 %s" % path)
		return false
	f.store_string(JSON.stringify(store))
	f.close()
	return true
