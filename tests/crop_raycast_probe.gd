extends Node
## 农作物射线复现探针：验证「左键收割小麦」走真实射线链路（而非直接调 _finish_break）。
## 站上田面、以典型俯视角瞄准作物：修复前会被脚下耕地的物理面抢走命中，
## 且体素命中字典缺 collider 键导致 _update_breaking 每帧报错中断。
## 运行：Godot_console.exe --headless --path . res://tests/crop_raycast_probe.tscn

const TIMEOUT_FRAMES := 600
const CROPS := [
	BlockTypes.Block.WHEAT_CROP,
	BlockTypes.Block.CARROT_CROP,
	BlockTypes.Block.POTATO_CROP,
	BlockTypes.Block.RADISH_CROP,
]

var _failed := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame

	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")
	var camera: Camera3D = player.get_node("SpringArm3D/Camera3D")

	# ── 准备：找到村庄农田里的一株小麦 ──────────────────────
	var crop_cell := Vector3i.ZERO
	var farm_o := VillageBuilder.FARM_ORIGIN
	var base_y := _probe_base_y(world)
	for x in range(7):
		for z in range(7):
			var p := Vector3i(farm_o.x + x, base_y + 1, farm_o.z + z)
			if world.get_block(p) == BlockTypes.Block.WHEAT_CROP:
				crop_cell = p
				break
		if crop_cell != Vector3i.ZERO:
			break
	_check(crop_cell != Vector3i.ZERO, "农田中找到小麦作物")
	if crop_cell == Vector3i.ZERO:
		_finish()
		return

	# 发一把木镰刀并选中。
	player.inventory.add_item(ItemTypes.WOOD_SICKLE, 1)
	var sickle_slot := -1
	for s in range(Inventory.SLOT_COUNT):
		if player.inventory.get_item(s) == ItemTypes.WOOD_SICKLE:
			sickle_slot = s
			break
	_check(sickle_slot >= 0, "木镰刀已入背包")
	player.select_slot(sickle_slot)
	_check(ItemTypes.tool_type(player.get_selected_tool()) == "sickle", "当前手持木镰刀")

	# 站上田面（耕地顶面 = base_y+1），等物理稳定后再以真实相机位姿瞄准。
	player.global_position = Vector3(
		float(crop_cell.x) + 0.5 + 2.3, float(base_y) + 1.05, float(crop_cell.z) + 0.5)
	player.camera_distance = 0.0
	player.velocity = Vector3.ZERO
	for i in range(10):
		await get_tree().physics_frame
	var crop_center := Vector3(crop_cell) + Vector3(0.5, 0.5, 0.5)
	camera.look_at(crop_center)

	var hit := player._raycast_target()
	var hit_id := -1
	var hit_cell := Vector3i.ZERO
	if not hit.is_empty():
		hit_id = int(hit["id"])
		hit_cell = hit["cell"]
	print("  [俯视] 命中 id=%d cell=%s（瞄准作物 %s）" % [hit_id, hit_cell, crop_cell])
	_check(hit_id in CROPS, "俯视瞄准作物时射线命中作物（而非耕地/泥土）")

	# 真实链路收割：按住左键直至命中的作物消失（镰刀对小麦收成 ×4）。
	var wheat_before := player.inventory.count_item(ItemTypes.WHEAT)
	player.start_break_or_attack()
	var broken := false
	for i in range(TIMEOUT_FRAMES):
		await get_tree().process_frame
		if world.get_block(hit_cell) == BlockTypes.Block.AIR:
			broken = true
			break
	player.break_held = false
	_check(broken, "俯视姿态按住左键可收割作物")
	var gained := player.inventory.count_item(ItemTypes.WHEAT) - wheat_before
	_check(gained >= 4 and gained % 4 == 0,
		"镰刀收割小麦收成 ×4（实际 +%d，含连割）" % gained)

	_finish()


func _probe_base_y(world: World) -> int:
	## 与 VillageBuilder._probe_base_y / life_probe 同款复算。
	var top := 0
	for x in range(VillageBuilder.REGION_MIN.x, VillageBuilder.REGION_MAX.x + 1):
		for z in range(VillageBuilder.REGION_MIN.z, VillageBuilder.REGION_MAX.z + 1):
			top = maxi(top, world.get_surface_height(x, z) - 1)
	return top


func _finish() -> void:
	if _failed == 0:
		print("CROP_RAYCAST_OK")
		get_tree().quit(0)
	else:
		print("CROP_RAYCAST_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
