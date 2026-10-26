class_name MissionData
extends Resource

## 飞行任务静态定义（数据驱动，可 JSON / .tres 存档扩展）。
## MVP 三种任务：起飞 / 绕点 / 降落——对应「建造→试飞→任务→奖励」闭环里的「任务」段。
##
## 与 QuestData（元进度：成就/新手链）区分：MissionData 是单次飞行挑战的
## 运行时参数与评分口径；完成后的奖励（绿宝石）由外部结算进玩家货币，
## 经 ProgressManager 驱动零件解锁（见 Phase 3c）。

enum Type { TAKEOFF, CIRCUIT, LANDING }

const DEFAULT_TARGET_ALT := 40.0        # 起飞：目标离地高度 (m)（D-073：30→40 用户定稿，配 P2a 谷地与 FD 爬升剖面，给悬崖顶航点留余量）
const DEFAULT_MIN_SPEED := 40.0         # 起飞：最低安全空速 (km/h)
const DEFAULT_RADIUS := 30.0            # 绕点：判定半径 (m)
const DEFAULT_ZONE_RADIUS := 50.0       # 降落：降落区半径 (m)
const DEFAULT_TOUCHDOWN_VS := 3.0       # 降落：允许最大触地垂直速度 (m/s)
## D-072：绕场巡航层高度（m，相对跑道面）。机场口袋外 200~500 m 即有
## 120~150 m 高差的山体，30 m 平飞习惯必撞；80 m 巡航层配 FD 10° 爬升
## 与（后续 P2）近场限高后，孩子在高处飞才有余量。
const CIRCUIT_ALT := 80.0
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


## LANDING：降落区要求的地面方块（-1 = 不限定）。锚定机场/降落场的任务
## 要求停在 COBBLESTONE 跑道面上——落进旁边草地或水里不算完成。
func zone_block() -> int:
	return int(params.get("zone_block", -1))

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
	# center 契约（D-072）：x/z = 机场中心，**y = 跑道面高度**（main.gd 传
	# builder.base_y + 1）。历史版本 y=0，航点全埋在地下 29 m——FD 进近段按
	# 3° 下滑道修正到地下点、3D 目标环埋在地下，见 D-072 根因②。
	var cx := center.x
	var cz := center.z
	var cy := center.y + CIRCUIT_ALT   # 绕场巡航层（MSL）

	var takeoff := MissionData.new()
	takeoff.id = "m_takeoff"
	takeoff.title = "初次起飞"
	takeoff.type = Type.TAKEOFF
	takeoff.params = {"target_alt": DEFAULT_TARGET_ALT, "min_speed": DEFAULT_MIN_SPEED}

	var circuit := MissionData.new()
	circuit.id = "m_circuit"
	circuit.title = "绕场巡航"
	circuit.type = Type.CIRCUIT
	# 跑道朝向 +Z 的单向进场矩形（起飞越过北端 → 侧风 → 南端外侧风 →
	# 回到中线）：末航点落在跑道中线上，最后一程即直线进场，对准跑道。
	# D-072：航点高度 = 跑道面 + CIRCUIT_ALT（80 m 巡航层）。MissionManager
	# 只按 xz 判定捕获（mission_manager.gd _step_circuit），高度不改变捕获；
	# 它修好的是 FD 下滑道参照与 3D 目标环的可见性（此前 y=0 埋在地下）。
	# D-073：半径 90/110 → 120（用户定稿「绕场半径扩到 120 m」）。120 m 仍在
	# P2a 谷地（VALLEY_R 300）内——四边都是平野；配 P2b 地形前视预警，出谷
	# 边缘前有「前方有山」提示。
	circuit.waypoints = [
		Vector3(cx, cy, cz + 120.0),
		Vector3(cx + 120.0, cy, cz + 120.0),
		Vector3(cx + 120.0, cy, cz - 120.0),
		Vector3(cx, cy, cz - 120.0),
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
		"zone_block": BlockTypes.Block.COBBLESTONE,  # 必须停在跑道面上
	}
	return [takeoff, circuit, landing]
