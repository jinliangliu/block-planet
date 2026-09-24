class_name HeldItem
extends Node3D
## 第一人称手持模型：空手显示手臂，选中方块显示图集贴图小方块，
## 选中工具显示"手柄 + 锤头"组合（木/石按 tier 着色）。
## 每帧轮询玩家选中物品，变化时重建模型；swing() 播放一次挥动动画。

const BLOCK_SIZE := 0.26
const ARM_COLOR := Color(0.87, 0.66, 0.51)
const HANDLE_COLOR := Color(0.47, 0.33, 0.19)
const TIER_COLORS: Array[Color] = [Color(0.62, 0.49, 0.29), Color(0.55, 0.55, 0.58)]

var _player: Player
var _root: Node3D
var _last_item := -1
var _swing_tween: Tween
var _block_material: StandardMaterial3D


func _ready() -> void:
	_root = Node3D.new()
	add_child(_root)

	_block_material = StandardMaterial3D.new()
	_block_material.albedo_texture = TextureAtlas.build_atlas_texture()
	_block_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST


func setup(player: Player) -> void:
	_player = player


func _process(_delta: float) -> void:
	if _player == null:
		return
	var item := _player.get_selected_item()
	if item != _last_item:
		_last_item = item
		_rebuild(item)


## 播放一次挥动动画（破坏/攻击/放置时由 Player 调用）。
func swing() -> void:
	if _swing_tween and _swing_tween.is_valid():
		_swing_tween.kill()
	rotation = Vector3.ZERO
	_swing_tween = create_tween()
	_swing_tween.tween_property(self, "rotation:x", -0.9, 0.08)
	_swing_tween.tween_property(self, "rotation:x", 0.0, 0.14)


## 是否已生成模型（供测试断言）。
func has_model() -> bool:
	return _root != null and not _root.get_children().is_empty()


func _rebuild(item: int) -> void:
	for child in _root.get_children():
		_root.remove_child(child)
		child.queue_free()

	if item == BlockTypes.Block.AIR:
		_build_arm()
	elif ItemTypes.is_tool_item(item):
		_build_tool(item)
	elif ItemTypes.is_plain_item(item):
		_build_plain_item(item)
	else:
		_build_block(item)


func _build_arm() -> void:
	var mesh_instance := _make_box(Vector3(0.12, 0.12, 0.4), _flat_material(ARM_COLOR))
	mesh_instance.position = Vector3(0.27, -0.22, -0.38)
	mesh_instance.rotation_degrees = Vector3(-18.0, -12.0, 6.0)
	_root.add_child(mesh_instance)


func _build_block(item: int) -> void:
	var tiles: Vector3i = BlockTypes.TILES.get(item, Vector3i(0, 0, 0))
	var tile := tiles.z
	var cell := 1.0 / float(TextureAtlas.ATLAS_TILES)
	var inset := 0.5 / float(TextureAtlas.TILE_SIZE * TextureAtlas.ATLAS_TILES)
	_block_material.uv1_scale = Vector3(cell - inset * 2.0, cell - inset * 2.0, 1.0)
	_block_material.uv1_offset = Vector3(
		(tile % TextureAtlas.ATLAS_TILES) * cell + inset,
		(tile / TextureAtlas.ATLAS_TILES) * cell + inset,
		0.0
	)

	var mesh_instance := _make_box(Vector3.ONE * BLOCK_SIZE, _block_material)
	mesh_instance.position = Vector3(0.3, -0.26, -0.5)
	mesh_instance.rotation_degrees = Vector3(4.0, 28.0, 0.0)
	_root.add_child(mesh_instance)


## 肉/骨/线等普通物品：按物品表平涂颜色的小方块。
func _build_plain_item(item: int) -> void:
	var color: Color = ItemTypes.ITEM_COLORS.get(item, Color.WHITE)
	var mesh_instance := _make_box(Vector3.ONE * (BLOCK_SIZE * 0.6), _flat_material(color))
	mesh_instance.position = Vector3(0.3, -0.24, -0.5)
	mesh_instance.rotation_degrees = Vector3(6.0, 24.0, 0.0)
	_root.add_child(mesh_instance)


func _build_tool(item: int) -> void:
	var tier := clampi(ItemTypes.tool_tier(item), 0, TIER_COLORS.size() - 1)
	var rot := Vector3(12.0, 0.0, -18.0)

	var handle := _make_box(Vector3(0.055, 0.42, 0.055), _flat_material(HANDLE_COLOR))
	handle.position = Vector3(0.3, -0.2, -0.48)
	handle.rotation_degrees = rot
	_root.add_child(handle)

	var head := _make_box(Vector3(0.2, 0.1, 0.09), _flat_material(TIER_COLORS[tier]))
	head.position = Vector3(0.32, 0.02, -0.48)
	head.rotation_degrees = rot
	_root.add_child(head)


func _make_box(size: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.material_override = material
	return mesh_instance


func _flat_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	return material
