extends Node
## 无头交互探针：验证手持模型挂载、滚轮缩放、按住左键破坏方块的完整链路。
## 运行：Godot_console.exe --headless --path . res://tests/interaction_probe.tscn

const TIMEOUT_FRAMES := 900
const CLEAR_Z := [6, 7]
const TARGET_Z := 5

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
	var camera: Camera3D = player.get_node("Camera3D")

	# 1) 手持模型已挂载并生成空手手臂模型。
	var held: HeldItem = camera.get_node_or_null("HeldItem")
	_check(held != null, "Camera3D 下存在 HeldItem")
	if held:
		_check(held.has_model(), "空手时已生成手臂模型")

	# 2) 滚轮拉远 → 第三人称（角色形体可见）；滚轮拉近 → 第一人称恢复。
	_check(player.camera_distance == 0.0, "初始为第一人称（距离 0）")
	var model: PlayerModel = player.get_node("PlayerModel")
	var spring: SpringArm3D = player.get_node("SpringArm3D")
	player._unhandled_input(_wheel(MOUSE_BUTTON_WHEEL_DOWN))
	_check(absf(player.camera_distance - player.CAM_STEP) < 0.01, "滚轮下拉远相机距离")
	_check(spring.spring_length > 0.0 and spring.get_node("Camera3D").current, "拉远后第三人称相机生效")
	_check(model.visible and not held.visible, "第三人称下角色模型可见、手持模型隐藏")
	player._unhandled_input(_wheel(MOUSE_BUTTON_WHEEL_UP))
	player._unhandled_input(_wheel(MOUSE_BUTTON_WHEEL_UP))
	_check(player.camera_distance == 0.0 and camera.current, "滚轮上拉近回第一人称")
	_check(not model.visible and held.visible, "第一人称下模型隐藏、手持模型恢复")

	# 3) 按住左键破坏全链路：清空视线、在正前方 3 格放木头、模拟按住。
	var from := camera.global_position
	var forward := -camera.global_transform.basis.z
	var target := Vector3i((from + forward * 3.0).floor())
	target.y = int(floor(from.y))
	for z_offset: int in CLEAR_Z:
		var clear_cell := Vector3i(target.x, target.y, target.z + (TARGET_Z - z_offset))
		world.set_block(clear_cell, BlockTypes.Block.AIR)
	var wood_cell := Vector3i(target.x, target.y, target.z)
	world.set_block(wood_cell, BlockTypes.Block.WOOD)
	_check(world.get_block(wood_cell) == BlockTypes.Block.WOOD, "目标木头已放置在视线正前方")

	player.start_break_or_attack()
	_check(player.break_held, "左键按下进入破坏状态")
	await _wait_frames(10)
	_check(player.is_breaking(), "破坏中状态可查询")
	_check(player.break_ratio() > 0.0, "破坏进度大于 0")

	var broken := false
	for i in range(TIMEOUT_FRAMES):
		await get_tree().process_frame
		if world.get_block(wood_cell) == BlockTypes.Block.AIR:
			broken = true
			break
	_check(broken, "按住左键在超时前破坏木头")

	var fx_found := false
	for child in world.get_children():
		if child is CPUParticles3D:
			fx_found = true
			break
	_check(fx_found, "破坏完成生成碎屑粒子特效")

	var got_wood := false
	for s in range(Inventory.SLOT_COUNT):
		if player.inventory.get_item(s) == BlockTypes.Block.WOOD and player.inventory.get_count(s) > 0:
			got_wood = true
	_check(got_wood, "破坏后木头进入背包（生存掉落闭环）")
	player.break_held = false

	if _failed == 0:
		print("INTERACTION_TEST_OK")
		get_tree().quit(0)
	else:
		print("INTERACTION_TEST_FAILED count=%d" % _failed)
		get_tree().quit(1)


func _wheel(button: MouseButton) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = true
	return event


func _check(cond: bool, label: String) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)


func _wait_frames(count: int) -> void:
	for i in range(count):
		await get_tree().process_frame
