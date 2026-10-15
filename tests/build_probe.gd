extends Node
## 建造编辑器探针（D-032 Phase 2）：纯逻辑验证——蓝图的合法性校验、
## 重心/升力中心/推力矢量、序列化存读、对称镜像、增删旋转、可视化建节点。
## 无世界依赖，直接驱动 Blueprint / BuildEditor / BuildVisualizer。
## 运行：Godot_v4.6.3-stable_win64_console.exe --headless --path . res://tests/build_probe.tscn

var _failed := 0


func _ready() -> void:
	await _run()
	_finish()


func _run() -> void:
	_check_default_valid()
	_check_center_of_gravity()
	_check_aggregates()
	_check_orphan_invalid()
	_check_no_fuselage_invalid()
	_check_symmetry_mirror()
	_check_save_load_roundtrip()
	_check_remove_rotate()
	_check_rotate_then_remove_mirror()
	_check_visualizer()
	_check_robust_io()


## 默认套件合法（含机身且全连通）。
func _check_default_valid() -> void:
	var e := BuildEditor.new()
	e.blueprint.parts = PartRegistry.default_loadout()
	var v: Dictionary = e.validate()
	_check(v["ok"], "默认套件合法（含机身且全连通）")


## 蓝图重心 = Airframe 聚合重心（单一数据源，不应有二套计算）。
func _check_center_of_gravity() -> void:
	var bp := Blueprint.new()
	bp.parts = PartRegistry.default_loadout()
	var cog := bp.center_of_gravity()
	var ref := AircraftFlight.Airframe.aggregate(bp.parts).com
	_check(cog.distance_to(ref) < 1e-6,
		"蓝图重心 = 聚合重心（%.3f,%.3f,%.3f）" % [cog.x, cog.y, cog.z])


## 蓝图聚合与 D-031 标定一致（经 Blueprint 路径复算）。
func _check_aggregates() -> void:
	var bp := Blueprint.new()
	bp.parts = PartRegistry.default_loadout()
	var af := bp.aggregate()
	_check(absf(af.mass - 240.0) < 0.01, "聚合质量 = 240 kg（%.1f）" % af.mass)
	_check(absf(af.wing_area - 14.0) < 0.01, "聚合翼面积 = 14 m²（%.1f）" % af.wing_area)
	_check(absf(af.thrust_max - 1650.0) < 0.01, "聚合推力 = 1650 N（%.0f）" % af.thrust_max)
	_check(absf(af.cd0 - 0.075) < 1e-6, "聚合 cd0 = 0.075（%.3f）" % af.cd0)
	var tv: Dictionary = bp.thrust_vector()
	_check(absf(tv["magnitude"] - 1650.0) < 0.01, "推力矢量量级 = 1650 N")
	_check(tv["dir"].is_equal_approx(Vector3(0, 0, -1)), "推力矢量指向机头 -Z")


## 孤立零件（不与机身面邻接）→ 非法。
func _check_orphan_invalid() -> void:
	var e := BuildEditor.new()
	e.place(PartRegistry.by_id("fuselage"), Vector3i(0, 0, 0), 0, false)
	e.place(PartRegistry.by_id("wing"), Vector3i(20, 1, 0), 0, false)
	var v: Dictionary = e.validate()
	_check(not v["ok"], "孤立翼（不连机身）→ 非法")
	var joined := ""
	for s in v["errors"]:
		joined += s + ";"
	_check(joined.contains("orphan"), "孤立件报错含 orphan（%s）" % joined)


## 无机身 → 非法（机身是结构根）。
func _check_no_fuselage_invalid() -> void:
	var e := BuildEditor.new()
	e.place(PartRegistry.by_id("wing"), Vector3i(0, 1, 0), 0, false)
	var v: Dictionary = e.validate()
	_check(not v["ok"] and v["errors"].has("no_fuselage"), "无机身 → 报 no_fuselage")


## X 轴对称镜像：放右侧翼，镜像出左侧翼。
func _check_symmetry_mirror() -> void:
	var e := BuildEditor.new()
	e.place(PartRegistry.by_id("wing"), Vector3i(1, 1, -2), 0, true)
	_check(e.blueprint.parts.size() == 2, "镜像放置产生 2 个零件（实 %d）" % e.blueprint.parts.size())
	var mirrored := false
	for p in e.blueprint.parts:
		if p.cell.x == -24:  # 1 + 24 - 1 → -(-24) 的镜像锚
			mirrored = true
	_check(mirrored, "镜像件锚格落于 x=-24（对称于 x=0）")


## 蓝图存读：写 JSON → 读回，零件集合一致。
## 蓝图存读：写 JSON → 读回，零件集合一致。
func _check_save_load_roundtrip() -> void:
	var path := "user://build_probe_test.json"
	var e := BuildEditor.new()
	e.blueprint.parts = PartRegistry.default_loadout()
	e.blueprint.title = "probe_ship"
	e.save(path)
	var loaded := BuildEditor.load(path)
	_check(loaded != null, "从 JSON 读回蓝图成功")
	if loaded != null:
		_check(loaded.blueprint.parts.size() == 7, "读回零件数一致（7）")
		_check(loaded.blueprint.title == "probe_ship", "读回标题一致")
		var ok := true
		for i in loaded.blueprint.parts.size():
			var a := loaded.blueprint.parts[i]
			var b := e.blueprint.parts[i]
			if a.data.id != b.data.id or a.cell != b.cell or a.rot != b.rot:
				ok = false
		_check(ok, "读回每件 id/格/旋转一致")


## 存档健壮性（P2-13/14/15）：version 字段与旧档兼容、畸形态逐件容错
## 不崩栈、save 返回值可判成败。
func _check_robust_io() -> void:
	# P2-15：to_dict 带版本号；无 version 的旧档（缺省按 1）也能读。
	var e := BuildEditor.new()
	e.blueprint.parts = PartRegistry.default_loadout()
	var d := e.blueprint.to_dict()
	_check(int(d.get("version", 0)) == Blueprint.SAVE_VERSION,
		"P2-15：蓝图存档带 version 字段（%d）" % int(d.get("version", 0)))
	var legacy := d.duplicate()
	legacy.erase("version")
	var bp_legacy := Blueprint.from_dict(legacy)
	_check(bp_legacy != null and bp_legacy.parts.size() == 7,
		"P2-15：无 version 的旧档按最新格式兼容读入（7 件）")
	# P2-13：畸形态逐件容错——缺 id/cell、cell 长度不足、未知 id、类型不对
	# 全部跳过不崩栈；缺 rot 缺省 0；合法件照常装入。
	var broken := {
		"title": "broken",
		"parts": [
			{"cell": [0, 0, 0], "rot": 0},
			{"id": "fuselage", "rot": 0},
			{"id": "fuselage", "cell": [0, 0], "rot": 0},
			{"id": "no_such_part", "cell": [0, 0, 0], "rot": 0},
			"not_a_dict",
			{"id": "fuselage", "cell": [0, 0, 0]},
		],
	}
	var bp_broken := Blueprint.from_dict(broken)
	_check(bp_broken != null and bp_broken.parts.size() == 1,
		"P2-13：畸形态存档只装入合法件（1 件，5 种坏件跳过不崩）")
	if bp_broken != null and bp_broken.parts.size() == 1:
		_check(bp_broken.parts[0].rot == 0,
			"P2-13：缺 rot 缺省 0（实 %d）" % bp_broken.parts[0].rot)
	# P2-14：save 返回值可判成败——好路径 true、坏路径（目录不存在）false。
	var path := "user://build_probe_test.json"
	_check(e.save(path), "P2-14：save 正常路径返回 true")
	_check(not e.save("user://no_such_dir/bp.json"),
		"P2-14：save 到不存在目录返回 false（调用方可提示玩家）")


## 删除与旋转：删除减少计数；旋转步进 mod 4。
func _check_remove_rotate() -> void:
	var e := BuildEditor.new()
	e.place(PartRegistry.by_id("wing"), Vector3i(1, 1, -2), 0, true)
	var before := e.blueprint.parts.size()
	e.remove_at(Vector3i(1, 1, -2), true)
	_check(e.blueprint.parts.size() == before - 2, "带镜像删除一次移除 2 件")
	e.clear()
	e.place(PartRegistry.by_id("engine"), Vector3i(-1, 0, -9), 0, false)
	var rot0 := e.blueprint.parts[0].rot
	e.rotate_at(Vector3i(-1, 0, -9), false)
	_check(e.blueprint.parts[0].rot == wrapi(rot0 + 1, 0, 4), "旋转一次 rot 步进 +1 mod 4")


## 旋转后删镜像伴侣（Phase 4a 修）：旋转改变宽/深跨度，按锚格反推镜像
## 关系会失效——镜像链接在放置时写死，删除/旋转按链接配对。
func _check_rotate_then_remove_mirror() -> void:
	var e := BuildEditor.new()
	e.place(PartRegistry.by_id("wing"), Vector3i(2, 1, -2), 0, true)
	_check(e.blueprint.parts.size() == 2, "旋转测试：镜像放置 2 件")
	e.rotate_at(Vector3i(2, 1, -2), true)
	var both_rotated := true
	for p in e.blueprint.parts:
		if p.rot != 1:
			both_rotated = false
	_check(both_rotated, "带镜像旋转时两侧同步步进")
	e.remove_at(Vector3i(2, 1, -2), true)
	_check(e.blueprint.parts.is_empty(),
		"旋转后仍能按链接删光镜像伴侣（剩 %d 件）" % e.blueprint.parts.size())
	# 反向：直接删镜像件，原装件连带删除。
	e.clear()
	e.place(PartRegistry.by_id("wing"), Vector3i(2, 1, -2), 0, true)
	var twin_cell := Vector3i.ZERO
	for p in e.blueprint.parts:
		if p.is_mirrored():
			twin_cell = p.cell
	e.remove_at(twin_cell, true)
	_check(e.blueprint.parts.is_empty(),
		"删镜像件连带删除原装件（剩 %d 件）" % e.blueprint.parts.size())


## 可视化：根据蓝图生成重心/升力中心/推力线标记节点。
func _check_visualizer() -> void:
	var bp := Blueprint.new()
	bp.parts = PartRegistry.default_loadout()
	var viz := BuildVisualizer.new()
	add_child(viz)
	viz.rebuild(bp)
	var count := viz.get_child_count()
	_check(count >= 3, "可视化生成 ≥3 个标记（实 %d）" % count)
	_check(viz.has_node("cog"), "含重心标记 cog")
	_check(viz.has_node("lift"), "含升力中心标记 lift")
	_check(viz.has_node("thrust"), "含推力线标记 thrust")


func _finish() -> void:
	# 清理探针临时蓝图，不留在 user://（D-010 铁律 3）。
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://build_probe_test.json"))
	if _failed == 0:
		print("BUILD_PROBE_OK")
		get_tree().quit(0)
	else:
		print("BUILD_PROBE_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
