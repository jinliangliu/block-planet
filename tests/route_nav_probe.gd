extends Node
## 航线规划与动态导航契约探针：纯逻辑验证避山净空、飞越切点、HSI 导航与退化输入。
## 按 D-010 在首项检查前快照、退出前统一还原，PASS/FAIL 两条路径均不污染 user://。

class RidgeWorld extends RefCounted:
	## 人工山脊：直飞线穿过 110 m 山体，|z| > 42 m 才能从侧面绕开。
	func get_surface_height(wx: int, wz: int) -> int:
		if absi(wx) <= 36 and absi(wz) <= 42:
			return 110
		return 10


const CLEARANCE_M := 30.0
var _failed := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	SaveGuard.snapshot()
	_run_generator_checks()
	_run_route_plan_checks()
	_run_navigation_checks()
	_run_degenerate_checks()
	_finish()


## 避山验收看最终平滑航线的每一个航点：净空不足一处即整项失败。
func _run_generator_checks() -> void:
	var world := RidgeWorld.new()
	_check(is_instance_valid(world), "① 人工山脊世界可用")
	if not is_instance_valid(world):
		return
	var from := Vector3(-120.0, 30.0, 0.0)
	var to := Vector3(120.0, 30.0, 0.0)
	var route := RouteGenerator.plan_between(world, from, to, CLEARANCE_M, 24)
	_check(route.size() == 24, "① 24 点等距采样生成完整航线")
	var endpoints_preserved := false
	if route.size() >= 2:
		endpoints_preserved = is_equal_approx(route[0].x, from.x) \
			and is_equal_approx(route[route.size() - 1].x, to.x)
	_check(endpoints_preserved, "① 航线保留两端水平位置")
	var has_lateral_detour := false
	var all_clear := true
	var all_above_cruise := true
	for point: Vector3 in route:
		has_lateral_detour = has_lateral_detour or absf(point.z) > 42.0
		var terrain := world.get_surface_height(roundi(point.x), roundi(point.z))
		all_clear = all_clear and point.y - float(terrain) >= CLEARANCE_M - 0.001
		all_above_cruise = all_above_cruise \
			and point.y >= maxf(from.y, to.y) + RouteGenerator.CRUISE_CLIMB_M - 0.001
	_check(has_lateral_detour, "① 穿山直线生成侧向绕行点")
	_check(all_clear, "① 最终航线每点地形净空均不小于 30 m")
	_check(all_above_cruise, "① 全线不低于较高端点加巡航增量")


func _run_route_plan_checks() -> void:
	var plan := RoutePlan.new()
	_check(is_instance_valid(plan), "② RoutePlan 可直接构造")
	if not is_instance_valid(plan):
		return
	_check(not plan.has_route(), "② 空航线无活动目标")
	_check(plan.current_target() == Vector3.ZERO, "② 空航线目标为零向量")
	_check(plan.total() == 0 and plan.remaining() == 0 and plan.progress() == 0.0,
		"② 空航线总数、剩余与进度均为零")
	_check(not plan.is_complete(), "② 空航线不冒充已完成航线")

	var p0 := Vector3(0.0, 50.0, 0.0)
	var p1 := Vector3(100.0, 55.0, 0.0)
	var p2 := Vector3(100.0, 60.0, 100.0)
	var points: Array[Dictionary] = [
		{"pos": p0, "name": "起点", "kind": RoutePlan.Kind.START},
		{"pos": p1, "name": "转向点", "kind": RoutePlan.Kind.ENROUTE},
		{"pos": p2, "name": "终点", "kind": RoutePlan.Kind.DEST},
	]
	plan.set_route(points)
	_check(plan.has_route() and plan.total() == 3 and plan.current_index() == 0
		and plan.current_target() == p0, "② 三点航线从首点激活")
	_check(plan.remaining() == 3 and plan.progress() == 0.0, "② 首点前剩余 3、进度 0")
	_check(not plan.advance(Vector3(41.0, 999.0, 0.0)) and plan.current_index() == 0,
		"② 水平距离 41 m 不提前切点且忽略高度差")
	_check(plan.advance(Vector3(40.0, -999.0, 0.0)), "② 捕获圈边界 40 m 可推进")
	_check(plan.current_index() == 1 and plan.current_target() == p1,
		"② 飞越首点后目标切到第二点")
	_check(plan.remaining() == 2 and absf(plan.progress() - 1.0 / 3.0) < 0.001,
		"② 切到第二点后剩余 2、进度三分之一")
	_check(plan.advance(p1) and plan.current_target() == p2, "② 飞越第二点后目标切到终点")
	_check(plan.advance(p2), "② 终点在捕获圈内可完成")
	_check(plan.is_complete() and not plan.has_route()
		and plan.current_target() == Vector3.ZERO, "② 完成状态明确且不再暴露活动目标")
	_check(plan.remaining() == 0 and plan.progress() == 1.0, "② 完成后剩余 0、进度 1")
	_check(not plan.advance(p2), "② 完成后重复飞越不会回退或再推进")


## 当前航点直接喂给既有仪表；+Z 为北、+X 为东，预期方位 atan2(50, 60)。
func _run_navigation_checks() -> void:
	var plan := RoutePlan.new()
	var instruments := FlightInstruments.new()
	_check(is_instance_valid(plan) and is_instance_valid(instruments), "③ 航线与飞行仪表对象可用")
	if not is_instance_valid(plan) or not is_instance_valid(instruments):
		return
	var target := Vector3(60.0, 80.0, 80.0)
	plan.set_route([{"pos": target, "name": "当前航点", "kind": RoutePlan.Kind.DEST}])
	_check(plan.current_target() == target, "③ 导航取 RoutePlan 当前航点")
	instruments.set_navigation(plan.current_target(), "当前航点")
	var craft_pos := Vector3(10.0, 5.0, 20.0)
	instruments.update({"position": craft_pos}, Basis.from_euler(Vector3(0.0, PI, 0.0)), 0.1)
	var expected_bearing := rad_to_deg(atan2(50.0, 60.0))
	var expected_distance := Vector2(50.0, 60.0).length()
	_check(instruments.nav_active and instruments.nav_name == "当前航点", "③ HSI 导航已激活当前航点")
	_check(absf(instruments.nav_bearing_deg - expected_bearing) < 0.01,
		"③ HSI 方位角指向当前航点")
	_check(absf(instruments.nav_distance_m - expected_distance) < 0.01,
		"③ HSI 水平距离等于当前航点距离")
	_check(absf(instruments.nav_dev_deg - expected_bearing) < 0.01,
		"③ 朝北时 CDI 偏差等于目标方位角")


func _run_degenerate_checks() -> void:
	var world := RidgeWorld.new()
	_check(is_instance_valid(world), "④ 退化检查世界对象可用")
	if not is_instance_valid(world):
		return
	var from := Vector3(-20.0, 15.0, -10.0)
	var to := Vector3(20.0, 25.0, 10.0)
	var null_route := RouteGenerator.plan_between(null, from, to)
	_check(null_route.size() == 2 and null_route[0] == from and null_route[1] == to,
		"④ world 为 null 返回最小两点航线")
	var same_route := RouteGenerator.plan_between(world, from, from)
	_check(same_route.size() == 2 and same_route[0] == from and same_route[1] == from,
		"④ 起降同点仍返回两点且不死循环")
	var zero_sample_route := RouteGenerator.plan_between(world, from, to, CLEARANCE_M, 0)
	_check(zero_sample_route.size() == 2 and zero_sample_route[0] == from
		and zero_sample_route[1] == to, "④ 采样数为零返回最小两点航线")

	var single := RoutePlan.new()
	_check(is_instance_valid(single), "④ 单点 RoutePlan 可用")
	if not is_instance_valid(single):
		return
	single.set_route([{"pos": to, "name": "唯一航点", "kind": RoutePlan.Kind.DEST}])
	_check(single.has_route() and single.total() == 1 and single.current_target() == to,
		"④ 单点航线正常激活")
	_check(single.advance(to) and single.is_complete() and single.progress() == 1.0,
		"④ 单点飞越后正常完成")
	single.clear()
	_check(not single.has_route() and not single.is_complete() and single.total() == 0
		and single.current_index() == -1, "④ clear 恢复未设置状态")


func _finish() -> void:
	SaveGuard.restore()
	if _failed == 0:
		print("ROUTE_NAV_PROBE_OK")
		get_tree().quit(0)
	else:
		print("ROUTE_NAV_PROBE_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
