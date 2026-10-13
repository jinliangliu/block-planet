extends Node

## 无头验证 FlightSettings 与飞机辅助稳定（纯逻辑，不依赖世界/地形）：
## 默认/难度预设、增益表、to_dict/from_dict/save 往返、辅助稳定对坡度与俯仰的配平
## 行为，以及「关闭档 = 纯气动模型、逐帧行为不变」回归守卫。

const DT := 0.05

var _pass := 0
var _fail := 0


func _check(cond, msg) -> void:
	if cond:
		print("PASS: " + msg)
		_pass += 1
	else:
		print("FAIL: " + msg)
		_fail += 1


func _bank_of(state) -> float:
	return asin(clampf(state.basis.x.y, -1.0, 1.0))


func _pitch_of(state) -> float:
	return asin(clampf((-state.basis.z).y, -1.0, 1.0))


## 构造一架带给定空速、已做姿态旋转（bank/pitch 弧度，绕机体轴）的飞机状态。
func _craft_state(bank_rad: float, pitch_rad: float, speed: float) -> AircraftFlight.State:
	var state = AircraftFlight.make_state(Vector3.ZERO, 0.0)
	# 先绕前向量（Z）压坡度、再绕翼展轴（X）起俯仰。
	state.basis = state.basis.rotated(Vector3(0.0, 0.0, 1.0), bank_rad)
	state.basis = state.basis.rotated(Vector3(1.0, 0.0, 0.0), pitch_rad)
	state.velocity = -state.basis.z * speed
	return state


func _ready() -> void:
	_run()
	print("FLIGHT_SETTINGS_DONE fails=%d" % _fail)
	if _fail > 0:
		print("FLIGHT_SETTINGS_FAIL")
	else:
		print("FLIGHT_SETTINGS_OK")
	get_tree().quit()


func _run() -> void:
	# ── 默认 ──
	var s := FlightSettings.default_settings()
	_check(s.difficulty == FlightSettings.Difficulty.NORMAL, "默认难度为标准")
	_check(s.assist_level == FlightSettings.Assist.PARTIAL, "默认辅助为半开")
	_check(s.difficulty_name() == "标准", "难度名=标准")
	_check(s.assist_name() == "半开", "辅助名=半开")

	# ── 难度预设决定默认辅助 ──
	var casual := FlightSettings.for_difficulty(FlightSettings.Difficulty.CASUAL)
	_check(casual.assist_level == FlightSettings.Assist.FULL, "休闲预设→辅助全开")
	_check(casual.assist_name() == "全开", "休闲辅助名=全开")
	var expert := FlightSettings.for_difficulty(FlightSettings.Difficulty.EXPERT)
	_check(expert.assist_level == FlightSettings.Assist.OFF, "硬核预设→辅助关闭")
	_check(expert.difficulty_name() == "硬核", "硬核难度名=硬核")

	# ── 难度切换重置辅助，但辅助可单独覆盖 ──
	var mid := FlightSettings.for_difficulty(FlightSettings.Difficulty.CASUAL)
	mid.set_assist_level(FlightSettings.Assist.PARTIAL)
	_check(mid.assist_level == FlightSettings.Assist.PARTIAL, "切换难度后单独改辅助生效")
	mid.set_difficulty(FlightSettings.Difficulty.EXPERT)
	_check(mid.assist_level == FlightSettings.Assist.OFF, "再切难度会重置辅助为硬核默认")

	# ── 增益表 ──
	var off_g := FlightSettings.for_difficulty(FlightSettings.Difficulty.EXPERT).gains()
	_check(off_g["roll_level"] == 0.0 and off_g["yaw_damp"] == 0.0, "关闭档增益全 0")
	var full_g := FlightSettings.for_difficulty(FlightSettings.Difficulty.CASUAL).gains()
	_check(full_g["roll_level"] == 1.8 and full_g["yaw_damp"] == 1.5, "全开档增益表正确")
	var partial_g := FlightSettings.for_difficulty(FlightSettings.Difficulty.NORMAL).gains()
	_check(partial_g["roll_level"] == 0.9 and partial_g["yaw_damp"] == 0.8, "半开档增益表正确")

	# ── to_dict / from_dict ──
	var a := FlightSettings.for_difficulty(FlightSettings.Difficulty.NORMAL)
	a.set_assist_level(FlightSettings.Assist.FULL)   # 标准难度下单独把辅助开到全开
	var d := a.to_dict()
	_check(d["difficulty"] == FlightSettings.Difficulty.NORMAL and d["assist_level"] == FlightSettings.Assist.FULL, "to_dict 含难度与（覆盖后的）辅助等级")
	var b := FlightSettings.from_dict(d)
	_check(b.difficulty == FlightSettings.Difficulty.NORMAL and b.assist_level == FlightSettings.Assist.FULL, "from_dict 还原难度与辅助覆盖")

	# ── save / load_or_new（临时路径）──
	var tmp := "user://flight_settings_probe.tmp.json"
	var c := FlightSettings.for_difficulty(FlightSettings.Difficulty.CASUAL)
	var ok := c.save(tmp)
	_check(ok, "save 写入成功")
	var d2 := FlightSettings.load_or_new(tmp)
	_check(d2.difficulty == FlightSettings.Difficulty.CASUAL and d2.assist_level == FlightSettings.Assist.FULL, "load_or_new 读档与写入一致")
	# 损坏文件安全退回默认。
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	f.store_string("{ this is not json ")
	f.close()
	var d3 := FlightSettings.load_or_new(tmp)
	_check(d3.difficulty == FlightSettings.Difficulty.NORMAL and d3.assist_level == FlightSettings.Assist.PARTIAL, "损坏文件安全退回默认（标准/半开）")

	# ── 辅助配平行为（空中、松杆）──
	var ctrl := AircraftFlight.Controls.new()
	# 坡度配平：30° 右坡度、无杆量；半开辅助应把坡度收敛，关闭档不配平。
	var bank_state := _craft_state(deg_to_rad(30.0), 0.0, 60.0)
	for i in range(40):
		AircraftFlight.integrate(bank_state, ctrl, DT, false, partial_g)
	var bank_partial := _bank_of(bank_state)
	_check(bank_partial < deg_to_rad(8.0) and bank_partial > 0.0,
		"半开辅助把 30° 坡度配平收敛（实际 %.1f°）" % rad_to_deg(bank_partial))

	var bank_off := _craft_state(deg_to_rad(30.0), 0.0, 60.0)
	for i in range(40):
		AircraftFlight.integrate(bank_off, ctrl, DT, false, {})
	var bank_after_off := _bank_of(bank_off)
	# 关闭档不介入配平：坡度仅因模型固有的偏航-坡度耦合缓慢漂移（2s 约 −9°），
	# 远不到水平；辅助档应比关闭档配平得多得多。
	_check(bank_after_off > deg_to_rad(12.0),
		"关闭档不配平坡度，仍保持带坡度（实际 %.1f°）" % rad_to_deg(bank_after_off))
	_check(bank_partial < bank_after_off - deg_to_rad(5.0),
		"辅助档配平效果显著强于关闭档（%.1f° vs %.1f°）" % [rad_to_deg(bank_partial), rad_to_deg(bank_after_off)])

	# 俯仰不干预：辅助刻意不含俯仰配平，20° 上仰在松杆时不应被自动压回水平。
	var pitch_state := _craft_state(0.0, deg_to_rad(20.0), 60.0)
	for i in range(30):
		AircraftFlight.integrate(pitch_state, ctrl, DT, false, partial_g)
	var pitch_after := _pitch_of(pitch_state)
	_check(pitch_after > deg_to_rad(12.0),
		"辅助不干预俯仰，20° 上仰不被自动压平（实际 %.1f°）" % rad_to_deg(pitch_after))
