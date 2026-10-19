extends Node
## D-055 新地形方块（ROCK / GRAVEL）属性探针：不纳入常规回归，手动跑。
## 运行：Godot --headless --path . res://tests/terrain_block_probe.tscn

var _failed := 0
var _passed := 0


func _check(ok: bool, msg: String) -> void:
	if ok:
		_passed += 1
		print("PASS %s" % msg)
	else:
		_failed += 1
		print("FAIL %s" % msg)


func _ready() -> void:
	_run()
	print("PROBE terrain_block %d PASS / %d FAIL" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _run() -> void:
	var rock := BlockTypes.Block.ROCK
	var gravel := BlockTypes.Block.GRAVEL

	# ① ID 与命名：紧跟导航灯之后，不与既有 ID 冲突。
	_check(rock == 35 and gravel == 36,
		"① ROCK=35 / GRAVEL=36（不撞既有 ID）")
	_check(BlockTypes.NAMES.has(rock) and BlockTypes.NAMES.has(gravel),
		"① 两者都有中文名（%s / %s）" % [BlockTypes.display_name(rock), BlockTypes.display_name(gravel)])

	# ② 实体与透明：都是实心不透明（否则不进碰撞、地表会漏光）。
	_check(BlockTypes.is_solid(rock) and BlockTypes.is_solid(gravel),
		"② 两者都是实心")
	_check(not BlockTypes.is_transparent(rock) and not BlockTypes.is_transparent(gravel),
		"② 两者都不透明")

	# ③ 纹理：瓦片号互异且都落在图集 8×8 范围内。
	var tr: Vector3i = BlockTypes.TILES[rock]
	var tg: Vector3i = BlockTypes.TILES[gravel]
	var max_tile := TextureAtlas.ATLAS_TILES * TextureAtlas.ATLAS_TILES - 1
	_check(tr.x == tr.y and tr.x == tr.z, "③ ROCK 六面同瓦片（%d）" % tr.x)
	_check(tg.x == tg.y and tg.x == tg.z, "③ GRAVEL 六面同瓦片（%d）" % tg.x)
	_check(tr.x != tg.x, "③ 两个瓦片号不同（%d vs %d）" % [tr.x, tg.x])
	_check(tr.x <= max_tile and tg.x <= max_tile,
		"③ 瓦片号都在图集范围内（上限 %d）" % max_tile)
	# 三面瓦片号不得与既有方块撞车。
	var used := {}
	for id in BlockTypes.TILES:
		if BlockTypes.is_nav_light(id):
			continue  # 导航灯是占位瓦片，允许撞
		var t: Vector3i = BlockTypes.TILES[id]
		used[t.x] = int(id)
	_check(used.get(tr.x, rock) == rock and used.get(tg.x, gravel) == gravel,
		"③ 两个瓦片号未被其它方块占用")

	# ④ 硬度/工具：未进 HARDNESS 表的方块玩家挖不动（player.gd:1063）。
	_check(BlockTypes.HARDNESS.has(rock) and BlockTypes.HARDNESS.has(gravel),
		"④ 两者都在 HARDNESS 表（否则成为挖不动的幽灵方块）")
	_check(BlockTypes.EFFECTIVE_TOOL.get(rock, "") == "pickaxe",
		"④ ROCK 要镐")
	_check(BlockTypes.EFFECTIVE_TOOL.get(gravel, "") == "shovel",
		"④ GRAVEL 要铲")
	_check(BlockTypes.required_tier(rock) == 0 and BlockTypes.required_tier(gravel) == 0,
		"④ 两者都无工具等级门槛（徒手慢挖也行）")

	# ⑤ 掉落：不把自身当物品（不进 HOTBAR_BLOCKS，否则得到放不回去的鬼物品）。
	_check(BlockTypes.drop_for(rock, "pickaxe") == BlockTypes.Block.COBBLESTONE,
		"⑤ 镐采 ROCK → 圆石")
	_check(BlockTypes.drop_for(rock, "") == BlockTypes.Block.AIR,
		"⑤ 徒手采 ROCK → 无掉落")
	_check(BlockTypes.drop_for(gravel, "shovel") == BlockTypes.Block.SAND,
		"⑤ 铲采 GRAVEL → 沙子")
	_check(BlockTypes.drop_for(gravel, "") == BlockTypes.Block.AIR,
		"⑤ 徒手采 GRAVEL → 无掉落")

	# ⑥ 不进快捷栏：地形专用，不该凭空获得。
	_check(not BlockTypes.HOTBAR_BLOCKS.has(rock)
		and not BlockTypes.HOTBAR_BLOCKS.has(gravel),
		"⑥ 两者都不进 HOTBAR_BLOCKS（纯地形方块）")

	# ⑦ 纹理真的画出来了：两个瓦片都存在非洋红像素（洋红 = 未定义的哨兵色）。
	var img := TextureAtlas.build_atlas_texture().get_image()
	var magenta := Color(1.0, 0.0, 1.0)
	var tile_px := TextureAtlas.TILE_SIZE
	var tiles: Array[int] = [tr.x, tg.x]   # typed：无类型 Array 迭代出 Variant，无法推断 ox/oy
	for t in tiles:
		var ox: int = (t % TextureAtlas.ATLAS_TILES) * tile_px
		var oy: int = (t / TextureAtlas.ATLAS_TILES) * tile_px
		var non_magenta := 0
		var distinct := {}
		for y in range(tile_px):
			for x in range(tile_px):
				var c: Color = img.get_pixel(ox + x, oy + y)
				if not c.is_equal_approx(magenta):
					non_magenta += 1
				distinct[c.to_html()] = true
		_check(non_magenta == tile_px * tile_px,
			"⑦ 瓦片 %d 全像素非哨兵色（%d/%d）" % [t, non_magenta, tile_px * tile_px])
		_check(distinct.size() > 8,
			"⑦ 瓦片 %d 颜色层次 %d 种（>8，说明有噪点/节理而非纯色）" % [t, distinct.size()])
