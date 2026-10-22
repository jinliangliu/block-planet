extends Node
## 地标特性探针（世界选择器 + 中国地标）：
## A. GeoProjection：球面往返互逆、包围盒健全、in_region 对已知地标判定正确
## B. REGION_LANDMARKS 数据完整性：11 区齐全 / 亚洲必备条目 / 五字段齐全 /
##    经纬度范围 / kind 受支持 / 河流类带 path / 标题不重名
## C. MapGlobe：图钉枚数与数据一致、浮在球面外且不飘远、基底右手系、
##    河流方块数与 path 一致、脉冲 alpha 有变化、射线拾取命中 / 背面 -1 / 未命中 -1
## D. MapSelector：介绍页地标分区条目数正确、点开科普卡、按钮文案诚实、
##    跨区域给切换提示、【去这里】发 region_entered 落到所属区域
##
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/landmark_probe.tscn

## 往返互逆的实际判定门限（度）。要求书写的是 < 0.5，这里收紧到 0.01：
## 单精度浮点下这套三角函数的往返误差在 1e-3 量级，收紧能更早发现
## 「有人顺手重写了一套球面映射」。
const ROUND_TRIP_LIMIT := 0.01

## 亚洲必须齐的地标（需求书点名：三山五岳 / 长江黄河 / 三峡 / 高原 / 珠峰）。
const REQUIRED_ASIA := [
	"泰山", "华山", "衡山", "恒山", "嵩山", "黄山",
	"长江", "黄河", "长江三峡", "青藏高原", "珠穆朗玛峰",
]

## 受支持的 kind（与 MapGlobe.LANDMARK_COLORS / MapSelector.LANDMARK_KIND_NAMES 同源）。
const KNOWN_KINDS := [
	"mountain", "river", "gorge", "plateau", "lake", "reef", "monolith",
]

## [纬度, 经度, 区域, 期望是否落在包围盒内, 说明]，正反例混在一张表里。
const KNOWN_IN_REGION := [
	[27.99, 86.93, RegionAtlas.ASIA, true, "珠穆朗玛峰在亚洲"],
	[48.20, 16.40, RegionAtlas.EUROPE, true, "多瑙河在欧洲"],
	[-3.07, 37.35, RegionAtlas.AFRICA, true, "乞力马扎罗在非洲"],
	[36.10, -112.10, RegionAtlas.NORTH_AMERICA, true, "大峡谷在北美洲"],
	[-15.80, -69.30, RegionAtlas.SOUTH_AMERICA, true, "的的喀喀湖在南美洲"],
	[-18.30, 147.70, RegionAtlas.OCEANIA, true, "大堡礁在大洋洲"],
	[-89.90, 0.0, RegionAtlas.ANTARCTICA, true, "南极点在南极洲"],
	[89.90, 0.0, RegionAtlas.ARCTIC, true, "北极点在北冰洋"],
	[19.60, -155.50, RegionAtlas.PACIFIC, true, "夏威夷在太平洋"],
	[-25.0, 0.0, RegionAtlas.ATLANTIC, true, "南大西洋在大西洋"],
	[-19.0, 46.80, RegionAtlas.INDIAN, true, "马达加斯加以东海域在印度洋"],
	[0.0, 0.0, RegionAtlas.ASIA, false, "本初子午线不属于亚洲"],
	[45.0, -100.0, RegionAtlas.EUROPE, false, "北美中部不属于欧洲"],
	[-60.0, 0.0, RegionAtlas.ASIA, false, "南纬 60° 不属于亚洲"],
]

var _failed := 0


func _ready() -> void:
	await _run()


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("PASS: %s" % msg)
	else:
		_failed += 1
		print("FAIL: %s" % msg)


func _run() -> void:
	# 存档隔离（D-010 铁律 3）：本探针不建主场景、不触碰 user://，
	# 但仍按范式备份/还原——宁可多一次，不能漏一次。
	# 断言失败走的是 _check 计数分支而非崩溃，故两条路径都能跑到 restore。
	SaveGuard.snapshot()

	_check_a_projection()
	_check_b_data()
	await _check_c_globe()
	await _check_d_selector()

	SaveGuard.restore()
	print("LANDMARK_PROBE_DONE failed=%d" % _failed)
	get_tree().quit(0 if _failed == 0 else 1)


# ── A. GeoProjection ──────────────────────────────────────────────────
func _check_a_projection() -> void:
	var fails := GeoProjection.self_test()
	_check(fails.is_empty(), "GeoProjection.self_test 无失败项%s" % (
		"" if fails.is_empty() else "（%s）" % "；".join(fails)))

	# 往返互逆：逐条走一遍真实地标坐标，外加一组跨象限的一般点。
	var probes: Array[Vector2] = [
		Vector2(0.0, 0.0), Vector2(45.0, 120.0), Vector2(-60.0, -75.0), Vector2(89.9, -179.0),
	]
	for region_id in RegionAtlas.COUNT:
		for mark: Dictionary in RegionAtlas.landmarks_of(region_id):
			probes.append(Vector2(float(mark["lat"]), float(mark["lon"])))
	var worst := 0.0
	for p: Vector2 in probes:
		var back := RegionAtlas.dir_to_lat_lon(GeoProjection.landmark_dir(p.x, p.y))
		worst = maxf(worst, absf(back.x - p.x))
		worst = maxf(worst, absf(back.y - p.y))
	_check(worst < ROUND_TRIP_LIMIT,
		"经纬度 → 方向向量 → 经纬度 往返误差 %.5f° < %.2f°（共 %d 点）" % [
			worst, ROUND_TRIP_LIMIT, probes.size(),
		])

	var known_ok := true
	for row: Array in KNOWN_IN_REGION:
		var lat: float = row[0]
		var lon: float = row[1]
		var region_id: int = row[2]
		var expect: bool = row[3]
		if GeoProjection.in_region(lat, lon, region_id) != expect:
			known_ok = false
	_check(known_ok, "in_region 对 %d 组已知正反例判定正确" % KNOWN_IN_REGION.size())

	# 每个地标都必须落在自己所属区域的近似包围盒内。
	var strays: Array[String] = []
	for region_id in RegionAtlas.COUNT:
		for mark: Dictionary in RegionAtlas.landmarks_of(region_id):
			if not GeoProjection.in_region(float(mark["lat"]), float(mark["lon"]), region_id):
				strays.append(String(mark["title"]))
	_check(strays.is_empty(), "全部地标落在所属区域的近似包围盒内%s" % (
		"" if strays.is_empty() else "（越界：%s）" % "、".join(strays)))

	# 全局序号 ↔ (区域, 区内下标) 的口径必须能往返。
	var total := GeoProjection.landmark_total()
	var reverse_ok := true
	for i in total:
		var ref := GeoProjection.landmark_ref(i)
		if ref.x < 0 or ref.y < 0:
			reverse_ok = false
			continue
		if _flat_index(ref.x, ref.y) != i:
			reverse_ok = false
	_check(reverse_ok, "全局地标序号 ↔ (区域, 区内下标) 口径互逆（共 %d 条）" % total)
	_check(
		GeoProjection.landmark_ref(-1) == Vector2i(-1, -1)
		and GeoProjection.landmark_ref(total + 5) == Vector2i(-1, -1),
		"越界的地标序号返回 (-1,-1)",
	)
	_check(GeoProjection.region_bounds(-7).has("lat_min"), "region_bounds 对越界 id 做钳制而不崩")


## 地标数据的「区域优先逐区摊平」全局序号（MapGlobe 图钉同口径）。
func _flat_index(region_id: int, index_in_region: int) -> int:
	var flat := 0
	for rid in RegionAtlas.COUNT:
		if rid == region_id:
			return flat + index_in_region
		flat += RegionAtlas.landmarks_of(rid).size()
	return -1


func _region_index_of(region_id: int, title: String) -> int:
	var marks := RegionAtlas.landmarks_of(region_id)
	for i in marks.size():
		if String(marks[i]["title"]) == title:
			return i
	return -1


# ── B. REGION_LANDMARKS 数据完整性 ────────────────────────────────────
func _check_b_data() -> void:
	var empty_regions: Array[String] = []
	var field_bad: Array[String] = []
	var range_bad: Array[String] = []
	var kind_bad: Array[String] = []
	var path_bad: Array[String] = []
	var dup_bad: Array[String] = []
	var total := 0
	for region_id in RegionAtlas.COUNT:
		var marks := RegionAtlas.landmarks_of(region_id)
		if marks.is_empty():
			empty_regions.append(RegionAtlas.title_of(region_id))
		var seen_titles: Dictionary = {}
		for mark: Dictionary in marks:
			total += 1
			var title := String(mark.get("title", ""))
			var kind := String(mark.get("kind", ""))
			var text := String(mark.get("text", ""))
			if title.is_empty() or kind.is_empty() or text.is_empty():
				field_bad.append(title if not title.is_empty() else "#%d" % total)
			var lat := float(mark.get("lat", 999.0))
			var lon := float(mark.get("lon", 999.0))
			if lat < -90.0 or lat > 90.0 or lon < -180.0 or lon > 180.0:
				range_bad.append(title)
			if not KNOWN_KINDS.has(kind):
				kind_bad.append("%s:%s" % [title, kind])
			if kind == "river" and Array(mark.get("path", [])).size() < 2:
				path_bad.append(title)
			if seen_titles.has(title):
				dup_bad.append(title)
			seen_titles[title] = true
	_check(empty_regions.is_empty(), "11 个区域都有地标%s" % (
		"" if empty_regions.is_empty() else "（缺：%s）" % "、".join(empty_regions)))
	_check(field_bad.is_empty(), "每条地标的 title/kind/text 均非空%s" % (
		"" if field_bad.is_empty() else "（缺字段：%s）" % "、".join(field_bad)))
	_check(range_bad.is_empty(), "经纬度均在合法范围内（纬度 ±90 / 经度 ±180）%s" % (
		"" if range_bad.is_empty() else "（越界：%s）" % "、".join(range_bad)))
	_check(kind_bad.is_empty(), "kind 全部落在画法表之内%s" % (
		"" if kind_bad.is_empty() else "（未知 kind：%s）" % "、".join(kind_bad)))
	_check(path_bad.is_empty(), "河流类地标都给了 ≥2 个河道采样点%s" % (
		"" if path_bad.is_empty() else "（缺 path：%s）" % "、".join(path_bad)))
	_check(dup_bad.is_empty(), "同区域内地标标题不重名%s" % (
		"" if dup_bad.is_empty() else "（重名：%s）" % "、".join(dup_bad)))
	_check(total == GeoProjection.landmark_total(),
		"地标条数统计一致（逐区求和 %d = landmark_total %d）" % [
			total, GeoProjection.landmark_total(),
		])

	# 亚洲：需求点名的条目必须齐全。
	var asia_titles: Array[String] = []
	for mark: Dictionary in RegionAtlas.landmarks_of(RegionAtlas.ASIA):
		asia_titles.append(String(mark["title"]))
	var missing: Array[String] = []
	for want: String in REQUIRED_ASIA:
		if not asia_titles.has(want):
			missing.append(want)
	_check(missing.is_empty(), "亚洲含三山五岳/长江黄河/三峡/高原/珠峰等 %d 条%s" % [
		asia_titles.size(), "" if missing.is_empty() else "（缺：%s）" % "、".join(missing),
	])

	# 七大洲的地标必须真实落在自己的陆地掩码里——这一步专抓「泰山写成 75°N」。
	# 四大洋不做这项断言：5° 粗掩码的洋界（147°E / 70°W）本就与常识有出入，
	# 例如马里亚纳海沟（142°E）会落在印度洋格上，那是精度问题不是数据错误。
	var drift: Array[String] = []
	for region_id in range(RegionAtlas.ASIA, RegionAtlas.COUNT):
		for mark: Dictionary in RegionAtlas.landmarks_of(region_id):
			if GeoProjection.land_mask_region(float(mark["lat"]), float(mark["lon"])) != region_id:
				drift.append(String(mark["title"]))
			if String(mark.get("kind", "")) != "river":
				continue
			for at: Vector2 in Array(mark.get("path", [])):
				if GeoProjection.land_mask_region(at.x, at.y) != region_id:
					drift.append(String(mark["title"]) + "河道")
	_check(drift.is_empty(), "七大洲地标（含河道采样点）落在自己的陆地掩码内%s" % (
		"" if drift.is_empty() else "（归错：%s）" % "、".join(drift)))

	_check(
		RegionAtlas.landmarks_of(-3).is_empty() and RegionAtlas.landmarks_of(999).is_empty(),
		"landmarks_of 对越界区域返回空数组",
	)


# ── C. MapGlobe 地标图钉 ──────────────────────────────────────────────
func _check_c_globe() -> void:
	var globe := MapGlobe.new()
	add_child(globe)
	globe.build()
	globe.set_view_angles(0.0, 0.0)
	for i in range(4):
		await get_tree().process_frame

	var expected := GeoProjection.landmark_total()
	_check(globe.landmark_marker_count() == expected,
		"球面上地标图钉枚数与数据条数一致（%d/%d）" % [
			globe.landmark_marker_count(), expected,
		])

	globe.build()
	await get_tree().process_frame
	_check(globe.landmark_marker_count() == expected,
		"重复 build 不重复生成图钉（仍 %d 枚）" % globe.landmark_marker_count())

	var pins: Array = globe._landmark_markers
	var outside_ok := true
	var handed_ok := true
	# 循环变量必须显式标注类型：pins 是 untyped Array，取出的元素是 Variant，
	# 用 := 让引擎推断会因「值没有固定类型」直接 parse error（本项目警告即错误）。
	for pin: Node3D in pins:
		if not is_instance_valid(pin):
			outside_ok = false
			continue
		var d := pin.position.length()
		if d <= 1.0 or d >= 1.20:
			outside_ok = false
		if pin.basis.determinant() <= 0.0:
			handed_ok = false
	_check(outside_ok, "地标图钉浮在球面之外且不飘远（|pos| ∈ (1.0, 1.20)）")
	_check(handed_ok, "地标图钉基底为右手系（无镜像翻转）")

	# 图钉不能挤到「区域名 / 小飞机 / 小鱼」那三件上（它们沿北向切向竖排）。
	var old_markers: Array = []
	old_markers.append_array(globe._region_labels)
	old_markers.append_array(globe._airport_markers)
	old_markers.append_array(globe._field_markers)
	old_markers.append_array(globe._fish_markers)
	var spread_ok := true
	for pin in pins:
		if not is_instance_valid(pin):
			continue
		for old_node: Node3D in old_markers:
			if not is_instance_valid(old_node):
				continue
			if pin.position.distance_to(old_node.position) < 0.05:
				spread_ok = false
	_check(spread_ok, "地标图钉与既有标记（名称/小飞机/小鱼）不叠在一起")

	# 河流光带：方块数 = 各河道采样点数之和。
	var want_segments := 0
	for region_id in RegionAtlas.COUNT:
		for mark: Dictionary in RegionAtlas.landmarks_of(region_id):
			if String(mark.get("kind", "")) == "river":
				want_segments += Array(mark.get("path", [])).size()
	_check(globe.river_segment_count() == want_segments,
		"河流光带方块数等于河道采样点总数（%d/%d）" % [
			globe.river_segment_count(), want_segments,
		])

	# 脉冲透明度：跑若干帧后 alpha 应当变化且落在设定区间内。
	var flowed := false
	var segments: Array = globe._river_segments
	if not segments.is_empty():
		var sample: MeshInstance3D = segments[0] as MeshInstance3D
		var flow_mat: StandardMaterial3D = \
			(sample.material_override as StandardMaterial3D) if sample != null else null
		if flow_mat != null:
			var before := flow_mat.albedo_color.a
			for i in range(20):
				await get_tree().process_frame
			var after := flow_mat.albedo_color.a
			flowed = absf(after - before) > 0.01
			flowed = flowed and after >= MapGlobe.RIVER_ALPHA_MIN - 0.001
			flowed = flowed and after <= MapGlobe.RIVER_ALPHA_MAX + 0.001
	_check(flowed, "长江/黄河光带有脉冲透明度动画且 alpha 落在设定区间")

	# 射线拾取：正面命中 / 背面 -1 / 完全没打到 -1。
	var target := _flat_index(RegionAtlas.ASIA, _region_index_of(RegionAtlas.ASIA, "泰山"))
	_check(target >= 0, "能定位到「泰山」图钉的全局序号（%d）" % target)
	if target >= 0:
		var pin_on_target: Node3D = pins[target]
		var aim: Vector3 = globe.to_global(pin_on_target.position)
		var outward: Vector3 = aim.normalized()
		var hit := globe.landmark_at_world_ray(outward * 4.0, -outward)
		_check(hit == target, "正面射线命中该图钉（返回 %d）" % hit)
		var entry := globe.landmark_entry(hit)
		_check(
			String(entry.get("title", "")) == "泰山"
			and int(entry.get("region", -1)) == RegionAtlas.ASIA,
			"命中的图钉能还原出地标数据与其所属区域",
		)
		_check(
			globe.landmark_at_world_ray(-outward * 4.0, outward) == -1,
			"背面射线返回 -1（背对相机的图钉不算命中）",
		)
	_check(
		globe.landmark_at_world_ray(Vector3(0.0, 0.0, 3.0), Vector3(1.0, 0.0, 0.0)) == -1,
		"射线完全没打到球体时返回 -1",
	)
	_check(
		globe.landmark_entry(-1).is_empty() and globe.landmark_entry(9999).is_empty(),
		"越界的图钉索引返回空数据",
	)

	globe.set_landmarks_visible(false)
	_check(not globe.landmarks_visible(), "地标图钉显隐开关可用（可隐藏）")
	globe.set_landmarks_visible(true)
	_check(globe.landmarks_visible(), "地标图钉可恢复显示")
	globe.queue_free()


# ── D. MapSelector 介绍页地标分区 ─────────────────────────────────────
func _check_d_selector() -> void:
	var selector := MapSelector.new()
	add_child(selector)
	for i in range(4):
		await get_tree().process_frame
	if not is_instance_valid(selector):
		_check(false, "地图选择器可独立实例化")
		return

	var asia_count := RegionAtlas.landmarks_of(RegionAtlas.ASIA).size()
	selector._show_intro(RegionAtlas.ASIA)
	# 必须等一帧：旧条目是 queue_free 掉的，本帧末尾才真正离开树，
	# 立刻数会数到「旧的 + 新的」。
	await get_tree().process_frame
	_check(selector._landmark_grid.get_child_count() == asia_count,
		"介绍页为所选区域生成地标条目（亚洲 %d 条，实际 %d）" % [
			asia_count, selector._landmark_grid.get_child_count(),
		])
	_check(selector.get_page() == MapSelector.Page.INTRO, "加了地标分区后仍停在介绍页（三页流程未变）")
	_check(selector._card_row.get_child_count() == 3, "原有 3 张知识卡没有被地标分区顶掉")

	var europe_count := RegionAtlas.landmarks_of(RegionAtlas.EUROPE).size()
	selector._show_intro(RegionAtlas.EUROPE)
	await get_tree().process_frame
	_check(selector._landmark_grid.get_child_count() == europe_count,
		"切换区域后地标条目随之刷新（欧洲 %d 条，实际 %d）" % [
			europe_count, selector._landmark_grid.get_child_count(),
		])

	# 本区地标：按钮文案必须诚实（「去亚洲看看」而不是「降落在泰山」）。
	selector._show_intro(RegionAtlas.ASIA)
	var tai_index := _region_index_of(RegionAtlas.ASIA, "泰山")
	selector._open_landmark_detail(RegionAtlas.ASIA, tai_index)
	_check(selector._landmark_detail.visible and selector.open_landmark_index() == tai_index,
		"点地标条目弹出科普卡浮层")
	_check(
		String(selector._landmark_detail_title.text) == "泰山"
		and not String(selector._landmark_detail_text.text).is_empty(),
		"科普卡显示地标标题与一句话科普",
	)
	_check(
		not selector._landmark_detail_note.visible
		and String(selector._landmark_detail_go.text) == "去亚洲看看",
		"本区地标的按钮诚实写「去亚洲看看」（不谎称降落在地标）",
	)
	selector._close_landmark_detail()
	_check(not selector._landmark_detail.visible and selector.open_landmark_index() == -1,
		"地标卡可关闭且状态复位")

	# 跨区域地标：明确指出在哪个区域，并允许一键切换。
	selector._show_intro(RegionAtlas.EUROPE)
	selector._open_landmark_detail(RegionAtlas.ASIA, tai_index)
	_check(
		selector.open_landmark_region() == RegionAtlas.ASIA
		and selector._landmark_detail_note.visible
		and String(selector._landmark_detail_note.text).begins_with("泰山在亚洲"),
		"跨区域地标给出「泰山在亚洲，要切换区域才能去」的提示",
	)

	var entered: Array = []
	selector.region_entered.connect(func(rid: int): entered.append(rid))
	selector._landmark_detail_go.pressed.emit()
	_check(entered == [RegionAtlas.ASIA], "点「去这里」进入地标所属区域（发出 region_entered(亚洲)）")
	_check(selector._selected == RegionAtlas.ASIA, "「去这里」后选中区域同步切到该地标所属区域")

	# 球体图钉 → 介绍页：把 MapGlobe 与 MapSelector 的索引口径串起来校验。
	selector._show_page(MapSelector.Page.GLOBE)
	selector.open_landmark(RegionAtlas.ASIA, _region_index_of(RegionAtlas.ASIA, "长江"))
	_check(
		selector.get_page() == MapSelector.Page.INTRO
		and String(selector._landmark_detail_title.text) == "长江"
		and selector.open_landmark_region() == RegionAtlas.ASIA,
		"从球体图钉打开地标：自动切到所属区域介绍页并弹出卡片",
	)

	selector.queue_free()
