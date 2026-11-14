extends Node
## 座舱抖动幅度钉死探针（D-075，无头，纯逻辑）：钉住「座舱一直在抖」修复的幅度契约。
##
## 为什么是无头纯逻辑：幅度是数据，不看画面。构造式喂帧——直接 `Aircraft.new()`
## （不实例化 main.tscn，项目踩坑 #22：--script 不加载 Autoload，探针场景方式才安全），
## 把飞行状态写进它的 _state，再调 `shake_envelope()` 读包络。沿用 stall_coach_probe
## 的「AircraftFlight.State.new() + AircraftFlight._refresh_readings()」喂帧法。
##
## 幅度单位 m，与 aircraft_camera.gd 的乘子同源派生：单轴峰值 = SHAKE_AMP × 1.5 × envelope
## （= 满幅 envelope=1.0 时的世界系位移；座舱内视还会再乘 COCKPIT_SHAKE_SCALE，但该乘子
## 现由 A7 直接钉住为 0.0（D-097）；本探针仍只守「包络不越界」这一上界，两者互补）。

var _pass := 0
var _fail := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: " + msg)
		_pass += 1
	else:
		print("FAIL: " + msg)
		_fail += 1


## 峰值单轴幅度（m）= SHAKE_AMP × 1.5 × envelope。与 aircraft_camera 的乘子一致。
static func _amp(craft: Aircraft) -> float:
	return AircraftCamera.SHAKE_AMP * 1.5 * craft.shake_envelope()


## 旧公式（修复前：唯二输入 = engine_running + 油门），用于反向对照——证明下面的
## 断言是真正的回归闸，去掉修复后会确实报错。
static func _old_amp(throttle: float) -> float:
	return AircraftCamera.SHAKE_AMP * 1.5 * (0.25 + 0.75 * throttle)


func _ready() -> void:
	_run()
	print("COCKPIT_SHAKE_TEST_DONE fails=%d" % _fail)
	if _fail > 0:
		print("COCKPIT_SHAKE_TEST_FAILED")
	else:
		print("COCKPIT_SHAKE_TEST_OK")
	get_tree().quit(0 if _fail == 0 else 1)


func _run() -> void:
	# 守护：幅度派生基准与相机一致（SHAKE_AMP 改了，上界 0.075 也要跟着改）。
	_check(absf(AircraftCamera.SHAKE_AMP - 0.05) < 1e-6,
		"A0 相机 SHAKE_AMP==0.05（上界 0.075 m = 0.05×1.5 的派生基准）")

	# A7（D-097）：补上 D-075 探针排除在契约外的乘子——座舱内视位置抖动收敛为 0。
	_check(absf(AircraftCamera.COCKPIT_SHAKE_SCALE) < 1e-6,
		"A7 座舱内视位置抖动收敛为 0（D-097：红圈闪边根治）")

	# ── 正向断言 ──
	# ① 停放怠速 / 收油门：无功率、无抖振、无切变、不计地面 ⇒ 包络恒 0。
	#    旧版的 0.25 怠速地板正是「停着也在抖」的根；去掉修复会 FAIL 本条。
	var idle := Aircraft.new()
	idle.controls.throttle = 0.0
	idle._state.velocity = Vector3.ZERO
	AircraftFlight._refresh_readings(idle._state, false)
	_check(idle.shake_envelope() == 0.0,
		"A1 怠速/收油门（无功率无抖振无切变）包络 == 0（修复前此情景为 0.25）")

	# ② 巡航平飞：40 m/s、油门 0.6、水平 ⇒ 幅度须远小于旧版 0.0525 m。
	var cruise := Aircraft.new()
	cruise.controls.throttle = 0.6
	cruise._state.velocity = -cruise._state.basis.z * 40.0
	AircraftFlight._refresh_readings(cruise._state, false)
	var a_cruise := _amp(cruise)
	_check(a_cruise <= 0.02,
		"A2 巡航(40 m/s, 油门0.6) 幅度 %.4f m ≤ 0.02（旧版 %.4f）" % [a_cruise, _old_amp(0.6)])

	# ③ 失速告警：大迎角（α≈0.30 > STALL_WARN_ALPHA 0.27）+ 速度>3 + 离地。
	var stall := Aircraft.new()
	stall.controls.throttle = 0.3
	var spd := 25.0
	# 机头 -Z、略下沉 ⇒ 机身相对气流来自下方 ⇒ 正迎角。
	stall._state.velocity = Vector3(0.0, -sin(0.30) * spd, -cos(0.30) * spd)
	AircraftFlight._refresh_readings(stall._state, false)
	_check(stall._state.stall_warning, "A3a 构造态 stall_warning==true（α≈0.30, v=%d）" % int(spd))
	var a_stall := _amp(stall)
	_check(a_stall >= 0.015,
		"A3b 失速告警 幅度 %.4f m ≥ 0.015（buffet 通道生效）" % a_stall)

	# ④ 风切变瞬态：直写 WindModel（与 wind_flight_probe 同法），is_shear_active 为真。
	var shear := Aircraft.new()
	shear.controls.throttle = 0.6
	shear._state.velocity = -shear._state.basis.z * 40.0
	AircraftFlight._refresh_readings(shear._state, false)
	shear._wind.inject_shear(Vector3(5.0, 0.0, 0.0), 8.0)
	_check(shear._wind.is_shear_active(), "A4a 注入切变后 is_shear_active==true")
	var a_shear := _amp(shear)
	_check(a_shear >= 0.015,
		"A4b 风切变 幅度 %.4f m ≥ 0.015（气象通道生效）" % a_shear)

	# ⑤ 上界守卫：任何状态幅度 ≤ 0.075 m（= 满幅，绝不允许比修复前更大）。
	#    扫一批极端组合，含：地面满油门静止 / 满油门高速 / 失速+切变+高G / 低空强切变。
	var worst := 0.0
	for combo: Aircraft in _extreme_states():
		worst = maxf(worst, _amp(combo))
		combo.free()
	_check(worst <= 0.075 + 1e-9,
		"A5 各极端组合幅度上界 %.4f m ≤ 0.075（不大于修复前满幅）" % worst)
	_check(idle.shake_envelope() <= 1.0 and cruise.shake_envelope() <= 1.0,
		"A6 包络本身恒 ≤ 1.0（amp 派生不会超 0.075）")
	idle.free()
	cruise.free()
	stall.free()
	shear.free()

	# ── 反向对照（去掉修复后应确实报错：非空闸）──
	# B1：旧怠速幅度 >0 ⇒ 若回退旧公式，A1 必红。
	_check(_old_amp(0.0) > 0.0,
		"B1 旧公式下怠速幅度 %.4f m > 0（去掉修复 A1 必红：非空闸）" % _old_amp(0.0))
	# B2：旧巡航幅度 > A2 阈值 ⇒ 若回退，A2 必红。
	_check(_old_amp(0.6) > 0.02,
		"B2 旧公式下巡航幅度 %.4f m > 0.02（去掉修复 A2 必红）" % _old_amp(0.6))
	# B3：旧满幅恰等于上界 ⇒ A5 上界是「不收紧」而非凭空放宽（旧满油门仍 ≤0.075）。
	_check(_old_amp(1.0) <= 0.075 + 1e-9,
		"B3 旧满幅 %.4f m == 上界 0.075（A5 守卫不凭空收紧）" % _old_amp(1.0))


## 极端状态组合（不加入树、用后即 free）。
func _extreme_states() -> Array[Aircraft]:
	var arr: Array[Aircraft] = []
	# 地面满油门静止（envelope 最坏点之一，cockpit3d_shot ⑦ 依赖）。
	var a1 := Aircraft.new()
	a1.controls.throttle = 1.0
	a1._state.velocity = Vector3.ZERO
	AircraftFlight._refresh_readings(a1._state, false)
	arr.append(a1)
	# 满油门 + 高速巡航（空速衰减降到最低，但仍 ≤1.0）。
	var a2 := Aircraft.new()
	a2.controls.throttle = 1.0
	a2._state.velocity = -a2._state.basis.z * 55.0
	AircraftFlight._refresh_readings(a2._state, false)
	arr.append(a2)
	# 失速 + 切变 + 高 G（多分量叠加，应被钳在 1.0）。
	var a3 := Aircraft.new()
	a3.controls.throttle = 1.0
	a3._state.velocity = Vector3(0.0, -sin(0.31) * 30.0, -cos(0.31) * 30.0)
	AircraftFlight._refresh_readings(a3._state, false)
	a3._wind.inject_shear(Vector3(8.0, 0.0, 0.0), 8.0)
	a3._state.load_factor = 4.0   # 直接注 G（盘旋/拉升极值），_refresh_readings 之后覆盖。
	arr.append(a3)
	# 低空强切变 + 满油门。
	var a4 := Aircraft.new()
	a4.controls.throttle = 1.0
	a4._state.velocity = -a4._state.basis.z * 40.0
	AircraftFlight._refresh_readings(a4._state, false)
	a4._wind.inject_shear(Vector3(10.0, 0.0, 0.0), 8.0)
	arr.append(a4)
	return arr
