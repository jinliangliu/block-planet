extends Node
## 竞速系统（Autoload：RaceSystem）——赛道选择 → 比赛 → 结算 → 记录 的单一入口。
##
## 职责边界：
##   · 数据：加载 data/racing/ 五份 JSON（赛道/地形/机器人/赛车/教学）；
##   · 会话参数：赛道选择器把「选了什么」寄存在这里，赛道场景读走并开赛；
##   · 记录：user://race_records.json 的读写与破纪录判定（纯逻辑在 RaceRecords）；
##   · 跨系统广播：完赛时向 Events 发信号，供进度核心（任务/成就）累计。
##
## 注意：本脚本刻意不写 class_name —— 与 Autoload 单例同名会让 Godot 报
## 「类遮蔽了自动加载单例」而整个项目加载失败（本工程已踩过一次）。

signal race_started(track_id: String)
signal lap_completed(lap: int, lap_time: float)
signal race_finished(results: Array)
signal new_record(track_id: String, record_type: String, value: float)

const RECORDS_PATH := "user://race_records.json"
const TRACKS_PATH := "res://data/racing/tracks.json"
const TERRAIN_PATH := "res://data/racing/terrain.json"
const AI_PATH := "res://data/racing/ai_racers.json"
const VEHICLES_PATH := "res://data/racing/vehicles.json"
const TEACHING_PATH := "res://data/racing/teaching.json"

var _tracks: Array = []
var _track_by_id: Dictionary = {}
var _terrains: Array = []
var _terrain_by_id: Dictionary = {}
var _difficulties: Array = []
var _difficulty_by_id: Dictionary = {}
var _vehicles: Array = []
var _vehicle_by_id: Dictionary = {}
var _ai_names: Array = []
var _ai_vehicle_ids: Array = []
var _teaching: Array = []
var _records: Dictionary = {}

## 上一场的选择（赛道选择器写入 → 赛道场景读取）。
var pending := {
	"track_id": "",
	"vehicle_id": "tricycle",
	"ai_count": 3,
	"ai_difficulty": "easy",
}

## 从赛道返回主场景后是否直接再开赛道选择器（race_scene 写、main 读后清）。
var open_selector_on_return := false


func _ready() -> void:
	load_data()
	load_records()


# ── 数据加载 ──────────────────────────────────────────────
func load_data() -> void:
	_tracks = _read_array(TRACKS_PATH, "tracks")
	_track_by_id = _index_by_id(_tracks)
	_terrains = _read_array(TERRAIN_PATH, "terrains")
	_terrain_by_id = _index_by_id(_terrains)
	_difficulties = _read_array(AI_PATH, "difficulties")
	_difficulty_by_id = _index_by_id(_difficulties)
	_vehicles = _read_array(VEHICLES_PATH, "vehicles")
	_vehicle_by_id = _index_by_id(_vehicles)
	_teaching = _read_array(TEACHING_PATH, "teaching")
	var ai_root := _read_root(AI_PATH)
	var names: Variant = ai_root.get("ai_names", [])
	_ai_names = names if names is Array else []
	var av: Variant = ai_root.get("ai_vehicles", [])
	_ai_vehicle_ids = av if av is Array else []


func _read_root(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("RaceSystem: 缺少数据文件 %s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _read_array(path: String, key: String) -> Array:
	var root := _read_root(path)
	var value: Variant = root.get(key, [])
	return value if value is Array else []


func _index_by_id(items: Array) -> Dictionary:
	var out: Dictionary = {}
	for item: Variant in items:
		if item is Dictionary:
			out[String((item as Dictionary).get("id", ""))] = item
	return out


# ── 查询 ──────────────────────────────────────────────────
func tracks() -> Array:
	return _tracks


func track(id: String) -> Dictionary:
	return _track_by_id.get(id, {})


func terrains() -> Array:
	return _terrains


func terrain(id: String) -> Dictionary:
	var t: Dictionary = _terrain_by_id.get(id, {})
	if t.is_empty():
		return {"id": id, "name_zh": id, "grip": 1.0, "rolling_resistance": 0.02,
			"speed_factor": 1.0, "brake_factor": 1.0, "color": "#666666"}
	return t


func difficulty(id: String) -> Dictionary:
	var d: Dictionary = _difficulty_by_id.get(id, {})
	if d.is_empty():
		return {"id": "normal", "name_zh": "普通", "speed_factor": 0.85,
			"steering_accuracy": 0.8, "reaction_time": 0.3, "mistake_chance": 0.08}
	return d


func difficulties() -> Array:
	return _difficulties


## 玩家可选的赛车（不含 ai_only 的机器人专用车）。
func player_vehicles() -> Array:
	var out: Array = []
	for v: Variant in _vehicles:
		if v is Dictionary and not bool((v as Dictionary).get("ai_only", false)):
			out.append(v)
	return out


## 机器人可用的赛车 id 池（数据里声明，缺省退回默认三台）。
func ai_vehicle_ids() -> Array:
	if not _ai_vehicle_ids.is_empty():
		return _ai_vehicle_ids
	return ["ai_tricycle_red", "ai_car_blue", "ai_car_green"]


func vehicle(id: String) -> Dictionary:
	var v: Dictionary = _vehicle_by_id.get(id, {})
	if v.is_empty():
		return _vehicle_by_id.get("tricycle", {})
	return v


func ai_names() -> Array:
	return _ai_names


func teaching() -> Array:
	return _teaching


## 某触发点应弹的教学条目（首次比赛 / 首次过检查点 / 首次完圈）。
func teachings_for(trigger: String) -> Array:
	var out: Array = []
	for item: Variant in _teaching:
		if item is Dictionary and String((item as Dictionary).get("trigger", "")) == trigger:
			out.append(item)
	return out


## 解锁判定：unlock 取值 default / wins:N / record:N。空串与未知格式一律视为已解锁
## （儿童向：宁可多给，不要因为写错解锁串把赛道锁死）。
func is_unlocked(unlock: String) -> bool:
	var u := unlock.strip_edges()
	if u.is_empty() or u == "default":
		return true
	var parts := u.split(":")
	if parts.size() != 2:
		return true
	var n := int(parts[1])
	match parts[0]:
		"wins":
			return RaceRecords.total_wins(_records) >= n
		"record":
			return RaceRecords.record_count(_records) >= n
	return true


## 解锁条件的中文说明（UI 用来告诉孩子怎么解锁）。
func unlock_hint(unlock: String) -> String:
	var u := unlock.strip_edges()
	if u.is_empty() or u == "default":
		return "已解锁"
	var parts := u.split(":")
	if parts.size() != 2:
		return "已解锁"
	var n := int(parts[1])
	match parts[0]:
		"wins":
			return "赢 %d 场后解锁" % n
		"record":
			return "破 %d 次最快圈速后解锁" % n
	return "已解锁"


func build_layout(track_id: String) -> TrackLayout:
	var def := track(track_id)
	if def.is_empty():
		var all := tracks()
		if all.is_empty():
			return null
		def = all[0]
	return TrackLayout.build(def)


# ── 会话参数 ──────────────────────────────────────────────
func select_race(track_id: String, vehicle_id: String, ai_count: int, ai_difficulty: String) -> void:
	pending["track_id"] = track_id
	pending["vehicle_id"] = vehicle_id
	pending["ai_count"] = clampi(ai_count, 0, 5)
	pending["ai_difficulty"] = ai_difficulty
	var def := track(track_id)
	if def.is_empty():
		return
	# 数量与难度缺省回落到赛道推荐值，避免选择器未设置时开出空场。
	if ai_count < 0:
		pending["ai_count"] = int(def.get("ai_count", 3))
	if ai_difficulty.is_empty():
		pending["ai_difficulty"] = String(def.get("ai_difficulty", "easy"))


func has_pending_race() -> bool:
	return not String(pending["track_id"]).is_empty()


# ── 记录 ──────────────────────────────────────────────────
func records() -> Dictionary:
	return _records


func entry_of(track_id: String) -> Dictionary:
	return RaceRecords.entry_of(_records, track_id)


func best_lap_of(track_id: String) -> float:
	return float(entry_of(track_id)["best_lap_time"])


func best_time_of(track_id: String) -> float:
	return float(entry_of(track_id)["best_race_time"])


func load_records() -> void:
	_records = RaceRecords.load_from(RECORDS_PATH)


func save_records() -> bool:
	return RaceRecords.save_to(RECORDS_PATH, _records)


func clear_records() -> void:
	_records = RaceRecords.blank_store()
	save_records()


## 一场比赛结束后结算：写记录、判破纪录、广播。
## 返回 {broke_lap, broke_race, entry, first_race}。
func submit_result(track_id: String, vehicle_id: String, rank: int, best_lap: float,
		total_time: float, clean: bool, laps: int) -> Dictionary:
	var outcome := RaceRecords.apply(_records, track_id, vehicle_id, rank, best_lap,
		total_time, _now_iso())
	save_records()
	if bool(outcome["broke_lap"]):
		new_record.emit(track_id, "best_lap", best_lap)
		Events.race_record_beaten.emit(track_id, "best_lap")
	if bool(outcome["broke_race"]):
		new_record.emit(track_id, "best_time", total_time)
		Events.race_record_beaten.emit(track_id, "best_time")
	Events.race_finished.emit(track_id, vehicle_id, rank, laps, best_lap, total_time, clean)
	return outcome


func _now_iso() -> String:
	return Time.get_datetime_string_from_system(false, false)


# ── 计时格式化（UI 与日志共用一份）────────────────────────
static func format_time(seconds: float) -> String:
	if seconds < 0.0:
		return "--:--.--"
	var m := int(seconds) / 60
	var s := int(seconds) % 60
	var cs := int(round((seconds - floor(seconds)) * 100.0))
	if cs >= 100:
		cs = 99
	return "%02d:%02d.%02d" % [m, s, cs]


static func format_lap(seconds: float) -> String:
	if seconds <= 0.0:
		return "--:--.--"
	return format_time(seconds)
