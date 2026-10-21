extends Node
## D-055 亚洲分层地形勘察探针（不纳入常规回归，手动跑）。
## 目的：用数字证明「喜马拉雅/青藏高原/长江黄河」真的生成了，而不是只改了常量。
## 运行：Godot --headless --path . res://tests/terrain_survey_probe.tscn

const SAMPLE := 512          # 采样区边长（格）：512×512 = 26 万列
const HALF := SAMPLE / 2

var _failed := 0
var _passed := 0


func _check(ok: bool, msg: String) -> void:
	if ok:
		_passed += 1
		print("PASS %s" % msg)
	else:
		_failed += 1
		print("FAIL %s" % msg)


func _ready() -> void:
	await _run()
	print("PROBE terrain_survey %d PASS / %d FAIL" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	await get_tree().process_frame
	var world: World = main_scene.get_node("World")

	# 亚洲（默认区域）应为 layered。
	_check(String(world._profile.get("terrain", "")) == "layered",
		"① 默认区域是 layered（%s）" % world._profile.get("terrain", ""))
	_check(world._flat_zones().size() == 4,
		"① 平整保护区 %d 个（机场×2 + 村庄 + 降落场）" % world._flat_zones().size())

	# ── ② 高度分布统计 ──
	var h_min := 9999
	var h_max := -1
	var sum := 0.0
	var n := 0
	var above_rock := 0     # 裸岩线以上（山体）
	var above_snow := 0     # 雪线以上
	var in_river := 0       # 河心
	var river_wet := 0      # 河心且低于海面（有水）
	var heights := {}
	for x in range(-HALF, HALF, 2):
		for z in range(-HALF, HALF, 2):
			var h := world._terrain_height(x, z)
			h_min = mini(h_min, h)
			h_max = maxi(h_max, h)
			sum += float(h)
			n += 1
			if h > World.ROCK_LINE:
				above_rock += 1
			if h > World.SNOW_LINE:
				above_snow += 1
			var rv := world._river_strength(x, z)
			if rv > 0.78:
				in_river += 1
				if h < World.SEA_LEVEL:
					river_wet += 1
			var bucket := int(floor(float(h) / 20.0)) * 20
			heights[bucket] = int(heights.get(bucket, 0)) + 1
	var mean := sum / float(n)
	print("DBG 高度 min=%d max=%d mean=%.1f n=%d" % [h_min, h_max, mean, n])
	print("DBG 裸岩线以上 %d 列 (%.2f%%) / 雪线以上 %d 列 (%.2f%%)"
		% [above_rock, 100.0 * above_rock / n, above_snow, 100.0 * above_snow / n])
	print("DBG 河心 %d 列 (%.2f%%) / 其中有水 %d 列"
		% [in_river, 100.0 * in_river / n, river_wet])

	_check(h_max > World.ROCK_LINE + 30,
		"② 出现高山：最高 %d 格（%.1f m），远超裸岩线 %d" % [h_max, h_max * 0.5, World.ROCK_LINE])
	_check(above_rock > n / 500,
		"② 山体占比 %.2f%%（>0.2%%，%d 列）——不是孤例" % [100.0 * above_rock / n, above_rock])
	_check(above_snow > 0,
		"② 雪线以上有积雪：%d 列（%.2f%%）" % [above_snow, 100.0 * above_snow / n])
	_check(h_min < World.SEA_LEVEL,
		"② 有低于海面的河床/洼地：最低 %d（海面 %d）" % [h_min, World.SEA_LEVEL])
	_check(in_river > n / 200,
		"② 河心占比 %.2f%%（>0.5%%，%d 列）——河道成规模" % [100.0 * in_river / n, in_river])
	_check(river_wet > 0,
		"② 有有水的河段：%d 列河床低于海面" % river_wet)

	# ── ③ 高度分层不是一锅粥：应有清晰的「平原 / 高原 / 雪脊」三团 ──
	var p_low := 0      # < 60 平原丘陵
	var p_mid := 0      # 60..160 高原与山腰
	var p_high := 0     # > 160 雪脊
	for x in range(-HALF, HALF, 2):
		for z in range(-HALF, HALF, 2):
			var h := world._terrain_height(x, z)
			if h < 60:
				p_low += 1
			elif h <= 160:
				p_mid += 1
			else:
				p_high += 1
	print("DBG 分层 <60: %d / 60..160: %d / >160: %d" % [p_low, p_mid, p_high])
	_check(p_low > n / 10,
		"③ 平原丘陵仍是主体：%.1f%%（玩家日常活动区没被山占满）" % (100.0 * p_low / n))
	_check(p_high < n / 20,
		"③ 雪脊不过量：%.2f%%（<5%%，世界不至于到处是雪山）" % (100.0 * p_high / n))

	# ── ③b 可飞性：全域无「空气墙」（D-055 陡壁回归闸）──
	# 这条是踩过坑才加的：分层地形初版在保护区边界出162 格（81m）断崖，
	# 玩家在机场外遇到空气墙，飞机巡航撞上直接解体，且探针
	# cockpit_instruments_shot 连挂 4 项。噪声参数怎么调都难保证全域无陡壁，
	# 故把「单步落差≤ MAX_SLOPE」钉成断言——地形再改、参数再动，陡壁回归
	# 会立刻在这里 FAIL，而不是等到玩家撞山。
	var worst := 0
	var worst_at := Vector2i.ZERO
	for x in range(-HALF, HALF, 2):
		for z in range(-HALF, HALF, 2):
			var d := absi(world._terrain_height(x, z)
				- world._terrain_height(x - 1, z))
			if d > worst:
				worst = d
				worst_at = Vector2i(x, z)
	_check(worst <= World.MAX_SLOPE + World.SLOPE_SLACK,
		"③b 全域无空气墙：最大单步落差 %d 格（%.1f m）≤ 限坡 %d+%d 格，@%s"
			% [worst, worst * 0.5, World.MAX_SLOPE, World.SLOPE_SLACK,
			str(worst_at)])

	# ── ④ 平整保护区：山与河都不得进入 ──
	var zones: Array[Rect2i] = world._flat_zones()
	var violations := 0
	var zone_cells := 0
	for r in zones:
		for x in range(r.position.x, r.end.x, 3):
			for z in range(r.position.y, r.end.y, 3):
				zone_cells += 1
				var h := world._terrain_height(x, z)
				if h > 44 or h < 18:
					violations += 1
				if world._river_strength(x, z) > 0.34:
					violations += 1
	_check(violations == 0,
		"④ 平整保护区 %d 格零越界（山不进、河不进、高度恒定在 18..44）"
			% zone_cells)

	# ── ⑤ 机场选址仍成功（山顶只有一格可站，凑不出四格空气） ──
	var ok_cols := 0
	for x in range(84, 144, 2):
		for z in range(32, 156, 2):
			var top := -1
			for y in range(World.CHUNK_SIZE.y - 1, 0, -1):
				if world.get_block(Vector3i(x, y, z)) != BlockTypes.Block.AIR:
					top = y
					break
			if top < 0:
				continue
			var clear := true
			for h in range(1, 5):
				if world.get_block(Vector3i(x, top + h, z)) != BlockTypes.Block.AIR:
					clear = false
					break
			if clear:
				ok_cols += 1
	_check(ok_cols > 1000,
		"⑤ 机场区有 %d 列可站立且上方四格空气（选址判据能过）" % ok_cols)

	# ── ⑥ 地表材质真的分层了（不是只有草） ──
	var mats := {}
	for x in range(-HALF, HALF, 4):
		for z in range(-HALF, HALF, 4):
			var h := world._terrain_height(x, z)
			var ids := world._surface_ids(x, z, h)
			mats[ids.x] = int(mats.get(ids.x, 0)) + 1
	var kinds := mats.size()
	print("DBG 地表材质种类 %d：" % kinds)
	for id in mats:
		print("DBG   %s = %d (%.2f%%)" % [
			BlockTypes.display_name(id), mats[id], 100.0 * mats[id] / n])
	_check(kinds >= 3,
		"⑥ 地表材质 %d 种（≥3：草/岩/雪/砾石至少三种同时存在）" % kinds)
	_check(mats.has(BlockTypes.Block.ROCK),
		"⑥ 出现裸岩地表（%d 列）" % int(mats.get(BlockTypes.Block.ROCK, 0)))
	_check(mats.has(BlockTypes.Block.SNOW),
		"⑥ 出现积雪地表（%d 列）" % int(mats.get(BlockTypes.Block.SNOW, 0)))
	_check(mats.has(BlockTypes.Block.GRAVEL),
		"⑥ 出现砾石河床（%d 列）" % int(mats.get(BlockTypes.Block.GRAVEL, 0)))

	# ── ⑦ 生成耗时（高度 4 倍后不能把流式加载拖垮） ──
	var t0 := Time.get_ticks_usec()
	for i in range(8):
		world._load_chunk(Vector2i(200 + i, 200), false)
	var dt_ms := float(Time.get_ticks_usec() - t0) / 8000.0
	print("DBG 单块生成 %.2f ms（8 块平均）" % dt_ms)
	_check(dt_ms < 60.0,
		"⑦ 单块生成 %.2f ms（<60 ms：飞行流式每帧预算 8 ms 的余量内）" % dt_ms)
