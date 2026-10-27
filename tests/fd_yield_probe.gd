extends Node
## 飞行指引十字让位探针（D-074）：纯逻辑构造式断言——不实例化 main.tscn，
## 直接 new 一个 FlightInstrumentHUD，塞入假机体/假相机，逐帧 tick 驱动其
## FD 可见门，验证「拉升类 WARNING（地形前视 / 过低）活跃时指引十字退场，
## caution 级保留」。沿用 D-071 同一可见门（flight_instrument_hud.gd:188）。
##
## 与 D-071 探针的关系：D-071 只门 _stall_coach_active；本探针钉的是同一条
## 可见门上新增的 terrain_warn/alt_warn 两项——证明「拉升」类文字指令与
## 指引十字的下滑/低头指令冲突时，FD 同样退场（儿童一次只听一个声音）。
##
## 隔离：SaveGuard 快照/还原（D-010 铁律 3）；FakeCraft/FakeCamera 不进场景树、
## 不跑 _ready，只读合成快照——既绕开真实飞行的不可控物理，也避免与既有
## main.tscn 探针抢同一帧循环。
##
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/fd_yield_probe.tscn

const NAV_TARGET := Vector3(0.0, 50.0, 100.0)  # 水平距离 100 m → FD 进近段（mode != OFF）
var _failed := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	SaveGuard.snapshot()
	_build_and_check()
	SaveGuard.restore()
	_finish()


## 墙高度场：z >= wall_z 起 wall_h，否则 flat_h（地形前视采样器形态，与
## terrain_warning_probe 同款；wall_z=300 + 速度(0,0,50) 外推命中 300m 档）。
func _wall(wall_z: int, wall_h: int, flat_h: int) -> Callable:
	return func(_wx: int, wz: int) -> int:
		return wall_h if wz >= wall_z else flat_h


## 合成 Aircraft 快照（同名字典，接 FlightInstruments.update 读取契约）。
## 只给本探针用到的键；其余走 update 的默认值。
func _make_snap(agl: float, vs: float, pos: Vector3) -> Dictionary:
	return {
		"kmh": 60.0,
		"altitude": agl,
		"altitude_agl": agl,
		"vertical_speed": vs,
		"position": pos,
		"velocity": Vector3(0.0, 0.0, 50.0),
		"stalled": false,
		"stall_warning": false,
		"overspeed": false,
		"load_factor": 1.0,
		"throttle": 1.0,
		"engine": true,
		"gear_down": false,
		"flaps": 0,
		"rpm": 1000.0,
		"fuel_liters": 100.0,
		"fuel_capacity": 100.0,
		"sideslip_deg": 0.0,
	}


func _build_and_check() -> void:
	# 控制组：无任何 WARNING——FD 可见（基准，证明门默认放行）。
	_run_scenario(Callable(), 70.0, 0.0, Vector3(0.0, 70.0, 0.0),
		0, 0, true, "① 无告警基准：FD 可见")
	# D-074 R1：地形前视 WARNING（level 2）→ FD 退场。
	_run_scenario(_wall(300, 60, 0), 70.0, 0.0, Vector3(0.0, 70.0, 0.0),
		2, 0, false, "② 地形前视 WARNING(2) → FD 退场")
	# D-074 R2：地形告警回退 <2 → FD 即刻归位。
	_run_scenario(Callable(), 70.0, 0.0, Vector3(0.0, 70.0, 0.0),
		0, 0, true, "③ 地形告警<2 → FD 恢复可见")
	# D-074 R3：过低 WARNING（level 2）→ FD 退场。
	_run_scenario(Callable(), 5.0, -5.0, Vector3(0.0, 5.0, 0.0),
		0, 2, false, "④ 过低 WARNING(2) → FD 退场")
	# D-074 R4：过低告警回退到 0（非 caution）→ FD 恢复可见。
	_run_scenario(Callable(), 15.0, -1.0, Vector3(0.0, 15.0, 0.0),
		0, 0, true, "⑤ 过低告警<2(=0) → FD 恢复可见")
	# D-074 R5：地形 caution（level 1）→ 不抢指令，FD 仍可见。
	_run_scenario(_wall(300, 40, 0), 70.0, 0.0, Vector3(0.0, 70.0, 0.0),
		1, 0, true, "⑥ 地形 caution(1) → FD 仍可见（不锁）")
	# D-074 R6：过低 caution（level 1）→ 不抢指令，FD 仍可见。
	_run_scenario(Callable(), 10.0, -3.0, Vector3(0.0, 10.0, 0.0),
		0, 1, true, "⑦ 过低 caution(1) → FD 仍可见（不锁）")


## 单场景：构建一份全新的 HUD（隔离场景间 alt_warn 的滞环/残留状态），
## 注入采样器 + 合成快照 + 连 tick 多帧让垂直速度收敛，断言 FD.visible 与告警级别。
## expect_terrain / expect_alt 为预期级别，仅作自诊断（FD.visible 为假时
## 能直接看出是级别算错还是门逻辑错）。
func _run_scenario(sampler: Callable, agl: float, vs: float, pos: Vector3,
		expect_terrain: int, expect_alt: int, expect_visible: bool, label: String) -> void:
	var ih := FlightInstrumentHUD.new()
	add_child(ih)  # 触发 _ready：构建 _fd / _cockpit 等覆盖层
	var craft := FakeCraft.new()
	var cam := FakeCamera.new()
	ih.setup(craft, cam)
	ih.set_navigation(NAV_TARGET, "POI")
	ih.set_stall_coach_active(false)  # D-071 逻辑不动：本探针只测地形/过低让位
	ih.set_terrain_sampler(sampler)
	craft.snap = _make_snap(agl, vs, pos)
	craft.global_position = pos
	# 多帧 tick：FlightInstruments.vertical_speed 经时间常数平滑（lerpf），
	# 单帧只把原始 vs 部分施加；过低告警阈值按「收敛后的垂直速度」判定，
	# 故需连 tick 多帧让其收敛到 snapshot 给的 vs，否则 ④/⑦ 的告警级别会算低。
	for _i in range(20):
		ih.tick(0.05)
	var fi: FlightInstruments = ih.instruments_ref()
	_check(fi.terrain_warn == expect_terrain,
		"%s（诊断：terrain_warn=%d 期望 %d）" % [label, fi.terrain_warn, expect_terrain])
	_check(fi.alt_warn == expect_alt,
		"%s（诊断：alt_warn=%d 期望 %d）" % [label, fi.alt_warn, expect_alt])
	_check(ih._fd.current_mode() != FlightDirector.Mode.OFF,
		"%s（前提：FD mode != OFF，才有「可见/退场」可言）" % label)
	_check(ih._fd.visible == expect_visible,
		"%s（FD.visible=%s 期望 %s）" % [label, str(ih._fd.visible), str(expect_visible)])
	ih.queue_free()


func _finish() -> void:
	if _failed == 0:
		print("FD_YIELD_PROBE_OK")
		get_tree().quit(0)
	else:
		print("FD_YIELD_PROBE_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)


## 假机体：不进场景树、不跑 _ready，只读合成快照——tick 只调 snapshot() 与
## global_position，二者都可在无树状态下稳定给出。extends Aircraft 以满足
## FlightInstrumentHUD._craft 的类型约束。
class FakeCraft extends Aircraft:
	var snap: Dictionary = {}
	func snapshot() -> Dictionary:
		return snap


## 假相机：恒定第一人称座舱——_apply_visibility 据此点亮 _cockpit.visible，
## 否则 FD 整条可见门因 _cockpit.visible=false 直接短路（测不到告警让位）。
class FakeCamera extends AircraftCamera:
	func current_mode() -> AircraftCamera.ViewMode:
		return AircraftCamera.ViewMode.FIRST_PERSON
