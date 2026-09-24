class_name MiniMap
extends Control
## 右上角圆形小地图：以玩家为中心，定时采样周围顶面方块颜色。
## 圆心箭头指示观察方向，北（-z）朝上。

## 地图直径（像素）。
const SIZE := 132.0
## 采样半径（格），圆域直径约 22 格。
const MAP_RADIUS := 11
## 采样周期（秒）：低频采样避免每帧扫描地形。
const SAMPLE_INTERVAL := 0.6

var _player: Player
var _world: World
var _timer := SAMPLE_INTERVAL
## 相对玩家格坐标 → 顶面颜色。键为 Vector2i(dx, dz)。
var _samples: Dictionary = {}


func setup(player: Player, world: World) -> void:
	_player = player
	_world = world
	custom_minimum_size = Vector2(SIZE, SIZE)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_snap()
	queue_redraw()


func _process(delta: float) -> void:
	if _player == null or _world == null:
		return
	_timer += delta
	if _timer < SAMPLE_INTERVAL:
		return
	_timer = 0.0
	_snap()
	queue_redraw()


## 采样以玩家所在格为中心、半径 MAP_RADIUS 的圆形区域顶面方块颜色。
func _snap() -> void:
	_samples.clear()
	if _player == null or _world == null:
		return
	var center := _player.global_position
	var cx := int(floor(center.x))
	var cz := int(floor(center.z))
	var limit := MAP_RADIUS * MAP_RADIUS + MAP_RADIUS
	for dx in range(-MAP_RADIUS, MAP_RADIUS + 1):
		for dz in range(-MAP_RADIUS, MAP_RADIUS + 1):
			if dx * dx + dz * dz > limit:
				continue
			var id := _top_block(cx + dx, cz + dz)
			if id == BlockTypes.Block.AIR:
				continue
			var tiles: Vector3i = BlockTypes.TILES.get(id, Vector3i(0, 0, 0))
			_samples[Vector2i(dx, dz)] = TextureAtlas.tile_color(tiles.x)


## 从估算地表上方往下扫，返回该列第一个非空方块（未加载返回 AIR）。
func _top_block(wx: int, wz: int) -> int:
	if _world == null:
		return BlockTypes.Block.AIR
	var y := _world.get_surface_height(wx, wz) + 14
	while y >= 0:
		var id := _world.get_block(Vector3i(wx, y, wz))
		if id != BlockTypes.Block.AIR:
			return id
		y -= 1
	return BlockTypes.Block.AIR


func _draw() -> void:
	var center := size / 2.0
	var radius := SIZE / 2.0 - 4.0
	draw_circle(center, radius, Color(0.08, 0.10, 0.14, 0.85))

	var cells := MAP_RADIUS * 2 + 1
	var step := radius * 2.0 / float(cells)
	var edge := radius - step
	for pos: Vector2i in _samples:
		var offset := Vector2(pos.x, pos.y) * step
		if offset.length() > edge:
			continue
		var color: Color = _samples[pos]
		draw_rect(
			Rect2(center + offset - Vector2.ONE * step * 0.5, Vector2.ONE * step),
			color
		)

	# 观察方向箭头：取相机水平前向，玩家转向时箭头同步旋转。
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var forward := -cam.global_transform.basis.z
		forward.y = 0.0
		if forward.length_squared() > 0.0001:
			forward = forward.normalized()
			var dir := Vector2(forward.x, forward.z)
			var tip := center + dir * radius * 0.55
			var left := center + dir.rotated(2.55) * radius * 0.20
			var right := center + dir.rotated(-2.55) * radius * 0.20
			draw_colored_polygon(
				PackedVector2Array([tip, left, right]),
				Color(1.0, 0.85, 0.25)
			)

	draw_arc(center, radius, 0.0, TAU, 48, Color(1.0, 1.0, 1.0, 0.55), 2.0, true)
