extends Node3D
class_name DayNightCycle
## 简单昼夜循环：白天 10 分钟，夜晚 5 分钟，控制方向光角度/颜色/强度。
## 同时调制环境光与背景色：仅压暗方向光不足以"入夜变黑"（环境光恒定会
## 把场景整体抬亮），夜晚须同步把环境光与天幕压至近黑。
## time_changed 每秒发射一次，供 HUD 刷新时钟，避免每帧刷新文本。

const DAY_LENGTH := 600.0
const NIGHT_LENGTH := 300.0
const FULL_CYCLE := DAY_LENGTH + NIGHT_LENGTH

# 场景默认环境参数（main.tscn 的 Environment），白天按此恢复。
const DAY_AMBIENT_ENERGY := 0.6
const DAY_AMBIENT_COLOR := Color(0.75, 0.78, 0.85)
const DAY_BACKGROUND_COLOR := Color(0.47, 0.68, 0.94)
# 日落边缘（sun=0）过渡色：与夜晚起始值衔接，避免黄昏瞬间跳变。
const DUSK_AMBIENT_COLOR := Color(0.30, 0.32, 0.45)
const DUSK_BACKGROUND_COLOR := Color(0.08, 0.10, 0.18)
# 夜晚目标值：环境光近黑、天幕深蓝近黑。
const NIGHT_AMBIENT_ENERGY := 0.08
const NIGHT_AMBIENT_COLOR := Color(0.18, 0.20, 0.36)
const NIGHT_BACKGROUND_COLOR := Color(0.02, 0.03, 0.08)

signal time_changed(day_percent: float, is_day: bool)

var _light: DirectionalLight3D
var _env: Environment
var _time := 0.0
var _last_emitted_second := -1


func setup(light: DirectionalLight3D) -> void:
	_light = light


func setup_environment(env: Environment) -> void:
	_env = env


func _process(delta: float) -> void:
	_time = fmod(_time + delta, FULL_CYCLE)
	_apply_lighting()
	var second := int(_time)
	if second != _last_emitted_second:
		_last_emitted_second = second
		time_changed.emit(_time / FULL_CYCLE, is_day())


func is_day() -> bool:
	return _time < DAY_LENGTH


func get_clock() -> String:
	var minutes := 0.0
	if _time < DAY_LENGTH:
		minutes = 360.0 + (_time / DAY_LENGTH) * 720.0
	else:
		minutes = 1080.0 + ((_time - DAY_LENGTH) / NIGHT_LENGTH) * 720.0
	minutes = fmod(minutes, 1440.0)

	var h := int(minutes / 60.0)
	var m := int(minutes) % 60
	return "%02d:%02d" % [h, m]


func _apply_lighting() -> void:
	if _light == null:
		return

	if is_day():
		var t := _time / DAY_LENGTH
		var sun := sin(PI * t)
		_light.rotation_degrees.x = lerpf(-85.0, -10.0, sun)
		_light.light_energy = maxf(lerpf(0.2, 1.0, sun), 0.2)
		_light.light_color = Color(1.0, 0.98, 0.92)
		if _env != null:
			# 环境光随日落渐暗并向暮色过渡，与夜晚起始值衔接不跳变。
			_env.ambient_light_energy = lerpf(0.35, DAY_AMBIENT_ENERGY, sun)
			_env.ambient_light_color = DAY_AMBIENT_COLOR.lerp(DUSK_AMBIENT_COLOR, 1.0 - sun)
			_env.background_color = DAY_BACKGROUND_COLOR.lerp(DUSK_BACKGROUND_COLOR, 1.0 - sun)
	else:
		var t := (_time - DAY_LENGTH) / NIGHT_LENGTH
		_light.rotation_degrees.x = -85.0
		_light.light_energy = lerpf(0.35, 0.06, t)
		_light.light_color = Color(0.55, 0.60, 0.85)
		if _env != null:
			# 夜晚：环境光与天幕压至近黑，保证"晚上天是黑的"可感知。
			# 渐暗在入夜前 40% 内完成，其余时间保持近黑，避免整夜缓慢变暗。
			var fade := minf(1.0, t / 0.4)
			_env.ambient_light_energy = lerpf(0.30, NIGHT_AMBIENT_ENERGY, fade)
			_env.ambient_light_color = DUSK_AMBIENT_COLOR.lerp(NIGHT_AMBIENT_COLOR, fade)
			_env.background_color = DUSK_BACKGROUND_COLOR.lerp(NIGHT_BACKGROUND_COLOR, fade)
