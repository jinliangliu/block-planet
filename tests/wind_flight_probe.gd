extends Node
## 飞行气象之风层契约探针（D-067 §2.1 地面风 + 风梯度 / §2.2 风切变）。
## 三段：A 风模型单元（梯度/漂移/开关/注入/门控/冷却/可复现）、B 气动端到端
## （同空速下顺风地速大、侧风偏流、空速/地速读数、切变掉高度与推油门改出）、
## C 数据与接线（11 区 profile、越界拒绝、Aircraft.setup_wind、设置开关）。
## 按 D-010 在首项检查前快照、退出前统一还原，PASS/FAIL 两条路径均不污染 user://。

const FRAME := 1.0 / 60.0
var _failed := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	SaveGuard.snapshot()
	_run_wind_model_checks()
	_run_aero_checks()
	_run_shear_checks()
	_run_data_checks()
	_finish()


# ── A 段：WindModel 单元 ────────────────────────────────────────

func _run_wind_model_checks() -> void:
	var w := WindModel.new()
	w.configure({"surface_wind_mps": 4.0, "shear_probability": 0.0}, 42)
	_check(is_instance_valid(w), "A1 WindModel 可直接构造配置")

	# 梯度：地面 = surface，GRADIENT_TOP 处 = surface×3，中点单调居中。
	var g0 := w.wind_at()
	w.update(0.1, 0.0)
	var low := w.wind_at()
	_check(absf(low.length() - 4.0) < 0.35, "A2 地面风≈surface（%.2f m/s）" % low.length())
	_check(absf(low.y) < 0.001, "A2 梯度风无垂直分量")
	w.update(0.1, WindModel.GRADIENT_TOP)
	var top := w.wind_at()
	_check(absf(top.length() - 12.0) < 0.6, "A3 梯度封顶处≈surface×3（%.2f m/s）" % top.length())
	w.update(0.1, WindModel.GRADIENT_TOP * 0.5)
	var mid := w.wind_at()
	_check(mid.length() > low.length() and mid.length() < top.length(),
		"A3 梯度随 AGL 单调增强（%.1f < %.1f < %.1f）" % [low.length(), mid.length(), top.length()])

	# 开关：关闭后恒零（探针与取证同用这条路径）。
	w.set_enabled(false)
	_check(w.wind_at() == Vector3.ZERO, "A4 关闭后风矢量恒零")
	w.set_enabled(true)
	_check(w.wind_at().length() > 0.1, "A4 重开恢复梯度风")

	# 注入：wind_at 精确等于注入矢量（含 downdraft 的 y 负分量）。
	var shear := Vector3(3.0, -5.0, 7.0)
	w.inject_shear(shear, 8.0)
	_check(w.is_shear_active(), "A5 注入后切变激活")
	_check(w.wind_at() == shear, "A5 切变期 wind_at 精确等于注入矢量")
	for i in range(20):
		w.update(0.5, 0.0)   # 10 s > 8 s 持续期
	_check(not w.is_shear_active(), "A6 切变到期自动退出")
	_check(w.wind_at().y == 0.0, "A6 退出后回梯度风（无 downdraft）")

	# 低空门控：高概率但 AGL ≥ 门限，长跑绝不触发。
	var high := WindModel.new()
	high.configure({"surface_wind_mps": 4.0, "shear_probability": 0.9}, 7)
	var ever := false
	for i in range(240):   # 24 s
		high.update(0.1, WindModel.SHEAR_AGL_MAX + 5.0)
		ever = ever or high.is_shear_active()
	_check(not ever, "A7 高空带不触发切变（AGL 门限 %.0f m）" % WindModel.SHEAR_AGL_MAX)

	# 可复现：同种子同剧本——两个实例同步驱动，激活历史逐帧一致（600 帧窗口）。
	var r1 := WindModel.new()
	var r2 := WindModel.new()
	r1.configure({"surface_wind_mps": 5.0, "shear_probability": 0.6}, 99)
	r2.configure({"surface_wind_mps": 5.0, "shear_probability": 0.6}, 99)
	var same_history := true
	for i in range(600):
		r1.update(0.1, 10.0)
		r2.update(0.1, 10.0)
		same_history = same_history and r1.is_shear_active() == r2.is_shear_active()
	_check(same_history, "A8 同种子切变剧本逐帧一致（可复现）")

	# 概率链路非死键：满概率 + 300 s 低空（扣除 60 s 冷却限流后期望 ≥4 次，
	# 泊松 P(0) < 0.3%）。窗口必须给够——0.02/s 的基准概率下 40 s 期望值不足 1。
	var hot := WindModel.new()
	hot.configure({"surface_wind_mps": 5.0, "shear_probability": 1.0}, 3)
	var triggered := false
	for i in range(3000):
		hot.update(0.1, 10.0)
		triggered = triggered or hot.is_shear_active()
	_check(triggered, "A8 300 s 低空内触发过切变（概率链路非死键）")

	# 冷却：触发后 20 s 内不二次触发（冷却 60 s）。
	var cd := WindModel.new()
	cd.configure({"surface_wind_mps": 5.0, "shear_probability": 1.0}, 5)
	cd.inject_shear(Vector3(0.0, -3.0, 8.0), 8.0)
	var second := false
	for i in range(200):   # 注入后 20 s（切变 8 s + 冷却未到的 12 s）
		cd.update(0.1, 10.0)
		if cd.is_shear_active() and i > 100:
			second = true
	_check(not second, "A9 切变后冷却期内不二次触发")


# ── B 段：气动端到端（同空速，风只改地速） ──────────────────────

## 造一架朝北平飞的状态：空速 AIR 由 velocity 与 wind 反算（velocity 存地速度）。
func _north_cruise(air_speed: float, wind: Vector3) -> AircraftFlight.State:
	var st := AircraftFlight.make_state(Vector3(0.0, 80.0, 0.0), PI)
	st.velocity = Vector3(0.0, 0.0, air_speed) + wind
	st.wind = wind
	return st


func _fly(st: AircraftFlight.State, frames: int, throttle: float = 0.0) -> void:
	var controls := AircraftFlight.Controls.new()
	controls.throttle = throttle
	for i in range(frames):
		AircraftFlight.integrate(st, controls, FRAME, false, {}, 0.0)


func _run_aero_checks() -> void:
	# 空速/地速读数分流：同空速下顺风地速大、逆风地速小，且气动读数只看空速。
	var calm := _north_cruise(50.0, Vector3.ZERO)
	_fly(calm, 60)
	var tail := _north_cruise(50.0, Vector3(0.0, 0.0, 10.0))   # 风朝北吹 = 顺风
	_fly(tail, 60)
	var head := _north_cruise(50.0, Vector3(0.0, 0.0, -10.0))  # 风朝南吹 = 逆风
	_fly(head, 60)
	_check(absi(calm.airspeed - tail.airspeed) < 2.0 and absi(calm.airspeed - head.airspeed) < 2.0,
		"B1 同空速初值下三场景空速读数一致（%.1f/%.1f/%.1f）"
			% [calm.airspeed, tail.airspeed, head.airspeed])
	_check(tail.ground_speed > calm.ground_speed + 5.0,
		"B1 顺风地速>静风（%.1f > %.1f）" % [tail.ground_speed, calm.ground_speed])
	_check(head.ground_speed < calm.ground_speed - 5.0,
		"B1 逆风地速<静风（%.1f < %.1f）" % [head.ground_speed, calm.ground_speed])
	_check(tail.position.z > calm.position.z + 4.0 and head.position.z < calm.position.z - 4.0,
		"B2 同空速 1 s 后顺风飞得远、逆风飞得近（%.1f/%.1f/%.1f）"
			% [tail.position.z, calm.position.z, head.position.z])

	# 侧风：地速矢量与机头不一致（蟹形进近的物理来源），航向不被风标掰动。
	var cross := _north_cruise(50.0, Vector3(10.0, 0.0, 0.0))  # 风朝东吹 = 右侧风
	var cross0 := cross.position
	_fly(cross, 60)
	_check(cross.position.x > cross0.x + 4.0,
		"B3 右侧风 1 s 把飞机向东带 %.1f m" % (cross.position.x - cross0.x))
	_check(absi(cross.position.z - cross0.z - calm.position.z) < 4.0,
		"B3 侧风不拖慢向北的地速分量")
	var nose_deg: float = rad_to_deg(atan2(-cross.basis.z.x, -cross.basis.z.z))
	_check(absi(wrapf(nose_deg, -180.0, 180.0)) < 5.0,
		"B3 侧风下机头仍指北（风标只对气流生效，航向 %.1f°）" % nose_deg)

	# 无风等价：wind 为零时 air_velocity 恒等于 velocity。
	var z := AircraftFlight.make_state(Vector3(0.0, 80.0, 0.0), PI)
	z.velocity = Vector3(3.0, -1.0, 40.0)
	_check(AircraftFlight.air_velocity(z) == z.velocity, "B4 无风时空速矢量≡地速度")


# ── C 段前奏：风切变端到端（掉高度 + 推油门改出） ────────────────

## 风切变剧本：1 s 巡航后命中微暴 8 s（与 WindModel.SHEAR_DURATION 同长），
## 随后风回到原值——切变是瞬态特情，不是永久环境。真实路径由 Aircraft 每帧
## 把 WindModel.wind_at() 填进 _state.wind，这里按同一时序直接填 st.wind
## （确定性、可复现），全程不碰 velocity——气动自洽不被破坏（§2.2 红线）。
const CRUISE_PRE := 60                                  # 切变前 1 s 巡航
const SHEAR_HOLD := int(WindModel.SHEAR_DURATION / FRAME)   # 480 帧 = 8 s
const STORY_WINDOW := CRUISE_PRE + SHEAR_HOLD + 360     # 总窗 15 s（切变后 6 s）


## 跑一遍切变剧本，返回关键帧采样（唯一变量是油门）。
func _shear_story(throttle: float) -> Dictionary:
	var st := _north_cruise(50.0, Vector3(0.0, 0.0, -5.0))   # 弱逆风，空速 55
	var calm := st.wind
	var controls := AircraftFlight.Controls.new()
	controls.throttle = throttle
	var as0 := 0.0
	var as_hit := 0.0
	var as_end := 0.0
	var vy_end := 0.0
	var y0 := st.position.y
	for i in range(STORY_WINDOW):
		if i == CRUISE_PRE:
			as0 = st.airspeed                     # 切变前空速（已随阻力衰减）
			st.wind = Vector3(0.0, -5.0, 4.0)     # 微暴：顺风突增 + 下沉气流
		if i == CRUISE_PRE + 1:
			as_hit = st.airspeed                  # 命中后 1 帧
		if i == CRUISE_PRE + SHEAR_HOLD:
			as_end = st.airspeed                  # 切变第 8 s 末
			vy_end = st.velocity.y
			st.wind = calm                        # 切变结束，风回原值
		AircraftFlight.integrate(st, controls, FRAME, false, {}, 0.0)
	return {
		"as0": as0, "as_hit": as_hit, "as_end": as_end,
		"vy_end": vy_end, "dy": st.position.y - y0, "vy_final": st.velocity.y,
	}


func _run_shear_checks() -> void:
	# 同一剧本、同一 15 s 窗口，唯一变量是油门（任务书 §2.2/§7 验收口径：
	# 「风切变触发时飞机掉高度，推油门能改出，不推则解体」——无地面场景，
	# 「不推」一侧以整窗持续掉高度 + 空速崩作为不解体的代理判据）。
	var idle := _shear_story(0.0)
	var power := _shear_story(1.0)
	_check(float(idle["as_hit"]) < float(idle["as0"]) - 5.0,
		"C1 切变命中瞬间空速骤降（%.1f → %.1f m/s）" % [idle["as0"], idle["as_hit"]])
	_check(float(idle["dy"]) < -30.0,
		"C1 不推油门整窗掉高度 %.1f m（下沉气流 + 空速崩，无改出）" % idle["dy"])
	_check(float(power["as_end"]) > float(idle["as_hit"]) + 2.0,
		"C2 满油门切变中空速改出回升（%.1f → %.1f m/s）"
			% [idle["as_hit"], power["as_end"]])
	_check(absf(float(power["as_end"]) - float(power["as0"])) < 2.0,
		"C2 满油门 8 s 空速恢复至切变前水平（%.1f ≈ %.1f m/s）"
			% [power["as_end"], power["as0"]])
	_check(float(power["dy"]) > float(idle["dy"]) + 5.0,
		"C2 同窗口推油门比不推少掉 %.1f m" % (float(power["dy"]) - float(idle["dy"])))
	_check(absf(float(power["vy_final"])) < absf(float(power["vy_end"])) - 3.0,
		"C2 切变结束后下沉收敛（|vy| %.1f → %.1f m/s）"
			% [power["vy_end"], power["vy_final"]])

	# 切变只走风矢量：改 wind 不动 velocity——气动自洽不被破坏（任务书 §2.2 红线）。
	var st3 := _north_cruise(50.0, Vector3.ZERO)
	var v_before := st3.velocity
	st3.wind = Vector3(0.0, -6.0, 0.0)
	_check(st3.velocity == v_before, "C3 切变只改 wind 矢量、不动 velocity")


# ── C 段：区域数据与接线 ────────────────────────────────────────

func _run_data_checks() -> void:
	# 11 区 profile 完整且取值范围受控（儿童向硬顶 9 m/s）。
	var complete := true
	var in_range := true
	var rid := 0
	while rid < RegionAtlas.COUNT:
		var p := RegionAtlas.weather_profile_of(rid)
		if p.is_empty():
			complete = false
		else:
			var s: float = float(p["surface_wind_mps"])
			var q: float = float(p["shear_probability"])
			if s <= 0.0 or s > 9.0 or q < 0.0 or q > 1.0:
				in_range = false
		rid += 1
	_check(complete, "D1 11 个区域 weather_profile 全部非空")
	_check(in_range, "D1 各区 surface∈(0,9]、shear∈[0,1]")
	_check(RegionAtlas.weather_profile_of(-3).is_empty()
		and RegionAtlas.weather_profile_of(999).is_empty(),
		"D2 越界区域 id 返回空（拒绝语义，不夹取）")
	var asia := RegionAtlas.weather_profile_of(RegionAtlas.ASIA)
	_check(absi(float(asia["surface_wind_mps"]) - 5.0) < 0.001, "D2 亚洲地面风 = 5.0 m/s")

	# 接线：Aircraft.setup_wind 把区域 profile 灌进 WindModel（不碰场景树）。
	var craft := Aircraft.new()
	_check(is_instance_valid(craft), "D3 Aircraft 可无头构造")
	if not is_instance_valid(craft):
		return
	craft.setup_wind(RegionAtlas.PACIFIC)
	_check(absi(craft._wind.surface_speed() - 7.0) < 0.001,
		"D3 亚洲→太平洋换区后地面风 = 7.0 m/s（%.1f）" % craft._wind.surface_speed)
	_check(craft._wind.shear_probability() > 0.5, "D3 太平洋切变概率 0.6（洋面对流旺）")

	# 设置开关：默认开、to_dict/from_dict 往返保留。
	var s := FlightSettings.current()
	var saved := s.wind_enabled
	_check(saved, "D4 风场默认开启")
	_check(bool(FlightSettings.from_dict(s.to_dict()).wind_enabled),
		"D4 wind_enabled 随 settings.json 往返")
	s.wind_enabled = false
	_check(not FlightSettings.from_dict(s.to_dict()).wind_enabled, "D4 关闭态同样往返")
	s.wind_enabled = saved


func _finish() -> void:
	SaveGuard.restore()
	if _failed == 0:
		print("WIND_FLIGHT_PROBE_OK")
		get_tree().quit(0)
	else:
		print("WIND_FLIGHT_PROBE_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
