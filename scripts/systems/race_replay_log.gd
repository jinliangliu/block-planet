class_name RaceReplayLog
extends RefCounted
## 比赛事件日志（JSON Lines，追加写 user://race_replay.jsonl）。
##
## 每行一条：tick / action / track_id / vehicle_id / position / player。
## 记录 race_start、checkpoint、lap_complete、race_finish 四类事件——将来做
## 「幽灵车回放」时，这串就是重演的原始素材（与 flight_recorder 的思路一致，
## 只是飞行轨迹在内存里、这里落盘，因为它跨场景且要留给下次启动）。

## D-086：不再是 const，且必须是 static var（本类全静态、从无实例）。
## 无槽时 slot_file() 逐字节产出旧根路径 "user://race_replay.jsonl"。
static var PATH: String = "user://race_replay.jsonl"
const MAX_LINES := 600   # 分槽后语义自动变成「每槽 600 行」，比全局 600 行更正确


## 本类是 RefCounted 全静态、没有 _ready()、不能连 Profile.slot_changed；
## append() 也没有持久文件句柄（每次读全量 → 内存 append → 裁剪 → WRITE 覆写），
## 所以换槽无需换句柄，只要在 append/read_lines/clear 每次入口现算一次路径。
static func _refresh_path() -> void:
	if Profile != null:
		PATH = Profile.slot_file("race_replay.jsonl")


static func append(tick: int, action: String, track_id: String, vehicle_id: String,
		position: Vector3, player_name: String) -> void:
	_refresh_path()
	var line := JSON.stringify({
		"tick": tick,
		"action": action,
		"track_id": track_id,
		"vehicle_id": vehicle_id,
		"position": [
			snappedf(position.x, 0.01),
			snappedf(position.y, 0.01),
			snappedf(position.z, 0.01),
		],
		"player": player_name,
	})
	var lines := read_lines()
	lines.append(line)
	if lines.size() > MAX_LINES:
		lines = lines.slice(lines.size() - MAX_LINES)
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("\n".join(lines) + "\n")
	f.close()


static func read_lines() -> PackedStringArray:
	_refresh_path()
	if not FileAccess.file_exists(PATH):
		return PackedStringArray()
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return PackedStringArray()
	var out := PackedStringArray()
	for raw in f.get_as_text().split("\n", false):
		var s := raw.strip_edges()
		if not s.is_empty():
			out.append(s)
	f.close()
	return out


## 解析成事件字典数组（坏行跳过）。
static func read_events() -> Array:
	var out: Array = []
	for line in read_lines():
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			out.append(parsed)
	return out


static func clear() -> void:
	_refresh_path()
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
