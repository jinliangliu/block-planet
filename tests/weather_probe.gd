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

	# ── D-093 天空（BG_SKY + ProceduralSkyMaterial）──────────────────
	# 构造前置：main.tscn 的 Environment_main 显式 fog_enabled=true，而本探针用的是
	# Environment.new()（默认 false）。先置回主场景同款，后面经过整轮天气/时间切换
	# 后仍应为真，证明 setup_environment 与 _apply_lighting 都没把距离雾关掉。
	env.fog_enabled = true
	_check(env.sky != null, "D-093 setup_environment 从空 Environment 建出 Sky")
	_check(env.background_mode == Environment.BG_SKY, "D-093 背景模式切到 BG_SKY")
	_check(env.fog_sky_affect == 0.0, "D-093 fog_sky_affect 归零（灰屏根因）")
	_check(dn._sky_mat != null, "D-093 _sky_mat 非空")
	_check(dn._sky_mat != null and dn._sky_mat.sky_cover is NoiseTexture2D,
		"D-093 云纹为纯代码 NoiseTexture2D")
	_check(env.sky.sky_material is ProceduralSkyMaterial,
		"D-093 sky_material 为 ProceduralSkyMaterial")

	# 三档天气：云调制色与天顶色亮度，晴 > 阴 > 雨。
	# 阶段 B 精修：云调制现含昼夜系数，故把三档比较钉在正午(sun=1、系数=1.0)，
	# 排除时间插值干扰，使比较只反映天气表本身。
	dn.set_weather(DayNightCycle.Weather.CLEAR)
	dn._time = DayNightCycle.DAY_LENGTH * 0.5
	dn._apply_lighting()
	var mod_clear := dn._sky_mat.sky_cover_modulate
	var v_clear := dn._sky_mat.sky_top_color.v
	dn.set_weather(DayNightCycle.Weather.CLOUDY)
	var mod_cloudy := dn._sky_mat.sky_cover_modulate
	var v_cloudy := dn._sky_mat.sky_top_color.v
	dn.set_weather(DayNightCycle.Weather.RAIN)
	var mod_rain := dn._sky_mat.sky_cover_modulate
	var v_rain := dn._sky_mat.sky_top_color.v
	_check(mod_clear.v > mod_cloudy.v and mod_cloudy.v > mod_rain.v,
		"D-093 云调制亮度 晴>阴>雨（%.3f>%.3f>%.3f）" % [mod_clear.v, mod_cloudy.v, mod_rain.v])
	_check(v_clear > v_cloudy and v_cloudy > v_rain,
		"D-093 天顶亮度 晴>阴>雨（%.3f>%.3f>%.3f）" % [v_clear, v_cloudy, v_rain])
	dn.set_weather(DayNightCycle.Weather.CLEAR)
	_check(dn._sky_mat.sky_cover_modulate == mod_clear,
		"D-093 换回 CLEAR 后云调制复原")

	# 正午/午夜：天顶 + 云调制双比（阶段 B 新增「午夜云调制明显小于正午」防
	# 夜晚亮云地板回归）。时间与天气钉在 CLEAR 正午/午夜，排除天气表差异。
	dn.set_weather(DayNightCycle.Weather.CLEAR)
	dn._time = DayNightCycle.DAY_LENGTH * 0.5
	dn._apply_lighting()
	var v_noon := dn._sky_mat.sky_top_color.v
	var mod_noon := dn._sky_mat.sky_cover_modulate
	dn._time = DayNightCycle.DAY_LENGTH + DayNightCycle.NIGHT_LENGTH * 0.5
	dn._apply_lighting()
	var v_midnight := dn._sky_mat.sky_top_color.v
	var mod_midnight := dn._sky_mat.sky_cover_modulate
	_check(v_midnight < v_noon - 0.05,
		"D-093 午夜天顶明显暗于正午（%.3f < %.3f）" % [v_midnight, v_noon])
	_check(mod_midnight.v < mod_noon.v - 0.05,
		"D-093 午夜云调制亮度明显小于正午（%.3f < %.3f，夜晚云不铺亮色地板）"
			% [mod_midnight.v, mod_noon.v])

	# 空 Environment 守卫：独立实例 + sky=null 的新环境，从零建天空不崩。
	var dn2 := DayNightCycle.new()
	var env2 := Environment.new()
	dn2.setup_environment(env2)
	_check(env2.sky != null and dn2._sky_mat != null,
		"D-093 空 Environment 守卫：独立实例从零建天空不崩")
	dn2.free()

	# 整轮天气/时间切换后，距离雾仍为真（D-090 保留）。
	_check(env.fog_enabled == true, "D-093 距离雾保留（整轮切换后 fog_enabled 仍为真）")

	# 恢复时间与天气再收尾。
	dn._time = 0.0
	dn.set_weather(DayNightCycle.Weather.CLEAR)

	print("WEATHER_DONE fails=%d" % _fail)
	if _fail > 0:
		print("WEATHER_FAIL")
	else:
		print("WEATHER_OK")
	get_tree().quit()
