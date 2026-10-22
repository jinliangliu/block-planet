class_name RoutePlan
extends RefCounted
## 多航路点航线的纯逻辑状态机；不持有节点，仪表、地图与探针可共用。

## 捕获半径取 40 m：比 CIRCUIT 默认 30 m 略宽，儿童飞行时允许柔和切点。
const WP_CAPTURE_R := 40.0

enum Kind { START, ENROUTE, DEST }

var _points: Array[Dictionary] = []
var _active_index := -1
var _complete := false


## 设置完整航线。元素契约为 {pos: Vector3, name: String, kind: int}；
## 无效元素直接忽略，避免外部规划结果不完整时打断飞行。
func set_route(points: Array) -> void:
	clear()
	for item: Variant in points:
		if not item is Dictionary:
			continue
		var point := item as Dictionary
		var pos: Variant = point.get("pos", Vector3.ZERO)
		if not pos is Vector3:
			continue
		_points.append({
			"pos": pos,
			"name": String(point.get("name", "")),
			"kind": int(point.get("kind", Kind.ENROUTE)),
		})
	if not _points.is_empty():
		_active_index = 0


## has_route 只表示仍有活动目标；完成后保留原航点供 total/progress 查询，
## 并由 is_complete 明确区分“完成”与“从未设置/已清空”。
func has_route() -> bool:
	return not _complete and _active_index >= 0 and _active_index < _points.size()


## 仅在当前航点 40 m 水平捕获圈内推进；飞过不惩罚、不回退。
func advance(pos: Vector3) -> bool:
	if not has_route():
		return false
	var target := current_target()
	var distance := Vector2(pos.x - target.x, pos.z - target.z).length()
	if distance > WP_CAPTURE_R:
		return false
	_active_index += 1
	if _active_index >= _points.size():
		_complete = true
	return true


## 由**外部判定**直接指定当前航点（本作任务航点的飞越由 MissionManager 裁决，
## 判定半径是任务自带的 radius()，与本类 WP_CAPTURE_R 不同）。
##
## 为什么还要这条而不是只用 advance()：任务绕点已经有一套判定真相，若这里再
## 按 40 m 自己推进一次，就会出现「地图上已切下一个点、仪表还指着上一个」的
## 双份真相。故任务链路统一走 set_current_index 对齐，advance() 留给无任务的
## 自由航线（探针与未来 A→B 规划）。
func set_current_index(index: int) -> void:
	if _points.is_empty():
		return
	_active_index = clampi(index, 0, _points.size() - 1)
	_complete = false


func current_index() -> int:
	return _active_index


func current_target() -> Vector3:
	if not has_route():
		return Vector3.ZERO
	var pos: Variant = _points[_active_index].get("pos", Vector3.ZERO)
	return pos if pos is Vector3 else Vector3.ZERO


func remaining() -> int:
	if _points.is_empty() or _complete:
		return 0
	return maxi(_points.size() - _active_index, 0)


func total() -> int:
	return _points.size()


## 进度按已捕获航点数计算：首点前为 0，最后一点捕获后为 1。
func progress() -> float:
	if _points.is_empty():
		return 0.0
	if _complete:
		return 1.0
	return clampf(float(_active_index) / float(_points.size()), 0.0, 1.0)


func is_complete() -> bool:
	return _complete


func clear() -> void:
	_points.clear()
	_active_index = -1
	_complete = false
