class_name Tombstone
extends Node3D
## 玩家死亡墓碑：灰色石碑 + R.I.P 铭文 + 一撮尘土，短暂停留后自行消散。
## 纯装饰无碰撞，不参与物理与寻路。

const LIFETIME := 45.0


static func spawn(parent: Node, world_pos: Vector3, face_toward: Vector3 = Vector3.INF) -> void:
	var tomb := Tombstone.new()
	parent.add_child(tomb)
	tomb.global_position = world_pos
	if face_toward != Vector3.INF:
		# 铭文贴在 +Z 面：把 +Z 转向凭吊者（默认转向玩家死亡点）。
		var dir := face_toward - world_pos
		dir.y = 0.0
		if dir.length_squared() > 0.0001:
			tomb.rotation.y = atan2(dir.x, dir.z)


func _ready() -> void:
	# 碑身：上窄下宽的两段灰石，近似圆顶墓碑的剪影。
	var stone := Color(0.62, 0.62, 0.60)
	var stone_dark := Color(0.50, 0.50, 0.49)
	_add_slab(Vector3(0.46, 0.58, 0.13), stone, Vector3(0.0, 0.29, 0.0))
	_add_slab(Vector3(0.30, 0.20, 0.13), stone_dark, Vector3(0.0, 0.66, 0.0))

	# 铭文：碑面正中一行 R.I.P（儿童向：不加恐怖元素，配一朵小白花）。
	# Label3D 文字朝 +Z，故贴在 +Z 面上（spawn 已把 +Z 转向凭吊者）。
	var rip := Label3D.new()
	rip.text = "R.I.P"
	rip.font_size = 40
	rip.pixel_size = 0.004
	rip.modulate = Color(0.30, 0.28, 0.26)
	rip.outline_size = 4
	rip.outline_modulate = Color(0.82, 0.82, 0.80)
	rip.position = Vector3(0.0, 0.42, 0.075)
	rip.no_depth_test = false
	add_child(rip)

	var flower := Label3D.new()
	flower.text = "✿"
	flower.font_size = 26
	flower.pixel_size = 0.004
	flower.modulate = Color(0.95, 0.95, 0.98)
	flower.position = Vector3(0.0, 0.18, 0.075)
	add_child(flower)

	# 落碑尘土：一次性灰雾喷发。
	var dust := CPUParticles3D.new()
	dust.amount = 14
	dust.lifetime = 0.7
	dust.one_shot = true
	dust.emitting = true
	dust.direction = Vector3(0, 1, 0)
	dust.spread = 70.0
	dust.initial_velocity_min = 0.8
	dust.initial_velocity_max = 1.6
	dust.gravity = Vector3(0, -2.5, 0)
	dust.scale_amount_min = 0.05
	dust.scale_amount_max = 0.12
	dust.color = Color(0.72, 0.70, 0.66, 0.85)
	dust.position = Vector3(0.0, 0.1, 0.0)
	add_child(dust)

	# 停留一段时间后缩小消散（掉落物式生命周期，避免墓碑无限堆积）。
	# Node3D 没有整体透明度，用缩放到 0 表现「风化消失」。
	var tween := create_tween()
	tween.tween_interval(LIFETIME)
	tween.tween_property(self, "scale", Vector3.ONE * 0.01, 1.0).set_trans(Tween.TRANS_BACK) \
		.set_ease(Tween.EASE_IN)
	tween.tween_callback(queue_free)


func _add_slab(size: Vector3, color: Color, pos: Vector3) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.95
	mesh.material_override = mat
	mesh.position = pos
	add_child(mesh)
