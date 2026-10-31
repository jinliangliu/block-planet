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

## 只减速侧橡皮筋的三段阈值（沿赛道米数，正 = AI 领先玩家）。
## 30 m 以内属于贴身缠斗，不干预；领先到 150 m 才减到最低配速。
const PACE_GAP_FREE := 30.0
const PACE_GAP_MAX := 150.0
const PACE_MIN_BIAS := 0.82

var difficulty: Dictionary = {}
var layout: TrackLayout = null
var index := 0
var rng := RandomNumberGenerator.new()
## 场地极速（m/s，通常取玩家车的极速）：目标速度的超速上界。0 = 不启用归一。
## 没有它，AI 会拿自己车的极速算目标（racer 40 m/s 开 easy 系数 0.7 仍有 28 m/s），
## 于是孩子开 24 m/s 的小三轮永远追不上。
var field_top := 0.0
## 只减速侧橡皮筋系数（≤ 1.0，由 set_gap 写入）：领先越多收油越多，落后恒 1.0。
var pace_bias := 1.0
var _mistake_left := 0.0
var _mistake_steer := 0.0
var _mistake_slow := 0.0


## p_field_top 可选（默认 0 = 不归一），旧的 3 参调用照旧可用。
func setup(p_layout: TrackLayout, p_difficulty: Dictionary, p_seed: int,
		p_field_top: float = 0.0) -> void:
	layout = p_layout
	difficulty = p_difficulty
	index = 0
	rng.seed = p_seed
	field_top = maxf(p_field_top, 0.0)
	pace_bias = 1.0
	_mistake_left = 0.0
	_mistake_steer = 0.0
	_mistake_slow = 0.0


## 只减速侧橡皮筋：gap_m > 0 表示 AI 领先玩家（沿赛道米数）。
## 领先 30 m 以内不干预，30→150 m 线性降到 0.82，之后保持 0.82。
## 落后（gap_m < 0）恒返回 1.0 —— 绝不加速追赶，保证不越过玩家车的极速。
static func pace_bias_for(gap_m: float) -> float:
	if gap_m <= PACE_GAP_FREE:
		return 1.0
	if gap_m >= PACE_GAP_MAX:
		return PACE_MIN_BIAS
	var t := (gap_m - PACE_GAP_FREE) / (PACE_GAP_MAX - PACE_GAP_FREE)
	return lerpf(1.0, PACE_MIN_BIAS, t)


## 每帧由场景喂入「AI 进度 − 玩家进度」，刷新橡皮筋系数。
func set_gap(gap_m: float) -> void:
	pace_bias = pace_bias_for(gap_m)


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

	# 速度目标：配速归一后的极速 × 难度系数 × 地形 × 弯道系数（弯越急越收油）。
	# base_top 取「自己车极速」与「场地极速（玩家车极速）」的较小值——任何难度、
	# 任何 AI 车的目标速度都不会超过玩家车，孩子才追得上。
	var base_top := car.max_speed()
	if field_top > 0.0:
		base_top = minf(base_top, field_top)
	var corner := clampf(1.0 - absf(err) * 0.9, 0.35, 1.0)
	var target_speed := base_top \
		* float(difficulty.get("speed_factor", 0.85)) \
		* float(terrain.get("speed_factor", 1.0)) \
		* corner * (1.0 - _mistake_slow) * pace_bias
	var throttle := 0.0
	var brake := 0.0
	if spd < target_speed * 0.95:
		throttle = 1.0
	elif spd > target_speed * 1.12:
		brake = clampf((spd - target_speed) / maxf(target_speed, 1.0), 0.0, 1.0)

	return {"throttle": throttle, "brake": brake, "steer": steer, "handbrake": false}
