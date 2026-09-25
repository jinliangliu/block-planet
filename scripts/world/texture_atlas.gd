class_name TextureAtlas
## 在运行时生成像素风方块纹理图集，避免依赖外部美术资源。
## 每个瓦片为 16x16 像素，图集为 ATLAS_TILES x ATLAS_TILES。

const TILE_SIZE := 16
const ATLAS_TILES := 8


static func build_atlas_texture() -> ImageTexture:
	var width := TILE_SIZE * ATLAS_TILES
	var height := TILE_SIZE * ATLAS_TILES
	var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)

	for tile in range(ATLAS_TILES * ATLAS_TILES):
		_paint_tile(image, tile)

	return ImageTexture.create_from_image(image)


static func tile_color(tile: int) -> Color:
	return _tile_color(tile)


static func _paint_tile(image: Image, tile: int) -> void:
	var color := _tile_color(tile)
	var ox := (tile % ATLAS_TILES) * TILE_SIZE
	var oy := (tile / ATLAS_TILES) * TILE_SIZE

	# 玻璃（瓦片 9）：不透明浅蓝边框 + 全透明中心 + 两道斜向高光，
	# 配合图集材质的 alpha scissor 渲染成「有框的透明窗」。
	# 中心像素 RGB 保留玻璃色（alpha=0），万一在不支持透明的材质上
	# 兜底显示为浅蓝而不是黑色。
	if tile == 9:
		for y in range(TILE_SIZE):
			for x in range(TILE_SIZE):
				var edge := x == 0 or x == TILE_SIZE - 1 or y == 0 or y == TILE_SIZE - 1
				var c := color
				if edge:
					if _hash2(x, y) % 7 == 0:
						c = c.darkened(0.12)
					c.a = 1.0
				elif x - y == 4 or x - y == 5:
					c = Color(1.0, 1.0, 1.0, 0.9)
				else:
					c.a = 0.0
				image.set_pixel(ox + x, oy + y, c)
		return

	# 冰（瓦片 31）：冰蓝底 + 两道斜向白色裂纹高光，一眼读出「滑溜溜」。
	if tile == 31:
		for y in range(TILE_SIZE):
			for x in range(TILE_SIZE):
				var c := color
				var h := _hash2(x, y)
				if h % 9 == 0:
					c = c.darkened(0.10)
				if x - y == 3 or x - y == 4 or x + y == 22 or x + y == 23:
					c = Color(0.94, 0.98, 1.0)
				image.set_pixel(ox + x, oy + y, c)
		return

	for y in range(TILE_SIZE):
		for x in range(TILE_SIZE):
			var c := color
			var h := _hash2(x, y)
			if h % 7 == 0:
				c = c.darkened(0.12)
			elif h % 11 == 0:
				c = c.lightened(0.10)
			image.set_pixel(ox + x, oy + y, c)


static func _tile_color(tile: int) -> Color:
	match tile:
		0:
			return Color(0.36, 0.75, 0.32)
		1:
			return Color(0.49, 0.42, 0.24)
		2:
			return Color(0.55, 0.40, 0.26)
		3:
			return Color(0.50, 0.50, 0.53)
		4:
			return Color(0.84, 0.77, 0.51)
		5:
			return Color(0.40, 0.28, 0.16)
		6:
			return Color(0.62, 0.49, 0.29)
		7:
			return Color(0.22, 0.55, 0.25)
		8:
			return Color(0.20, 0.42, 0.82)
		9:
			return Color(0.68, 0.86, 0.93)
		10:
			return Color(0.44, 0.44, 0.47)
		11:
			return Color(0.94, 0.94, 0.94)
		12:
			return Color(0.62, 0.38, 0.72)
		13:
			return Color(0.58, 0.40, 0.20)
		14:
			return Color(0.40, 0.28, 0.16)
		15:
			return Color(0.78, 0.72, 0.28)
		16:
			return Color(0.62, 0.44, 0.30)
		17:
			return Color(0.72, 0.72, 0.75)
		18:
			return Color(0.32, 0.32, 0.35)
		19:
			return Color(0.22, 0.52, 0.30)
		20:
			return Color(0.30, 0.48, 0.20)
		21:
			return Color(0.44, 0.74, 0.34)
		22:
			return Color(0.26, 0.58, 0.26)
		23:
			return Color(0.95, 0.62, 0.78)
		24:
			return Color(0.94, 0.96, 0.99)
		25:
			return Color(0.70, 0.60, 0.50)
		26:
			return Color(0.76, 0.68, 0.36)
		27:
			# 床：红毯色（底面瓦片用木头 5）。
			return Color(0.78, 0.22, 0.24)
		28:
			# 胡萝卜作物：绿叶间的橙色萝卜头。
			return Color(0.86, 0.52, 0.18)
		29:
			# 土豆作物：土黄叶丛。
			return Color(0.74, 0.62, 0.30)
		30:
			# 白萝卜作物：绿叶与露白的萝卜身。
			return Color(0.88, 0.90, 0.80)
		31:
			# 冰：清透的冰蓝。
			return Color(0.62, 0.80, 0.94)
		_:
			return Color(1.0, 0.0, 1.0)


static func _hash2(x: int, y: int) -> int:
	var h := x * 374761393 + y * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	return (h ^ (h >> 16)) & 0x7FFFFFFF
