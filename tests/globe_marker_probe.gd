extends Node
## 球面玩法标记探针（D-044）：地球上的飞行标记改为 3D 小飞机
## （红=机场 / 琥珀=降落场），钓鱼标记改为 3D 小鱼，钉在四大洋球面。
##
## A. 枚数与区域判据一致：可飞区域一一对应小飞机、有钓点海域一一对应小鱼
## B. 几何：标记浮在球面之外、基底为右手系（不镜像）、同区域两枚不重叠
## C. 结构：小飞机带螺旋桨、小鱼带上下两片尾鳍
## D. 动画：小飞机起伏 + 桨自转，小鱼摆头 + 摆尾
## E. 显隐：飞行标记随探索模式开关，小鱼不受模式影响
##
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/globe_marker_probe.tscn

var _failed := 0


func _ready() -> void:
	await _run()


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("PASS: %s" % msg)
	else:
		_failed += 1
		print("FAIL: %s" % msg)


## 尾鳍用 meta 标记（不用 node.name：同父下重名会被引擎改名）。
func _tail_count(fish: Node3D) -> int:
	var count := 0
	for child in fish.get_children():
		if bool(child.get_meta("tail", false)):
			count += 1
	return count


func _first_tail(fish: Node3D) -> Node3D:
	for child in fish.get_children():
		if bool(child.get_meta("tail", false)):
			return child
	return null


func _run() -> void:
	# 存档隔离（D-010 铁律 3）：本探针不建主场景，但仍按范式备份/还原。
	SaveGuard.snapshot()

	var globe := MapGlobe.new()
	add_child(globe)
	for i in range(6):
		await get_tree().process_frame

	# ── A. 枚数与区域判据一致 ──
	var n_airport := 0
	var n_field := 0
	var n_fish := 0
	for region_id in RegionAtlas.COUNT:
		if RegionAtlas.has_airport(region_id):
			n_airport += 1
		elif RegionAtlas.has_landing_field(region_id):
			n_field += 1
		if not FishingSystem.get_spots_for_atlas(region_id).is_empty():
			n_fish += 1
	_check(globe.airport_marker_count() == n_airport,
		"机场小飞机覆盖全部机场区域（%d/%d）" % [globe.airport_marker_count(), n_airport])
	_check(globe.field_marker_count() == n_field,
		"降落场小飞机覆盖全部降落场区域（%d/%d）" % [globe.field_marker_count(), n_field])
	_check(globe.airport_marker_count() + globe.field_marker_count() == RegionAtlas.COUNT,
		"每个区域各有一枚飞行标记（合计 %d）" % RegionAtlas.COUNT)
	_check(globe.fish_marker_count() == n_fish,
		"小鱼覆盖全部有钓点海域（%d/%d）" % [globe.fish_marker_count(), n_fish])
	_check(globe.fish_marker_count() == 4, "小鱼恰好钉在四大洋（%d 枚）" % globe.fish_marker_count())

	# ── B. 几何：浮在球面外（>1.0）、不飘太远（<1.20）、基底右手系 ──
	var all_planes: Array[Node3D] = []
	all_planes.append_array(globe._airport_markers)
	all_planes.append_array(globe._field_markers)
	var outside_ok := true
	var handed_ok := true
	for plane in all_planes:
		var d := plane.position.length()
		if d <= 1.0 or d >= 1.20:
			outside_ok = false
		if plane.basis.determinant() <= 0.0:
			handed_ok = false
	_check(outside_ok, "小飞机浮在球面之外且不飘远（|pos| ∈ (1.0, 1.20)）")
	_check(handed_ok, "小飞机基底为右手系（无镜像翻转）")

	var fish_outside_ok := true
	for fish in globe._fish_markers:
		var d2 := fish.position.length()
		if d2 <= 1.0 or d2 >= 1.20:
			fish_outside_ok = false
	_check(fish_outside_ok, "小鱼浮在球面之外且不飘远（|pos| ∈ (1.0, 1.20)）")

	# 四大洋同时有降落场与小鱼：两枚标记必须分开，否则叠成一团看不出是两种。
	var spread_ok := true
	for fish in globe._fish_markers:
		for plane in all_planes:
			if fish.position.distance_to(plane.position) < 0.08:
				spread_ok = false
	_check(spread_ok, "同区域的小飞机与小鱼彼此错开（间距 ≥ 0.08）")

	# ── C. 结构：螺旋桨 / 尾鳍 ──
	var prop_ok := true
	for plane in all_planes:
		if plane.get_node_or_null("Propeller") == null:
			prop_ok = false
	_check(prop_ok, "每枚小飞机都带螺旋桨子节点")

	var tail_ok := true
	for fish in globe._fish_markers:
		if _tail_count(fish) != 2:
			tail_ok = false
	_check(tail_ok, "每条小鱼有上下两片尾鳍")

	# ── D. 动画：跑若干帧后位置/桨角应有变化 ──
	var plane_sample: Node3D = all_planes[0] if not all_planes.is_empty() else null
	var fish_sample: Node3D = globe._fish_markers[0] if not globe._fish_markers.is_empty() else null
	if plane_sample != null:
		var base_pos: Vector3 = plane_sample.get_meta("base_pos", plane_sample.position)
		var prop_before := 0.0
		var prop_node := plane_sample.get_node_or_null("Propeller")
		if prop_node != null:
			prop_before = prop_node.rotation.x
		for i in range(30):
			await get_tree().process_frame
		var moved := plane_sample.position.distance_to(base_pos) > 0.0005
		var spun := prop_node != null and absf(prop_node.rotation.x - prop_before) > 0.05
		_check(moved, "小飞机有起伏动画（离开基准位置）")
		_check(spun, "螺旋桨持续自转")
	if fish_sample != null:
		var fish_base: Vector3 = fish_sample.get_meta("base_pos", fish_sample.position)
		var tail_node := _first_tail(fish_sample)
		var tail_before := tail_node.rotation.z if tail_node != null else 0.0
		for i in range(30):
			await get_tree().process_frame
		_check(fish_sample.position.distance_to(fish_base) > 0.0005, "小鱼有起伏动画")
		_check(tail_node != null and absf(tail_node.rotation.z - tail_before) > 0.02, "小鱼尾鳍持续摆动")

	# ── E. 显隐：飞行标记随模式开关，小鱼常显 ──
	globe.set_flight_flags_visible(true)
	_check(globe.flight_flags_visible(), "开启后飞行标记可见")
	globe.set_flight_flags_visible(false)
	_check(not globe.flight_flags_visible(), "关闭后飞行标记隐藏")
	_check(globe.fish_markers_visible(), "小鱼不随飞行标记一起隐藏（钓鱼不绑定载具）")
	globe.set_fish_markers_visible(false)
	_check(not globe.fish_markers_visible(), "小鱼显隐开关可用（供将来纯净地图/探针）")
	globe.set_fish_markers_visible(true)
	globe.set_flight_flags_visible(true)

	SaveGuard.restore()
	print("GLOBE_MARKER_PROBE_DONE failed=%d" % _failed)
	get_tree().quit(0 if _failed == 0 else 1)
