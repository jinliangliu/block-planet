class_name TrackLoader
extends Node3D
## 把 TrackLayout（纯数据）变成看得见、跑得起来的赛道竞技场。
##
## 竞技场刻意是一块平整大地台 + 一条贴地路面带，不做体素铺路、也不放碰撞体：
## 车辆运动是纯运动学的（CarPhysics），不依赖物理引擎，因此不需要碰撞；路面之外
## 就是草地（另一种地形参数），开出去只会变慢——对儿童比撞墙友好，也让物理
## 完全确定性、探针可断言。边界由 RaceCar 做软性收束（不会掉出世界）。

const ROAD_LIFT := 0.04        # 路面比地台抬高一点，避免共面闪烁
const PLATE_MARGIN := 90.0     # 地台比赛道外接圆再大这么多米
const ARCH_HEIGHT := 5.5
const ARCH_POST := 0.6

## 检查点拱门配色（循环取用；起跑线单独用红白）。
const ARCH_COLORS := [
	Color(0.95, 0.80, 0.20), Color(0.30, 0.75, 0.95),
	Color(0.55, 0.90, 0.45), Color(0.95, 0.55, 0.25),
	Color(0.80, 0.55, 0.95), Color(0.35, 0.90, 0.80),
]

var layout: TrackLayout = null
var arena_radius := 0.0


## 按布局构建整座竞技场（重复调用会先清空旧内容）。
func build(p_layout: TrackLayout) -> void:
	layout = p_layout
	for child in get_children():
		child.queue_free()
	var extent := 0.0
	for p in layout.points:
		extent = maxf(extent, Vector2(p.x, p.z).length())
	arena_radius = extent + PLATE_MARGIN
	_build_plate()
	_build_road()
	_build_start_line()
	_build_arches()


func _build_plate() -> void:
	var plane := PlaneMesh.new()
	var s := arena_radius * 2.2
	plane.size = Vector2(s, s)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.position = Vector3(0.0, -0.06, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.34, 0.48, 0.24)
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.name = "GroundPlate"
	add_child(mi)


## 路面：中心线两侧各偏移 half_width 得到左右边线，逐环缝合成带状网格，
## 顶点色取该段地形色——孩子一眼能看出「这段是柏油、那段是湿地」。
func _build_road() -> void:
	var n := layout.size()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for i in n + 1:
		var k := layout.wrap_index(i)
		var p := layout.point(k)
		var nrm := layout.normal(k)
		var l := p + nrm * layout.half_width
		var r := p - nrm * layout.half_width
		verts.append(Vector3(l.x, l.y + ROAD_LIFT, l.z))
		verts.append(Vector3(r.x, r.y + ROAD_LIFT, r.z))
		norms.append(Vector3.UP)
		norms.append(Vector3.UP)
		var c := _terrain_color(layout.terrain_at_index(k))
		cols.append(c)
		cols.append(c)
		var v := float(i) * TrackLayout.SPACING / 4.0
		uvs.append(Vector2(0.0, v))
		uvs.append(Vector2(1.0, v))
	for i in n:
		var a := i * 2
		# 绕序必须是「从上往下看为顺时针」——Godot 4 以顺时针为正面。写成逆时针
		# 时三角形全被判成背面：虽然 cull_mode 关着照样画得出来，但着色器会对背面
		# 翻转法线，UP 法线变 DOWN 法线 → 太阳光归零、只剩天穹「地面半球」的暗绿
		# 环境光，整条路渲染成暗橄榄色（本工程实际踩过，截图才看得出，无头探针查不到）。
		idx.append_array([a, a + 3, a + 1, a, a + 2, a + 3])

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	# 注意：Godot 4 是 vertex_color_use_as_albedo；Godot 3 的 vertex_colors_enabled
	# 赋值会被静默忽略（本工程踩过）。
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.name = "Road"
	add_child(mi)


## 起跑线：横跨路面的一条白色带（在 index 0 处）。
func _build_start_line() -> void:
	var p := layout.point(0)
	var nrm := layout.normal(0)
	var w := layout.half_width
	var a := p + nrm * w
	var b := p - nrm * w
	var fwd := layout.direction(0)
	var half_depth := 0.6
	var verts := PackedVector3Array([
		Vector3(a.x - fwd.x * half_depth, a.y + ROAD_LIFT + 0.01, a.z - fwd.z * half_depth),
		Vector3(b.x - fwd.x * half_depth, b.y + ROAD_LIFT + 0.01, b.z - fwd.z * half_depth),
		Vector3(b.x + fwd.x * half_depth, b.y + ROAD_LIFT + 0.01, b.z + fwd.z * half_depth),
		Vector3(a.x + fwd.x * half_depth, a.y + ROAD_LIFT + 0.01, a.z + fwd.z * half_depth),
	])
	var mi := MeshInstance3D.new()
	mi.mesh = _quad_mesh(verts, Color(0.95, 0.95, 0.95))
	mi.name = "StartLine"
	add_child(mi)


## 检查点拱门：两侧立柱 + 顶梁。只是同一份门数据的可视化——
## 判定走 RaceSession 的门平面穿越，不依赖这些节点。
func _build_arches() -> void:
	var count := layout.gate_count()
	for g in count:
		var at := layout.gate_position(g)
		var dir := layout.direction(layout.gate_index(g))
		var root := Node3D.new()
		root.name = "Gate%d" % g
		root.position = at
		root.rotation.y = atan2(dir.x, dir.z)
		var col: Color = Color(0.92, 0.20, 0.18) if g == 0 \
			else ARCH_COLORS[(g - 1) % ARCH_COLORS.size()]
		_add_box(root, Vector3(-(layout.half_width + ARCH_POST), ARCH_HEIGHT * 0.5, 0.0),
			Vector3(ARCH_POST, ARCH_HEIGHT, ARCH_POST), col)
		_add_box(root, Vector3(layout.half_width + ARCH_POST, ARCH_HEIGHT * 0.5, 0.0),
			Vector3(ARCH_POST, ARCH_HEIGHT, ARCH_POST), col)
		_add_box(root, Vector3(0.0, ARCH_HEIGHT, 0.0),
			Vector3((layout.half_width + ARCH_POST) * 2.0, ARCH_POST, ARCH_POST), col)
		if g == 0:
			# 终点拱门再加一道白条，和起跑线连成一体，冲线看得清。
			_add_box(root, Vector3(0.0, ARCH_HEIGHT * 0.55, 0.0),
				Vector3((layout.half_width + ARCH_POST) * 2.0, 0.8, 0.25),
				Color(0.96, 0.96, 0.96))
		add_child(root)


func _add_box(parent: Node3D, at: Vector3, size: Vector3, color: Color) -> void:
	var box := BoxMesh.new()
	box.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = box
	mi.position = at
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.85
	mi.material_override = mat
	parent.add_child(mi)


func _quad_mesh(verts: PackedVector3Array, color: Color) -> ArrayMesh:
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	for _i in verts.size():
		norms.append(Vector3.UP)
		cols.append(color)
	var idx := PackedInt32Array([0, 1, 2, 0, 2, 3])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _terrain_color(id: String) -> Color:
	# terrain.json 里的色值是「看着像柏油/砾石」的显示色（sRGB），而 Godot 4 的材质
	# 颜色一律按线性空间解释（编辑器取色器会自己转）。直接塞进顶点色等于把 0.72 的
	# 中灰度当线性值用，再叠上阳光就被 filmic 压成近白色（本工程实际踩过）。这里显式
	# 做 sRGB→线性，路面才会呈现设计者挑的那个颜色。UI 侧仍用原始色值做色板，两边
	# 各自正确。
	var t := RaceSystem.terrain(id)
	var hex := String(t.get("color", "#666666"))
	return Color(hex).srgb_to_linear()
