class_name RaceReplayLog
extends RefCounted
## 比赛事件日志（JSON Lines，追加写 user://race_replay.jsonl）。
##
## 每行一条：tick / action / track_id / vehicle_id / position / player。
## 记录 race_start、checkpoint、lap_complete、race_finish 四类事件——将来做
## 「幽灵车回放」时，这串就是重演的原始素材（与 flight_recorder 的思路一致，
## 只是飞行轨迹在内存里、这里落盘，因为它跨场景且要留给下次启动）。

const PATH := "user://race_replay.jsonl"
const MAX_LINES := 600   # 只留最近 600 条，避免存档无限增长


static func append(tick: int, action: String, track_id: String, vehicle_id: String,
		position: Vector3, player_name: String) -> void:
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
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
