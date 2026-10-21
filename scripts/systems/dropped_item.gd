extends Node3D
class_name DroppedItem
## 掉落到地上的物品，靠近玩家后自动拾取进入背包。
## 无物理体：从怪物位置生成后原地旋转，超时未拾取自动清除。

const LIFETIME := 300.0

var item_id: int
var count := 1
var _player: Player
var _age := 0.0


func setup(player: Player, id: int, amount: int) -> void:
	_player = player
	item_id = id
	count = amount


func _ready() -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	# D-062 P1：1 格 = 1 m，掉落物按真实米制（0.28 m 立方），不再 ×2。
	box.size = Vector3(0.28, 0.28, 0.28)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _color()
	mesh.mesh = box
	mesh.material_override = mat
	add_child(mesh)


func _process(delta: float) -> void:
	_age += delta
	if _age >= LIFETIME:
		queue_free()
		return

	rotate_y(delta * 2.0)
	if _player == null or not is_instance_valid(_player):
		return
	if global_position.distance_to(_player.global_position) < 2.4:
		if _player.inventory.add_item(item_id, count) == 0:
			queue_free()


func _color() -> Color:
	if ItemTypes.is_tool_item(item_id):
		return Color(0.95, 0.78, 0.25)
	if ItemTypes.is_plain_item(item_id):
		return ItemTypes.ITEM_COLORS.get(item_id, Color.WHITE)
	var tiles: Vector3i = BlockTypes.TILES.get(item_id, Vector3i(0, 0, 0))
	return TextureAtlas.tile_color(tiles.x)

