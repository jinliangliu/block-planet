class_name FallingTree
extends Node3D
## 树干被砍断后的倒塌演出：砍口以上的那截树干连同树冠绕砍口倒下，落地后自行消失。
##
## 这是纯视觉代理——方块的真正移除由 World.fell_trunk_above / decay_tree_leaves 完成，
## 落地后的木头由 World.place_fallen_logs 铺回地面。演出与数据分离是为了：
## 万一场景切换把演出节点干掉，世界里也不会留下悬空的木头或凭空消失的树冠。
##
## 为什么不做刚体：一棵树就是几十个方块，用物理体去推会让每次砍树都付一次物理
## 开销，而且落点不可控（可能把玩家砸进地里）。这里用绕砍口的定轴旋转 + 重力感的
## ease-in 曲线，视觉上就是「倒下」，落点则由传入的方向唯一决定。

const FALL_TIME := 0.72
const TRUNK_THICK := 0.72
const CANOPY_SIZE := Vector3(2.4, 1.7, 2.4)

var _axis := Vector3(1.0, 0.0, 0.0)
var _on_landed: Callable
var _landing_point := Vector3.ZERO
var _canopy_offset := 0.0


## 在 parent 下生成一棵倒下的树。base 为砍口方块中心，log_count 为树干节数，
## dir 为水平倒向（不必归一化，内部会取主轴）。on_landed 在落地瞬间回调。
static func spawn(parent: Node, base: Vector3, log_count: int, dir: Vector3,
		on_landed: Callable = Callable()) -> void:
	if parent == null or not parent.is_inside_tree() or log_count <= 0:
		return
	var tree := FallingTree.new()
	tree.position = base
	parent.add_child(tree)
	tree._setup(log_count, dir, on_landed)


func _setup(log_count: int, dir: Vector3, on_landed: Callable) -> void:
	_on_landed = on_landed
	# 倒向取主轴：斜向向量会让树倒在两个方块的缝里，落点不好看也不好放木头。
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length_squared() < 0.01:
		flat = Vector3(1.0, 0.0, 0.0)
	flat = flat.normalized()
	if absf(flat.x) >= absf(flat.z):
		flat = Vector3(signf(flat.x), 0.0, 0.0)
	else:
		flat = Vector3(0.0, 0.0, signf(flat.z))
	_axis = Vector3.UP.cross(flat).normalized()
	_landing_point = position + flat * (float(log_count) * 0.7 + 0.5)

	# 树干：一段长方体，底端正好落在砍口上（绕自身原点旋转即绕砍口倒下）。
	var trunk := _mesh(BoxMesh.new(), BreakFx.color_for_block(BlockTypes.Block.WOOD))
	var trunk_mesh := trunk.mesh as BoxMesh
	trunk_mesh.size = Vector3(TRUNK_THICK, float(log_count), TRUNK_THICK)
	trunk.position = Vector3(0.0, float(log_count) * 0.5, 0.0)
	add_child(trunk)

	# 树冠：压在树干顶端，随同一旋转一起倒下去。
	_canopy_offset = float(log_count) + CANOPY_SIZE.y * 0.45
	var canopy := _mesh(BoxMesh.new(), BreakFx.color_for_block(BlockTypes.Block.LEAVES))
	var canopy_mesh := canopy.mesh as BoxMesh
	canopy_mesh.size = CANOPY_SIZE
	canopy.position = Vector3(0.0, _canopy_offset, 0.0)
	add_child(canopy)

	var tween := create_tween()
	tween.tween_method(_set_fall, 0.0, 1.0, FALL_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(_landed)


## 0→1 对应树干从竖直转到平躺（绕 _axis 转 90°）。
func _set_fall(t: float) -> void:
	quaternion = Quaternion(_axis, t * PI * 0.5)


func _landed() -> void:
	# 落地扬起的两撮叶屑：树冠砸下来的那两下。
	for i in 2:
		var at := _landing_point + Vector3(0.0, 0.35, 0.0) \
			+ Vector3(float(i) - 0.5, 0.0, 0.0) * 0.6
		BreakFx.leaf_fall(get_parent(), at)
	if _on_landed.is_valid():
		_on_landed.call()
	queue_free()


func _mesh(mesh: Mesh, color: Color) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material = mat
	instance.mesh = mesh
	return instance
