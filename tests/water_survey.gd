extends Node
## 一次性水情勘察（非回归探针）：用地形高度场统计水体区域面积分布，
## 用于确定「大河 / 小池塘」的判据阈值。
## 运行：Godot_v4.6.3-stable_win64_console.exe --headless --path . res://tests/water_survey.tscn

const HALF := 160
const MAX_REGION := 4000

var _heights := {}
var _water := {}
var _visited := {}
var _regions: Array = []


func _ready() -> void:
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	await get_tree().process_frame
	await get_tree().process_frame

	var world: World = main_scene.get_node("World")
	_collect(world)
	_report(world)
	get_tree().quit(0)


func _collect(world: World) -> void:
	for x in range(-HALF, HALF + 1):
		for z in range(-HALF, HALF + 1):
			var h: int = world._terrain_height(x, z)
			_heights[Vector2i(x, z)] = h
			if h < World.SEA_LEVEL:
				_water[Vector2i(x, z)] = true


func _report(world: World) -> void:
	print("SEA_LEVEL=%d TOTAL_TILES=%d WATER_TILES=%d (%.1f%%)" % [
		World.SEA_LEVEL, _heights.size(), _water.size(), 100.0 * float(_water.size()) / float(_heights.size())
	])

	var sizes: Array[int] = []
	var buckets := {"1-8": 0, "9-39": 0, "40-149": 0, "150-599": 0, "600+": 0}
	var near_spawn := {}  # 出生点 48 格内的区域面积集合
	for key in _water:
		if _visited.has(key):
			continue
		var size := _flood(key)
		sizes.append(size)
		var label := _bucket_label(size)
		buckets[label] = int(buckets[label]) + 1
		var sum := Vector2i.ZERO
		var depth_max := 0
		for c: Vector2i in _region_cells:
			sum += c
			depth_max = maxi(depth_max, World.SEA_LEVEL - int(_heights[c]))
		var center := Vector2i(sum.x / size, sum.y / size)
		_regions.append({"size": size, "center": center, "depth_max": depth_max})
		# 该区域是否靠近出生点
		for c: Vector2i in _region_cells:
			if absi(c.x - 8) <= 48 and absi(c.y - 8) <= 48:
				near_spawn[size] = true
				break

	sizes.sort()
	print("REGION_COUNT=%d" % sizes.size())
	print("BUCKETS=" + str(buckets))
	var top := sizes.slice(maxi(0, sizes.size() - 8))
	print("LARGEST=%s" % str(top))
	print("NEAR_SPAWN_SIZES=" + str(near_spawn.keys()))

	# 各区域明细：面积、中心、距出生点距离（用于探针取样点选择）。
	var detail: Array[String] = []
	for entry: Dictionary in _regions:
		var size: int = entry["size"]
		if size < 40:
			continue
		var c: Vector2i = entry["center"]
		var d := maxi(absi(c.x - 8), absi(c.y - 8))
		detail.append("size=%d center=(%d,%d) spawn_delta=%d depth_max=%d" % [
			size, c.x, c.y, d, int(entry["depth_max"])
		])
	detail.sort()
	for line in detail:
		print("REGION " + line)

	# 出生点 64x64 内水深与水面积
	var shallow := 0
	var deep := 0
	for x in range(0, 65):
		for z in range(0, 65):
			var h: int = _heights[Vector2i(x, z)]
			if h < World.SEA_LEVEL:
				if World.SEA_LEVEL - h <= 2:
					shallow += 1
				else:
					deep += 1
	print("SPAWN_64_SHALLOW=%d SPAWN_64_DEEP=%d" % [shallow, deep])


var _region_cells: Array = []


func _flood(start: Vector2i) -> int:
	_region_cells = []
	if not _water.has(start):
		return 0
	var queue: Array[Vector2i] = [start]
	_visited[start] = true
	while not queue.is_empty() and _region_cells.size() < MAX_REGION:
		var cur: Vector2i = queue.pop_back()
		_region_cells.append(cur)
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nxt: Vector2i = cur + d
			if _water.has(nxt) and not _visited.has(nxt):
				_visited[nxt] = true
				queue.append(nxt)
	return _region_cells.size()


func _bucket_label(size: int) -> String:
	if size <= 8:
		return "1-8"
	if size <= 39:
		return "9-39"
	if size <= 149:
		return "40-149"
	if size <= 599:
		return "150-599"
	return "600+"
