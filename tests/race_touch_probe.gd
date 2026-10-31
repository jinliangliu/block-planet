extends Node
## 竞速触屏操控层无头探针（race_touch）：
##   A. 键盘路径零回归：没有触屏时不建按钮、touch_input().active == false；
##   B. 触屏输入契约：自动油门 / 转向轴 / 刹车压制油门 / 手刹；
##   C. 触屏层结构：6 个按钮到位、容器不吃输入、按住语义接线、面板让位；
##   D. 多指兜底：模拟「第二根手指」点按钮也能改状态（emulate_mouse_from_touch
##      只翻译第一根手指）；
##   E. 抬指事件丢失的自愈：比赛途中的教学弹窗/切后台吞掉 up 事件时不能残留刹车
##      （index 复用即清残留、无手指即归零、失焦全清）。
##
## 运行：Godot_console.exe --headless --path . res://tests/race_touch_probe.tscn
## 本探针不加载 main.tscn、不写任何 user:// 存档（D-010 铁律）。

const LEFT_BTN := "SteerLeft"
const RIGHT_BTN := "SteerRight"
const BRAKE_BTN := "Brake"
const HANDBRAKE_BTN := "Handbrake"
const RESTART_BTN := "RestartBtn"
const EXIT_BTN := "ExitBtn"

const STEER_SIZE := Vector2(132, 132)
const BRAKE_SIZE := Vector2(132, 132)
const HANDBRAKE_SIZE := Vector2(104, 104)
const ACTION_SIZE := Vector2(96, 56)

var _fails := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	await _test_keyboard_path()
	await _test_touch_contract()
	await _test_touch_structure()
	_finish()


func _finish() -> void:
	print("RACE_TOUCH_TEST_DONE fails=%d" % _fails)
	if _fails == 0:
		print("RACE_TOUCH_TEST_OK")
		get_tree().quit(0)
	else:
		print("RACE_TOUCH_TEST_FAILED")
		get_tree().quit(1)


# ────────────────────── A. 键盘路径：一个像素都不变 ──────────────────────
func _test_keyboard_path() -> void:
	var hud := RaceHUD.new()
	hud.force_touch = false
	add_child(hud)
	await get_tree().process_frame

	var d := hud.touch_input()
	_check(not bool(d.get("active", true)), "键盘路径：touch_input().active == false")
	# 没有触屏层就不该自作主张给油门：消费端此时走键盘分支。
	_check(float(d.get("throttle", -1.0)) == 0.0, "键盘路径：throttle == 0（不抢键盘的油门）")

	var buttons: Array[Node] = hud.find_children("*", "Button", true, false)
	_check(buttons.is_empty(), "键盘路径：界面里没有新增任何按钮（%d 个）" % buttons.size())

	# 消费端/老代码误调内部设置方法时必须是无害空操作，不能崩、也不能把 active 变真。
	hud._set_steer_axis(1.0)
	hud._set_brake(true)
	hud._set_handbrake(true)
	var after := hud.touch_input()
	_check(not bool(after.get("active", true)), "键盘路径：_set_* 不会把 active 变真（不崩）")
	_check(float(after.get("steer", 9.0)) == 0.0
		and float(after.get("brake", 9.0)) == 0.0
		and not bool(after.get("handbrake", true)),
		"键盘路径：_set_* 不改动输入快照")


# ────────────────────── B. 触屏输入契约（消费端按此写） ──────────────────────
func _test_touch_contract() -> void:
	var hud := RaceHUD.new()
	# 无头环境没有触摸屏，靠公开开关把触屏层建出来。必须在 add_child 之前置位。
	hud.force_touch = true
	add_child(hud)
	await get_tree().process_frame

	var d := hud.touch_input()
	_check(bool(d.get("active", false)), "触屏路径：touch_input().active == true")
	_check(float(d.get("steer", 9.0)) == 0.0, "初始 steer == 0.0")
	_check(float(d.get("throttle", 0.0)) == 1.0, "初始自动油门 throttle == 1.0（只按左右就能开）")
	_check(float(d.get("brake", 9.0)) == 0.0 and not bool(d.get("handbrake", true)),
		"初始 brake == 0.0 且 handbrake == false")

	hud._set_steer_axis(-1.0)
	_check(float(hud.touch_input().get("steer", 9.0)) == -1.0, "左转 → steer == -1.0")
	hud._set_steer_axis(1.0)
	_check(float(hud.touch_input().get("steer", 9.0)) == 1.0, "右转 → steer == +1.0")
	hud._set_steer_axis(0.0)
	_check(float(hud.touch_input().get("steer", 9.0)) == 0.0, "松手 → steer 回 0.0")

	hud._set_brake(true)
	var braking := hud.touch_input()
	_check(float(braking.get("brake", 0.0)) == 1.0
		and float(braking.get("throttle", 1.0)) == 0.0,
		"踩刹车：brake == 1.0 且自动油门压成 0.0")
	hud._set_brake(false)
	var released := hud.touch_input()
	_check(float(released.get("brake", 9.0)) == 0.0
		and float(released.get("throttle", 0.0)) == 1.0,
		"松刹车：brake == 0.0 且油门回到 1.0")

	hud._set_handbrake(true)
	_check(bool(hud.touch_input().get("handbrake", false)), "按住手刹 → handbrake == true")
	hud._set_handbrake(false)
	_check(not bool(hud.touch_input().get("handbrake", true)), "松手刹 → handbrake == false")

	# 残留状态清理：重开一场时消费端会调 clear_touch_input()。
	hud._set_steer_axis(-1.0)
	hud._set_brake(true)
	hud.clear_touch_input()
	var cleared := hud.touch_input()
	_check(float(cleared.get("steer", 9.0)) == 0.0
		and float(cleared.get("brake", 9.0)) == 0.0
		and float(cleared.get("throttle", 0.0)) == 1.0,
		"clear_touch_input() 清空残留（否则重开后车一出发就被刹车按住）")

	# 收尾归零，避免后续用例读到残留状态。
	hud._set_steer_axis(0.0)
	hud._set_brake(false)
	hud._set_handbrake(false)


# ────────────────────── C/D. 触屏层结构与多指兜底 ──────────────────────
func _test_touch_structure() -> void:
	var hud := RaceHUD.new()
	hud.force_touch = true
	add_child(hud)
	# 容器在孩子加入后的排序帧里算布局，等两帧再读矩形。
	await get_tree().process_frame
	await get_tree().process_frame

	var pad := hud.find_child("TouchPad", true, false) as Control
	_check(pad != null, "触屏层 TouchPad 已构建")
	if pad == null:
		return
	_check(pad.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"触屏层容器不吃输入（中央倒计时/顶部面板不被挡）")

	var buttons: Array[Node] = hud.find_children("*", "Button", true, false)
	_check(buttons.size() == 6, "触屏层一共 6 个按钮（%d）" % buttons.size())

	var names: Array[String] = [LEFT_BTN, RIGHT_BTN, BRAKE_BTN, HANDBRAKE_BTN, RESTART_BTN, EXIT_BTN]
	var missing := ""
	for n: String in names:
		if hud.find_child(n, true, false) == null:
			missing += n + " "
	_check(missing.is_empty(), "6 个按钮名字齐全（缺：%s）" % missing)

	var left := hud.find_child(LEFT_BTN, true, false) as Button
	var brake := hud.find_child(BRAKE_BTN, true, false) as Button
	var handbrake := hud.find_child(HANDBRAKE_BTN, true, false) as Button
	var restart := hud.find_child(RESTART_BTN, true, false) as Button
	var exit_btn := hud.find_child(EXIT_BTN, true, false) as Button
	if left == null or brake == null or handbrake == null or restart == null or exit_btn == null:
		return

	_check(restart.visible and exit_btn.visible,
		"「↻ 重开」「✕ 退出」在场景树里可见（Android 没有 Esc，退出是必需品）")
	_check(hud.has_signal("touch_exit_requested") and hud.has_signal("touch_restart_requested"),
		"对外信号 touch_exit_requested / touch_restart_requested 存在")
	_check(exit_btn.pressed.get_connections().size() > 0
		and restart.pressed.get_connections().size() > 0,
		"重开/退出已接 pressed（点一下即触发信号）")

	# 按住语义：驾驶按钮必须接 button_down/button_up，且不能接 pressed。
	_check(left.button_down.get_connections().size() > 0
		and left.button_up.get_connections().size() > 0
		and left.pressed.get_connections().is_empty(),
		"转向按钮用按住语义（button_down/button_up，不用 pressed）")
	_check(brake.button_down.get_connections().size() > 0
		and brake.button_up.get_connections().size() > 0
		and handbrake.button_down.get_connections().size() > 0
		and handbrake.button_up.get_connections().size() > 0,
		"刹车/手刹用按住语义")

	_check(left.custom_minimum_size == STEER_SIZE
		and brake.custom_minimum_size == BRAKE_SIZE
		and handbrake.custom_minimum_size == HANDBRAKE_SIZE
		and restart.custom_minimum_size == ACTION_SIZE,
		"热区尺寸：转向/刹车 132²、手刹 104²、重开/退出 96×56")
	_check(left.size.x >= 120.0 and left.size.y >= 120.0,
		"转向按钮实际布局尺寸 %.0f×%.0f（锚点+min_size 生效）" % [left.size.x, left.size.y])

	# ── D. 多指兜底：第二根手指（index != 第一根）也要能操作 ──
	var rect := brake.get_global_rect()
	_check(rect.size.x > 0.0 and rect.size.y > 0.0,
		"刹车按钮有有效命中矩形（%.0f×%.0f）" % [rect.size.x, rect.size.y])
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var down := InputEventScreenTouch.new()
	down.index = 1
	down.pressed = true
	down.position = rect.get_center()
	hud._input(down)
	_check(float(hud.touch_input().get("brake", 0.0)) == 1.0,
		"第二根手指点刹车 → brake == 1.0（多指兜底生效）")
	var up := InputEventScreenTouch.new()
	up.index = 1
	up.pressed = false
	up.position = rect.get_center()
	hud._input(up)
	_check(float(hud.touch_input().get("brake", 9.0)) == 0.0,
		"第二根手指抬起 → brake 回 0.0")
	_check(hud._down_touches.is_empty(), "抬指后触摸记账清空（无残留手指）")

	# ── E. 抬指事件丢失的自愈（比赛途中的教学弹窗 / 切后台） ──
	# 场景：按住刹车 → 教学弹窗弹出 → 抬指事件被吞 → 状态残留「一直在刹车」。
	var left_rect := left.get_global_rect()
	if left_rect.size.x <= 0.0:
		return

	# ① 同一 index 又按下来（Android 复用 pointer id）= 上次抬指丢了 → 先清残留。
	hud._input(_touch_event(0, true, rect.get_center()))
	_check(float(hud.touch_input().get("brake", 0.0)) == 1.0, "按住刹车（不发抬指，模拟事件被吞）")
	hud._input(_touch_event(0, true, left_rect.get_center()))
	var revived := hud.touch_input()
	_check(float(revived.get("brake", 9.0)) == 0.0 and float(revived.get("steer", 0.0)) == -1.0,
		"复用 index 再按 = 抬指丢失 → 清残留刹车并接手新按键")
	hud._input(_touch_event(0, false, left_rect.get_center()))

	# ② 一根手指都不在屏幕上 ⇒ 状态必须是零。
	hud._input(_touch_event(2, true, rect.get_center()))
	hud._input(_touch_event(3, true, left_rect.get_center()))
	hud._input(_touch_event(2, false, rect.get_center()))
	hud._input(_touch_event(3, false, left_rect.get_center()))
	var idle := hud.touch_input()
	_check(float(idle.get("brake", 9.0)) == 0.0 and float(idle.get("steer", 9.0)) == 0.0
		and float(idle.get("throttle", 0.0)) == 1.0,
		"两指先后抬起 → 全部归零、自动油门恢复")

	# ③ 失焦（通知栏/来电/Home 键）→ 全清。
	hud._input(_touch_event(0, true, rect.get_center()))
	_check(float(hud.touch_input().get("brake", 0.0)) == 1.0, "失焦前刹车处于按下态")
	hud._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(float(hud.touch_input().get("brake", 9.0)) == 0.0
		and float(hud.touch_input().get("throttle", 0.0)) == 1.0,
		"失焦即清空触屏状态（回来时不会带着刹车）")

	# 面板让位：触屏版把油表/圈速面板抬到按钮之上，否则被按钮整块盖住。
	_check(hud._panel_bl.offset_bottom < -100.0 and hud._panel_tr.offset_top > 50.0,
		"触屏版面板已让位（左下 offset_bottom=%.0f，右上 offset_top=%.0f）"
		% [hud._panel_bl.offset_bottom, hud._panel_tr.offset_top])


func _touch_event(index: int, pressed: bool, pos: Vector2) -> InputEventScreenTouch:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.pressed = pressed
	e.position = pos
	return e


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_fails += 1
		print("FAIL: " + label)
