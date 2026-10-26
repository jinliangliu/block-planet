extends Node
## POI 直飞契约探针（D-073 P3）：POI 注册表 / RouteGenerator 集成 / RoutePlan.points
## 访问器 / 世界环廊几何 / POI→航线→导航管线。按 D-010 在首项检查前快照、退出前
## 统一还原，PASS/FAIL 两条路径均不污染 user://。

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
	_run_registry_checks()
	_run_generator_checks()
	_run_route_plan_points_checks()
	_run_corridor_checks()
	_run_pipeline_checks()
	_finish()


## POI 注册表：登记/查询/最近点/拷贝隔离/清空。
func _run_registry_checks() -> void:
	var reg := PoiRegistry.new()
	_check(is_instance_valid(reg), "① POI 注册表可构造")
	if not is_instance_valid(reg):
		return
	reg.register("airport", "机场", PoiRegistry.Kind.AIRPORT, Vector3(100.0, 31.0, 100.0))
	reg.register("field", "降落场", PoiRegistry.Kind.FIELD, Vector3(200.0, 20.0, 200.0))
	reg.register("v0", "村庄", PoiRegistry.Kind.VILLAGE, Vector3(0.0, 30.0, 0.0))
	reg.register("harbor", "港口", PoiRegistry.Kind.HARBOR, Vector3(300.0, 1.0, 300.0))
	_check(reg.size() == 4, "① 登记 4 个 POI 后 size 为 4")
	var by_id := reg.by_id("v0")
	_check(not by_id.is_empty() and by_id["title"] == "村庄", "① by_id 命中返回完整条目")
	_check(reg.by_id("nope").is_empty(), "① by_id 未命中返回空字典")
	var villages := reg.by_kind(PoiRegistry.Kind.VILLAGE)
	_check(villages.size() == 1 and villages[0]["id"] == "v0", "① by_kind 按类型过滤")
	var near := reg.nearest(Vector3(10.0, 30.0, 10.0), -1.0)
	_check(not near.is_empty() and near["id"] == "v0", "① nearest 返回水平最近 POI")
	var far := reg.nearest(Vector3(1000.0, 0.0, 1000.0), 5.0)
	_check(far.is_empty(), "① nearest 超距（max_dist=5）返回空")
	# 拷贝隔离：改动 all() 返回的元素不影响注册表内部。
	var all := reg.all()
	_check(all.size() == 4, "① all() 返回全部条目")
	all[0]["title"] = "篡改"
	_check(reg.by_id("airport")["title"] == "机场", "① all() 返回拷贝，外部改写不污染注册表")
	# 同 id 覆盖（幂等）。
	reg.register("airport", "机场(夜)", PoiRegistry.Kind.AIRPORT, Vector3(100.0, 31.0, 100.0))
	_check(reg.size() == 4 and reg.by_id("airport")["title"] == "机场(夜)", "① 同 id 覆盖不增计数")
	reg.clear()
	_check(reg.size() == 0 and reg.all().is_empty(), "① clear 后为空")


## RouteGenerator 与现有山脊世界集成：绕山 + 净空 + 端点保留。
func _run_generator_checks() -> void:
	var world := RidgeWorld.new()
	var reg := PoiRegistry.new()
	reg.register("dest", "终点", PoiRegistry.Kind.HARBOR, Vector3(120.0, 30.0, 0.0))
	var poi := reg.by_id("dest")
	var from := Vector3(-120.0, 30.0, 0.0)
	var to: Vector3 = poi["pos"]
	var route := RouteGenerator.plan_between(world, from, to, CLEARANCE_M, 24)
	_check(route.size() == 24, "② 24 点等距采样生成完整航线到 POI")
	var endpoints := is_equal_approx(route[0].x, from.x) \
		and is_equal_approx(route[route.size() - 1].x, to.x) \
		and is_equal_approx(route[route.size() - 1].z, to.z)
	_check(endpoints, "② 航线保留两端水平位置（起点与 POI）")
	var has_detour := false
	var all_clear := true
	for point: Vector3 in route:
		has_detour = has_detour or absf(point.z) > 42.0
		var terrain := world.get_surface_height(roundi(point.x), roundi(point.z))
		all_clear = all_clear and point.y - float(terrain) >= CLEARANCE_M - 0.001
	_check(has_detour, "② 穿山直线生成侧向绕行点")
	_check(all_clear, "② 最终航线每点地形净空均不小于 30 m")


## RoutePlan.points() 返回拷贝：外部改写不污染状态机内部数组。
func _run_route_plan_points_checks() -> void:
	var plan := RoutePlan.new()
	var pts: Array[Dictionary] = [
		{"pos": Vector3(0.0, 50.0, 0.0), "name": "A", "kind": RoutePlan.Kind.START},
		{"pos": Vector3(100.0, 55.0, 0.0), "name": "B", "kind": RoutePlan.Kind.DEST},
	]
	plan.set_route(pts)
	var got := plan.points()
	_check(got.size() == 2, "③ points() 返回全部航点")
	got[0]["pos"] = Vector3(999.0, 0.0, 0.0)
	_check(plan.current_target() == Vector3(0.0, 50.0, 0.0), "③ points() 返回拷贝，外部改写不影响内部")


## 世界环廊几何：沿航线生成青色垂直环，数量受封顶约束，clear 后清空。
## 注：clear_corridor 用 queue_free（延迟到下一帧），故清除后需 await 一帧再断言。
func _run_corridor_checks() -> void:
	var markers := FlightMarkers.new()
	add_child(markers)
	var path: Array[Vector3] = [
		Vector3(0.0, 30.0, 0.0),
		Vector3(200.0, 30.0, 0.0),
	]
	markers.set_corridor(path, 30.0)
	var group := markers.get_node_or_null("PoiCorridor")
	_check(group != null, "④ 走廊节点已创建")
	var rings := 0
	if group != null:
		rings = group.get_child_count()
	_check(rings > 0 and rings <= FlightMarkers.CORRIDOR_MAX_RINGS,
		"④ 环廊环数 %d 在 (0, %d] 内" % [rings, FlightMarkers.CORRIDOR_MAX_RINGS])
	# 单段过短/点不足不应绘制：先清空（await 一帧让 queue_free 生效）。
	markers.clear_corridor()
	await get_tree().process_frame
	_check(markers.get_node_or_null("PoiCorridor") == null, "④ clear_corridor 后走廊节点移除")
	markers.set_corridor([Vector3(0.0, 30.0, 0.0)], 30.0)
	_check(markers.get_node_or_null("PoiCorridor") == null, "④ 单点航线不绘制走廊")
	markers.queue_free()


## 完整管线：POI → 规划 → RoutePlan（末点 DEST）→ advance 推进至完成。
func _run_pipeline_checks() -> void:
	var world := RidgeWorld.new()
	var reg := PoiRegistry.new()
	reg.register("dest", "终点港", PoiRegistry.Kind.HARBOR, Vector3(120.0, 30.0, 0.0))
	var poi := reg.by_id("dest")
	var from := Vector3(-120.0, 30.0, 0.0)
	var pts := RouteGenerator.plan_between(world, from, poi["pos"], CLEARANCE_M, 24)
	_check(pts.size() > 1, "⑤ 规划得到非空航线")
	var route_pts: Array = []
	for i in range(pts.size()):
		var p: Vector3 = pts[i]
		var kind := RoutePlan.Kind.ENROUTE
		if i == pts.size() - 1:
			kind = RoutePlan.Kind.DEST
		route_pts.append({"pos": p, "name": "WP%d" % i, "kind": int(kind)})
	var plan := RoutePlan.new()
	plan.set_route(route_pts)
	_check(plan.current_target() == pts[0], "⑤ 航线从首点激活")
	# 沿航线逐点喂入 advance，直到完成（末点 DEST 在捕获圈内收尾）。
	var completed := false
	for i in range(pts.size()):
		var at: Vector3 = pts[i]
		if plan.advance(at):
			completed = plan.is_complete()
		if plan.is_complete():
			break
	_check(completed, "⑤ 沿航线逐点推进后航线完成（末点 DEST 捕获）")


func _finish() -> void:
	SaveGuard.restore()
	if _failed == 0:
		print("POI_ROUTE_PROBE_OK")
		get_tree().quit(0)
	else:
		print("POI_ROUTE_PROBE_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
