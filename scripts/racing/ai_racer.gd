class_name AiRacer
extends RefCounted
## 机器人赛车手的驾驶决策（纯逻辑，可无头测试）。
##
## 策略：沿中心线的前视点追线（lookahead 随速度增长），弯道按「转向误差」自动
## 收油/点刹。难度四档直接改变：极速上限、转向精度（噪声量）、犯错概率与恢复时间。
## 机器人不消耗真实燃料（spec.fuel_burn_lps = 0），也从不拉手刹。

const LOOKAHEAD_BASE := 10.0
const LOOKAHEAD_PER_SPEED := 0.9
const LOOKAHEAD_MIN := 12.0
const LOOKAHEAD_MAX := 46.0
const SEARCH_WINDOW := 24   # 每帧只在前方这么多采样点内找最近点（≈96 m）

var difficulty: Dictionary = {}
var layout: TrackLayout = null
var index := 0
var rng := RandomNumberGenerator.new()
var _mistake_left := 0.0
var _mistake_steer := 0.0
var _mistake_slow := 0.0


func setup(p_layout: TrackLayout, p_difficulty: Dictionary, p_seed: int) -> void:
	layout = p_layout
	difficulty = p_difficulty
	index = 0
	rng.seed = p_seed
	_mistake_left = 0.0
	_mistake_steer = 0.0
	_mistake_slow = 0.0


## 返回一帧输入 {throttle, brake, steer, handbrake}。
func think(car: CarPhysics, terrain: Dictionary, dt: float) -> Dictionary:
	if layout == null:
		return {"throttle": 0.0, "brake": 0.0, "steer": 0.0, "handbrake": false}
	var spd := car.speed()
	var at := Vector3(car.pos.x, 0.0, car.pos.y)
	index = layout.nearest_index_forward(index, at, SEARCH_WINDOW)

	# 前视点 → 期望朝向 → 转向误差
	var lookahead := clampf(LOOKAHEAD_BASE + spd * LOOKAHEAD_PER_SPEED, LOOKAHEAD_MIN, LOOKAHEAD_MAX)
	var ahead := index + int(round(lookahead / TrackLayout.SPACING))
	var target := layout.point(ahead)
	var to := Vector2(target.x - car.pos.x, target.z - car.pos.y)
	var desired := atan2(to.x, to.y)
	var err := wrapf(desired - car.heading, -PI, PI)

	var acc := float(difficulty.get("steering_accuracy", 0.8))
	# steer +1 = 向右，而 heading 增大 = 向左，故取负号。
	var steer := clampf(-err * (1.8 + 1.2 * acc), -1.0, 1.0)
	steer += rng.randf_range(-1.0, 1.0) * (1.0 - acc) * 0.25

	# 犯错：按概率进入一段「手抖 + 收油」的窗口，难度越高越少。
	if _mistake_left <= 0.0 and rng.randf() < float(difficulty.get("mistake_chance", 0.08)) * dt:
		_mistake_left = float(difficulty.get("reaction_time", 0.3))
		_mistake_steer = rng.randf_range(-0.5, 0.5)
		_mistake_slow = rng.randf_range(0.0, 0.35)
	if _mistake_left > 0.0:
		_mistake_left -= dt
		steer += _mistake_steer
	steer = clampf(steer, -1.0, 1.0)

	# 速度目标：难度系数 × 地形 × 弯道系数（弯越急越收油）。
	var corner := clampf(1.0 - absf(err) * 0.9, 0.35, 1.0)
	var target_speed := car.max_speed() \
		* float(difficulty.get("speed_factor", 0.85)) \
		* float(terrain.get("speed_factor", 1.0)) \
		* corner * (1.0 - _mistake_slow)
	var throttle := 0.0
	var brake := 0.0
	if spd < target_speed * 0.95:
		throttle = 1.0
	elif spd > target_speed * 1.12:
		brake = clampf((spd - target_speed) / maxf(target_speed, 1.0), 0.0, 1.0)

	return {"throttle": throttle, "brake": brake, "steer": steer, "handbrake": false}
