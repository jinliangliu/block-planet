extends Node
## 一键返航 UI / 引导层无头探针（D-098，return_hud）：只做静态契约断言，
## 不加载 main.tscn、不写任何 user:// 存档（D-010）。禁止由本 worker 运行；
## 由核心 worker 统一登记 tmp/run_regression.sh 并串行放行。
##   A. 跨文件契约：HUD.return_flight_requested 信号存在；set_return_active()
##      在 _fd 为空时安全（不报错、不崩）；
##   B. flight_director 契约不回退：label_text() 偏差 170° 仍返回「掉头」；
##      guide_alpha() 跨距离恒 1.0（引导层与 D-090 衰减解耦）；
##   C. turn_readout() 四档边界：起始掉头 / 转对半程 / 转过头 / 到达捕获；
##   D. 触屏控件：返航按钮热区 ≥112×64、视角区 ≥44×44，均挂 _flight_touch
##      （登机可见容器、不复用被隐藏的 _touch_walk），按钮接 pressed、视角区
##      mouse_filter=STOP 且接 gui_input、返航按钮只 emit 同一条 signal。
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/return_hud_probe.tscn

var _fails := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	_check_signal_and_forward()
	_check_label()
	_check_guide_alpha()
	_check_turn_readout()
	await _check_touch_widgets()
	_finish()


## A. 信号与转发安全。裸 HUD（未 setup / 未 _build）时 _fd 与 _instrument_hud
## 均为 null：set_return_active() 必须只切按钮文案后安全早退，绝不报错。
func _check_signal_and_forward() -> void:
	var hud := HUD.new()
	add_child(hud)
	_check(hud.has_signal("return_flight_requested"),
		"A HUD.return_flight_requested 信号存在（跨文件契约对齐）")
	hud.set_return_active(true)
	hud.set_return_active(false)
	_check(hud._fd == null,
		"A _fd 为空时 set_return_active() 安全返回（不报错、不崩）")
	hud.free()


## B. label_text() 逐字契约不回退（D-054 §4 / flight_director_probe.gd:222）。
func _check_label() -> void:
	var fd := FlightDirector.new()
	fd._dev_h = 170.0
	fd._dev_v = 0.0
	fd._mode = FlightDirector.Mode.APPROACH
	_check(fd.label_text() == "掉头",
		"B label_text() 偏差 170° 仍返回「掉头」（实得 %s）" % fd.label_text())
	fd.free()


## C. 引导层 alpha 与 D-090 的 col 衰减解耦：任意距离恒 1.0。
func _check_guide_alpha() -> void:
	_check(is_equal_approx(FlightDirector.guide_alpha(0.0), 1.0)
		and is_equal_approx(FlightDirector.guide_alpha(800.0), 1.0)
		and is_equal_approx(FlightDirector.guide_alpha(99999.0), 1.0),
		"C guide_alpha() 跨距离恒 1.0（引导层不随距离淡出）")


## D. turn_readout() 四档边界 + 不变量。
func _check_turn_readout() -> void:
	var a := FlightDirector.turn_readout(170.0, 1.0, 0.0, 170.0)
	_check(String(a["dir"]) == "掉头" and is_equal_approx(float(a["total"]), 170.0)
		and is_equal_approx(float(a["remaining"]), 170.0)
		and is_equal_approx(float(a["progress"]), 0.0)
		and not bool(a["wrong_way"]) and not bool(a["arrived"]),
		"D 档①起始掉头：dir=掉头 / remaining=170 / progress=0 / 未到达")
	var b := FlightDirector.turn_readout(170.0, 1.0, 85.0, 85.0)
	_check(String(b["dir"]) == "右转" and is_equal_approx(float(b["remaining"]), 85.0)
		and is_equal_approx(float(b["progress"]), 0.5) and not bool(b["arrived"]),
		"D 档②转对半程：dir=右转 / remaining=85 / progress=0.5")
	var c := FlightDirector.turn_readout(170.0, 1.0, 180.0, -10.0)
	_check(bool(c["wrong_way"]) and float(c["remaining"]) >= 0.0
		and is_equal_approx(float(c["progress"]), 1.0),
		"D 档③转过头：wrong_way=true / remaining≥0 / progress 钳在 1.0")
	var d := FlightDirector.turn_readout(170.0, 1.0, 169.0, 1.0)
	_check(bool(d["arrived"]) and float(d["remaining"]) >= 0.0
		and float(d["progress"]) >= 0.0 and float(d["progress"]) <= 1.0,
		"D 档④进入 CAPTURE_DEG：arrived=true / remaining≥0 / progress∈[0,1]")
	var ok := true
	for dev in [-200.0, -30.0, 0.0, 60.0, 150.0, 179.0, 360.0]:
		var r := FlightDirector.turn_readout(180.0, 1.0, 40.0, float(dev))
		if float(r["remaining"]) < 0.0 or float(r["progress"]) < 0.0 \
				or float(r["progress"]) > 1.0:
			ok = false
	_check(ok, "D 不变量：remaining≥0 且 progress∈[0,1]（多偏差扫描）")


## E. 触屏控件结构 / 热区 / 让位容器 / 接线。
## 无头环境 is_touchscreen_available()=false，直接调 _build_flight_touch()
## 把飞行触屏层铺出来（该函数构建期不依赖 _player，按钮回调不在构建时执行）。
func _check_touch_widgets() -> void:
	var hud := HUD.new()
	add_child(hud)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.add_child(root)
	hud._build_flight_touch(root)
	await get_tree().process_frame
	await get_tree().process_frame

	var pad := hud._flight_touch
	_check(pad != null, "E 飞行触屏层 _flight_touch 已构建")
	if pad == null:
		hud.free()
		return
	var btn := hud.find_child("ReturnBtn", true, false) as Button
	var look := hud.find_child("FlightLookArea", true, false) as Control
	var freelook := hud.find_child("FreeLookBtn", true, false) as Button
	_check(btn != null, "E 触屏「返航」按钮 ReturnBtn 存在")
	_check(look != null, "E 触屏飞行视角区 FlightLookArea 存在")
	_check(freelook != null, "E 触屏「自由观察」按钮 FreeLookBtn 存在")
	if btn == null or look == null or freelook == null:
		hud.free()
		return
	# 热区：儿童向 ≥44×44；返航按钮按规格 ≥112×64。
	_check(btn.custom_minimum_size.x >= 112.0 and btn.custom_minimum_size.y >= 64.0,
		"E 返航按钮热区 %.0f×%.0f ≥112×64" % [btn.custom_minimum_size.x, btn.custom_minimum_size.y])
	_check(look.custom_minimum_size.x >= 44.0 and look.custom_minimum_size.y >= 44.0,
		"E 视角区热区下限 %.0f×%.0f ≥44×44" % [look.custom_minimum_size.x, look.custom_minimum_size.y])
	var lr := look.get_global_rect()
	_check(lr.size.x >= 44.0 and lr.size.y >= 44.0,
		"E 视角区实际布局命中矩形 %.0f×%.0f ≥44×44" % [lr.size.x, lr.size.y])
	_check(freelook.custom_minimum_size.x >= 44.0 and freelook.custom_minimum_size.y >= 44.0,
		"E 自由观察按钮热区 ≥44×44")
	# 「驾驶态可见」：挂 _flight_touch（登机 pad.visible=true）而非被隐藏的 _touch_walk。
	_check(pad.is_ancestor_of(btn) and pad.is_ancestor_of(look) and pad.is_ancestor_of(freelook),
		"E 返航/视角区/自由观察均挂 _flight_touch（登机随 pad 显示，不复用 _touch_walk）")
	_check(hud._touch_walk == null or not hud._touch_walk.is_ancestor_of(btn),
		"E 返航按钮不是被隐藏的 _touch_walk 的后代")
	# 接线：按钮接 pressed；视角区 STOP 且接 gui_input（拖拽可达相机）。
	_check(btn.pressed.get_connections().size() > 0,
		"E 返航按钮已接 pressed（只 emit return_flight_requested）")
	_check(look.mouse_filter == Control.MOUSE_FILTER_STOP
		and look.gui_input.get_connections().size() > 0,
		"E 视角区 mouse_filter=STOP 且已接 gui_input")
	# 按钮文案：常态含「N 返航」+ 接管提示；set_return_active 切换激活态。
	_check(btn.text.contains("N 返航") and btn.text.contains("接管"),
		"E 返航按钮常态文案含「N 返航」与「接管」提示")
	hud.set_return_active(true)
	_check(btn.text.contains("取消返航"),
		"E set_return_active(true) 切「取消返航 / 返航中」")
	hud.set_return_active(false)
	_check(btn.text.contains("N 返航"),
		"E set_return_active(false) 复位「N 返航」")
	hud.free()


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS  " + label)
	else:
		_fails += 1
		print("FAIL  " + label)


func _finish() -> void:
	print("RESULT return_hud_probe: FAIL=%d" % _fails)
	get_tree().quit(0 if _fails == 0 else 1)
