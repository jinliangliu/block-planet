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
## 底盘与色块透明度：底盘半透明，可见后方 3D 画面。
const BASE_ALPHA := 0.42
const TILE_ALPHA := 0.78
## 指南针框体配色与四方位（北为 -z，与地图上方一致）。
const FRAME_BRASS := Color(0.80, 0.64, 0.34)
const FRAME_DARK := Color(0.30, 0.22, 0.12)
const FRAME_INNER := Color(0.24, 0.18, 0.10, 0.85)
const NORTH_COLOR := Color(0.90, 0.26, 0.24)
const CARDINALS := [
	{"label": "北", "dir": Vector2(0.0, -1.0), "north": true},
	{"label": "东", "dir": Vector2(1.0, 0.0), "north": false},
	{"label": "南", "dir": Vector2(0.0, 1.0), "north": false},
	{"label": "西", "dir": Vector2(-1.0, 0.0), "north": false},
]

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


## 外部（HUD）重新显示本图时调用：把采样计时器顶到阈值，下一帧立刻重采样。
## 用途：驾驶飞行器时 HUD 会隐藏小地图并停掉 _process（飞行中高速掠过地形，
## 每 0.6 s 扫一遍圆域纯属白工），下机恢复显示后必须立刻刷新，否则玩家看到
## 的是上机之前那一帧的旧图。
func request_resample() -> void:
	_timer = SAMPLE_INTERVAL


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
## 实际走 World.top_block_at：区块内直接取列顶（pristine）或列内扫描，
## 比逐格 get_block 快一个量级（每格一次 world_to_chunk + 字典查询）。
func _top_block(wx: int, wz: int) -> int:
	if _world == null:
		return BlockTypes.Block.AIR
	return _world.top_block_at(wx, wz)


func _draw() -> void:
	var center := size / 2.0
	var radius := SIZE / 2.0 - 13.0
	draw_circle(center, radius, Color(0.08, 0.10, 0.14, BASE_ALPHA))

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
			Color(color.r, color.g, color.b, TILE_ALPHA)
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

	_draw_compass_frame(center, radius)


## 指南针框体：黄铜环带（内含四方位字，北为红色）+ 内外细沿 + 十二刻度。
func _draw_compass_frame(center: Vector2, radius: float) -> void:
	var band_mid := radius + 6.0
	draw_arc(center, band_mid, 0.0, TAU, 64, FRAME_BRASS, 11.0, true)
	draw_arc(center, radius - 0.5, 0.0, TAU, 64, FRAME_INNER, 1.5, true)
	draw_arc(center, radius + 11.5, 0.0, TAU, 64, FRAME_DARK, 1.5, true)
	for i in range(16):
		if i % 4 == 0:
			continue
		var a := TAU * float(i) / 16.0
		var dir := Vector2(sin(a), -cos(a))
		draw_line(
			center + dir * (radius + 1.0),
			center + dir * (radius + 5.5),
			FRAME_DARK,
			1.5,
			true
		)
	var font := get_theme_default_font()
	for card: Dictionary in CARDINALS:
		var label: String = card["label"]
		var color: Color = NORTH_COLOR if card["north"] else FRAME_DARK
		var font_size := 15 if card["north"] else 13
		var extent := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		var dir: Vector2 = card["dir"]
		var at := center + dir * band_mid - extent * 0.5 + Vector2(0.0, extent.y * 0.3)
		draw_string(font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
