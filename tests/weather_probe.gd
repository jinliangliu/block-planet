extends Node

## 无头验证 DayNightCycle 的天气（Phase 5-d）：晴/阴/雨 对环境光的压暗乘算、
## 雨幕粒子开关、天气名映射、手动钉住与交回自动轮换。

var _pass := 0
var _fail := 0


func _check(cond, msg) -> void:
	if cond:
		print("PASS: " + msg)
		_pass += 1
	else:
		print("FAIL: " + msg)
		_fail += 1


func _ready() -> void:
	var dn := DayNightCycle.new()
	add_child(dn)
	var light := DirectionalLight3D.new()
	add_child(light)
	dn.setup(light)
	var env := Environment.new()
	dn.setup_environment(env)
	await get_tree().process_frame

	# 天气名映射。
	dn.set_weather(DayNightCycle.Weather.CLEAR)
	_check(dn.get_weather() == DayNightCycle.Weather.CLEAR and dn.weather_name() == "晴", "晴天")
	dn.set_weather(DayNightCycle.Weather.CLOUDY)
	_check(dn.weather_name() == "阴", "阴天")
	dn.set_weather(DayNightCycle.Weather.RAIN)
	_check(dn.weather_name() == "雨", "雨天")

	# 环境光乘算：晴 > 阴 > 雨（同一时刻，只差天气乘数）。
	dn.set_weather(DayNightCycle.Weather.CLEAR)
	var e_clear := env.ambient_light_energy
	dn.set_weather(DayNightCycle.Weather.CLOUDY)
	var e_cloudy := env.ambient_light_energy
	dn.set_weather(DayNightCycle.Weather.RAIN)
	var e_rain := env.ambient_light_energy
	_check(e_clear > e_cloudy and e_cloudy > e_rain,
		"环境光随天气压暗（晴 %.3f > 阴 %.3f > 雨 %.3f）" % [e_clear, e_cloudy, e_rain])

	# 雨幕粒子：雨天开启、非雨关闭。
	dn.set_weather(DayNightCycle.Weather.RAIN)
	dn._update_rain()
	_check(dn._rain.emitting, "雨天雨幕开启")
	dn.set_weather(DayNightCycle.Weather.CLEAR)
	dn._update_rain()
	_check(not dn._rain.emitting, "晴天雨幕关闭")

	# 手动钉住 vs 自动轮换。
	dn.set_weather(DayNightCycle.Weather.RAIN)
	dn.advance_days(3)   # 跨过多个天气时段
	_check(dn.get_weather() == DayNightCycle.Weather.RAIN, "手动设定不被时间推进覆盖")
	dn.clear_weather_override()
	# 交回自动：应等于按 _elapsed 取的序列值。
	dn.advance_days(2)
	var auto_w := dn.get_weather()
	_check(auto_w in [DayNightCycle.Weather.CLEAR, DayNightCycle.Weather.CLOUDY, DayNightCycle.Weather.RAIN],
		"交回自动轮换返回合法天气（%s）" % dn.weather_name())
	# 越界夹回。
	dn.set_weather(99)
	_check(dn.get_weather() == DayNightCycle.Weather.RAIN, "越界天气索引夹回雨天")

	print("WEATHER_DONE fails=%d" % _fail)
	if _fail > 0:
		print("WEATHER_FAIL")
	else:
		print("WEATHER_OK")
	get_tree().quit()
