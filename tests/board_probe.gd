extends Node

## 无头验证 F 键登机判定（D-032 玩家反馈）：机模放大后（MODEL_SCALE=3）机身
## 碰撞盒 6.6 × 4.8 × 15.6 m，右键放机固定落在身前 5 m 处——旧的「到重心原点
## ≤ 4 m」判定会出现「明明站在飞机旁边却提示附近没有飞行器」。新判定按玩家
## 到机身碰撞盒最近点 + BOARD_MARGIN 容差计算。覆盖：放机距离可登机、机身
## 侧旁可登机、翼尖/远处不可登机、已被驾驶与已解体的机体被排除。

var _pass := 0
var _fail := 0


func _check(cond, msg) -> void:
	if cond:
		print("PASS: " + msg)
		_pass += 1
	else:
		print("FAIL: " + msg)
		_fail += 1


func _ready() -> void:
	InputActions.register()

	# 最小玩家骨架：Player._ready 需要 $Camera3D/HeldItem、$SpringArm3D/Camera3D、
	# $PlayerModel 五个节点路径，逐一补齐后再入树，并停掉玩家物理。
	var player := Player.new()
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	player.add_child(cam)
	var held := HeldItem.new()
	held.name = "HeldItem"
	cam.add_child(held)
	var spring := SpringArm3D.new()
	spring.name = "SpringArm3D"
	player.add_child(spring)
	var chase_cam := Camera3D.new()
	chase_cam.name = "Camera3D"
	spring.add_child(chase_cam)
	var model := PlayerModel.new()
	model.name = "PlayerModel"
	player.add_child(model)
	add_child(player)
	player.set_physics_process(false)

	# 放一架飞机并停掉它的飞行动力学（无地形会自由落体，干扰位置断言）。
	var craft_origin := Vector3(50.0, 2.0, 50.0)
	var craft := Aircraft.spawn(self, craft_origin, 0.0)
	craft.set_physics_process(false)
	await get_tree().process_frame

	# ① 复现报告场景：放机后玩家距重心 5 m（放机距离，机头前）。旧判定 5 > 4
	#    直接报「附近没有飞行器」；新判定玩家已贴近机身碰撞盒 → 可登机。
	player.global_position = craft_origin + Vector3(0.0, 0.0, -5.0)
	_check(player.nearest_aircraft() == craft,
		"放机距离 5 m（机头前）可登机，_board_distance=%.2f" % player._board_distance(craft))

	# ② 站机身侧旁 4.0 m（碰撞盒半宽 3.3 m）→ 最近点 0.7 m，容差 1.6 m 内，可登机。
	player.global_position = craft_origin + Vector3(4.0, craft_origin.y, 0.0)
	_check(player.nearest_aircraft() == craft, "机身侧旁 4.0 m 可登机")

	# ③ 站在翼尖下方 6 m（机翼不参与碰撞）→ 最近点 2.7 m，超出容差。
	player.global_position = craft_origin + Vector3(6.0, craft_origin.y, 0.0)
	_check(player.nearest_aircraft() == null, "翼尖 6 m 不可登机（机翼不算机身）")

	# ④ 远处 20 m → 不可登机。
	player.global_position = craft_origin + Vector3(20.0, craft_origin.y, 0.0)
	_check(player.nearest_aircraft() == null, "远处 20 m 不可登机")

	# ⑤ 贴身但已被驾驶 → 排除。
	player.global_position = craft_origin + Vector3(4.0, craft_origin.y, 0.0)
	craft.piloted = true
	_check(player.nearest_aircraft() == null, "机体已被驾驶时排除")
	craft.piloted = false

	# ⑥ 贴身但已解体 → 排除。
	craft._wrecked = true
	_check(player.nearest_aircraft() == null, "机体已解体时排除")

	# ⑦ 与重心重合时距离为 0（判定基准自洽）。注意 place() 会抬升机体，
	#    重心实际在 craft.global_position 而非传入的落点。
	craft._wrecked = false
	player.global_position = craft.global_position
	_check(absf(player._board_distance(craft)) < 0.001,
		"玩家与重心重合时碰撞盒距离为 0")

	print("BOARD_DONE fails=%d" % _fail)
	if _fail > 0:
		print("BOARD_FAIL")
	else:
		print("BOARD_OK")
	get_tree().quit()
