extends Node
## 卸载补面探针（性能优化回归，2026-10-17）：验证 _unload_chunk 入队的邻居
## 补重建真会被消费——排泄循环曾在 _load_priority 的 return 之后当了很久死
## 代码（初始提交起就位置正确，后来提取该函数时被甩丢），后果是走出加载范围
## 后世界边界永远缺面。本探针即该修复的可观测断言。
##
## 运行：Godot --headless --path . res://tests/rebuild_drain_probe.tscn

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

	# 传到 A 点等 5×5 窗口加载齐备（同步推进，不经 _process）。
	var c0 := world.world_to_chunk(Vector3(600.0, 48.0, 600.0))
	_teleport(player, Vector3(600.0, 48.0, 600.0))
	_settle(world, 90)

	# 再向西移一格：wanted 变为以 C0-(1,0) 为中心的 5×5。C0+(2,0)（E）落进
	# UNLOAD_PAD=1 环——已加载、不重载，正好隔离观测；C0+(1,0)（X）仍在 wanted 内。
	_teleport(player, Vector3(584.0, 48.0, 600.0))
	_settle(world, 90)
	var center := world.world_to_chunk(player.global_position)
	print("INFO center=%s chunks=%d pending=%d wanted=%d" % [
		str(center), world._chunks.size(),
		world._pending_load.size(), world._wanted.size()])

	# X 与 E：X 在 wanted 东缘，E 在 pad 环内（已加载且不会被自动重载）。
	var x_coord := c0 + Vector2i(1, 0)
	var e_coord := c0 + Vector2i(2, 0)
	_check(world._chunks.has(x_coord) and world._chunks.has(e_coord),
		"① 缘区块 X 与外侧邻居 E 均在加载窗口内")
	var x_chunk: Chunk = world._chunks[x_coord]
	# X 初次构建时 E 可能尚未加载（东 face 是对空气生成的埋藏面）；先带 E
	# 显式重建一次，让边界归位到「E 存在」的真实状态，再观测卸载效果。
	world._rebuild_chunk(x_coord)
	var faces_before := _faces(x_chunk)

	# 清掉传送远点产生的历史积压（机场/村庄区块卸载入队），只保留本测试的
	# 观测目标——E 的四个邻居。
	world._pending_rebuilds.clear()
	world._unload_chunk(e_coord)
	_check(not world._chunks.has(e_coord), "② E 已卸载")
	_check(world._pending_rebuilds.has(x_coord), "③ X 已入队补重建队列")

	# 推进若干帧：_update_chunks 末尾的排泄循环应消费掉队列（每帧至多 2 个，
	# 4 个入队项两帧内即空）。
	for _i in 20:
		world._update_chunks()
	_check(world._pending_rebuilds.is_empty(),
		"④ 补重建队列已排空（若此处失败即排泄循环仍是死代码）")

	var faces_after := _faces(x_chunk)
	_check(faces_after > faces_before,
		"⑤ X 东侧边界重新出面（%d → %d）" % [faces_before, faces_after])

	_finish()
	if _failed == 0:
		print("DRAIN_TEST_OK")
	get_tree().quit(1 if _failed > 0 else 0)


# ── 辅助 ─────────────────────────────────────────────────────────────────

func _faces(chunk: Chunk) -> int:
	if chunk._mesh_instance != null and chunk._mesh_instance.mesh != null:
		return chunk._mesh_instance.mesh.surface_get_array_len(0)
	return 0


func _settle(world: World, frames: int) -> void:
	for _i in frames:
		world._update_chunks()
		if world._pending_load.is_empty():
			break


func _teleport(player: Player, at: Vector3) -> void:
	player.global_position = at


func _check(ok: bool, label: String) -> void:
	if ok:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)


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
