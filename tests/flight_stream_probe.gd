extends Node
## 飞行流式加载探针（D-035）：验证「登机后加载窗口沿机头方向偏置、按时间预算
## 推进、卸载带滞后」这三条机制，并量化 50 m/s 巡航时前方地形的缺口——
## 飞行抱怨「前方地形加载滞后」的可观测指标。
##
## 运行：Godot --headless --path . res://tests/flight_stream_probe.tscn

## 巡航速度（m/s）：接近满油门平飞的实测值。
const SPEED := 50.0
const DT := 1.0 / 60.0
const FRAMES := 600
## 机组方向：机头朝 +Z（Godot 机头为局部 −Z，与 flight_probe 的 RUNWAY_HEADING
## 同约定）。这里只关心 World 的窗口几何，故直接给定。
const DIR := Vector3(0.0, 0.0, 1.0)

var _failed := 0
## 存档隔离（D-010 铁律 3）：本探针会实例化主场景，退出前原样还原 user://
## 与 Progress 内存态——Progress._exit_tree 会 _save() 覆盖文件还原。
var _saved_progress := ""
var _saved_settings := ""
var _saved_counters: Dictionary = {}
var _saved_states: Dictionary = {}


func _ready() -> void:
	await _run()


func _run() -> void:
	_saved_progress = _read_user_text("user://progress.json")
	_saved_settings = _read_user_text("user://settings.json")
	_saved_counters = Progress.counters.duplicate()
	_saved_states = Progress.states.duplicate()

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	await get_tree().process_frame
	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()

	# ── ① 徒步：方形窗口（半径 World.LOAD_RADIUS，D-064 起为 4）─────────
	_teleport(player, Vector3(400.0, 48.0, 400.0))
	_settle(world, 400)
	var center := world.world_to_chunk(player.global_position)
	var walk_missing := 0
	for dx in range(-World.LOAD_RADIUS, World.LOAD_RADIUS + 1):
		for dz in range(-World.LOAD_RADIUS, World.LOAD_RADIUS + 1):
			if not world._chunks.has(center + Vector2i(dx, dz)):
				walk_missing += 1
	_check(walk_missing == 0,
		"① 徒步窗口 %d×%d 区块全部加载（缺 %d 块）"
			% [World.LOAD_RADIUS * 2 + 1, World.LOAD_RADIUS * 2 + 1, walk_missing])

	# ── ② 飞行：沿机头的偏置窗口（前 5 / 侧 2 / 后 1）─────────
	world.set_flight_stream(true)
	world._stream_dir = DIR
	_teleport(player, Vector3(1200.0, 48.0, 1200.0))
	_settle(world, 200)
	center = world.world_to_chunk(player.global_position)
	var front_missing := 0
	for u in range(0, 6):
		for v in range(-2, 3):
			if not world._chunks.has(center + _offset(u, v)):
				front_missing += 1
	_check(front_missing == 0,
		"② 飞行窗口前方 5 / 侧向 2 的全部区块已加载（缺 %d 块）" % front_missing)
	_check(world._chunks.has(center + _offset(-1, 0)),
		"② 飞行窗口保留机身后方 1 区块")
	_check(not world._chunks.has(center + _offset(-3, 0)),
		"② 机身后方 3 区块外不再保留（预算不浪费在看不见的地方）")
	_check(not world._chunks.has(center + _offset(0, 4)),
		"② 侧向 4 区块外不再保留")

	# ── ③ 加载优先级：脚下先落地，同距离档内前方优先 ────────────
	_teleport(player, Vector3(1600.0, 48.0, 1600.0))
	world._update_chunks()
	center = world.world_to_chunk(player.global_position)
	_check(world._chunks.has(center),
		"③ 首批即补机体所在区块（脚下先落地，前方偏置不得把脚下排到队尾）")
	var front_key := center + _offset(1, 0)
	var back_key := center + _offset(-1, 0)
	_check(world._load_priority(front_key, center) < world._load_priority(back_key, center),
		"③ 同距离档内机头前方优先于后方")
	_check(world._load_priority(center, center) < world._load_priority(front_key, center),
		"③ 机体所在区块优先级高于任何邻块")

	# ── ④ 巡航推进：前方窗口不得持续留缺 ──────────────────────
	_teleport(player, Vector3(2000.0, 48.0, 2000.0))
	_settle(world, 300)
	var miss_sum := 0.0
	var samples := 0
	var max_miss := 0
	for i in FRAMES:
		player.global_position += DIR * SPEED * DT
		world._update_chunks()
		if i > FRAMES / 2:
			var miss := _front_gap(world)
			miss_sum += float(miss)
			max_miss = maxi(max_miss, miss)
			samples += 1
	var avg := miss_sum / float(samples)
	_check(avg < 3.0,
		"④ 50 m/s 巡航：前方 3 区块窗口内平均缺 %.2f 块（峰值 %d）" % [avg, max_miss])

	# 对照组：同样的巡航，但用徒步方形窗口（半径 World.LOAD_RADIUS）——这正是
	# D-035 之前的行为。只作诊断输出，不作断言（数值随机器性能浮动）。
	world.set_flight_stream(false)
	_teleport(player, Vector3(2400.0, 48.0, 2400.0))
	_settle(world, 300)
	var walk_miss_sum := 0.0
	var walk_samples := 0
	for i in FRAMES / 2:
		player.global_position += DIR * SPEED * DT
		world._update_chunks()
		if i > FRAMES / 4:
			walk_miss_sum += float(_walk_gap(world))
			walk_samples += 1
	print("INFO 对照：徒步 %d×%d 窗口同样巡航，窗口内平均缺 %.2f 块（飞行窗口为 %.2f）"
		% [World.LOAD_RADIUS * 2 + 1, World.LOAD_RADIUS * 2 + 1,
			walk_miss_sum / float(walk_samples), avg])
	world.set_flight_stream(true)

	# ── ⑤ 下机回落：窗口退回徒步尺寸 ──────────────────────────
	world.set_flight_stream(false)
	_settle(world, 400)
	center = world.world_to_chunk(player.global_position)
	var walk_reach := World.LOAD_RADIUS + World.UNLOAD_PAD
	var far := 0
	for key in world._chunks:
		var off: Vector2i = key - center
		if absi(off.x) > walk_reach or absi(off.y) > walk_reach:
			far += 1
	var back_missing := 0
	for dx in range(-World.LOAD_RADIUS, World.LOAD_RADIUS + 1):
		for dz in range(-World.LOAD_RADIUS, World.LOAD_RADIUS + 1):
			if not world._chunks.has(center + Vector2i(dx, dz)):
				back_missing += 1
	_check(back_missing == 0,
		"⑤ 下机后徒步 %d×%d 窗口重新填满（缺 %d 块）"
			% [World.LOAD_RADIUS * 2 + 1, World.LOAD_RADIUS * 2 + 1, back_missing])
	_check(not world._chunks.has(center + _offset(walk_reach + 1, 0)),
		"⑤ 下机后不再保留徒步窗口外的区块（飞行专属扩展已收回）")
	_check(far == 0, "⑤ 下机后徒步窗口（含卸载滞后）外的区块已全部卸载（残留 %d 块）" % far)

	_finish()


# ── 辅助 ─────────────────────────────────────────────────────────────────

## 机头坐标系 (u 前 / v 右) → 区块偏移。DIR=(0,0,1) 时 u 沿 +Z、v 沿 −X。
func _offset(u: int, v: int) -> Vector2i:
	return Vector2i(roundi(-float(v) * DIR.z), roundi(float(u) * DIR.z))


## 反复推进流式加载直至队列清空（或达到帧数上限）。
func _settle(world: World, frames: int) -> void:
	for _i in frames:
		world._update_chunks()
		if world._pending_load.is_empty():
			break


## 前方窗口（u ∈ [0,3]、|v| ≤ 1，共 12 块）中尚未加载的区块数。
func _front_gap(world: World) -> int:
	var center := world.world_to_chunk(world._player.global_position)
	var miss := 0
	for u in range(0, 4):
		for v in range(-1, 2):
			if not world._chunks.has(center + _offset(u, v)):
				miss += 1
	return miss


## 徒步窗口（半径 World.LOAD_RADIUS 的方形）内尚未加载的区块数——对照组的同口径指标。
func _walk_gap(world: World) -> int:
	var center := world.world_to_chunk(world._player.global_position)
	var miss := 0
	for dx in range(-World.LOAD_RADIUS, World.LOAD_RADIUS + 1):
		for dz in range(-World.LOAD_RADIUS, World.LOAD_RADIUS + 1):
			if not world._chunks.has(center + Vector2i(dx, dz)):
				miss += 1
	return miss


func _teleport(player: Player, at: Vector3) -> void:
	player.global_position = at


func _check(ok: bool, label: String) -> void:
	if ok:
		print("PASS ", label)
	else:
		_failed += 1
		print("FAIL ", label)


func _read_user_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


func _write_user_text(path: String, text: String) -> void:
	if text == "":
		DirAccess.remove_absolute(path.replace("user://", ProjectSettings.globalize_path("user://") + "/"))
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()


func _finish() -> void:
	_write_user_text("user://progress.json", _saved_progress)
	_write_user_text("user://settings.json", _saved_settings)
	Progress.counters = _saved_counters
	Progress.states = _saved_states
	print("RESULT flight_stream_probe: %d FAIL" % _failed)
	get_tree().quit(1 if _failed > 0 else 0)
