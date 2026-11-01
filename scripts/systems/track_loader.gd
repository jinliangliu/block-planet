class_name TrackLoader
extends Node3D
## 把 TrackLayout（纯数据）变成看得见、跑得起来的赛道竞技场。
##
## 竞技场刻意是一块平整大地台 + 一条贴地路面带，不做体素铺路、也不放碰撞体：
## 车辆运动是纯运动学的（CarPhysics），不依赖物理引擎，因此不需要碰撞；路面之外
## 就是草地（另一种地形参数），开出去只会变慢——对儿童比撞墙友好，也让物理
## 完全确定性、探针可断言。边界由 RaceCar 做软性收束（不会掉出世界）。
##
## 主题（TrackLayout.theme）在这里真正生效：地台底色 + 两侧的低模装饰都按主题换。
## 没有这两样，6 条赛道在画面上是同一条「绿板 + 灰带」，孩子看不出沙漠和城市的区别。
## 装饰一律走 MultiMeshInstance3D：一个 (形状, 颜色) 组 = 一个 draw call，单条赛道
## ≤ 10 组——中低端 Android 上几百个 MeshInstance3D 是跑不动的。
##
## 路肩（红白交替）是「可读性」的兜底：地台按主题上色之后，城市/森林这类主题的地台
## 亮度与该段路面的亮度只差 0.03~0.06（Rec.601），光靠色盘救不回来——forest/mixed
## 的路面亮度本身就横跨 0.284~0.624，任何单一地台色都至少贴近其中一种。红白高频
## 交替不依赖明度差，是「路的左右边界在哪」唯一可靠的视觉锚点。

const ROAD_LIFT := 0.04        # 路面比地台抬高一点，避免共面闪烁
const PLATE_MARGIN := 90.0     # 地台比赛道外接圆再大这么多米
const ARCH_HEIGHT := 5.5
const ARCH_POST := 0.6

## ── 路肩（kerb）────────────────────────────────────────────
const KERB_WIDTH := 0.9        # 路肩带宽度（m），铺在路面外侧 half_width → +0.9
## 一块红/白路肩的圈程长度（m）。**必须整除 TrackLayout.SPACING（4 m）**：块边界
## 落在采样环上才有整齐的节奏。取 6 时块长在 4/8 m 之间乱跳（一圈 1.5 环），
## 取 4 = 一块正好一个采样段，交替最规整。
const KERB_SEG_M := 4.0
const KERB_LIFT := 0.012       # 比路面再抬高一点：0.04 → 0.052，避免共面闪烁
const KERB_A := Color(0.86, 0.20, 0.20)   # 红
const KERB_B := Color(0.96, 0.96, 0.93)   # 白

## 检查点拱门配色（循环取用；起跑线单独用红白）。
const ARCH_COLORS := [
	Color(0.95, 0.80, 0.20), Color(0.30, 0.75, 0.95),
	Color(0.55, 0.90, 0.45), Color(0.95, 0.55, 0.25),
	Color(0.80, 0.55, 0.95), Color(0.35, 0.90, 0.80),
]

## 主题 → 地台底色。这组值直接写进 StandardMaterial3D.albedo_color（与原来的单色
## 草地同一色彩空间：albedo 按线性解释，不额外做 sRGB→线性，否则会被压暗两层）。
## city 用浅混凝土（0.58）而不是冷灰（0.30）：冷灰的亮度 0.319 与沥青 #4A4A4A 的
## 0.290 只差 0.03，全沥青赛道（harbor_chicane）的路面在画面上几乎融进地台里。
const PLATE_COLORS := {
	"desert": Color(0.62, 0.52, 0.32),    # 沙黄
	"forest": Color(0.26, 0.42, 0.20),    # 深绿
	"wetland": Color(0.30, 0.44, 0.30),   # 苔绿
	"mountain": Color(0.38, 0.40, 0.30),  # 岩灰绿
	"city": Color(0.58, 0.58, 0.56),      # 浅混凝土
	"mixed": Color(0.34, 0.48, 0.24),     # 原绿（也是未知主题的回落值）
}
const PLATE_DEFAULT := "mixed"

## ── 装饰 ────────────────────────────────────────────────────
## 每 DECOR_STRIDE 个采样点（4 m 一个点 → 24 m）取一个装饰位，左右各掷一次骰子。
const DECOR_STRIDE := 6
const DECOR_SIDE_CHANCE := 0.55
## 装饰中心到「可驾驶边缘外沿」（路面 + 路肩）的最小留白（m）。
const DECOR_CLEARANCE := 3.0
## 落账时的额外安全边距（m）。为什么不是 0：① 部件的局部偏移会把件中心再往路面
## 推最多 1 m（仙人掌的手臂、岩石的第二块、看台 4 m 长条），② 探针量的「横向距离」
## 是最近采样点法向的投影，比点到线段的真实距离略小。留 0.6 m 抵消这两笔。
const DECOR_SAFE_MARGIN := 3.6
## 留白之外再往外撒的随机距离（m）。
const DECOR_SPREAD := 11.0
const DECOR_MIN_SCALE := 0.8
const DECOR_SCALE_SPAN := 0.55
const DECOR_MAX_SCALE := DECOR_MIN_SCALE + DECOR_SCALE_SPAN
## 单赛道实例（= 装饰部件）硬上限。留出余量：外部约定是「< 400 件」，
## 这里卡 360，超了就不再放新的一件（不是截断已放的）。
const DECOR_MAX_INSTANCES := 360
## 装饰总高上限（m，含最大缩放）：太高会挡驾驶时的视距。
const DECOR_MAX_HEIGHT := 4.0

var layout: TrackLayout = null
var arena_radius := 0.0
## 装饰摆位的纯数据镜像：[{mesh: String, color: Color, xform: Transform3D}]，每次
## build 重建。给探针读的原因：无头模式跑的是 RendererDummy，而 MultiMesh 的实例
## 缓冲存在 RenderingServer 侧，dummy 后端不保存它——`get_instance_transform` 恒返回
## 单位矩阵（本工程实测，见 tests/track_decor_probe.gd 的注释）。所以摆位在这里
## 同时记一份，让「不压路面 / 高度 / 确定性」这些几何断言在无头下依然可测。
var decor_instances: Array = []

# 装饰用的三个单位图元：所有装饰都靠 Transform3D 的缩放变尺寸，
# 于是「同图元 + 同颜色」的部件天然落进同一个 MultiMesh 组。
var _box_mesh: BoxMesh = null
var _cyl_mesh: CylinderMesh = null
var _cone_mesh: CylinderMesh = null


## 按布局构建整座竞技场（重复调用会先清空旧内容）。
func build(p_layout: TrackLayout) -> void:
	layout = p_layout
	# queue_free 是延后释放：只调它的话，重复 build 之后立刻 get_child_count()
	# 还会数到上一轮的节点（探针里踩过）。先 remove_child 摘树，再 queue_free 释放。
	for child in get_children():
		remove_child(child)
		child.queue_free()
	var extent := 0.0
	for p in layout.points:
		extent = maxf(extent, Vector2(p.x, p.z).length())
	arena_radius = extent + PLATE_MARGIN
	_build_plate()
	_build_road()
	_build_kerbs()
	_build_start_line()
	_build_arches()
	_build_decor()


## 主题 → 地台底色（缺省回落 mixed）。探针直调它比对色盘。
func plate_color(theme: String) -> Color:
	if PLATE_COLORS.has(theme):
		var c: Color = PLATE_COLORS[theme]
		return c
	var fallback: Color = PLATE_COLORS[PLATE_DEFAULT]
	return fallback


func _build_plate() -> void:
	var plane := PlaneMesh.new()
	var s := arena_radius * 2.2
	plane.size = Vector2(s, s)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.position = Vector3(0.0, -0.06, 0.0)
	var mat := StandardMaterial3D.new()
	var theme_id := PLATE_DEFAULT if layout == null else layout.theme
	mat.albedo_color = plate_color(theme_id)
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


## 路肩：沿路两侧各铺一条红白交替的窄带（横向 half_width → half_width+KERB_WIDTH）。
##
## 地台按主题上色之后，城市（浅混凝土 0.58）以外的主题地台亮度与该段路面亮度只差
## 0.06~0.09，而 forest/mixed 的路面亮度横跨 0.284~0.624——靠地台色永远救不回来。
## 红白高频交替提供的是「结构上的边界」，不依赖明度差，所以它比调色盘可靠。
##
## 两侧合成**一个** ArrayMesh（顶点色），1 个 draw call，不是每块一个节点。
##
## 顶点不做环间共享（每段每带各 4 个顶点，共 8 个/段）：共享顶点会强制顶点色在
## 相邻环之间插值，红块与白块之间出现一条 4 m 长的过渡带，整条路肩糊成一片淡粉
## （本工程实测踩过，截图一看就是「粉带」而不是「红白块」）。每段独立顶点 = 每块
## 纯色 = 真正的红白交替。代价只是顶点数翻倍（2500 m 赛道 5000 个顶点，可忽略）。
##
## 绕序照抄路面：每带每段的顶点顺序取 [A 更靠 +normal, A 更靠 -normal,
## B 更靠 +normal, B 更靠 -normal]，索引 [0,3,1,0,2,3] 与路面同一模式，
## 才能保证正面朝上（否则法线被翻成 DOWN，太阳光归零，路肩渲染成暗带）。
func _build_kerbs() -> void:
	var n := layout.size()
	var hw := layout.half_width
	var y := ROAD_LIFT + KERB_LIFT
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for i in n:
		var k0 := layout.wrap_index(i)
		var k1 := layout.wrap_index(i + 1)
		var p0 := layout.point(k0)
		var p1 := layout.point(k1)
		var n0 := layout.normal(k0)
		var n1 := layout.normal(k1)
		# 块号按圈程算：每 KERB_SEG_M 换一次色，红白交替。
		var along := float(i) * TrackLayout.SPACING
		var col := kerb_color(int(along / KERB_SEG_M))
		# 左带：外沿（+normal 侧）在前。
		var base := verts.size()
		_kerb_quad(verts, norms, cols, p0, n0, p1, n1, hw + KERB_WIDTH, hw, y, col)
		idx.append_array([base, base + 3, base + 1, base, base + 2, base + 3])
		# 右带：内沿（-normal 侧）才是「更靠 +normal」的那个，所以顺序是 (hw, hw+W)。
		base = verts.size()
		_kerb_quad(verts, norms, cols, p0, n0, p1, n1, -hw, -(hw + KERB_WIDTH), y, col)
		idx.append_array([base, base + 3, base + 1, base, base + 2, base + 3])

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.name = "Kerbs"
	add_child(mi)


## 路肩某一块的顶点色（**已转成线性空间**）。block 偶数 = 红，奇数 = 白。
##
## 为什么顶点色要自己转、而地台不用：材质上的 albedo_color 由引擎按 sRGB→线性
## 自动换算，但 ArrayMesh 的顶点色是**直接当线性值**送进着色器的（路面那侧踩着
## 同一个坑，见 _terrain_color 的注释）。把设计用的 sRGB 值原样塞进顶点色，红
## (0.86, 0.20, 0.20) 会显示成 sRGB 约 (0.94, 0.48, 0.48)——整条路肩看着是
## 「白 + 粉」而不是「白 + 红」（本工程实测踩过，截图才看得出）。
func kerb_color(block: int) -> Color:
	var srgb: Color = KERB_A if block % 2 == 0 else KERB_B
	return srgb.srgb_to_linear()


## 往路肩网格里追加一段四边形：off_hi 是「更靠 +normal」的横向偏移（m），
## off_lo 是另一个。两个环 p0/p1 各两个顶点，纯色 col。
func _kerb_quad(verts: PackedVector3Array, norms: PackedVector3Array,
		cols: PackedColorArray, p0: Vector3, n0: Vector3, p1: Vector3, n1: Vector3,
		off_hi: float, off_lo: float, y: float, col: Color) -> void:
	var a_hi := p0 + n0 * off_hi
	var a_lo := p0 + n0 * off_lo
	var b_hi := p1 + n1 * off_hi
	var b_lo := p1 + n1 * off_lo
	verts.append(Vector3(a_hi.x, y, a_hi.z))
	verts.append(Vector3(a_lo.x, y, a_lo.z))
	verts.append(Vector3(b_hi.x, y, b_hi.z))
	verts.append(Vector3(b_lo.x, y, b_lo.z))
	for _s in 4:
		norms.append(Vector3.UP)
		cols.append(col)


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


## ── 主题装饰 ────────────────────────────────────────────────
## 沿中心线每 24 m 一个装饰位，左右各以 55% 概率摆一件；每件由 1~4 个图元部件拼成，
## 按 (图元, 颜色) 归组写进 MultiMesh。整条赛道 ≤ 10 组 → ≤ 10 个 draw call。
## 随机源钉死在 layout.seed 上：同一赛道每次 build 的摆位逐位相同。
func _build_decor() -> void:
	if layout == null or layout.size() < DECOR_STRIDE:
		return
	decor_instances = []
	_prepare_primitives()
	var setup := _decor_setup(layout.theme)
	var channels: Array = setup["channels"]
	var templates: Array = setup["templates"]
	if channels.is_empty() or templates.is_empty():
		return
	# 每通道一个 Transform3D 池（通道 = 一个 MultiMeshInstance3D）。
	var slots: Array = []
	slots.resize(channels.size())
	for ci in slots.size():
		slots[ci] = []

	var rng := RandomNumberGenerator.new()
	rng.seed = layout.seed * 31 + 7
	var alternate: bool = setup.get("alternate", false)
	var instances := 0
	var placed := 0
	for i in range(0, layout.size(), DECOR_STRIDE):
		for side in 2:
			if rng.randf() >= DECOR_SIDE_CHANCE:
				continue
			var sgn := -1.0 if side == 0 else 1.0
			# 留白从「路面边缘」起算要再加上路肩宽度：路肩是 0.9 m 宽的可见结构，
			# 装饰贴到路肩外沿上同样算压路。
			var lat := layout.half_width + KERB_WIDTH + DECOR_CLEARANCE \
				+ rng.randf() * DECOR_SPREAD
			var pos: Vector3 = layout.point(i) + layout.normal(i) * (lat * sgn)
			var sc := DECOR_MIN_SCALE + rng.randf() * DECOR_SCALE_SPAN
			var yaw := rng.randf() * TAU
			var pick := rng.randi_range(0, templates.size() - 1)
			if alternate:
				pick = placed % templates.size()
			var tmpl: Array = templates[pick]
			if instances + tmpl.size() > DECOR_MAX_INSTANCES:
				continue
			# 压路面保护：留白要按「部件最大水平偏移」放大后再整体查一遍全赛道——
			# ① 只判落点不够：部件自己的局部偏移会把件中心往路面推（本工程实测踩过：
			#    mountain_road 上落点合规、岩石第二块却贴到 6.91 m < 7.4 m）；
			# ② 只判本段也不够：弯道另一头可能贴得很近，装饰压到那段路上同样穿帮。
			# ③ 留白算在「路面 + 路肩」的外沿上（+ KERB_WIDTH），不是路面边缘。
			var need := layout.half_width + KERB_WIDTH + DECOR_SAFE_MARGIN \
				+ _template_reach(tmpl) * DECOR_MAX_SCALE
			if not _road_clear(pos, need):
				continue
			var rot := Basis(Vector3.UP, yaw)
			for part: Variant in tmpl:
				var pd: Dictionary = part
				var ci := int(pd["ch"])
				var dims: Vector3 = pd["size"]
				var off: Vector3 = pd["off"]
				var basis := rot * Basis.from_scale(dims * sc)
				var origin := pos + rot * (off * sc)
				var bucket: Array = slots[ci]
				var xf := Transform3D(basis, origin)
				bucket.append(xf)
				var ch_def: Dictionary = channels[ci]
				decor_instances.append({
					"mesh": String(ch_def["mesh"]),
					"color": ch_def["color"],
					"xform": xf,
				})
				instances += 1
			placed += 1

	for ci in channels.size():
		var xforms: Array = slots[ci]
		if xforms.is_empty():
			continue
		var ch: Dictionary = channels[ci]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = false
		mm.mesh = _mesh_of(String(ch["mesh"]))
		# instance_count 必须在 mesh 与 transform_format 之后赋值，否则按旧的
		# transform_format 分配缓冲，第二次 set_instance_transform 会越界。
		mm.instance_count = xforms.size()
		for k in xforms.size():
			mm.set_instance_transform(k, xforms[k])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Decor%d" % ci
		mmi.multimesh = mm
		mmi.material_override = _decor_material(ch)
		# 装饰一律不投影：Mobile 渲染器下阴影是第一笔要省的开销，
		# 几百个低模装饰投影换不来画面收益。
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)


## 装饰点是否离整条路面带都够远（对每一段中心线做点到线段距离）。
func _road_clear(pos: Vector3, need: float) -> bool:
	var n := layout.size()
	for j in n:
		var a := layout.point(j)
		var b := layout.point(j + 1)
		if _seg_dist_xz(pos, a, b) < need:
			return false
	return true


## 一件装饰的部件最远能比落点多伸出多少（水平，m，未乘缩放）。
func _template_reach(tmpl: Array) -> float:
	var reach := 0.0
	for part: Variant in tmpl:
		var off: Vector3 = (part as Dictionary)["off"]
		reach = maxf(reach, Vector2(off.x, off.z).length())
	return reach


func _seg_dist_xz(p: Vector3, a: Vector3, b: Vector3) -> float:
	var p2 := Vector2(p.x, p.z)
	var a2 := Vector2(a.x, a.z)
	var b2 := Vector2(b.x, b.z)
	var ab := b2 - a2
	var len2 := ab.length_squared()
	if len2 < 0.000001:
		return p2.distance_to(a2)
	var t := clampf((p2 - a2).dot(ab) / len2, 0.0, 1.0)
	return p2.distance_to(a2 + ab * t)


func _decor_material(ch: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var col: Color = ch["color"]
	mat.albedo_color = col
	mat.roughness = 1.0
	var energy := float(ch["emission"])
	if energy > 0.0:
		# 路灯灯头这类「自发光感」的件：高值 albedo + 一点 emission。
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = energy
	if col.a < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat


func _prepare_primitives() -> void:
	# 三个单位图元：1 m³ 盒 / 直径 1 高 1 的柱 / 直径 1 高 1 的锥。
	# 具体尺寸全靠 Transform3D 的缩放表达，这样「柱身 + 锥形树冠」也只需两个组。
	if _box_mesh == null:
		var box := BoxMesh.new()
		box.size = Vector3.ONE
		_box_mesh = box
	if _cyl_mesh == null:
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.5
		cyl.bottom_radius = 0.5
		cyl.height = 1.0
		cyl.radial_segments = 8
		_cyl_mesh = cyl
	if _cone_mesh == null:
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 0.5
		cone.height = 1.0
		cone.radial_segments = 8
		_cone_mesh = cone


func _mesh_of(mesh_key: String) -> Mesh:
	match mesh_key:
		"cyl":
			return _cyl_mesh
		"cone":
			return _cone_mesh
	return _box_mesh


## 一个图元部件：通道号（决定图元 + 颜色）+ 尺寸 + 相对装饰落点的偏移。
func _part(ch: int, dims: Vector3, off: Vector3) -> Dictionary:
	return {"ch": ch, "size": dims, "off": off}


## 一个装饰通道：图元种类 + 颜色 + 自发光强度（0 = 不发光）。
func _chan(mesh_key: String, color: Color, emission: float = 0.0) -> Dictionary:
	return {"mesh": mesh_key, "color": color, "emission": emission}


## 返回 {channels: Array[Dictionary], templates: Array[Array], alternate: bool}。
## channels 的条数就是这条赛道的 draw call 数，必须 ≤ 10。
func _decor_setup(theme: String) -> Dictionary:
	var kind := theme
	if not PLATE_COLORS.has(kind):
		kind = PLATE_DEFAULT
	match kind:
		"desert":
			return _setup_desert()
		"forest":
			return _setup_forest()
		"wetland":
			return _setup_wetland()
		"mountain":
			return _setup_mountain()
		"city":
			return _setup_city()
		_:
			return _setup_mixed()


## 沙漠：3 档绿的仙人掌 + 3 档褐的砂岩巨石。6 组。
func _setup_desert() -> Dictionary:
	var channels := [
		_chan("box", Color(0.20, 0.40, 0.19)),
		_chan("box", Color(0.26, 0.48, 0.22)),
		_chan("box", Color(0.15, 0.33, 0.17)),
		_chan("box", Color(0.46, 0.33, 0.21)),
		_chan("box", Color(0.56, 0.41, 0.26)),
		_chan("box", Color(0.38, 0.28, 0.19)),
	]
	var templates := [
		_cactus(0), _cactus(1), _cactus(2),
		_rock(3), _rock(4), _rock(5),
	]
	return {"channels": channels, "templates": templates}


## 森林：树干（柱）+ 3 档绿的树冠（锥）+ 2 档绿的灌木（盒）。6 组。
func _setup_forest() -> Dictionary:
	var channels := [
		_chan("cyl", Color(0.24, 0.16, 0.10)),
		_chan("cone", Color(0.12, 0.30, 0.12)),
		_chan("cone", Color(0.15, 0.36, 0.15)),
		_chan("cone", Color(0.19, 0.42, 0.18)),
		_chan("box", Color(0.32, 0.54, 0.26)),
		_chan("box", Color(0.38, 0.60, 0.30)),
	]
	var templates := [
		_tree(0, 1), _tree(0, 2), _tree(0, 3),
		_bush(4), _bush(5),
	]
	return {"channels": channels, "templates": templates}


## 湿地：2 档芦苇簇 + 一片半透明水洼。3 组。
func _setup_wetland() -> Dictionary:
	var channels := [
		_chan("box", Color(0.42, 0.52, 0.26)),
		_chan("box", Color(0.34, 0.46, 0.22)),
		_chan("box", Color(0.18, 0.42, 0.46, 0.72)),
	]
	var templates := [
		_reeds(0), _reeds(1), _puddle(2),
	]
	return {"channels": channels, "templates": templates}


## 山地：3 档灰的岩块 + 白色护栏桩。4 组。
func _setup_mountain() -> Dictionary:
	var channels := [
		_chan("box", Color(0.42, 0.42, 0.40)),
		_chan("box", Color(0.50, 0.50, 0.47)),
		_chan("box", Color(0.31, 0.31, 0.29)),
		_chan("box", Color(0.86, 0.86, 0.83)),
	]
	var templates := [
		_rock(0), _rock(1), _rock(2),
		[_part(3, Vector3(0.24, 1.0, 0.24), Vector3(0.0, 0.5, 0.0))],
	]
	return {"channels": channels, "templates": templates}


## 城市：路灯（暗柱 + 亮黄自发光灯头）+ 2 档灰的看台阶梯。4 组。
## 台阶刻意比地台暗两档：地台是浅混凝土（0.58），台阶若还用 0.58 灰就等于隐形
## （上一版对着冷灰地台踩过反向的同一个坑：同明度的灰压在灰地台上看不出来）。
func _setup_city() -> Dictionary:
	var channels := [
		_chan("box", Color(0.13, 0.14, 0.16)),
		_chan("box", Color(1.0, 0.86, 0.30), 1.2),
		_chan("box", Color(0.40, 0.40, 0.43)),
		_chan("box", Color(0.28, 0.28, 0.31)),
	]
	var templates := [
		_lamp(0, 1), _stand(2), _stand(3),
	]
	return {"channels": channels, "templates": templates}


## 混合：沙漠与森林各减配一半，交替摆放。8 组（必须 ≤ 10）。
func _setup_mixed() -> Dictionary:
	var channels := [
		_chan("box", Color(0.20, 0.40, 0.19)),
		_chan("box", Color(0.26, 0.48, 0.22)),
		_chan("box", Color(0.46, 0.33, 0.21)),
		_chan("box", Color(0.56, 0.41, 0.26)),
		_chan("cyl", Color(0.24, 0.16, 0.10)),
		_chan("cone", Color(0.13, 0.32, 0.13)),
		_chan("cone", Color(0.19, 0.42, 0.18)),
		_chan("box", Color(0.32, 0.54, 0.26)),
	]
	# 顺序刻意排成「沙 / 林」交替：alternate 模式下按落点序取模，两种主题轮流出现。
	var templates := [
		_cactus(0), _tree(4, 5), _rock(2), _bush(7), _cactus(1), _tree(4, 6),
	]
	return {"channels": channels, "templates": templates, "alternate": true}


## 仙人掌：竖干 + 左右各一条小臂。最高 2.4 m（×1.35 缩放 ≈ 3.2 m）。
func _cactus(ch: int) -> Array:
	return [
		_part(ch, Vector3(0.5, 2.4, 0.5), Vector3(0.0, 1.2, 0.0)),
		_part(ch, Vector3(0.9, 0.32, 0.32), Vector3(0.42, 1.55, 0.0)),
		_part(ch, Vector3(0.32, 0.85, 0.32), Vector3(0.74, 1.95, 0.0)),
		_part(ch, Vector3(0.7, 0.28, 0.28), Vector3(-0.34, 1.85, 0.0)),
	]


## 砂岩/岩块：两块错开的方块，比单个立方像石头。最高 1.15 m。
func _rock(ch: int) -> Array:
	return [
		_part(ch, Vector3(1.5, 1.2, 1.4), Vector3(0.0, 0.55, 0.0)),
		_part(ch, Vector3(0.9, 0.8, 1.0), Vector3(0.55, 0.40, 0.25)),
	]


## 树：圆柱干 + 圆锥冠。整棵最高 2.9 m（×1.35 ≈ 3.9 m，卡住 4 m 上限）。
func _tree(trunk_ch: int, crown_ch: int) -> Array:
	return [
		_part(trunk_ch, Vector3(0.4, 1.8, 0.4), Vector3(0.0, 0.9, 0.0)),
		_part(crown_ch, Vector3(2.4, 1.4, 2.4), Vector3(0.0, 2.2, 0.0)),
	]


## 灌木：两块错开的扁方块（单个方块看着就是个立方体，不像植物）。高 0.7 m。
func _bush(ch: int) -> Array:
	return [
		_part(ch, Vector3(1.0, 0.7, 1.0), Vector3(0.0, 0.35, 0.0)),
		_part(ch, Vector3(0.75, 0.52, 0.75), Vector3(0.28, 0.30, 0.18)),
	]


## 芦苇簇：三根错开的细高方块。最高 1.8 m。
func _reeds(ch: int) -> Array:
	return [
		_part(ch, Vector3(0.16, 1.8, 0.16), Vector3(0.0, 0.9, 0.0)),
		_part(ch, Vector3(0.16, 1.5, 0.16), Vector3(0.22, 0.75, 0.12)),
		_part(ch, Vector3(0.16, 1.65, 0.16), Vector3(-0.20, 0.82, -0.14)),
	]


## 水洼：极扁的大方块，贴地。y 中心 0.02 m（不埋、不挡）。
func _puddle(ch: int) -> Array:
	return [
		_part(ch, Vector3(2.6, 0.03, 2.6), Vector3(0.0, 0.02, 0.0)),
	]


## 路灯：暗色柱 + 顶端亮黄块。最高 2.66 m。
func _lamp(post_ch: int, head_ch: int) -> Array:
	return [
		_part(post_ch, Vector3(0.18, 2.6, 0.18), Vector3(0.0, 1.3, 0.0)),
		_part(head_ch, Vector3(0.8, 0.22, 0.8), Vector3(0.0, 2.64, 0.0)),
	]


## 看台阶梯：两级错开的横向长条。最高 1.1 m。
func _stand(ch: int) -> Array:
	return [
		_part(ch, Vector3(4.0, 0.6, 0.8), Vector3(0.0, 0.30, 0.0)),
		_part(ch, Vector3(4.0, 0.5, 0.8), Vector3(0.0, 0.85, -0.70)),
	]


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
