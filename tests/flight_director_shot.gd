extends Node
## 飞行指引十字（D-054）取证（窗口模式：截图走 Vulkan，headless 下
## frame_post_draw 永不触发会挂死）。不跑真实世界，直接驱动控件本身——
## 手搓一份 FlightInstruments，精确制造已知偏差，三段取证 + 几何断言：
##   ① 对准：偏差≈0 → 绿色十字套在中心准星上（带四角捕获括号）；
##   ② 偏航 + 偏高：目标在右下方 → 十字右下偏移、转琥珀（含 ▲▼ 提示）；
##   ③ 起飞爬升：离地爬升中 → 十字上移到 8° 爬升指令位，标签「起飞」。
## 顺带把座舱仪表簇（CockpitInstruments）一起画出来当背景，取证「十字与
## 底部仪表板不打架」这件事（D-053 后 dash 占屏高 25.2%）。
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/flight_director_shot.tscn

const SHOT_DIR := "res://tmp"

var _fails := 0
var _fd: FlightDirector = null
var _cockpit: CockpitInstruments = null


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		_fails += 1
		print("FAIL: ", msg)


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


func _wait(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


func _ready() -> void:
	await _run()


func _run() -> void:
	SaveGuard.snapshot()
	var layer := CanvasLayer.new()
	add_child(layer)
	# 座舱仪表簇作背景（证明十字与它不打架），再叠指引十字（后加 = 上层）。
	_cockpit = CockpitInstruments.new()
	layer.add_child(_cockpit)
	_fd = FlightDirector.new()
	layer.add_child(_fd)
	await _wait(4)

	var vp := get_viewport().get_visible_rect().size
	print("DBG viewport=", vp)

	# ── ① 对准：目标正前方、正在 3° 下滑道上 ──
	var target := Vector3(0.0, 0.0, 0.0)
	var d := 400.0
	var on_path_y := d * tan(deg_to_rad(3.0))
	# 机体在目标 +Z 方向 400m 处、朝 −Z（heading=180°）正对目标。
	var pos := Vector3(0.0, on_path_y, d)
	var fi := _mk_instruments(pos, target, 0.0, 90.0, on_path_y, -2.1)
	_fd.set_guide(target)
	_fd.refresh(pos, fi)
	_cockpit.refresh(fi)
	_check(_fd.current_mode() == FlightDirector.Mode.APPROACH,
		"① 进近态（实得 %d）" % _fd.current_mode())
	_check(absf(_fd.deviation_deg().x) < 0.5 and absf(_fd.deviation_deg().y) < 0.5,
		"① 对准偏差 h=%.2f° v=%.2f°（应≈0）" % [_fd.deviation_deg().x,
			_fd.deviation_deg().y])
	await _snap("fd_aligned.png")

	# ── ② 偏航 + 偏高：机头左偏 18°、高度比下滑道高 30m ──
	var pos2 := Vector3(0.0, on_path_y + 30.0, d)
	var fi2 := _mk_instruments(pos2, target, -18.0, 90.0, on_path_y + 20.0, -1.0)
	_fd.refresh(pos2, fi2)
	_cockpit.refresh(fi2)
	_check(_fd.deviation_deg().x > 5.0,
		"② 机头左偏 18° → 横向指令 +%.1f°（十字右移）" % _fd.deviation_deg().x)
	_check(_fd.deviation_deg().y < -1.0,
		"② 高于下滑道 → 垂直指令 %.1f°（十字下移，提示低头追回）"
			% _fd.deviation_deg().y)
	await _snap("fd_offset.png")

	# ── ③ 起飞爬升：贴地刚离地、正在爬升 ──
	var t3 := Vector3(0.0, 40.0, 0.0)
	var pos3 := Vector3(0.0, 44.0, 60.0)
	var fi3 := _mk_instruments(pos3, t3, 0.0, 70.0, 4.0, 3.5)
	_fd.set_guide(t3)
	_fd.refresh(pos3, fi3)
	_cockpit.refresh(fi3)
	_check(_fd.current_mode() == FlightDirector.Mode.TAKEOFF,
		"③ 爬升 → TAKEOFF（实得 %d）" % _fd.current_mode())
	_check(_fd.deviation_deg().y > 0.0,
		"③ 爬升角不足 → 垂直指令 +%.1f°（十字上移，提示继续抬头）"
			% _fd.deviation_deg().y)
	await _snap("fd_takeoff.png")

	# ── ④ 几何：十字与底部仪表板不重叠（含标签）──
	var s := CockpitInstruments.ui_scale(vp)
	var frame := CockpitInstruments.frame_rects(vp)
	var dash_r: Rect2 = frame["dash"]
	var off := FlightDirector.cross_offset(180.0, 180.0, s)   # 双向满偏
	var p: Vector2 = vp * 0.5 + off
	var bot: float = p.y + (FlightDirector.ARM + 8.0) * s
	_check(bot <= dash_r.position.y,
		"④ 满偏十字底 %.0f 不压仪表板顶 %.0f" % [bot, dash_r.position.y])
	_check(p.x - (FlightDirector.ARM + 8.0) * s >= 0.0
		and p.x + (FlightDirector.ARM + 8.0) * s <= vp.x,
		"④ 满偏十字横向在屏内（x %.0f..%.0f）"
			% [p.x - (FlightDirector.ARM + 8.0) * s, p.x + (FlightDirector.ARM + 8.0) * s])

	# 无导航目标 → 不显示（下机/清目标不留残影）。
	_fd.clear_guide()
	_fd.refresh(pos, fi)
	_check(_fd.current_mode() == FlightDirector.Mode.OFF,
		"⑤ clear_guide 后 mode=OFF")

	SaveGuard.restore()
	print("FLIGHT_DIRECTOR_DONE fails=%d" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


## 手搓读数：yaw 为机头相对「朝 −Z」的偏转角（度），agl 离地高度，vs 升降率。
func _mk_instruments(pos: Vector3, target: Vector3, yaw: float, kmh: float,
		agl: float, vs: float) -> FlightInstruments:
	var fi := FlightInstruments.new()
	fi.set_navigation(target, "机场")
	# 航向约定：Basis 绕 UP 转 θ 后 heading = (θ + 180) mod 360，故 yaw=0 时
	# 机头朝 −Z（heading 180°），正对位于 −Z 方向的目标 → 偏差 0。yaw 为负
	# 时机头左偏，目标出现在右侧（dev_h 为正）。
	var basis := Basis.IDENTITY.rotated(Vector3.UP, deg_to_rad(yaw))
	var reading := {
		"position": pos, "kmh": kmh, "altitude": pos.y, "altitude_agl": agl,
		"vertical_speed": vs, "stall_speed": 12.0, "engine": true,
		"throttle": 1.0, "fuel_pct": 1.0, "gear_down": false,
	}
	# 升降率是平滑量（VSI_TAU），连跑多帧让它收敛到目标值。
	for _i in range(40):
		fi.update(reading, basis, 0.1)
	return fi


func _snap(file_name: String) -> void:
	await _wait(2)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path(file_name))
	print("DBG ", file_name, " mode=", _fd.current_mode(),
		" dev=", _fd.deviation_deg())
