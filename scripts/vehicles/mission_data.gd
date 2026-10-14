class_name MissionData
extends Resource

## 飞行任务静态定义（数据驱动，可 JSON / .tres 存档扩展）。
## MVP 三种任务：起飞 / 绕点 / 降落——对应「建造→试飞→任务→奖励」闭环里的「任务」段。
##
## 与 QuestData（元进度：成就/新手链）区分：MissionData 是单次飞行挑战的
## 运行时参数与评分口径；完成后的奖励（绿宝石）由外部结算进玩家货币，
## 经 ProgressManager 驱动零件解锁（见 Phase 3c）。

enum Type { TAKEOFF, CIRCUIT, LANDING }

const DEFAULT_TARGET_ALT := 30.0        # 起飞：目标离地高度 (m)
const DEFAULT_MIN_SPEED := 40.0         # 起飞：最低安全空速 (km/h)
const DEFAULT_RADIUS := 30.0            # 绕点：判定半径 (m)
const DEFAULT_ZONE_RADIUS := 50.0       # 降落：降落区半径 (m)
const DEFAULT_TOUCHDOWN_VS := 3.0       # 降落：允许最大触地垂直速度 (m/s)
const DEFAULT_ROLL_SPEED := 25.0        # 降落：允许最大停稳滑跑速度 (km/h)
const DEFAULT_REWARD := 5               # 成功奖励绿宝石

@export var id: String = ""
@export var title: String = ""
@export var type: int = Type.TAKEOFF
## CIRCUIT：按顺序经过的世界坐标（按水平 xz 距离判定）。
@export var waypoints: Array[Vector3] = []
## LANDING：降落区中心（按水平 xz 距离判定是否停在区内）。
@export var zone_center: Vector3 = Vector3.ZERO
@export var params: Dictionary = {}

func target_altitude() -> float:
	return float(params.get("target_alt", DEFAULT_TARGET_ALT))

func min_speed() -> float:
	return float(params.get("min_speed", DEFAULT_MIN_SPEED))

func radius() -> float:
	return float(params.get("radius", DEFAULT_RADIUS))

func zone_radius() -> float:
	return float(params.get("zone_radius", DEFAULT_ZONE_RADIUS))

func max_touchdown_vs() -> float:
	return float(params.get("max_touchdown_vs", DEFAULT_TOUCHDOWN_VS))

func max_roll_speed() -> float:
	return float(params.get("max_roll_speed", DEFAULT_ROLL_SPEED))

func reward_emeralds() -> int:
	return int(params.get("reward", DEFAULT_REWARD))


## MVP 三任务预设（起飞 / 绕点 / 降落），Phase 3b 试飞闭环与 HUD 任务面板共用。
static func default_missions() -> Array[MissionData]:
	var takeoff := MissionData.new()
	takeoff.id = "m_takeoff"
	takeoff.title = "初次起飞"
	takeoff.type = Type.TAKEOFF
	takeoff.params = {"target_alt": DEFAULT_TARGET_ALT, "min_speed": DEFAULT_MIN_SPEED}

	var circuit := MissionData.new()
	circuit.id = "m_circuit"
	circuit.title = "绕点巡航"
	circuit.type = Type.CIRCUIT
	circuit.waypoints = [
		Vector3(0, 0, 150), Vector3(200, 0, 150),
		Vector3(200, 0, 0), Vector3(0, 0, 0),
	]
	circuit.params = {"radius": DEFAULT_RADIUS}

	var landing := MissionData.new()
	landing.id = "m_landing"
	landing.title = "平稳降落"
	landing.type = Type.LANDING
	landing.zone_center = Vector3(0, 0, 0)
	landing.params = {
		"zone_radius": DEFAULT_ZONE_RADIUS,
		"max_touchdown_vs": DEFAULT_TOUCHDOWN_VS,
		"max_roll_speed": DEFAULT_ROLL_SPEED,
	}
	return [takeoff, circuit, landing]


## 锚定到给定中心（机场跑道中心，或非机场区域的出生点）的 MVP 三任务：
## 降落区落在锚点、绕点航路为绕锚点的矩形，使「起飞 → 绕场 → 落回」闭环贴合实际机场位置。
## 只取 center 的 xz（y 忽略）。传 Vector3.ZERO 时退化为绕原点的旧预设形状。
static func missions_for_airport(center: Vector3) -> Array[MissionData]:
	var cx := center.x
	var cz := center.z

	var takeoff := MissionData.new()
	takeoff.id = "m_takeoff"
	takeoff.title = "初次起飞"
	takeoff.type = Type.TAKEOFF
	takeoff.params = {"target_alt": DEFAULT_TARGET_ALT, "min_speed": DEFAULT_MIN_SPEED}

	var circuit := MissionData.new()
	circuit.id = "m_circuit"
	circuit.title = "绕场巡航"
	circuit.type = Type.CIRCUIT
	# 绕机场的矩形航路（西南→东南→东北→西北，顺时针一圈）。
	circuit.waypoints = [
		Vector3(cx - 100.0, 0.0, cz - 75.0),
		Vector3(cx + 100.0, 0.0, cz - 75.0),
		Vector3(cx + 100.0, 0.0, cz + 75.0),
		Vector3(cx - 100.0, 0.0, cz + 75.0),
	]
	circuit.params = {"radius": DEFAULT_RADIUS}

	var landing := MissionData.new()
	landing.id = "m_landing"
	landing.title = "平稳降落"
	landing.type = Type.LANDING
	landing.zone_center = Vector3(cx, 0.0, cz)  # 落回机场跑道区
	landing.params = {
		"zone_radius": DEFAULT_ZONE_RADIUS,
		"max_touchdown_vs": DEFAULT_TOUCHDOWN_VS,
		"max_roll_speed": DEFAULT_ROLL_SPEED,
	}
	return [takeoff, circuit, landing]
