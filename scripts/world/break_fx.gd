class_name BreakFx
extends Node3D
## 方块破坏碎屑特效。
## 作为节点挂载（main.tscn）时监听 block_broken，在方块中心生成爆裂粒子；
## 另提供静态方法供挥动命中时生成少量碎屑（Player 每次挥动调用）。

const BLOCK_COLORS := {
	BlockTypes.Block.GRASS: Color(0.40, 0.62, 0.30),
	BlockTypes.Block.DIRT: Color(0.52, 0.37, 0.25),
	BlockTypes.Block.STONE: Color(0.55, 0.55, 0.55),
	BlockTypes.Block.SAND: Color(0.85, 0.78, 0.55),
	BlockTypes.Block.WOOD: Color(0.45, 0.33, 0.20),
	BlockTypes.Block.LEAVES: Color(0.25, 0.48, 0.22),
	BlockTypes.Block.GLASS: Color(0.75, 0.90, 0.95),
	BlockTypes.Block.COBBLESTONE: Color(0.42, 0.42, 0.42),
}
const BURST_COUNT := 26
const BURST_LIFETIME := 0.7
const HIT_COUNT := 5
const HIT_LIFETIME := 0.35
const LEAF_COUNT := 4
const LEAF_LIFETIME := 0.9
const CLEANUP_DELAY := 0.4
const PARTICLE_SIZE := 0.18


func _ready() -> void:
	Events.block_broken.connect(_on_block_broken)


func _on_block_broken(block_id: int, cell: Vector3i) -> void:
	var center := Vector3(cell) + Vector3(0.5, 0.5, 0.5)
	burst(get_parent(), center, color_for_block(block_id), BURST_COUNT, BURST_LIFETIME)


## 方块代表色（碎屑着色）。
static func color_for_block(id: int) -> Color:
	return BLOCK_COLORS.get(id, Color(0.6, 0.6, 0.6))


## 在指定父节点下生成一次性爆裂碎屑；寿命结束后自动释放。
static func burst(parent: Node, center: Vector3, color: Color, count: int, lifetime: float) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var particles := _make_particles(center, color, count, lifetime)
	particles.direction = Vector3.UP
	particles.spread = 80.0
	particles.initial_velocity_min = 3.6
	particles.initial_velocity_max = 7.2
	parent.add_child(particles)
	particles.emitting = true
	_recycle_later(parent, particles, lifetime)


## 挥动命中：在命中点沿面法线喷少量碎屑（破坏进行中的持续反馈）。
static func spawn_hit(parent: Node, point: Vector3, normal: Vector3, block_id: int) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var particles := _make_particles(point + normal * 0.16, color_for_block(block_id), HIT_COUNT, HIT_LIFETIME)
	particles.direction = normal
	particles.spread = 35.0
	particles.initial_velocity_min = 2.0
	particles.initial_velocity_max = 4.4
	parent.add_child(particles)
	particles.emitting = true
	_recycle_later(parent, particles, HIT_LIFETIME)


## 树叶落下：一小撮叶屑受重力下落、飘散消逝（树干砍光后整冠落叶时逐片调用）。
static func leaf_fall(parent: Node, center: Vector3) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var particles := _make_particles(center, color_for_block(BlockTypes.Block.LEAVES), LEAF_COUNT, LEAF_LIFETIME)
	particles.direction = Vector3.DOWN
	particles.spread = 40.0
	particles.initial_velocity_min = 1.0
	particles.initial_velocity_max = 2.8
	parent.add_child(particles)
	particles.emitting = true
	_recycle_later(parent, particles, LEAF_LIFETIME)


static func _make_particles(center: Vector3, color: Color, count: int, lifetime: float) -> CPUParticles3D:
	var particles := CPUParticles3D.new()
	particles.amount = count
	particles.lifetime = lifetime
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.gravity = Vector3(0.0, -28.0, 0.0)
	particles.scale_amount_min = 0.7
	particles.scale_amount_max = 1.3
	particles.position = center

	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * PARTICLE_SIZE
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	mesh.material = material
	particles.mesh = mesh
	return particles


static func _recycle_later(parent: Node, particles: CPUParticles3D, lifetime: float) -> void:
	var tree := parent.get_tree()
	if tree == null:
		return
	tree.create_timer(lifetime + CLEANUP_DELAY).timeout.connect(
		func() -> void:
			if is_instance_valid(particles):
				particles.queue_free()
	)
