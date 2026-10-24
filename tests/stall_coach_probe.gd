extends Node
## 失速改出教案（U-8）与座舱一次性教学提示（U-9）的端到端探针（D-069）。
##
##   A 段 StallCoach 纯逻辑状态机：不依赖场景，直接喂 Aircraft.snapshot() 同款
##       字典，把五态（IDLE / ①低头 / ②油门 / ③等速度 / 成功）与四条边界
##       （单步超时、着陆收起、重复失速回①、成功保持后收起）逐条钉死。
##   B 段 FlightTeaching 触发判据与持久化：六个 gate 逐条 + 落盘 round-trip +
##       原子写无 tmp 残留 + 损坏/错类型容错 + 一次性语义（第二次返回空）。
##   C 段 hud.gd 集成（真实场景）：起飞教练失速让位 → 真实起飞到 40 m →
##       U-9 Toast 一次性投递（且不再复发）→ 怠速满杆逼出失速告警 → 走完
##       ①②③成功的完整教案（用 latch 抓每一步的文案）。
##
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/stall_coach_probe.tscn

const PROBE_PAD := preload("res://tests/probe_pad.gd")

## 巡航目标离地高度（m）：> U-9 触发高度 15 m，且高于起飞教练成功判定高度。
const CRUISE_ALT := 40.0
## 单阶段等待上限（秒），超时即失败，避免探针卡死。
const PHASE_TIMEOUT := 30.0
## StallCoach 纯逻辑段的固定步长（s）：状态机所有计时都按 delta 累加，
## 用固定步长喂可以把「维持 0.3 s」「保持 2.5 s」这类阈值钉成确定的帧数。
const STEP := 0.1

var _fails := 0
var _craft: Aircraft
var _player: Player
var _hud: HUD
## C 段每一步文案的 latch（去重）：教案推进很快，单帧只能看到一句，
## 必须全程收集再回头断言「①/②/③/成功都出现过」。
var _latch: Array[String] = []


func _ready() -> void:
	await _run()


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("PASS: %s" % msg)
	else:
		_fails += 1
		print("FAIL: %s" % msg)


func _run() -> void:
	# 存档隔离（D-010 铁律 3）：必须在实例化 main.tscn 之前——B 段会往
	# user://flight_teaching.json 写损坏文件做容错断言，C 段还会真实飞
	# 行推进 flew 计数，两者都要原样还原。
	SaveGuard.snapshot()
	# 钉死标准难度 + **关风**：风场每进程随机播种（区域梯度风 + 阵风切变），
	# 会让「怠速满杆逼失速」的时序与轨迹逐 run 漂移——单独跑 50/0、回归里
	# 却 4 FAIL，风是最主要的随机源。探针要的是确定的教案时序，不是真实天气。
	var profile := FlightSettings.for_difficulty(FlightSettings.Difficulty.NORMAL)
	profile.wind_enabled = false
	FlightSettings.set_current(profile)
	_a_stall_coach_logic()
	_b_flight_teaching()
	await _c_integration()
	SaveGuard.restore()
	print("STALL_COACH_DONE fails=%d" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


# ── A 段：StallCoach 纯逻辑 ────────────────────────────────
func _a_stall_coach_logic() -> void:
	var c := StallCoach.new()
	# A1 IDLE：无告警 → 空字典（HUD 见空即隐藏教练区）。
	_check(c.step_for(_snap(false, false, 30.0, 0.0, 1.0, 30.0, true), STEP).is_empty(),
		"A1 无失速告警时教案为空（教练区让位给起飞教练）")

	# A2 仅接近失速（stall_warning 上升沿）→ ① 用「要失速了」的缓和语气。
	var s2 := c.step_for(_snap(false, true, 13.5, 0.0, 1.0, 30.0, true), STEP)
	_check(String(s2.get("text", "")).contains("要失速了") \
		and String(s2.get("text", "")).contains("低头"),
		"A2 接近失速上升沿进入第①步（黄闪「要失速了」+ 低头）")
	_check(bool(s2.get("flash", false)), "A2b 第①步带呼吸闪烁（要玩家动手）")

	# A3 完全失速上升沿 → ① 改成「失速了！」的告警语气（同一动作两种措辞）。
	c.reset()
	var s3 := c.step_for(_snap(true, true, 12.0, 0.0, 1.0, 30.0, true), STEP)
	_check(String(s3.get("text", "")).contains("失速了！"),
		"A3 完全失速上升沿进入第①步（红闪「失速了！」）")

	# A4 ①→②：俯角 ≤ −3° 维持 0.3 s 才推进（防穿越时抖动静翻步）。
	var s4: Dictionary = {}
	for i in range(4):
		s4 = c.step_for(_snap(false, true, 13.5, -5.0, 1.0, 30.0, true), STEP)
	_check(String(s4.get("text", "")).contains("油门推满"),
		"A4 俯角达标并维持 0.3 s 后推进第②步（油门推满）")

	# A5 ② 的熄火交圈：先教点火再教油门（不点火油门推不动）。
	var s5 := c.step_for(_snap(false, true, 13.5, -5.0, 1.0, 30.0, false), STEP)
	_check(String(s5.get("text", "")).contains("点火"),
		"A5 第②步遇熄火改教「先按 F 点火」")

	# A6 ②→③：失速余量 ≥0 并维持 0.3 s（margin-only，不考核油门本身）。
	var s6: Dictionary = {}
	for i in range(4):
		s6 = c.step_for(_snap(false, true, 13.5, -5.0, 1.0, 30.0, true), STEP)
	_check(String(s6.get("text", "")).contains("保持低头"),
		"A6 余量转正并维持 0.3 s 后推进第③步（等速度恢复）")

	# A7 ③→成功：余量 ≥10 km/h（≈2.8 m/s，温和不易二次失速）。
	var s7 := c.step_for(_snap(false, false, 16.5, -5.0, 1.0, 30.0, true), STEP)
	_check(String(s7.get("text", "")).contains("改出成功"),
		"A7 余量 ≥10 km/h 判定改出成功")

	# A8 成功保持 2.5 s 后收起（避免长时间占屏）。
	for i in range(26):
		s7 = c.step_for(_snap(false, false, 20.0, -5.0, 1.0, 30.0, true), STEP)
	_check(s7.is_empty(), "A8 成功文案保持 2.5 s 后自动收起")

	# A9 ② 单步 15 s 无推进 → 回 IDLE 静默（危险已过就不跟读）。
	var c9 := StallCoach.new()
	c9.step_for(_snap(false, true, 13.5, 0.0, 1.0, 30.0, true), STEP)
	for i in range(4):
		c9.step_for(_snap(false, true, 13.5, -5.0, 1.0, 30.0, true), STEP)
	var s9 := c9.step_for(_snap(false, true, 13.5, -5.0, 1.0, 30.0, true), STEP)
	_check(String(s9.get("text", "")).contains("油门推满"), "A9 前置：已进第②步")
	for i in range(152):
		s9 = c9.step_for(_snap(false, true, 13.0, -5.0, 1.0, 30.0, true), STEP)
	_check(s9.is_empty(), "A9b 第②步 15 s 无推进回 IDLE 静默")

	# A10 着陆（AGL ≤2 m）→ 整体收起；①不设超时，着地才收。
	var c10 := StallCoach.new()
	c10.step_for(_snap(false, true, 13.5, 0.0, 1.0, 30.0, true), STEP)
	var s10 := c10.step_for(_snap(false, true, 13.5, 0.0, 1.0, 1.0, true), STEP)
	_check(s10.is_empty(), "A10 着陆（AGL≤2 m）教案整体收起")

	# A11 教案进行中再次完全失速 → 回第①步重头教（每次失速完整教一遍）。
	var c11 := StallCoach.new()
	c11.step_for(_snap(false, true, 13.5, 0.0, 1.0, 30.0, true), STEP)
	for i in range(4):
		c11.step_for(_snap(false, true, 13.5, -5.0, 1.0, 30.0, true), STEP)
	var s11 := c11.step_for(_snap(true, true, 12.0, -5.0, 1.0, 30.0, true), STEP)
	_check(String(s11.get("text", "")).contains("失速了！"),
		"A11 第②步中再次失速 → 回第①步重头教")

	# A12 计时器仅供 HUD 算闪烁相位：喂几帧后应等于累计 delta。
	var c12 := StallCoach.new()
	for i in range(3):
		c12.step_for(_snap(false, false, 30.0, 0.0, 1.0, 30.0, true), STEP)
	_check(absf(c12.elapsed() - 0.3) < 0.001,
		"A12 elapsed() 随帧累加（%.3f s，HUD 闪烁相位源）" % c12.elapsed())
	# unbind 后整体重置：非失速帧恒空（下机后不残留教案）。
	c12.step_for(_snap(false, true, 13.5, 0.0, 1.0, 30.0, true), STEP)
	c12.unbind()
	_check(c12.step_for(_snap(false, false, 30.0, 0.0, 1.0, 30.0, true), STEP).is_empty(),
		"A12b unbind() 后教案重置为空（下机不残留）")


	# A13 ①不设超时：停在① 40 s（俯角始终不达标）也不该自行收起——指令性
	# 步骤，着地才收（防儿童慌乱期提示中途消失）。
	var c13 := StallCoach.new()
	c13.step_for(_snap(false, true, 13.5, 0.0, 1.0, 30.0, true), STEP)
	var s13: Dictionary = {}
	for i in range(400):
		s13 = c13.step_for(_snap(false, true, 13.5, 0.0, 1.0, 30.0, true), STEP)
	_check(String(s13.get("text", "")).contains("低头"),
		"A13 第①步不设超时：停 40 s 仍在①（着地才收）")

	# A14 ①的俯角去抖是**双向**的：维持期间被拉起 → 计时清零 → 停在①。
	var c14 := StallCoach.new()
	c14.step_for(_snap(false, true, 13.5, 0.0, 1.0, 30.0, true), STEP)
	for i in range(2):
		c14.step_for(_snap(false, true, 13.5, -5.0, 1.0, 30.0, true), STEP)
	c14.step_for(_snap(false, true, 13.5, 5.0, 1.0, 30.0, true), STEP)
	var s14: Dictionary = {}
	for i in range(2):
		s14 = c14.step_for(_snap(false, true, 13.5, -5.0, 1.0, 30.0, true), STEP)
	_check(String(s14.get("text", "")).contains("低头"),
		"A14 ①俯角维持被拉起 → 去抖计时清零、停在①（不足 0.3 s 不推进）")

	# A15 成功保持期内再次完全失速 → 回①重头教（与 A11 的②中失速同一分支）。
	var c15 := StallCoach.new()
	_to_success(c15)
	var s15 := c15.step_for(_snap(false, false, 20.0, -5.0, 1.0, 30.0, true), STEP)
	_check(String(s15.get("text", "")).contains("改出成功"), "A15 前置：已进入成功态")
	s15 = c15.step_for(_snap(true, true, 12.0, -5.0, 1.0, 30.0, true), STEP)
	_check(String(s15.get("text", "")).contains("失速了！"),
		"A15b 成功保持期内再次失速 → 回第①步")

	# A16 着陆兜底要覆盖②/③/成功三态（A10 只钉了①）：AGL≤2 m 一律静默。
	var c16a := StallCoach.new()
	_to_step2(c16a)
	_check(c16a.step_for(_snap(false, false, 16.5, -5.0, 1.0, 0.5, true), STEP).is_empty(),
		"A16 第②步着地（AGL≤2 m）→ 教案静默")
	var c16b := StallCoach.new()
	_to_step3(c16b)
	_check(c16b.step_for(_snap(false, false, 16.5, -5.0, 1.0, 0.5, true), STEP).is_empty(),
		"A16b 第③步着地 → 教案静默")
	var c16c := StallCoach.new()
	_to_success(c16c)
	_check(c16c.step_for(_snap(false, false, 16.5, -5.0, 1.0, 0.5, true), STEP).is_empty(),
		"A16c 成功态着地 → 教案静默")

	# A17 三个等值点（判据都是 `>=` / `<=`，等号必须成立）：
	var c17a := StallCoach.new()
	c17a.step_for(_snap(false, true, 13.5, 0.0, 1.0, 30.0, true), STEP)
	for i in range(3):
		c17a.step_for(_snap(false, true, 13.5, -3.0, 1.0, 30.0, true), STEP)
	_check(String(c17a.step_for(
			_snap(false, true, 13.5, -3.0, 1.0, 30.0, true), STEP).get("text", "")
		).contains("油门推满"), "A17 俯角 == −3.0° 等值点成立（<= 判据）")
	var c17b := StallCoach.new()
	_to_step2(c17b)
	for i in range(3):
		c17b.step_for(_snap(false, true, 13.1, -5.0, 1.0, 30.0, true), STEP)
	_check(String(c17b.step_for(
			_snap(false, true, 13.1, -5.0, 1.0, 30.0, true), STEP).get("text", "")
		).contains("保持低头"), "A17b 余量 == 0.0 km/h 等值点成立（>= 判据）")
	# ③→成功 的 10 km/h 阈值：浮点数拿不到「恰好 10.0」（margin = (airspeed
	# − stall_speed) × 3.6 的乘除往返必然有尾差），改用**贴着阈值的两点**钉住
	# 边界：9.9 不推进、10.1 推进。
	var c17c := StallCoach.new()
	_to_step3(c17c)
	var s17c := c17c.step_for(
		_snap(false, false, 13.1 + 9.9 / 3.6, -5.0, 1.0, 30.0, true), STEP)
	_check(String(s17c.get("text", "")).contains("保持低头"),
		"A17c 余量 9.9 km/h（阈值下沿）不推进，仍在③")
	var c17d := StallCoach.new()
	_to_step3(c17d)
	_check(String(c17d.step_for(
			_snap(false, false, 13.1 + 10.1 / 3.6, -5.0, 1.0, 30.0, true), STEP)
		.get("text", "")).contains("改出成功"),
		"A17d 余量 10.1 km/h（阈值上沿）判成功")

	# A18 ②的熄火交圈是**可逆**的：点火后自动回到推油门措辞。
	var c18 := StallCoach.new()
	_to_step2(c18)
	_check(String(c18.step_for(
			_snap(false, true, 13.5, -5.0, 1.0, 30.0, false), STEP).get("text", "")
		).contains("点火"), "A18 ②遇熄火改教点火")
	_check(String(c18.step_for(
			_snap(false, true, 13.5, -5.0, 1.0, 30.0, true), STEP).get("text", "")
		).contains("油门推满"), "A18b 点火后②自动回到推油门措辞")

	# A19（D-1 的回归闸）：着陆退出必须清掉边沿记忆，否则下一次失速没有
	# 上升沿、教案从此再也不触发。
	#
	# ⚠️ 构造要点：**告警必须连续**。着陆帧要把 `stall_warning` 置为 true，
	# 且到断言帧为止**不能插入任何非失速帧**——否则 `step_for` 帧顶那句
	# 无条件的 `_was_warning = warning` 会顺手把它清成 false，清不清理都
	# 一样，断言就退化成「怎么改都 PASS」的假闸门（D-069 复核指出）。
	# 真实场景就是「带着告警触地、复飞，告警从头到尾没解除过」。
	var c19 := StallCoach.new()
	c19.step_for(_snap(false, true, 13.5, 0.0, 1.0, 30.0, true), STEP)   # 空中告警 → 进①
	c19.step_for(_snap(false, true, 13.5, 0.0, 1.0, 0.5, true), STEP)    # 着陆帧：告警仍在
	var s19 := c19.step_for(_snap(false, true, 13.5, 0.0, 1.0, 30.0, true), STEP)
	_check(String(s19.get("text", "")).contains("低头"),
		"A19 带告警触地后复飞、告警持续 → 教案仍能触发（边沿记忆已清）")

	# A20 余量门槛随**襟翼/载重派生出的 stall_speed** 变化，不是写死的 km/h：
	# 同样 12.0 m/s，襟翼放下（stall_speed 11.0）余量转正 → 推进③；
	# 襟翼收起（stall_speed 13.1）余量为负 → 停在②。
	var c20a := StallCoach.new()
	_to_step2(c20a)
	var s20a: Dictionary = {}
	for i in range(3):
		s20a = c20a.step_for(_snap(false, true, 12.0, -5.0, 1.0, 30.0, true, 11.0), STEP)
	_check(String(s20a.get("text", "")).contains("保持低头"),
		"A20 襟翼放下（stall_speed 11.0）→ 12 m/s 余量转正、推进③")
	var c20b := StallCoach.new()
	_to_step2(c20b)
	var s20b: Dictionary = {}
	for i in range(3):
		s20b = c20b.step_for(_snap(false, true, 12.5, -5.0, 1.0, 30.0, true, 13.1), STEP)
	_check(String(s20b.get("text", "")).contains("油门推满"),
		"A20b 襟翼收起（stall_speed 13.1）→ 12.5 m/s 余量为负、停在②")

	# A21 IDLE 的 airborne 闸（反向）：贴地告警不该触发教案——D-069 后数据层
	# 已加地面门（地面 stalled/stall_warning 恒 false，见 aircraft_flight.gd
	# _refresh_readings），本闸是 UI 层兜底，防数据层回归时教案在地面空转。
	# （原注释「地面失速物理上不可能」的论证已被证伪：alpha 是空速矢量与
	# 机头的夹角而非俯仰角，angle_of_attack 的分母下限 0.5 在低速把落稳垂直
	# 抖动放大成满攻角——地面确实会误报，数据层地面门才是根治。）
	var c21 := StallCoach.new()
	_check(c21.step_for(_snap(false, true, 13.5, 0.0, 1.0, 2.0, true), STEP).is_empty(),
		"A21 贴地（AGL == 2.0 m 等值点）告警上升沿不触发（> 才算 airborne）")
	# 反向对照必须用**全新实例**：贴地那一帧虽没触发，但 `step_for` 帧顶的
	# `_was_warning = warning` 已经把上升沿消费掉了，接着喂同一实例会恒不触发。
	# （真实飞行里地面失速不可能发生，这条只是把闸的存在钉住。）
	var c21b := StallCoach.new()
	_check(not c21b.step_for(_snap(false, true, 13.5, 0.0, 1.0, 2.5, true), STEP).is_empty(),
		"A21b 离地（AGL 2.5 m）同一告警上升沿即触发教案（反向对照）")

	# A22 教案进行中告警**持续**为 true 不得被当成新事件反复重触发：若每帧
	# 都重进①，`_nose_hold` 会被反复清零、永远推进不到②。判据是「持续 30 s
	# 之后再喂 3 帧达标俯角仍能推进」——推进得动就证明计时没被重置过。
	var c22 := StallCoach.new()
	c22.step_for(_snap(false, true, 13.5, 0.0, 1.0, 30.0, true), STEP)
	for i in range(300):
		c22.step_for(_snap(false, true, 13.5, 0.0, 1.0, 30.0, true), STEP)
	var s22: Dictionary = {}
	for i in range(3):
		s22 = c22.step_for(_snap(false, true, 13.5, -5.0, 1.0, 30.0, true), STEP)
	_check(String(s22.get("text", "")).contains("油门推满"),
		"A22 告警持续 30 s 期间教案未被反复重触发（3 帧达标俯角即推进②）")

	# A23 / A23b（R6 守卫，②③两侧）：完全失速**持续** + 余量卡住超过
	# STEP_TIMEOUT_S，教案**不得**静默收工——飞机还在失速，静默比教案更危险；
	# 守卫若缺失会回卷①，形成「15 s 超时 → 上升沿 → 重进①」的周期红闪。
	# 这条路径窗口截图不可达（C 段改出循环上限 12 s < 守卫 15 s），纯逻辑
	# 断言是**唯一**保护——回退守卫时这两条必须变红（鉴别力已验证）。
	# 喂帧注意：stalled 首帧是上升沿 → R9 正常回①，俯角保持达标 3 帧后
	# 重进②、余量转正 3 帧后重进③，之后持续失速不再有边沿，卡步计时。
	var c23 := StallCoach.new()
	_to_step2(c23)
	var s23: Dictionary = {}
	c23.step_for(_snap(true, true, 12.0, -5.0, 0.0, 30.0, true, 13.1), STEP)   # 上升沿→①
	for i in range(3):
		c23.step_for(_snap(true, true, 12.0, -5.0, 0.0, 30.0, true, 13.1), STEP)   # ①→②
	for i in range(200):   # 20 s > 守卫 15 s：stalled 恒 true、margin<0
		s23 = c23.step_for(_snap(true, true, 12.0, -5.0, 0.0, 30.0, true, 13.1), STEP)
	_check(not s23.is_empty() and String(s23["text"]).contains("油门推满"),
		"A23 完全失速 + margin 卡负 ≥15 s → 教案不静默（②侧 R6 守卫，停在②不收工）")
	var c23b := StallCoach.new()
	_to_step3(c23b)
	var s23b: Dictionary = {}
	c23b.step_for(_snap(true, true, 12.0, -5.0, 0.0, 30.0, true, 13.1), STEP)   # 上升沿→①
	for i in range(3):
		c23b.step_for(_snap(true, true, 12.0, -5.0, 0.0, 30.0, true, 13.1), STEP)   # ①→②
	for i in range(3):
		c23b.step_for(_snap(true, true, 13.5, -5.0, 1.0, 30.0, true, 13.1), STEP)   # ②→③
	for i in range(200):   # 20 s > 守卫 15 s：stalled 恒 true、margin=+3.24<10
		s23b = c23b.step_for(_snap(true, true, 13.5, -5.0, 1.0, 30.0, true, 13.1), STEP)
	_check(not s23b.is_empty() and String(s23b["text"]).contains("速度恢复"),
		"A23b 完全失速 + margin 卡 +3.24 ≥15 s → 教案不静默（③侧 R6 守卫，停在③不收工）")

	# A24（契约钉子）：StallCoach 刻意**没有** TakeoffCoach 那道
	# `if _craft == null: return {}` 守卫——本类 step_for 只读 snap 字典、
	# 从不解引用 _craft。A 段整段正是靠未 bind 的 StallCoach.new() 做纯逻辑
	# 断言，加了这道守卫会让本段 20+ 条断言全部静默返回空而连坐失败。
	# 这条把「未 bind 仍照常跑状态机」钉住，防止有人按对称直觉补上守卫。
	var c24 := StallCoach.new()
	_check(not c24.step_for(_snap(false, true, 13.5, 0.0, 1.0, 30.0, true), STEP).is_empty(),
		"A24 未 bind（_craft == null）时 step_for 照常跑状态机（刻意无守卫）")
	_check(c24.elapsed() > 0.0,
		"A24b 未 bind 时内部计时照常累加（无守卫的连带保证）")


## 推进到第②步（①起 3 帧俯角达标，各 0.1 s = 0.3 s 维持判据）。
func _to_step2(c: StallCoach) -> void:
	c.step_for(_snap(false, true, 13.5, 0.0, 1.0, 30.0, true), STEP)
	for i in range(3):
		c.step_for(_snap(false, true, 13.5, -5.0, 1.0, 30.0, true), STEP)


## 推进到第③步（②起 3 帧余量转正）。
func _to_step3(c: StallCoach) -> void:
	_to_step2(c)
	for i in range(3):
		c.step_for(_snap(false, true, 13.5, -5.0, 1.0, 30.0, true), STEP)


## 推进到成功态（③起 1 帧余量 ≥10 km/h）。
func _to_success(c: StallCoach) -> void:
	_to_step3(c)
	c.step_for(_snap(false, false, 16.5, -5.0, 1.0, 30.0, true), STEP)


# ── B 段：FlightTeaching 触发判据与持久化 ──────────────────
func _b_flight_teaching() -> void:
	_remove_teaching()
	var ft := FlightTeaching.new()
	_check(not ft.is_seen(FlightTeaching.HINT_LOOKDOWN),
		"B1 无存档时提示标记为未看过")

	var snap := _snap(false, false, 30.0, 0.0, 1.0, 30.0, true)
	var ok: Dictionary = {
		"cockpit_view": true, "coach_busy": false,
		"blueprint_built": false, "touch": false,
	}
	_check(FlightTeaching.should_fire(snap, ok, []),
		"B2 全绿时触发（座舱视角 + 30 m + 教练区空闲 + 未看过）")
	_check(not FlightTeaching.should_fire(snap, _ctx(ok, "touch", true), []),
		"B2b 触屏设备不触发（无鼠标环顾，缺口记 U-12）")
	_check(not FlightTeaching.should_fire(snap, _ctx(ok, "blueprint_built", true), []),
		"B2c 蓝图试飞机不触发（契约不建座舱几何）")
	_check(not FlightTeaching.should_fire(snap, _ctx(ok, "cockpit_view", false), []),
		"B2d 非座舱视角不触发（追尾视角低头无物）")
	_check(not FlightTeaching.should_fire(snap, _ctx(ok, "coach_busy", true), []),
		"B2e 教练区正被占用时不触发（不与教案抢话筒）")
	_check(not FlightTeaching.should_fire(
			_snap(false, false, 30.0, 0.0, 1.0, 14.9, true), ok, []),
		"B2f 离地 <15 m 不触发（起降阶段不教低头）")
	_check(not FlightTeaching.should_fire(snap, ok, [FlightTeaching.HINT_LOOKDOWN]),
		"B2g 已看过不再触发")

	var hint := ft.hint_for(snap, ok)
	_check(hint == String(FlightTeaching.HINTS[FlightTeaching.HINT_LOOKDOWN]),
		"B3 命中返回课文案（「%s」）" % hint)
	# F-13「看过才消耗」：命中**只记 pending**，不标看过、不落盘——Toast 是
	# 覆盖式的（hud.gd 共 11 处 _show_toast），投出去 2.8 s 内被坠机「💥」
	# 之类顶掉，旧实现（投递即 mark_seen）会把这条一次性提示永久消耗掉。
	_check(ft.has_pending(), "B3b 命中记 pending（待确认，F-13）")
	_check(not ft.is_seen(FlightTeaching.HINT_LOOKDOWN), "B3c 命中未标看过（看过才消耗）")
	_check(not FileAccess.file_exists(FlightTeaching.SAVE_PATH),
		"B3d 命中不写盘（pending 只在内存）")
	_check(ft.hint_for(snap, ok).is_empty(),
		"B4 待确认期间不重复占用 Toast（否则每帧顶掉自己、永远播不完）")

	# 播完确认：HUD 在 Toast tween 自然结束时回调 confirm_shown，此刻才落盘。
	ft.confirm_shown()
	_check(not ft.has_pending(), "B5 confirm 后 pending 清空")
	_check(ft.is_seen(FlightTeaching.HINT_LOOKDOWN), "B5b confirm 后标记看过")
	_check(FileAccess.file_exists(FlightTeaching.SAVE_PATH),
		"B5c confirm 后落盘 flight_teaching.json")
	_check(not FileAccess.file_exists(FlightTeaching.SAVE_PATH + ".tmp"),
		"B5d 原子写无 .tmp 残留（tmp → rename 覆盖）")
	_check(FlightTeaching.new().is_seen(FlightTeaching.HINT_LOOKDOWN),
		"B6 重新读档仍记得看过（round-trip）")

	# 被顶掉取消：cancel_pending 后不算看过，条件满足时重演——一次性提示
	# 不因一次遮挡而永久丢失（F-13 的另一半保障）。
	_remove_teaching()
	var ft9 := FlightTeaching.new()
	_check(not ft9.hint_for(snap, ok).is_empty(), "B6b 重演前提：未看过时再次命中")
	_check(ft9.has_pending() and not ft9.is_seen(FlightTeaching.HINT_LOOKDOWN),
		"B6c 命中记 pending、仍未看过")
	ft9.cancel_pending()
	_check(not ft9.has_pending() and not ft9.is_seen(FlightTeaching.HINT_LOOKDOWN),
		"B6d cancel 后 pending 清空、仍未看过")
	_check(not ft9.hint_for(snap, ok).is_empty(),
		"B6e cancel 后条件满足可再次命中（不因一次遮挡永久丢失）")
	# 收尾：确认并落盘（不是 cancel——B7 要读盘上的 seen 条目，文件得在）。
	ft9.confirm_shown()

	# 去重：重复 mark_seen 不产生重复条目。用 ft9（刚 confirm 落盘的实例）——
	# ft 在 B5 已 confirm 过，再 mark_seen 会走「已有则 return」、不落盘，
	# 盘上没有文件 _seen_count() 就读到 -1。
	ft9.mark_seen(FlightTeaching.HINT_LOOKDOWN)
	_check(_seen_count() == 1, "B7 重复标记不产生重复条目（seen 长度 %d）" % _seen_count())

	# 损坏容错：坏文件按「未看过」处理，最坏后果只是提示复发（无害）。
	_write_teaching("{broken json")
	_check(not FlightTeaching.new().is_seen(FlightTeaching.HINT_LOOKDOWN),
		"B8 JSON 损坏时按未看过处理（不崩、不误判）")
	_write_teaching('{"seen": "not-an-array"}')
	_check(not FlightTeaching.new().is_seen(FlightTeaching.HINT_LOOKDOWN),
		"B8b seen 类型错误时按未看过处理")
	_write_teaching('{"seen": ["lookdown_panel", 7, ""]}')
	var ft8 := FlightTeaching.new()
	_check(ft8.is_seen(FlightTeaching.HINT_LOOKDOWN),
		"B8c 数组里混入非法条目时跳过它们、保留合法条目")

	_write_teaching('["not", "an", "object"]')
	_check(not FlightTeaching.new().is_seen(FlightTeaching.HINT_LOOKDOWN),
		"B8d 顶层是数组（不是对象）时按未看过处理")
	_check(not FlightTeaching.new().is_seen("no_such_hint"),
		"B9 未知 id 恒为未看过（不崩、不误判）")

	# 清理：B 段写过的文件必须删掉，否则 C 段 HUD 构造时读档会看到「已看过」，
	# U-9 提示就永远不投递了（C 段正是要验证首次投递）。
	_remove_teaching()
	_check(not FileAccess.file_exists(FlightTeaching.SAVE_PATH),
		"B10 段末清理存档，为 C 段留出「首次投递」的前提")


# ── C 段：hud.gd 集成（真实场景）────────────────────────────
func _c_integration() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame
	_player = main_scene.get_node("Player")
	_hud = main_scene.get_node("UI") as HUD
	var world: World = main_scene.get_node("World")
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	# 探针可复现性（对齐 flight_probe）：停刷怪后世界状态确定，「怠速满杆逼
	# 失速」这类攻角时序敏感机动才不会逐 run 漂移。
	if _hud._map_selector != null and _hud._map_selector.is_open():
		_hud.close_map_selector()
	GameState.needs_region_pick = false
	for i in range(30):
		await get_tree().process_frame

	var pad := PROBE_PAD.prepare(world, _player)
	var spawn_pos: Vector3 = pad["spawn"]
	_craft = Aircraft.spawn(main_scene, spawn_pos, PI)
	_player.ride_aircraft(_craft)
	_craft.drive_remotely()
	for i in range(300):
		await get_tree().physics_frame
		if not is_instance_valid(_craft):
			break
		if _craft.is_on_floor() and _craft.velocity.length() < 0.5:
			break
	if not is_instance_valid(_craft) or _craft.is_wrecked():
		_check(false, "C0 就位阶段机体解体（落位点压到玩家/地形，见 probe_pad 类注释）")
		return

	_check(not _craft.is_wrecked(), "C1 就位后机体完好")
	# C1b（数据层地面门的确定性回归闸）：不用真实落稳过程——触地抖动的随机性
	# 决定它复不复现（实测回退数据层门后 C1b 仍全绿，机会性断言不是回归闸）。
	# 直接构造 State 喂 _refresh_readings：前向 5 m/s + 下沉 2.5 m/s，
	# angle_of_attack 的分母下限 0.5 会把垂直分量放大成满攻角。
	var st := AircraftFlight.State.new()
	st.velocity = Vector3(0.0, -2.5, -5.0)
	AircraftFlight._refresh_readings(st, true)
	_check(not st.stalled and not st.stall_warning,
		"C1b 地面 + 低速/下沉抖动 → 不报失速（D-069 数据层地面门）")
	# 反向对照（同一 state、只把地面门去掉）：物理层确实会误报——
	# 这条保证 C1b 不是「空闸」，也让根因（alpha 低速放大）本身可被看见。
	AircraftFlight._refresh_readings(st, false)
	_check(st.stalled or st.stall_warning,
		"C1b2 反向对照：非地面 + 同样低速/下沉 → 确实误报失速（证明 C1b 非空闸）")
	_check(_hud._stall_coach != null and _hud._stall_coach._craft == _craft,
		"C2 失速教案已随登机绑定（bind 即重置）")
	_check(_hud._flight_teaching != null \
		and not _hud._flight_teaching.is_seen(FlightTeaching.HINT_LOOKDOWN),
		"C3 教学进度层已就位且本次为首次（B 段已清理存档）")

	# 起飞教练失速让位（U-8 交圈）：同一块教练区不能两套教案同屏。
	# 用 delta=0 调一次，对教练自身计时零副作用（只推进 _elapsed/_step_time）。
	var with_warn: Dictionary = _craft.snapshot()
	with_warn["stall_warning"] = true
	with_warn["stalled"] = true
	with_warn["on_ground"] = false
	_check(_hud._takeoff_coach.step_for(with_warn, 0.0).is_empty(),
		"C4 空中失速时起飞教练让位（教练区归 StallCoach）")
	# C4b（D-069 对偶不变量回归闸）：地面即使带着失速标志也不让位——
	# 让位条件必须与 StallCoach 的接管条件（AGL > 2 m）对偶，否则地面出现
	# 两个教练同时沉默的空档，fp 的「空卡即隐藏」把它放大成整卡消失
	# （本次 full 档 3 项 FAIL 的根因）。
	with_warn["on_ground"] = true
	var c4b := _hud._takeoff_coach.step_for(with_warn, 0.0)
	_check(not c4b.is_empty() and String(c4b["text"]).contains("【F】"),
		"C4b 地面 + 失速标志 → 起飞教练仍显示点火提示（不让位，对偶不变量）")

	# ── 起飞到巡航：地面滑跑 → 抬升到 40 m 净空 ──────────────
	# 直接贴地爬升会在跑道尽头撞上更高的自然地形，故抬升到净空再改平
	# （与 flight_hud_shot ②同思路）。
	_craft.set_engine(true)
	_craft.controls.throttle = 1.0
	_craft.controls.pitch = 0.0
	_craft.controls.roll = 0.0
	var elapsed := 0.0
	while _craft.is_on_floor() and not _craft.is_wrecked() and elapsed < 12.0:
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()
		var s := _craft.snapshot()
		if float(s["airspeed"]) >= float(s["stall_speed"]) * 0.85:
			break
	_craft.global_position.y += 40.0
	_craft.launch(30.0)
	elapsed = 0.0
	while elapsed < PHASE_TIMEOUT and not _craft.is_wrecked():
		var agl := float(_craft.snapshot()["altitude_agl"])
		if not _craft.is_on_floor() and absf(agl - CRUISE_ALT) < 6.0:
			break
		_craft.controls.pitch = clampf((CRUISE_ALT - agl) * 0.08, -0.35, 0.5)
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()
	var cruise := _craft.snapshot()
	_check(not _craft.is_on_floor() and float(cruise["altitude_agl"]) > 15.0,
		"C5 已离地巡航且高于 U-9 触发高度（%.1f m）" % float(cruise["altitude_agl"]))

	# ── U-9：Toast 一次性投递 ──────────────────────────────
	# 起飞教练的「🎉 起飞成功」保持 3.5 s，期间教练区占用、提示不投；
	# 轮询 20 s 足够等到它收起。
	var hint_text := String(FlightTeaching.HINTS[FlightTeaching.HINT_LOOKDOWN])
	var toast_seen := false
	elapsed = 0.0
	while elapsed < 20.0 and not _craft.is_wrecked():
		if _hud._toast_label != null and _hud._toast_label.text == hint_text:
			toast_seen = true
			break
		_craft.controls.pitch = clampf(
			(CRUISE_ALT - float(_craft.snapshot()["altitude_agl"])) * 0.08, -0.35, 0.5)
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()
	_check(toast_seen, "C6 座舱视角已离地后投递「低头看仪表台」提示（Toast）")
	# F-13：投递先记 pending，「看过」要等 Toast tween 自然播完（2.2 s 保持
	# + 0.6 s 淡出）才由 finished 回调确认落盘。轮询等确认完成（5 s 上限）。
	var confirmed := false
	elapsed = 0.0
	while elapsed < 5.0 and not _craft.is_wrecked():
		if _hud._flight_teaching.is_seen(FlightTeaching.HINT_LOOKDOWN):
			confirmed = true
			break
		_craft.controls.pitch = clampf(
			(CRUISE_ALT - float(_craft.snapshot()["altitude_agl"])) * 0.08, -0.35, 0.5)
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()
	_check(confirmed, "C7 Toast 播完后确认看过（F-13 看过才消耗）")
	_check(not _hud._flight_teaching.has_pending(), "C7b 确认后 pending 清空")
	_check(FileAccess.file_exists(FlightTeaching.SAVE_PATH),
		"C8 确认后落盘（user://flight_teaching.json）")
	# 一次性：清掉文本后再等 3 s，不应再次投递。
	if _hud._toast_label != null:
		_hud._toast_label.text = ""
	for i in range(180):
		_craft.controls.pitch = clampf(
			(CRUISE_ALT - float(_craft.snapshot()["altitude_agl"])) * 0.08, -0.35, 0.5)
		await get_tree().physics_frame
	_check(_hud._toast_label == null or _hud._toast_label.text != hint_text,
		"C9 一次性语义：3 s 内不再重复投递")

	# ── 失速教案全流程：怠速拉杆逼失速 → 改出 ────────────────
	# 刻意**不用** flight_hud_shot ③ 那套「6 s 满油门爬升预热 + 收怠速满杆」：
	# 关掉风之后（风是最大的随机源，必须关），满杆会把机体带成 **89° 垂直
	# 爬升**并把速度耗到失速线以下 40 km/h——此时几乎没有气流、舵面没有权限，
	# 改出根本拉不回来（实测 12 s 改出超时、收尾段撞地解体）。改用「怠速 +
	# 中度拉杆 + 姿态上限保护」：让失速发生在**可控姿态**下（教科书式的
	# 减速失速），改出才有得教、教案才走得完。
	_latch = []
	_craft.controls.throttle = 0.0
	# 记「出现过」而不是「此刻是」：`stalled` / `stall_warning` 都带
	# `speed > 3.0` 门且随 alpha 摆动，深失速后瞬时读数会在两次刷新之间翻回
	# false（实测按瞬时读数断言 C10 FAIL）。教案看的是上升沿，探针同样该看
	# 「这一程有没有进入过失速态」。
	var saw_stall := false
	elapsed = 0.0
	while not saw_stall and elapsed < PHASE_TIMEOUT:
		# 姿态上限保护：仰角超过 45° 就松杆到 0.15，避免爬成垂直悬停。
		_craft.controls.pitch = 0.15 \
			if float(_craft.snapshot()["pitch_deg"]) > 45.0 else 0.45
		_latch_step()
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()
		_dbg("stall", elapsed)
		if not is_instance_valid(_craft) or _craft.is_wrecked():
			break
		if _stalling():
			saw_stall = true
	if not is_instance_valid(_craft) or _craft.is_wrecked():
		_check(false, "C10 逼失速过程中机体解体（教案断言全部作废）")
		return
	# 失速态首次出现后**再维持 30 个物理帧**（继续怠速满杆）：HUD 的教练区在
	# `_process` 里刷新，而物理帧与进程帧不是一一对应，一闪而过的失速态可能
	# 整帧没被刷新采到，教案就没机会亮起（回归里 C11~C15 连挂 4 项的根因）。
	# 维持住它，教案才走得到①。
	for i in range(30):
		_latch_step()
		await get_tree().physics_frame
		if not is_instance_valid(_craft) or _craft.is_wrecked():
			break
	# 读教练区前先放过两个进程帧：`process_frame` 信号在节点 `_process`
	# **之前**发出，等 1 次读到的还是上一帧的旧文案（等 2 次才确保拿到
	# 告警那一帧刷新后的结果）。
	await get_tree().process_frame
	await get_tree().process_frame
	_latch_step()
	_check(saw_stall, "C10 怠速满杆后进入失速态（stalled ∨ stall_warning）")
	_check(_hud._coach_main.visible and _hud._coach_main.text.contains("低头"),
		"C11 失速态教练区显示改出第①步（「%s」）" % _hud._coach_main.text)

	# 改出：低头 + 满油门补能。两个退出条件同时满足才收工——
	#   ① 失速态**连续解除 15 帧**（去抖：深失速后 alpha 大幅摆动，单次读数
	#      解除不算数）；
	#   ② 俯角真的压到 −8° 以下。这是关键：满拉杆把机体带进筋斗后，姿态可能
	#      停在 +70° 抬头（实测 +73°），俯角远在教案 ①→② 的 −3° 门槛之上，
	#      只满足①就收工的话教案会永远停在第①步。−8° 而非 −3°：给 0.3 s
	#      维持判据留出门槛余量。
	_craft.controls.throttle = 1.0
	# −0.3 而非 −0.6：改出太猛速度回得太快，失速余量会「一口气」越过 ③→成功
	# 的 10 km/h 门槛；缓改出让余量慢慢爬，②③两步才有机会入镜。
	_craft.controls.pitch = -0.3
	var clear_frames := 0
	var rec_ms := Time.get_ticks_msec()
	var rec_frames := 0
	while Time.get_ticks_msec() - rec_ms < 12000 and rec_frames < 1200:
		_latch_step()
		# 逐**进程帧**采样：无头下进程帧快于物理帧，按物理帧 latch 会整帧
		# 跳过只存在 1 帧的第③步（实测漏抓两次）。
		await get_tree().process_frame
		rec_frames += 1
		if not is_instance_valid(_craft) or _craft.is_wrecked():
			break
		if _stalling():
			clear_frames = 0
		else:
			clear_frames += 1
		if clear_frames >= 15 and float(_craft.snapshot()["pitch_deg"]) <= -8.0:
			break
	print("DBG recover frames=", rec_frames, " ms=", Time.get_ticks_msec() - rec_ms)
	if not is_instance_valid(_craft) or _craft.is_wrecked():
		_check(false, "C12 改出过程中机体解体（教案后段断言作废）")
		return
	_check(not _stalling(), "C12 低头补能后失速态解除")
	# 保持浅俯冲补能 5 s（墙钟计时，不用帧数——进程帧与物理帧并非一一对应，
	# 用帧数算「等 5 s」会横跨十几秒）。俯角已压过门槛，②→③→成功 在这段
	# 时间里依次走完。逐进程帧 latch：第③步的可见时长取决于余量从 0 爬到
	# 10 km/h 的快慢，按物理帧采样会整帧跳过它（实测漏抓）。
	# 高度保持目标取**进入本段时的高度**：巡航目标 40 m 远低于筋斗后的 160 m，
	# 照它做等于命令飞机俯冲回 40 m；AGL 只测正下方，前方坡地不在读数里，
	# 实测 5 s 浅俯冲一头撞进坡地、机体解体（教案后段断言全部作废）。
	var hold_agl := float(_craft.snapshot()["altitude_agl"])
	var hold_ms := Time.get_ticks_msec()
	var frames := 0
	while Time.get_ticks_msec() - hold_ms < 8000 and frames < 900:
		_latch_step()
		await get_tree().process_frame
		frames += 1
		if not is_instance_valid(_craft) or _craft.is_wrecked():
			break
		_craft.controls.pitch = clampf(
			(hold_agl - float(_craft.snapshot()["altitude_agl"])) * 0.08, -0.15, 0.35)
		# 拿到成功文案就收工：教案后段的正反馈已经取到，多飞一秒多一分
		# 撞地风险（探针的价值在断言，不在续航）。
		if _latch_any("改出成功"):
			break
	print("DBG hold frames=", frames, " ms=", Time.get_ticks_msec() - hold_ms,
		" hold_agl=%.1f" % hold_agl)
	if not is_instance_valid(_craft) or _craft.is_wrecked():
		_check(false, "C13 收尾平飞中机体解体（成功步断言作废）")
		return
	print("DBG latch: ", _latch)
	_check(_latch_any("油门推满"), "C13 教案第②步出现过（油门推满）")
	_check(_latch_any("保持低头"), "C14 教案第③步出现过（等速度恢复）")
	_check(_latch_any("改出成功"), "C15 教案收尾出现「改出成功」")
	# 步序：教案只能单向推进，①→②→③→成功 的首次出现顺序必须严格递增。
	# ①的两句文案都以「【↓】低头」收尾，第③步的「保持低头」不含「【↓】」，
	# 用它当①的标记不会误匹配到③。
	var i1 := _latch_index("【↓】低头")
	var i2 := _latch_index("油门推满")
	var i3 := _latch_index("保持低头")
	var i4 := _latch_index("改出成功")
	_check(i1 >= 0 and i1 < i2 and i2 < i3 and i3 < i4,
		"C15b 教案单向推进：①→②→③→成功 首次出现顺序递增（%d<%d<%d<%d）"
			% [i1, i2, i3, i4])
	# ①的两种语气：先「要失速了」（仅接近失速），随能量继续耗尽转为「失速了！」。
	_check(_latch_any("失速了！") and _latch_any("要失速了"),
		"C15c ①的两种语气都出现过（完全失速 / 仅接近失速）")

	# 下机：教练区随飞行面板一起收起（U-8 上线后教练区是失速唯一文字通道）。
	_player.exit_aircraft()
	for i in range(10):
		await get_tree().physics_frame
	_check(not _hud._flight_panel.visible, "C16 下机后飞行面板与教练区一起隐藏")
	_check(_hud._stall_coach._craft == null,
		"C17 下机后失速教案解绑（下次登机从头教）")


# ── 工具 ──────────────────────────────────────────────────
## StallCoach 只认这 8 个键（其余 snapshot 字段它不看）。
## `stall_speed` 默认 13.1 m/s（≈47 km/h，轻型机空载失速速度同量级）；A20
## 会传别的值来验「余量门槛随襟翼/载重派生」而不是写死 km/h。
func _snap(stalled: bool, warn: bool, airspeed: float, pitch: float,
		throttle: float, agl: float, engine: bool, stall_speed: float = 13.1) -> Dictionary:
	return {
		"stalled": stalled,
		"stall_warning": warn,
		"airspeed": airspeed,
		"stall_speed": stall_speed,
		"pitch_deg": pitch,
		"throttle": throttle,
		"altitude_agl": agl,
		"engine": engine,
	}


func _ctx(base: Dictionary, key: String, value: bool) -> Dictionary:
	var out: Dictionary = base.duplicate()
	out[key] = value
	return out


## 教案推进诊断：每 30 帧打一行（失速余量、俯仰角、教练文案），定位
## 「教案停在第①步」这类时序问题——单看断言只知道没到，不知道卡在哪。
func _dbg(phase: String, elapsed: float) -> void:
	if int(elapsed * 60.0) % 30 != 0:
		return
	var s := _craft.snapshot()
	var margin := (float(s["airspeed"]) - float(s["stall_speed"])) \
		* AircraftFlight.MPS_TO_KMH
	print("DBG %s t=%.1f warn=%s stalled=%s pitch=%.1fdeg margin=%.1fkm/h agl=%.1f coach=「%s」" % [
		phase, elapsed, bool(s["stall_warning"]), bool(s["stalled"]),
		float(s["pitch_deg"]), margin, float(s["altitude_agl"]),
		_hud._coach_main.text if _hud != null and _hud._coach_main != null else "",
	])


## 「失速态」= `stalled ∨ stall_warning`，与 StallCoach 内部的 `warning`
## 同式。两个标志都带 `speed > 3.0` 门且随 alpha 摆动，探针一律用这个合并
## 口径，不单独断言某一个。
func _stalling() -> bool:
	var s := _craft.snapshot()
	return bool(s["stalled"]) or bool(s["stall_warning"])


func _latch_step() -> void:
	if _hud == null or _hud._coach_main == null:
		return
	# 只 latch 真正显示出来的那一句：教练区隐藏时 _coach_main.text 保留
	# 上一次的值（HUD 只在 active 时才写 text），照单全收会把隐藏期间的
	# 陈旧文案算进来——实测「爬升中：轻拉【↑】」在 AGL 138 m 时仍躺在
	# latch 里，那是起飞教练收起后残留的旧文本。
	if not _hud._coach_main.is_visible_in_tree():
		return
	var text := _hud._coach_main.text
	if not text.is_empty() and not _latch.has(text):
		_latch.append(text)


func _latch_any(needle: String) -> bool:
	return _latch_index(needle) >= 0


## 含该关键字的文案在 latch 中首次出现的下标（-1 = 没出现过）。
func _latch_index(needle: String) -> int:
	for i in _latch.size():
		if (_latch[i] as String).contains(needle):
			return i
	return -1


func _write_teaching(text: String) -> void:
	var file := FileAccess.open(FlightTeaching.SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()


func _remove_teaching() -> void:
	if FileAccess.file_exists(FlightTeaching.SAVE_PATH):
		DirAccess.remove_absolute(
			ProjectSettings.globalize_path(FlightTeaching.SAVE_PATH))


func _seen_count() -> int:
	if not FileAccess.file_exists(FlightTeaching.SAVE_PATH):
		return -1
	var file := FileAccess.open(FlightTeaching.SAVE_PATH, FileAccess.READ)
	if file == null:
		return -1
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return -1
	if typeof(json.data) != TYPE_DICTIONARY:
		return -1
	var raw: Variant = (json.data as Dictionary).get("seen", [])
	if typeof(raw) != TYPE_ARRAY:
		return -1
	return (raw as Array).size()
