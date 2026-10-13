class_name BuildVisualizer
extends Node3D
## 建造可视化（D-032 Phase 2）：根据 Blueprint 在编辑器场景里生成
## 重心(红) / 升力中心(蓝) / 推力线(箭头) 标记。纯表现，节点可独立实例化。
##
## 坐标：Blueprint 的 local_pos() 已是米制（含 0.5 m/格换算），故标记直接
## 摆在对应 Vector3 上即可，编辑器根节点 1 单位 = 1 米。

const MARKER_RADIUS := 0.25
const COLOR_COG := Color(1.0, 0.2, 0.2)
const COLOR_LIFT := Color(0.2, 0.4, 1.0)
const THRUST_LENGTH := 3.0


func _make_sphere(color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = MARKER_RADIUS
	sphere.height = MARKER_RADIUS * 2.0
	mi.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission = color
	mat.emission_energy = 0.4
	mi.material_override = mat
	return mi


## 重建所有标记（先清后建，便于每次编辑后刷新）。
func rebuild(bp: Blueprint) -> void:
	for child in get_children():
		child.queue_free()

	var cog := _make_sphere(COLOR_COG)
	cog.position = bp.center_of_gravity()
	cog.name = "cog"
	add_child(cog)

	var lift := _make_sphere(COLOR_LIFT)
	lift.position = bp.lift_center()
	lift.name = "lift"
	add_child(lift)

	var tv: Dictionary = bp.thrust_vector()
	if tv["magnitude"] > 0.0:
		var line := _make_thrust_line(tv["origin"], tv["dir"], THRUST_LENGTH)
		add_child(line)


func _make_thrust_line(origin: Vector3, dir: Vector3, length: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.12, 0.12, length)
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.8, 0.1)
	mat.emission = Color(1.0, 0.8, 0.1)
	mat.emission_energy = 0.4
	mi.material_override = mat
	# Box 沿 +Z 居中；把尾部移到 origin，头部指向 dir（机头 -Z）。
	mi.position = origin + dir * (length * 0.5)
	mi.look_at_from_position(mi.position, origin + dir * length, Vector3.UP)
	mi.name = "thrust"
	return mi
