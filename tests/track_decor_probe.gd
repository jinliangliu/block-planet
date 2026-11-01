extends Node
## 无头探针：赛道主题装饰（把 TrackLayout.theme 从死字段变成真生效）。
##
## 钉住五件事：
##   A. 地台底色随主题变（desert / forest / city 三条互不相同），未知主题回落 mixed；
##   B. 6 条赛道各自都长出装饰，且 MultiMeshInstance3D 组数落在 2~10（draw call 预算）；
##   C. 装饰不压路面（横向距离 ≥ half_width + KERB_WIDTH + 2.9）、不埋地下不挡视距
##      （y ∈ [-0.1, 4.0]）、不投影（cast_shadow OFF）、实例总数 < 400，
##      且 MultiMesh 收下的实例数与摆位记录一致；
##   C2. 路肩：9 条赛道各有一个 "Kerbs" 节点（1 个 draw call）、顶点数 4×size()、
##      红白交替（两色都在且数量级相当）、外沿 = half_width+KERB_WIDTH、内沿 = half_width、
##      高于路面且不高于 ROAD_LIFT+0.05、顶点色接进 albedo、不投影；并且每条赛道的
##      地台亮度与首个路面地形的亮度差 ≥ 0.05（地台和路面不许糊成一片）；
##   D. 确定性：同一赛道连续 build 两次，所有实例 transform 逐位相同；
##   E. 重复 build 不残留（子节点数不增长），不同主题的装饰布局不同。
##
## ── 一个必须写下来的坑 ──────────────────────────────────────
## 几何断言**不能**从 MultiMesh.get_instance_transform 读回来：无头模式跑的是
## RendererDummy，实例缓冲在 RenderingServer 侧保存，dummy 后端不存——读回来的
## 永远是单位矩阵（本工程实测：3 个实例、写了缩放和位移，读回全是 identity，
## 于是「y 实测 0.00~0.00 / 最差横向 142.98 m」这种一眼假的数字还会 PASS）。
## 所以 TrackLoader 在 build 时把摆位同时记一份纯数据（decor_instances），
## 探针读那份；同时用 instance_count 之和做交叉校验，保证 MultiMesh 真的收下了。
##
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/track_decor_probe.tscn
##
## 本探针只读 RaceSystem 数据 + 新建场景节点，不写任何 user:// 存档，因此不需要
## SaveGuard 快照（写存档的是 racing_probe，不是这里）。

var _failed := 0
var _loader: TrackLoader = null
## 跨赛道的质量聚合：最差横向距离（及它出现在哪条赛道）/ y 取值范围 / 实例数上限。
var _worst_lateral := INF
var _worst_need := 0.0
var _worst_track := ""
var _min_y := INF
var _max_y := -INF
var _instance_max := 0
## 逐赛道摘要：{id: {theme, layout, groups(计数), group_nodes, total, dump, children, meshes, xforms}}。
var _summary: Dictionary = {}
## ── 路肩聚合 ──
## 缺 Kerbs 节点 / 出现多个 Kerbs 节点的赛道名。
var _kerb_missing: Array = []
var _kerb_extra_node: Array = []
## |顶点数 - 4×size| 的最大偏差、顶点色不是红白两色的赛道。
var _kerb_vert_dev := 0
var _kerb_color_bad: Array = []
## 红色顶点数与白色顶点数的最小比值（越接近 1 越说明交替均匀）。
var _kerb_color_ratio := INF
## 外沿/内沿横向距离与设计值的最大误差（m）。
var _kerb_outer_err := 0.0
var _kerb_inner_err := 0.0
## 路肩顶点的 y 取值范围。
var _kerb_y_min := INF
var _kerb_y_max := -INF
## 顶点色没接到 albedo / 还开着阴影的赛道名。
var _kerb_material_bad: Array = []
var _kerb_shadow_on: Array = []
## 地台与「该赛道首个地形」的亮度差（Rec.601）最差值与所属赛道。
var _plate_luma_worst := INF
var _plate_luma_track := ""
var _plate_luma_log: Array = []


func _ready() -> void:
	await get_tree().process_frame
	_run()


func _run() -> void:
	_loader = TrackLoader.new()
	_loader.name = "DecorLoader"
	add_child(_loader)

	_test_plate_colors()
	_test_per_track()
	_test_quality()
	_test_kerbs()
	_test_determinism()

	_finish()


func _finish() -> void:
	print("TRACK_DECOR_TEST_DONE fails=%d" % _failed)
	if _failed == 0:
		print("TRACK_DECOR_TEST_OK")
		get_tree().quit(0)
	else:
		print("TRACK_DECOR_TEST_FAILED")
		get_tree().quit(1)


# ─────────────────── A. 地台底色随主题变 ───────────────────
func _test_plate_colors() -> void:
	var seen: Dictionary = {}
	var all_distinct := true
	for theme: String in TrackLoader.PLATE_COLORS.keys():
		var c: Color = _loader.plate_color(theme)
		if seen.has(c.to_rgba32()):
			all_distinct = false
		seen[c.to_rgba32()] = true
	_check(TrackLoader.PLATE_COLORS.size() >= 6 and all_distinct,
		"色盘覆盖 %d 个主题且两两不同" % TrackLoader.PLATE_COLORS.size())
	_check(_loader.plate_color("no_such_theme") == _loader.plate_color("mixed"),
		"未知主题回落 mixed 底色")

	for tid: String in ["desert_ring", "forest_trail", "city_circuit"]:
		_build_track(tid)
		var theme_id := String((_summary[tid] as Dictionary)["theme"])
		var want: Color = _loader.plate_color(theme_id)
		var got := _ground_plate_color()
		_check(got.is_equal_approx(want),
			"%s 地台底色 = 主题色（%s，%.2f/%.2f/%.2f）"
			% [tid, theme_id, got.r, got.g, got.b])


# ─────────────── B. 每条赛道都有装饰，组数 2~10 ───────────────
func _test_per_track() -> void:
	var ids: Array = []
	for t: Variant in RaceSystem.tracks():
		ids.append(String((t as Dictionary).get("id", "")))
	_check(ids.size() >= 6, "赛道数据 ≥ 6 条（%d）" % ids.size())
	for tid: String in ids:
		var s := _build_track(tid)
		var groups := int(s["groups"])
		var total := int(s["total"])
		_check(groups >= 2 and groups <= 10,
			"%s：MultiMeshInstance3D 组数 %d ∈ [2,10]（一组 = 一个 draw call）"
			% [tid, groups])
		_check(total > 0, "%s：装饰实例 %d 件 > 0" % [tid, total])


# ─────── C. 装饰质量（压路面 / 高度 / 阴影 / 数量上限）───────
func _test_quality() -> void:
	_check(_worst_lateral >= _worst_need - 0.1,
		"全部装饰离中心线 ≥ half_width+KERB_WIDTH+2.9（最差 %.2f m @ %s，下限 %.2f m）"
		% [_worst_lateral, _worst_track, _worst_need])
	_check(_min_y >= -0.1 and _max_y <= TrackLoader.DECOR_MAX_HEIGHT,
		"全部装饰 y ∈ [-0.1, %.1f]（实测 %.2f ~ %.2f）"
		% [TrackLoader.DECOR_MAX_HEIGHT, _min_y, _max_y])
	_check(_instance_max >= 20 and _instance_max < 400,
		"单赛道装饰部件总数 %d ∈ [20, 400)" % _instance_max)
	_check(_all_shadows_off(), "所有装饰 cast_shadow = OFF（Mobile 省阴影开销）")
	_check(_all_transforms_finite(), "所有实例 transform 均为有限值（无 NaN）")
	_check(_counts_match(), "每条赛道 MultiMesh 的 instance_count 之和 = 摆位记录条数")


# ─────── C2. 路肩：红白交替、贴合路面外沿、1 个 draw call ───────
## 为什么要有路肩：地台按主题上色之后，城市/森林的地台亮度与该段路面只差
## 0.03~0.06（Rec.601），路在哪完全看不出来。红白交替不依赖明度差。
## 顶点布局是契约（每环 4 个：左外 / 左内 / 右内 / 右外，绕序与路面一致），
## 所以这里按 v/4 反推所在的环下标逐点验，而不用「最近采样点」——发卡弯两条腿
## 贴得近时「最近点」会指到另一条腿上，逐点验会假失败。
func _test_kerbs() -> void:
	_check(_kerb_missing.is_empty() and _kerb_extra_node.is_empty(),
		"9 条赛道各有且只有一个名为 Kerbs 的 MeshInstance3D（缺 %d / 多 %d）"
		% [_kerb_missing.size(), _kerb_extra_node.size()])
	_check(_kerb_vert_dev <= 8,
		"路肩顶点数 = 8 × size()（每段每带独立 4 顶点以保住纯色块；最大偏差 %d）"
		% _kerb_vert_dev)
	_check(_kerb_color_bad.is_empty() and _kerb_color_ratio >= 0.3 and _kerb_color_ratio <= 3.0,
		"红块与白块顶点都存在且数量级相当（最小红/白比 %.2f）" % _kerb_color_ratio)
	_check(_kerb_outer_err <= 0.05,
		"路肩外沿横向距离 = ±(half_width+KERB_WIDTH)（最大误差 %.4f m，容差 0.05）"
		% _kerb_outer_err)
	_check(_kerb_inner_err <= 0.05,
		"路肩内沿横向距离 = ±half_width（最大误差 %.4f m）" % _kerb_inner_err)
	_check(_kerb_y_min > TrackLoader.ROAD_LIFT,
		"路肩高于路面，不共面（最低 y %.4f > ROAD_LIFT %.3f）"
		% [_kerb_y_min, TrackLoader.ROAD_LIFT])
	_check(_kerb_y_max <= TrackLoader.ROAD_LIFT + 0.05,
		"路肩不高于 ROAD_LIFT+0.05（最高 y %.4f）" % _kerb_y_max)
	_check(_kerb_material_bad.is_empty(),
		"路肩材质开启 vertex_color_use_as_albedo（否则红白顶点色不生效）")
	_check(_kerb_shadow_on.is_empty(), "路肩 cast_shadow = OFF")
	# 逐条赛道的亮度差上面已随测量打印，这里只做汇总断言。
	_check(_plate_luma_worst >= 0.05,
		"每条赛道 |地台亮度 - 首个地形亮度| ≥ 0.05（最差 %.3f @ %s）"
		% [_plate_luma_worst, _plate_luma_track])


# ─────── D/E. 确定性 / 不残留 / 主题间有差异 ───────
func _test_determinism() -> void:
	var tid := "desert_ring"
	var first := _build_track(tid)
	var xforms_a: Array = first["xforms"]
	var children_a := int(first["children"])
	var second := _build_track(tid)
	var xforms_b: Array = second["xforms"]
	var children_b := int(second["children"])

	var same := xforms_a.size() == xforms_b.size() and xforms_a.size() > 0
	if same:
		for i in xforms_a.size():
			if (xforms_a[i] as Transform3D) != (xforms_b[i] as Transform3D):
				same = false
				break
	_check(same,
		"同一赛道连续 build 两次，%d 个实例 transform 逐位相同" % xforms_a.size())
	_check(children_b == children_a,
		"重复 build 不残留子节点（%d → %d）" % [children_a, children_b])

	# 不同主题的赛道装饰必须不同（否则等于 theme 没生效）。
	var city := _build_track("city_circuit")
	var desert := _build_track("desert_ring")
	var city_x: Array = city["xforms"]
	var desert_x: Array = desert["xforms"]
	var differ := int(city["total"]) != int(desert["total"]) \
		or int(city["groups"]) != int(desert["groups"])
	if not differ and not city_x.is_empty() and not desert_x.is_empty():
		differ = (city_x[0] as Transform3D) != (desert_x[0] as Transform3D)
	_check(differ,
		"不同主题装饰布局不同（city %d 件/%d 组 vs desert %d 件/%d 组）"
		% [int(city["total"]), int(city["groups"]), int(desert["total"]), int(desert["groups"])])

	# mixed 由沙漠 + 森林合并而来：必然同时出现盒 / 柱 / 锥三种图元。
	var mixed := _build_track("all_terrain")
	var meshes: Dictionary = mixed["meshes"]
	_check(meshes.has("cyl") and meshes.has("cone"),
		"mixed 同时含柱与锥图元（沙漠 + 森林两组都在）")


# ────────────────────────── 工具 ──────────────────────────
## 构建一条赛道并把测量结果灌进 _summary / 全局聚合。
func _build_track(track_id: String) -> Dictionary:
	var layout := RaceSystem.build_layout(track_id)
	_loader.build(layout)
	var group_nodes: Array = []
	var meshes: Dictionary = {}
	var total := 0
	var hw := layout.half_width
	for child in _loader.get_children():
		if child is not MultiMeshInstance3D:
			continue
		var mmi := child as MultiMeshInstance3D
		group_nodes.append(mmi)
		var mm := mmi.multimesh
		if mm == null:
			continue
		meshes[_mesh_key(mm.mesh)] = true
		total += mm.instance_count

	# 几何断言读 TrackLoader 的摆位记录（无头下 MultiMesh 实例缓冲读不回来）。
	var dump: Array = _loader.decor_instances
	var xforms: Array = []
	for rec: Variant in dump:
		var xf: Transform3D = (rec as Dictionary)["xform"]
		xforms.append(xf)
		var pos := xf.origin
		_min_y = minf(_min_y, pos.y)
		_max_y = maxf(_max_y, pos.y)
		var lat := _centerline_lateral(layout, pos)
		if lat < _worst_lateral:
			_worst_lateral = lat
			# 下限跟着路肩走：装饰要离「路面 + 路肩」的外沿够远。
			_worst_need = hw + TrackLoader.KERB_WIDTH + 2.9
			_worst_track = track_id
	_instance_max = maxi(_instance_max, total)
	_measure_kerbs(track_id, layout)
	_measure_plate_luma(track_id, layout)
	var summary := {
		"theme": layout.theme,
		"layout": layout,
		"groups": group_nodes.size(),
		"group_nodes": group_nodes,
		"total": total,
		"dump": dump.size(),
		"children": _loader.get_child_count(),
		"meshes": meshes,
		"xforms": xforms,
	}
	_summary[track_id] = summary
	return summary


## 路肩各项指标的测量（把结果灌进 _kerb_* 聚合）。
func _measure_kerbs(track_id: String, layout: TrackLayout) -> void:
	var nodes: Array = []
	for child in _loader.get_children():
		if String(child.name) == "Kerbs":
			nodes.append(child)
	if nodes.is_empty():
		_kerb_missing.append(track_id)
		return
	if nodes.size() > 1:
		_kerb_extra_node.append(track_id)
	var mi := nodes[0] as MeshInstance3D
	if mi == null or not (mi.mesh is ArrayMesh):
		_kerb_missing.append(track_id)
		return
	var mat := mi.material_override as StandardMaterial3D
	if mat == null or not mat.vertex_color_use_as_albedo:
		_kerb_material_bad.append(track_id)
	if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
		_kerb_shadow_on.append(track_id)

	var arrays := (mi.mesh as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	# 每段每带各 4 个顶点、不共享（共享会强制红白之间插值成粉带），故 8 × size()。
	_kerb_vert_dev = maxi(_kerb_vert_dev, absi(verts.size() - 8 * layout.size()))

	# 顶点色只该是红或白两色；顺便统计块数比例，确认是真交替而不是纯红/纯白。
	# 注意：ArrayMesh 的顶点色是 8 bit/通道量化存的（0.86 读回来是 0.8588），
	# 所以不能用 == / is_equal_approx 比，要带 1/255 量级的容差（本工程实测踩过）。
	var n_a := 0
	var n_b := 0
	for c in cols:
		if _kerb_color_is(c, _loader.kerb_color(0)):
			n_a += 1
		elif _kerb_color_is(c, _loader.kerb_color(1)):
			n_b += 1
		else:
			_kerb_color_bad.append(track_id)
			break
	if n_a == 0 or n_b == 0:
		if not _kerb_color_bad.has(track_id):
			_kerb_color_bad.append(track_id)
	else:
		var ratio := float(n_a) / float(n_b)
		_kerb_color_ratio = minf(_kerb_color_ratio, minf(ratio, 1.0 / ratio))

	var hw := layout.half_width
	var kw := TrackLoader.KERB_WIDTH
	# 顶点布局是 _build_kerbs 的契约：每段 8 个顶点
	#   [左A外, 左A内, 左B外, 左B内, 右A内, 右A外, 右B内, 右B外]
	# 左带「外」= +(hw+kw)、右带「外」= -(hw+kw)；A 环 = i，B 环 = i+1。
	for v in verts.size():
		var seg := int(floor(float(v) / 8.0))
		var slot := v % 8
		var ring := seg + (1 if slot == 2 or slot == 3 or slot == 6 or slot == 7 else 0)
		var off := 0.0
		match slot:
			0, 2:
				off = hw + kw
			1, 3:
				off = hw
			4, 6:
				off = -hw
			_:
				off = -(hw + kw)
		var lat := layout.lateral_offset(verts[v], layout.wrap_index(ring))
		var err := absf(lat - off)
		if absf(off) > hw + kw * 0.5:
			_kerb_outer_err = maxf(_kerb_outer_err, err)
		else:
			_kerb_inner_err = maxf(_kerb_inner_err, err)
		_kerb_y_min = minf(_kerb_y_min, verts[v].y)
		_kerb_y_max = maxf(_kerb_y_max, verts[v].y)


## 地台亮度 vs 该赛道「第一个地形」的亮度（Rec.601，原始显示色，不做 sRGB 转换）。
func _measure_plate_luma(track_id: String, layout: TrackLayout) -> void:
	var plate := _luma(_ground_plate_color())
	var terrain_id := layout.terrain_at_index(0)
	var hex := String(RaceSystem.terrain(terrain_id).get("color", "#666666"))
	var road := _luma(Color(hex))
	var delta := absf(plate - road)
	# 同一赛道在一次跑里会被 build 多次（色盘/确定性/差异三节都建），日志只记一次。
	if not _plate_luma_log.has(track_id):
		_plate_luma_log.append(track_id)
		print("  亮度差 %s：地台 %.3f / 路面 %s %.3f → Δ%.3f"
			% [track_id, plate, terrain_id, road, delta])
	if delta < _plate_luma_worst:
		_plate_luma_worst = delta
		_plate_luma_track = "%s(%s)" % [track_id, terrain_id]


func _luma(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


## 顶点色比对：允许 8 bit 量化误差（1/255 ≈ 0.0039）。
func _kerb_color_is(got: Color, want: Color) -> bool:
	return absf(got.r - want.r) <= 0.01 and absf(got.g - want.g) <= 0.01 \
		and absf(got.b - want.b) <= 0.01


## 该点到「最近中心线采样点」的横向距离（米，恒正）。
## 用最近点而不是固定下标：探针不知道每件装饰是被哪个下标生成的。
func _centerline_lateral(layout: TrackLayout, pos: Vector3) -> float:
	var p2 := Vector2(pos.x, pos.z)
	var best := INF
	var best_i := 0
	for i in layout.size():
		var q := layout.point(i)
		var d := p2.distance_squared_to(Vector2(q.x, q.z))
		if d < best:
			best = d
			best_i = i
	return absf(layout.lateral_offset(pos, best_i))


func _ground_plate_color() -> Color:
	for child in _loader.get_children():
		if child.name != "GroundPlate":
			continue
		var mi := child as MeshInstance3D
		var mat := mi.material_override as StandardMaterial3D
		if mat != null:
			return mat.albedo_color
	return Color(0.0, 0.0, 0.0, 0.0)


func _mesh_key(mesh: Mesh) -> String:
	if mesh is BoxMesh:
		return "box"
	if mesh is CylinderMesh:
		var cyl := mesh as CylinderMesh
		return "cone" if cyl.top_radius <= 0.0001 else "cyl"
	return "other"


func _counts_match() -> bool:
	for tid: String in _summary.keys():
		var s: Dictionary = _summary[tid]
		if int(s["total"]) != int(s["dump"]):
			return false
	return true


func _all_shadows_off() -> bool:
	for tid: String in _summary.keys():
		var nodes: Array = (_summary[tid] as Dictionary)["group_nodes"]
		for g: Variant in nodes:
			var mmi := g as MultiMeshInstance3D
			if mmi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				return false
	return true


func _all_transforms_finite() -> bool:
	for tid: String in _summary.keys():
		for xf: Variant in (_summary[tid] as Dictionary)["xforms"]:
			if not (xf as Transform3D).is_finite():
				return false
	return true


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
