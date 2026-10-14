class_name MissionManager
extends RefCounted

## 飞行任务运行时裁决（纯逻辑、无节点依赖，便于无头探针验证）。
## 由外部（真实游戏里是飞行器逐帧遥测，探针里是合成序列）每帧调用
## step(dt, telemetry) 喂入遥测；达成 / 失败 / 超时后一次性发出
## mission_result(success, result)，随后状态锁定，不再处理后续帧。
##
## 遥测字典约定：
##   altitude_agl  : 离地高度 (m)
##   speed        : 空速 (km/h)
##   position     : 世界坐标 Vector3（按 xz 水平距离判定绕点/降落区）
##   on_ground    : 机轮是否触地
##   vertical_speed : 垂直速度 (m/s，正为爬升)
##   wrecked      : 是否已坠毁解体
##   block_under  : 机身下方地面方块类型（降落区要求跑道面时判定；缺省 -1）

signal mission_result(success: bool, result: Dictionary)
signal progress_updated(info: Dictionary)

enum Status { IDLE, RUNNING, SUCCEEDED, FAILED }

var mission: MissionData
var status: int = Status.IDLE

var _elapsed := 0.0
var _next_waypoint := 0
var _was_airborne := false
var _touchdown_vs := 0.0
var _landed := false
var _min_dist_per_wp: Array[float] = []


func start(m: MissionData) -> void:
	mission = m
	status = Status.RUNNING
	_elapsed = 0.0
	_next_waypoint = 0
	_was_airborne = false
	_touchdown_vs = 0.0
	_landed = false
	_min_dist_per_wp = []
	for _i in m.waypoints.size():
		_min_dist_per_wp.append(INF)


func step(dt: float, telemetry: Dictionary) -> void:
	if status != Status.RUNNING or mission == null:
		return
	_elapsed += dt
	var agl: float = float(telemetry.get("altitude_agl", 0.0))
	var speed: float = float(telemetry.get("speed", 0.0))
	var pos: Vector3 = telemetry.get("position", Vector3.ZERO)
	var on_ground: bool = bool(telemetry.get("on_ground", true))
	var vs: float = float(telemetry.get("vertical_speed", 0.0))
	var wrecked: bool = bool(telemetry.get("wrecked", false))
	var block_under: int = int(telemetry.get("block_under", -1))

	if wrecked:
		_finish(false, "坠机解体")
		return
	if not on_ground:
		_was_airborne = true

	match mission.type:
		MissionData.Type.TAKEOFF:
			_step_takeoff(agl, speed, on_ground)
		MissionData.Type.CIRCUIT:
			_step_circuit(pos)
		MissionData.Type.LANDING:
			_step_landing(speed, pos, on_ground, vs, block_under)


## 外部超时（如任务限时）：当前仍 RUNNING 则判失败。
func timeout() -> void:
	if status == Status.RUNNING:
		_finish(false, "超时未达成")


## 主动放弃（UI 放弃按钮）：当前仍 RUNNING 则判失败，原因区别于超时。
func abandon() -> void:
	if status == Status.RUNNING:
		_finish(false, "主动放弃")


## 已进行时长（秒）；非 RUNNING 时为定格值，供面板计时显示。
func elapsed() -> float:
	return _elapsed


func _step_takeoff(agl: float, speed: float, on_ground: bool) -> void:
	if on_ground:
		return
	if agl >= mission.target_altitude() and speed >= mission.min_speed():
		_finish(true, "起飞成功")


func _step_circuit(pos: Vector3) -> void:
	if mission.waypoints.is_empty():
		return
	var target: Vector3 = mission.waypoints[_next_waypoint]
	var d := Vector2(pos.x - target.x, pos.z - target.z).length()
	_min_dist_per_wp[_next_waypoint] = minf(_min_dist_per_wp[_next_waypoint], d)
	if d <= mission.radius():
		_next_waypoint += 1
		if _next_waypoint >= mission.waypoints.size():
			_finish(true, "绕点成功")


func _step_landing(speed: float, pos: Vector3, on_ground: bool, vs: float,
		block_under: int) -> void:
	if not _was_airborne:
		return  # 还没离地，不算降落
	if on_ground:
		if not _landed:
			_touchdown_vs = vs
			_landed = true
			if absf(vs) > mission.max_touchdown_vs():
				_finish(false, "硬着陆")
				return
		# 已着陆：滑跑停稳后才判成功/出区失败
		if speed <= mission.max_roll_speed():
			var in_zone := Vector2(pos.x - mission.zone_center.x,
				pos.z - mission.zone_center.z).length() <= mission.zone_radius()
			if not in_zone:
				_finish(false, "滑出降落区")
				return
			# 锚定跑道的任务：停在区里还不够，必须压在跑道铺面方块上。
			var need_block := mission.zone_block()
			if need_block >= 0 and block_under != need_block and not BlockTypes.is_nav_light(block_under):
				_finish(false, "未停在跑道面")
				return
			_finish(true, "降落成功")


func _finish(success: bool, reason: String) -> void:
	status = Status.SUCCEEDED if success else Status.FAILED
	var result := {
		"success": success,
		"reason": reason,
		"elapsed": _elapsed,
		"score": _score(success),
		"reward": mission.reward_emeralds() if success else 0,
		"type": mission.type,
		"touchdown_vs": _touchdown_vs,
		"min_dist_per_wp": _min_dist_per_wp.duplicate(),
	}
	mission_result.emit(success, result)
	progress_updated.emit({"status": status, "elapsed": _elapsed, "reason": reason})


func _score(success: bool) -> int:
	if not success:
		return 0
	match mission.type:
		MissionData.Type.TAKEOFF:
			return int(clampf(120.0 - _elapsed * 1.5, 0, 200))
		MissionData.Type.CIRCUIT:
			var precision := 0.0
			for d in _min_dist_per_wp:
				precision += maxf(0.0, mission.radius() - d)
			return int(clampf(120.0 - _elapsed * 1.0 + precision, 0, 200))
		MissionData.Type.LANDING:
			return int(clampf(120.0 - absf(_touchdown_vs) * 10.0 - _elapsed * 1.0, 0, 200))
	return 0
