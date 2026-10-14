extends Node

## 无头验证 MissionManager 的三种任务裁决逻辑（纯逻辑，不依赖世界/地形）。
## 以合成遥测序列驱动 step()，覆盖：起飞成功/坠机/超时、绕点成功/坠机、
## 降落成功/硬着陆/滑出区/未停跑道面、奖励防刷（P2-9：每任务每进程一次）。

const DT := 0.1

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
	_run_mission_checks()
	print("MISSION_PROBE_DONE fails=%d" % _fail)
	if _fail > 0:
		print("MISSION_PROBE_FAIL")
		get_tree().quit(1)
	else:
		print("MISSION_PROBE_OK")
		get_tree().quit(0)


## 跑一个任务：逐帧喂遥测，提前结束则收尾；若全程未结束则模拟超时。
## 用共享字典持有结果（GDScript 闭包对捕获变量重赋值不向外传递，改 key 才可靠）。
func _run_mission(m: MissionData, frames: Array[Dictionary]) -> Dictionary:
	var mm := MissionManager.new()
	var holder := {"result": {}}
	mm.mission_result.connect(func(success: bool, r: Dictionary):
		holder["result"] = r)
	mm.start(m)
	for f in frames:
		if not holder["result"].is_empty():
			break
		mm.step(DT, f)
	if holder["result"].is_empty():
		mm.timeout()
	return holder["result"]


func _mk(t: MissionData.Type, extra: Dictionary = {}) -> MissionData:
	var m := MissionData.new()
	m.type = t
	m.params = extra
	return m


# ---------------------------------------------------------------- 起飞
func _frames_takeoff(leave_ground: bool, wreck: bool) -> Array[Dictionary]:
	var f: Array[Dictionary] = []
	for i in 3:  # 地面滑跑
		f.append({"altitude_agl": 0.0, "speed": 0.0, "position": Vector3.ZERO,
			"on_ground": true, "vertical_speed": 0.0, "wrecked": false})
	if not leave_ground:
		return f  # 始终在地面 → 超时
	for i in 5:  # 离地爬升
		f.append({"altitude_agl": 35.0 + i, "speed": 80.0,
			"position": Vector3(i * 10, 0, 0), "on_ground": false,
			"vertical_speed": 2.0, "wrecked": wreck})
	return f


func _check_takeoff() -> void:
	var m := _mk(MissionData.Type.TAKEOFF,
		{"target_alt": 30.0, "min_speed": 40.0})
	var ok := _run_mission(m, _frames_takeoff(true, false))
	_check(ok.get("success", false), "起飞：离地达 30m/80km/h 判成功")
	_check(ok.get("reason", "") == "起飞成功", "起飞：成功原因为「起飞成功」")
	_check(int(ok.get("reward", 0)) == 5, "起飞：成功奖励 5 绿宝石")

	var crash := _run_mission(m, _frames_takeoff(true, true))
	_check(not crash.get("success", true), "起飞：空中坠机判失败")
	_check(crash.get("reason", "") == "坠机解体", "起飞：失败原因为「坠机解体」")

	var timeout := _run_mission(m, _frames_takeoff(false, false))
	_check(not timeout.get("success", true), "起飞：始终在地面超时判失败")
	_check(timeout.get("reason", "") == "超时未达成", "起飞：超时原因为「超时未达成」")


# ---------------------------------------------------------------- 绕点
func _frames_circuit(hit_all: bool, wreck: bool) -> Array[Dictionary]:
	var f: Array[Dictionary] = []
	var path := [
		Vector3(0, 0, 0), Vector3(0, 0, 80), Vector3(0, 0, 150),
		Vector3(110, 0, 150), Vector3(200, 0, 150),
		Vector3(200, 0, 80), Vector3(200, 0, 0),
		Vector3(100, 0, 0), Vector3(0, 0, 0), Vector3(0, 0, -10),
	]
	var pts := path if hit_all else path.slice(0, 3)  # 不跑完 → 永远差几个点
	for p in pts:
		f.append({"altitude_agl": 40.0, "speed": 100.0, "position": p,
			"on_ground": false, "vertical_speed": 0.0, "wrecked": false})
	if wreck and f.size() > 4:
		f[4]["wrecked"] = true  # 过第一点后坠机
	return f


func _check_circuit() -> void:
	var m := _mk(MissionData.Type.CIRCUIT, {"radius": 30.0})
	m.waypoints = [Vector3(0, 0, 150), Vector3(200, 0, 150),
		Vector3(200, 0, 0), Vector3(0, 0, 0)]
	var ok := _run_mission(m, _frames_circuit(true, false))
	_check(ok.get("success", false), "绕点：按顺序过完 4 点判成功")
	_check(ok.get("reason", "") == "绕点成功", "绕点：成功原因为「绕点成功」")
	# 精度分应来自「最近距离」累加（每点贴着经过）
	_check(int(ok.get("score", 0)) > 0, "绕点：成功有正评分")

	var part := _run_mission(m, _frames_circuit(false, false))
	_check(not part.get("success", true), "绕点：未跑完所有点判失败")
	_check(part.get("reason", "") == "超时未达成", "绕点：未完成原因为「超时未达成」")

	var crash := _run_mission(m, _frames_circuit(true, true))
	_check(not crash.get("success", true), "绕点：中途坠机判失败")
	_check(crash.get("reason", "") == "坠机解体", "绕点：失败原因为「坠机解体」")


# ---------------------------------------------------------------- 降落
func _frames_landing(touchdown_vs: float, final_pos: Vector3, stop_speed: float,
		block_under: int = -1) -> Array[Dictionary]:
	var f: Array[Dictionary] = []
	for i in 4:  # 进近：空中
		f.append({"altitude_agl": 50.0 - i * 10.0, "speed": 100.0,
			"position": Vector3(0, 0, 0), "on_ground": false,
			"vertical_speed": -2.0, "wrecked": false})
	# 触地 + 滑跑停稳（block_under：机身下方地面方块，跑道面判据）
	f.append({"altitude_agl": 0.0, "speed": stop_speed, "position": final_pos,
		"on_ground": true, "vertical_speed": touchdown_vs, "wrecked": false,
		"block_under": block_under})
	return f


func _check_landing() -> void:
	var m := _mk(MissionData.Type.LANDING,
		{"zone_radius": 50.0, "max_touchdown_vs": 3.0, "max_roll_speed": 25.0})
	m.zone_center = Vector3(0, 0, 0)

	var ok := _run_mission(m, _frames_landing(-1.5, Vector3(5, 0, 0), 10.0))
	_check(ok.get("success", false), "降落：软着陆+区内停稳判成功")
	_check(ok.get("reason", "") == "降落成功", "降落：成功原因为「降落成功」")
	_check(absf(float(ok.get("touchdown_vs", 99.0)) + 1.5) < 0.01,
		"降落：记录触地垂直速度 -1.5 m/s")

	var hard := _run_mission(m, _frames_landing(-10.0, Vector3(5, 0, 0), 10.0))
	_check(not hard.get("success", true), "降落：硬着陆(10m/s)判失败")
	_check(hard.get("reason", "") == "硬着陆", "降落：失败原因为「硬着陆」")

	var out := _run_mission(m, _frames_landing(-1.0, Vector3(200, 0, 0), 10.0))
	_check(not out.get("success", true), "降落：停稳但滑出区判失败")
	_check(out.get("reason", "") == "滑出降落区", "降落：失败原因为「滑出降落区」")


## 降落（跑道面校验）：zone_block 任务落在草地上判失败，压在跑道面上才成功。
func _check_landing_runway() -> void:
	var m := _mk(MissionData.Type.LANDING,
		{"zone_radius": 50.0, "max_touchdown_vs": 3.0, "max_roll_speed": 25.0,
			"zone_block": BlockTypes.Block.COBBLESTONE})
	m.zone_center = Vector3(0, 0, 0)
	_check(m.zone_block() == BlockTypes.Block.COBBLESTONE,
		"降落：zone_block 参数可读（锚定跑道的任务带块要求）")

	var on_grass := _run_mission(m, _frames_landing(-1.5, Vector3(5, 0, 0), 10.0,
		BlockTypes.Block.GRASS))
	_check(not on_grass.get("success", true), "降落：区内但未压在跑道面判失败")
	_check(on_grass.get("reason", "") == "未停在跑道面",
		"降落：失败原因为「未停在跑道面」（实际「%s」）" % on_grass.get("reason", ""))

	var on_runway := _run_mission(m, _frames_landing(-1.5, Vector3(5, 0, 0), 10.0,
		BlockTypes.Block.COBBLESTONE))
	_check(on_runway.get("success", false), "降落：压在跑道面上停稳判成功")
	_check(on_runway.get("reason", "") == "降落成功",
		"降落：成功原因为「降落成功」")


## 防刷（P2-9）：同一任务每进程仅发一次奖励——重复完成仍判成功、仍计分，
## 但奖励归零并打 repeat 标记；换任务不受影响；状态不跨实例继承。
func _check_reward_guard() -> void:
	var mm := MissionManager.new()
	var results: Array[Dictionary] = []
	mm.mission_result.connect(func(_success: bool, r: Dictionary):
		results.append(r))

	var takeoff := _mk(MissionData.Type.TAKEOFF,
		{"target_alt": 30.0, "min_speed": 40.0})
	takeoff.id = "m_takeoff"

	# 第一次完成：正常发奖，无 repeat 标记。
	mm.start(takeoff)
	for f in _frames_takeoff(true, false):
		if not results.is_empty():
			break
		mm.step(DT, f)
	_check(results.size() == 1 and bool(results[0].get("success", false)),
		"防刷：首次完成起飞判成功")
	_check(int(results[0].get("reward", 0)) == 5, "防刷：首次完成发 5 绿宝石")
	_check(not bool(results[0].get("repeat", true)), "防刷：首次完成无 repeat 标记")

	# 第二次完成同一任务：仍成功、仍计分，但奖励归零 + repeat 标记。
	results.clear()
	mm.start(takeoff)
	for f in _frames_takeoff(true, false):
		if not results.is_empty():
			break
		mm.step(DT, f)
	_check(results.size() == 1 and bool(results[0].get("success", false)),
		"防刷：重复完成仍判成功（可反复挑战）")
	_check(int(results[0].get("reward", 0)) == 0, "防刷：重复完成奖励归零")
	_check(bool(results[0].get("repeat", false)), "防刷：重复完成打 repeat 标记")
	_check(int(results[0].get("score", 0)) > 0, "防刷：重复完成仍计分")

	# 换任务：另一个 id 的首次完成不受影响。
	results.clear()
	var landing := _mk(MissionData.Type.LANDING,
		{"zone_radius": 50.0, "max_touchdown_vs": 3.0, "max_roll_speed": 25.0})
	landing.id = "m_landing"
	landing.zone_center = Vector3(0, 0, 0)
	mm.start(landing)
	for f in _frames_landing(-1.5, Vector3(5, 0, 0), 10.0):
		if not results.is_empty():
			break
		mm.step(DT, f)
	_check(results.size() == 1 and int(results[0].get("reward", 0)) == 5,
		"防刷：不同任务首次完成仍发 5 绿宝石")

	# is_rewarded 查询接口 + 新实例不继承（进程语义：面板重建即重置）。
	_check(mm.is_rewarded("m_takeoff") and mm.is_rewarded("m_landing"),
		"防刷：is_rewarded 反映已发奖任务")
	_check(not mm.is_rewarded("m_circuit"), "防刷：未完成的任务 is_rewarded 为假")
	_check(not MissionManager.new().is_rewarded("m_takeoff"),
		"防刷：已发奖状态不跨 MissionManager 实例继承")


func _run_mission_checks() -> void:
	_check_takeoff()
	_check_circuit()
	_check_landing()
	_check_landing_runway()
	_check_reward_guard()
