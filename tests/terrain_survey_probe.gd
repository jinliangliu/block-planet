extends Node
## D-055 亚洲分层地形勘察探针（纳入日常回归；地形改动后它是主闸）。
## 目的：用数字证明「喜马拉雅/青藏高原/长江黄河」真的生成了，而不是只改了常量。
## D-072 机场谷地（近场限高）落地后增补三项巡察：
##   ⓪ 谷地安全区：机场 260 m 内无山、无陡壁（起飞不许装山）；
##   ②③⑥ 的世界性格采样从「原点 ±256 方区」改为机场外 950..1500 m 环带——
##       方区现已落进谷地（限高后量不到山，会假 FAIL/假 PASS）；
##   ③b 渐变带「限高不加剧陡壁」：同一批点比较限高后与未限高的单步落差。
## 运行：Godot --headless --path . res://tests/terrain_survey_probe.tscn

const CX := 114          # 机场中心格（与 main._airport_center(ASIA) 有交叉断言）
const CZ := 96
const VALLEY_R := 260    # 谷地盘巡察半径（格）：< world.VALLEY_R(300) 的纯谷地
const RING_IN := 950     # 环带内半径：> world.VALLEY_RAMP(900)，已是全量地形
const RING_OUT := 1500
const RING_DIRS := 64
const RING_STEP := 10

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


## 渐变带环（机场中心 260..1000 m，4 步长采样）西向单步落差的最大值。
func _ramp_worst_step(world: World) -> int:
	var worst := 0
	for x in range(CX - 1000, CX + 1000, 4):
		for z in range(CZ - 1000, CZ + 1000, 4):
			var rdx := x - CX
			var rdz := z - CZ
			var d2 := rdx * rdx + rdz * rdz
			if d2 < VALLEY_R * VALLEY_R or d2 > 1000 * 1000:
				continue
			worst = maxi(worst, absi(world._terrain_height(x, z)
				- world._terrain_height(x - 1, z)))
	return worst


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

	# D-072：谷地中心必须与 Main 的机场选址一致（两处硬编码会漂移，曾有
	# mission_anchor y=0 之类「两套真相」事故，这里钉死）。
	var c: Array = world._profile.get("airport_center", [])
	var main_center: Vector3i = main_scene._airport_center(GameState.current_region)
	_check(c.size() == 2 and int(c[0]) == main_center.x and int(c[1]) == main_center.z,
		"① 谷地中心 (%d,%d) 与 main 机场选址一致（%d,%d）"
			% [int(c[0]) if c.size() == 2 else -1, int(c[1]) if c.size() == 2 else -1,
			main_center.x, main_center.z])

	# ── ⓪ D-072 机场谷地：起飞安全区 ──
	# 谷内分层附加量被压到 0，高度只剩丘陵基底（28±10）。断言留了余量：
	# 基底理论上限 ~44（与④平整区的 18..44 同源），50 以内都算「没有山」。
	var v_max := -1
	var v_min := 9999
	var v_over := 0
	var v_worst := 0
	var v_n := 0
	for x in range(CX - VALLEY_R, CX + VALLEY_R, 2):
		for z in range(CZ - VALLEY_R, CZ + VALLEY_R, 2):
			var vdx := x - CX
			var vdz := z - CZ
			if vdx * vdx + vdz * vdz > VALLEY_R * VALLEY_R:
				continue
			var vh := world._terrain_height(x, z)
			v_max = maxi(v_max, vh)
			v_min = mini(v_min, vh)
			if vh > 60:
				v_over += 1
			v_n += 1
			v_worst = maxi(v_worst, absi(vh - world._terrain_height(x - 1, z)))
	print("DBG 谷地盘 max=%d min=%d >60m %d 列 最大单步 %d 格（n=%d）"
		% [v_max, v_min, v_over, v_worst, v_n])
	_check(v_max <= 50,
		"⓪ 谷地盘最高 %d 格（≤50：起飞视野内没有山，人工起飞不装山）" % v_max)
	_check(v_over == 0, "⓪ 谷地盘 >60m 的列 %d（=0）" % v_over)
	_check(v_min >= 10, "⓪ 谷地盘最低 %d 格（≥10：没被河床切到地下）" % v_min)
	_check(v_worst <= World.MAX_SLOPE + World.SLOPE_SLACK,
		"⓪ 谷地盘无空气墙：最大单步 %d 格 ≤ 限坡 %d+%d"
			% [v_worst, World.MAX_SLOPE, World.SLOPE_SLACK])

	# ── ② 高度分布统计（环带：谷地外的真实世界） ──
	var h_min := 9999
	var h_max := -1
	var sum := 0.0
	var n := 0
	var above_rock := 0     # 裸岩线以上（山体）
	var above_snow := 0     # 雪线以上
	var in_river := 0       # 河心
	var river_wet := 0      # 河心且低于海面（有水）
	var heights := {}
	for ring in range(RING_DIRS):
		var a := TAU * float(ring) / float(RING_DIRS)
		for d in range(RING_IN, RING_OUT, RING_STEP):
			var x := CX + int(round(cos(a) * d))
			var z := CZ + int(round(sin(a) * d))
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
	print("DBG 环带 %d..%dm 高度 min=%d max=%d mean=%.1f n=%d" % [RING_IN, RING_OUT, h_min, h_max, mean, n])
	print("DBG 裸岩线以上 %d 列 (%.2f%%) / 雪线以上 %d 列 (%.2f%%)"
		% [above_rock, 100.0 * above_rock / n, above_snow, 100.0 * above_snow / n])
	print("DBG 河心 %d 列 (%.2f%%) / 其中有水 %d 列"
		% [in_river, 100.0 * in_river / n, river_wet])

	_check(h_max > World.ROCK_LINE + 30,
		"② 出现高山：环带最高 %d 格（%.1f m），远超裸岩线 %d——限高没把世界推平"
			% [h_max, h_max * 0.5, World.ROCK_LINE])
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
	for ring in range(RING_DIRS):
		var a := TAU * float(ring) / float(RING_DIRS)
		for d in range(RING_IN, RING_OUT, RING_STEP):
			var x := CX + int(round(cos(a) * d))
			var z := CZ + int(round(sin(a) * d))
			var h := world._terrain_height(x, z)
			if h < 60:
				p_low += 1
			elif h <= 160:
				p_mid += 1
			else:
				p_high += 1
	print("DBG 分层 <60: %d / 60..160: %d / >160: %d" % [p_low, p_mid, p_high])
	_check(p_low > n / 10,
		"③ 平原丘陵仍是主体：%.1f%%（>10%%，世界不只剩山）" % (100.0 * p_low / n))
	_check(p_high < n / 20,
		"③ 雪脊不过量：%.2f%%（<5%%，世界不至于到处是雪山）" % (100.0 * p_high / n))

	# ── ③b 可飞性：全域无「空气墙」（D-055 陡壁回归闸）──
	# 这条是踩过坑才加的：分层地形初版在保护区边界出162 格（81m）断崖，
	# 玩家在机场外遇到空气墙，飞机巡航撞上直接解体，且探针
	# cockpit_instruments_shot 连挂 4 项。噪声参数怎么调都难保证全域无陡壁，
	# 故把「单步落差≤ MAX_SLOPE」钉成断言——地形再改、参数再动，陡壁回归
	# 会立刻在这里 FAIL，而不是等到玩家撞山。
	# D-072：原采样区（原点 ±256 方区）现已落进机场谷地（谷地由 ⓪ 专闸，
	# 更严），此处保留原扫描作为「谷地+内渐变带」闸；渐变带外沿山脊噪声
	# 的残留陡步（D-055 已知 <1%，rided crest 复现不了完美斜坡）由下一段
	# 「限高不加剧」兜底。
	var worst := 0
	var worst_at := Vector2i.ZERO
	for x in range(-256, 256, 2):
		for z in range(-256, 256, 2):
			var d := absi(world._terrain_height(x, z)
				- world._terrain_height(x - 1, z))
			if d > worst:
				worst = d
				worst_at = Vector2i(x, z)
	_check(worst <= World.MAX_SLOPE + World.SLOPE_SLACK,
		"③b 谷地方区无空气墙：最大单步 %d 格（%.1f m）≤ 限坡 %d+%d 格，@%s"
			% [worst, worst * 0.5, World.MAX_SLOPE, World.SLOPE_SLACK,
			str(worst_at)])

	# D-072 渐变带（260..1000 m）：限高后的单步不得比未限高更陡。
	# 「未限高」= 把谷地中心临时挪到世界外（_near_field_weight 恒 1）再量
	# 同一批点——不在探针里复刻四层噪声公式（抄一份必然与 world.gd 漂移），
	# 直接关掉乘子最同源。两遍都过 _limit_slope，松弛完全同源可比。
	# 注意：RegionAtlas.profile() 返回的字典是只读的（make_read_only），
	# 必须先整体换一份可写副本，量完把原字典装回去（成员本身可写）。
	var ramp_limited := _ramp_worst_step(world)
	var saved_profile: Dictionary = world._profile
	world._profile = world._profile.duplicate()
	world._profile["airport_center"] = [100000, 100000]
	world._valley_loaded = false
	var ramp_raw := _ramp_worst_step(world)
	world._profile = saved_profile
	world._valley_loaded = false
	print("DBG 渐变带 260..1000m：限高后最大单步 %d 格 / 未限高 %d 格" % [ramp_limited, ramp_raw])
	_check(ramp_limited <= ramp_raw,
		"③b 渐变带限高不加剧陡壁：限高后 %d ≤ 未限高 %d（乘子只压平、不制造新空气墙）"
			% [ramp_limited, ramp_raw])

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
	for ring in range(RING_DIRS):
		var a := TAU * float(ring) / float(RING_DIRS)
		for d in range(RING_IN, RING_OUT, RING_STEP):
			var x := CX + int(round(cos(a) * d))
			var z := CZ + int(round(sin(a) * d))
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
