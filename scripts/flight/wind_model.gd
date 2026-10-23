class_name WindModel
extends RefCounted
## 飞行气象的风层（任务书 §2.1 地面风 + 风梯度 / §2.2 风切变，D-067）。
##
## 纯逻辑无节点：被 Aircraft 每帧驱动，也可在无头探针里直接 new()。三条设计约束：
## 1. **只出风矢量，不改气动公式**——风由 aircraft_flight 以
##    `air_velocity = velocity − wind` 的形式进入气动，升力/失速/解体判定全部走
##    既有链路（任务书 §2.2：直接改 linear_velocity 会破坏气动自洽，是错的）。
## 2. **切变是随机剧本，不是必然事件**：概率取自区域 weather_profile
##    （RegionAtlas），低空门控 + 冷却防「全程在切」；登机后有一段静默期。
## 3. **可复现**：configure() 收种子，同种子同剧本（与 day_night 固定
##    WEATHER_CYCLE 同精神）；另给 inject_shear() 供探针/剧本精确注入。
##
## 尺度：1 格 = 1 m（D-063）。本作巡航 50~90 m AGL，梯度封顶取 120 m。
## 调用节拍：update() 每物理帧由 Aircraft 调用——触发概率按「每秒」计（乘
## delta），帧长无关；agl 用调用方的测高缓存值（射线在 Aircraft 侧 5 Hz 节流，
## 不因此多打）。wind_at() 每帧一次（O(1)，无分配）。

## 切变触发高度门（m）：只在 AGL < 此值的低空带里掷概率（任务书 §1）。
const SHEAR_AGL_MAX := 45.0
## 风梯度封顶高度（m）：此高度以上风不再增强。
const GRADIENT_TOP := 120.0
## 高空风倍数：风随 AGL 从地面值线性升到该倍数（任务书 §2.1）。
const GRADIENT_FACTOR := 3.0
## 单次切变持续（s）：一次微暴过程的时长。
const SHEAR_DURATION := 8.0
## 切变后冷却（s）：防连续切变把玩家按在地上。
const SHEAR_COOLDOWN := 60.0
## 切变阵风系数：切变风强度 = 当前梯度风 × 该倍数。
const SHEAR_GUST_MUL := 2.5
## 切变下沉气流上限（m/s）：y 负分量，即任务书 §2.2 的 downdraft。
const DOWNDRAFT_MAX := 6.0
## 风向慢漂移幅度（rad）：基准风向往复摆动（约 ±23°），免得风像钉死一样。
const DIR_DRIFT_AMP := 0.4
## 风向漂移周期（s）。
const DIR_DRIFT_PERIOD := 90.0
## shear_probability = 1.0 对应的每秒触发概率：0.02 → 太平洋(0.6) 约每 80 s 一次。
const SHEAR_P_PER_SEC := 0.02
## 开局静默（s）：登机后先给一段安稳风，别还没起飞就切。
const SHEAR_GRACE := 20.0
## 默认风参数：region profile 缺项时用（与 RegionAtlas.DEFAULT_WEATHER_PROFILE 同值）。
const DEFAULT_SURFACE := 3.0
const DEFAULT_SHEAR_P := 0.15

var _surface := DEFAULT_SURFACE
var _shear_p := DEFAULT_SHEAR_P
var _base_angle := 0.0
var _agl := 0.0
var _enabled := true
var _elapsed := 0.0
var _shear_vec := Vector3.ZERO
var _shear_left := 0.0
var _cooldown := SHEAR_GRACE
var _rng := RandomNumberGenerator.new()


## 配置区域风参数。profile 缺项退默认（与 RegionAtlas.weather_profile_of 的
## 双保险）；seed_value 决定基准风向与全部随机剧本——同种子同剧本。
func configure(profile: Dictionary, seed_value: int = 0) -> void:
	_surface = clampf(float(profile.get("surface_wind_mps", DEFAULT_SURFACE)), 0.0, 20.0)
	_shear_p = clampf(float(profile.get("shear_probability", DEFAULT_SHEAR_P)), 0.0, 1.0)
	_rng.seed = seed_value
	_base_angle = _rng.randf() * TAU
	_elapsed = 0.0
	_shear_vec = Vector3.ZERO
	_shear_left = 0.0
	_cooldown = SHEAR_GRACE
	_agl = 0.0


func set_enabled(on: bool) -> void:
	_enabled = on
	if not on:
		_shear_vec = Vector3.ZERO
		_shear_left = 0.0


func is_enabled() -> bool:
	return _enabled


## 推进风场（调用方每物理帧调）：刷新 agl、推进切变状态机与冷却。
## 触发概率 = shear_probability × SHEAR_P_PER_SEC × delta（每秒概率，
## 帧长无关；delta 很大时概率 >1 也无所谓——该触发就触发）。
func update(delta: float, agl: float) -> void:
	_agl = maxf(agl, 0.0)
	_elapsed += delta
	if not _enabled:
		return
	if _shear_left > 0.0:
		_shear_left -= delta
		if _shear_left <= 0.0:
			_shear_vec = Vector3.ZERO
		return
	if _cooldown > 0.0:
		_cooldown -= delta
		return
	if _agl >= SHEAR_AGL_MAX:
		return
	if _rng.randf() < _shear_p * SHEAR_P_PER_SEC * delta:
		_roll_shear()


## 当前风矢量（地速系，m/s）：每帧调用。切变期间返回切变风（含 downdraft），
## 否则返回梯度风；关闭时恒零。
func wind_at() -> Vector3:
	if not _enabled:
		return Vector3.ZERO
	if _shear_left > 0.0:
		return _shear_vec
	return _gradient_wind()


## 注入一次切变（探针/剧本用）：vec 为**绝对**风矢量（含下沉气流时 y 为负）。
## 注入会重置冷却——手动剧本不与随机剧本叠着来。
func inject_shear(vec: Vector3, duration: float = SHEAR_DURATION) -> void:
	_shear_vec = vec
	_shear_left = duration
	_cooldown = SHEAR_COOLDOWN


func is_shear_active() -> bool:
	return _shear_left > 0.0


func surface_speed() -> float:
	return _surface


func shear_probability() -> float:
	return _shear_p


## 当前 agl 缓存（探针观测用；真实 AGL 由调用方的射线给出）。
func cached_agl() -> float:
	return _agl


func _gradient_wind() -> Vector3:
	# 风向 = 基准角 + 慢漂移（正弦往复）。a=0 → (0,0,1) = 朝 +Z（北）。
	var drift: float = sin(_elapsed / DIR_DRIFT_PERIOD * TAU) * DIR_DRIFT_AMP
	var a: float = _base_angle + drift
	var grad: float = lerpf(1.0, GRADIENT_FACTOR, clampf(_agl / GRADIENT_TOP, 0.0, 1.0))
	var speed: float = _surface * grad
	return Vector3(sin(a), 0.0, cos(a)) * speed


func _roll_shear() -> void:
	var base := _gradient_wind()
	# 切变三件事：风向急转（±60°~120°）、强度倍增、加下沉气流。
	var turn: float = (0.33 + _rng.randf() * 0.67) * PI \
		* (1.0 if _rng.randf() < 0.5 else -1.0)
	var a: float = atan2(base.x, base.z) + turn
	var speed: float = maxf(base.length(), _surface) * SHEAR_GUST_MUL
	# 一半概率做成「逆风突减型」微暴：强度先砍半再转向——真实微暴的两副面孔，
	# 逆风突减对起飞未减速的飞机会更毒（空速骤掉）。
	if _rng.randf() < 0.5:
		speed *= 0.5
	var down: float = -_rng.randf() * DOWNDRAFT_MAX
	_shear_vec = Vector3(sin(a), down, cos(a)) * speed
	_shear_left = SHEAR_DURATION
	_cooldown = SHEAR_COOLDOWN
