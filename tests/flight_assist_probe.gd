extends Node
## 被动高度保持 Gap B 回归探针（D-074）：验证玩家松俯仰杆时，辅助层把俯仰
## 柔和配平到「保持当前高度」（抵消垂直速度漂移），且难度联动正确
## （休闲/标准开、硬核关）。纯逻辑：直接驱动 AircraftFlight.integrate。
##
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/flight_assist_probe.tscn

var _failed := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	SaveGuard.snapshot()
	_build_and_check()
	SaveGuard.restore()
	_finish()


## 构造：海拔 200 m 水平巡航基线 + 给定垂直速度扰动，松杆（pitch=0）。
func _make_state(vy: float) -> AircraftFlight.State:
	var s := AircraftFlight.make_state(Vector3(0.0, 200.0, 0.0))
	s.velocity = Vector3(0.0, vy, -40.0)
	s.basis = Basis.from_euler(Vector3(0.0, 0.0, 0.0))
	return s


func _neutral_controls() -> AircraftFlight.Controls:
	var c := AircraftFlight.Controls.new()
	c.throttle = 1.0
	c.pitch = 0.0
	c.roll = 0.0
	c.yaw = 0.0
	return c


func _build_and_check() -> void:
	# ── 难度联动（钉死 set_difficulty 的被动高度保持开关）──
	_check(FlightSettings.for_difficulty(FlightSettings.Difficulty.NORMAL).passive_altitude_hold,
		"难度联动：标准档被动高度保持开")
	_check(FlightSettings.for_difficulty(FlightSettings.Difficulty.EXPERT).passive_altitude_hold == false,
		"难度联动：硬核档被动高度保持关")

	# ── 单步符号闸：松杆 + 爬升（vy>0）→ 低头修正（pitch_rate < 0）──
	var s_up := _make_state(5.0)
	AircraftFlight.integrate(s_up, _neutral_controls(), 1.0 / 60.0, false, {}, 0.0, true)
	_check(s_up.pitch_rate < 0.0,
		"单步：爬升松杆 → 低头修正（pitch_rate=%.4f < 0）" % s_up.pitch_rate)

	# ── 单步符号闸：松杆 + 下沉（vy<0）→ 抬头修正（pitch_rate > 0）──
	var s_dn := _make_state(-5.0)
	AircraftFlight.integrate(s_dn, _neutral_controls(), 1.0 / 60.0, false, {}, 0.0, true)
	_check(s_dn.pitch_rate > 0.0,
		"单步：下沉松杆 → 抬头修正（pitch_rate=%.4f > 0）" % s_dn.pitch_rate)

	# ── 对照：松杆 + 关闭保持 → 不施加俯仰修正（pitch_rate 恒 0）──
	var s_off := _make_state(5.0)
	AircraftFlight.integrate(s_off, _neutral_controls(), 1.0 / 60.0, false, {}, 0.0, false)
	_check(absf(s_off.pitch_rate) < 1e-9,
		"对照：关闭保持时松杆无俯仰修正（pitch_rate=%.2f）" % s_off.pitch_rate)

	# ── 收敛闸（短窗 1 s，避开通量振荡）：持续松杆 + 开启保持，垂直速度
	#    应被拉回、机头朝抵消 VS 的方向压低（爬升起始 → pitch < 0）。──
	var vy0 := 5.0
	var s_on := _make_state(vy0)
	var c_on := _neutral_controls()
	for i in range(60):  # 1 s @60fps
		AircraftFlight.integrate(s_on, c_on, 1.0 / 60.0, false, {}, 0.0, true)
	_check(absf(s_on.velocity.y) < absf(vy0) * 0.5,
		"收敛：开启保持 1 s 后 |VS| 减半以上（%.2f → %.2f m/s）" % [vy0, s_on.velocity.y])


func _finish() -> void:
	if _failed == 0:
		print("FLIGHT_ASSIST_PROBE_OK")
		get_tree().quit(0)
	else:
		print("FLIGHT_ASSIST_PROBE_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
