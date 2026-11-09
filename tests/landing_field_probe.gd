extends Node

## 无头验证「机场 / 降落场永远建在水面以上」（D-081）。
##
## 为什么需要这个探针：`AirportBuilder._probe_base_y()` 用
## `get_surface_height() - 1` 取基准高度，而那是**裸地形高度**，不含其后的
## 水/冰填充层。大洋区域的地形基准本就低于海平面（大西洋 base_height=19、
## 振幅 9，SEA_LEVEL=22），于是：
##   · 大西洋 (8,8) 半径 10 内 441 列全部低于海平面、最高只有 21
##     → 跑道面铺在 21，被海面 22 淹掉一层，玩家看到「跑道在水底」；
##   · 北冰洋最高只有 19 而冰面封在 22 → 跑道被埋进冰层底下 3 格。
## 这类 bug 完全由**区域地形数据**触发，改别的代码不会暴露，只有切换大洲才看得见，
## 所以必须用探针把不变式钉住：**道面 ≥ SEA_LEVEL + 2，且道面与其上一格都不是水**。
##
## 探针自己造 World 并直接调 AirportBuilder，不加载 main.tscn（快，且不碰存档）。

var _pass := 0
var _fail := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: " + msg)
		_pass += 1
	else:
		print("FAIL: " + msg)
		_fail += 1


func _ready() -> void:
	_run()


func _run() -> void:
	# 大陆区走 build()（带机库的完整机场），大洋/极地区走 build_field()。
	var cases := [
		{"region": RegionAtlas.ASIA, "airport": true, "center": Vector3i(114, 0, -40)},
		{"region": RegionAtlas.ATLANTIC, "airport": false, "center": Vector3i(8, 0, 8)},
		{"region": RegionAtlas.ARCTIC, "airport": false, "center": Vector3i(8, 0, 8)},
		{"region": RegionAtlas.INDIAN, "airport": false, "center": Vector3i(8, 0, 8)},
		{"region": RegionAtlas.PACIFIC, "airport": false, "center": Vector3i(8, 0, 8)},
	]
	for case: Dictionary in cases:
		var region := int(case["region"])
		var center: Vector3i = case["center"]
		var with_hangar := bool(case["airport"])
		var world := World.new()
		world.set_region(region)
		add_child(world)
		await get_tree().process_frame
		var builder := AirportBuilder.new()
		var spawn := Vector3(0, 0, 0)
		if with_hangar:
			spawn = builder.build(world, center)
		else:
			spawn = builder.build_field(world, center)
		var surface := Vector3i(center.x, builder.base_y, center.z)
		var on_runway := world.get_block(surface)
		var above := world.get_block(surface + Vector3i(0, 1, 0))
		var above2 := world.get_block(surface + Vector3i(0, 2, 0))
		var tag := "region %d（base_y=%d）" % [region, builder.base_y]
		# ① 道面必须高于海平面 2 格：这是「跑道上不会有水」的根条件。
		_check(builder.base_y >= World.SEA_LEVEL + 2,
			"%s 道面高于海平面（%d >= %d）" % [tag, builder.base_y, World.SEA_LEVEL + 2])
		# ② 道面本身铺上了方块（不是空气/水）。
		_check(on_runway != BlockTypes.Block.AIR and on_runway != BlockTypes.Block.WATER,
			"%s 道面已铺装（block=%d）" % [tag, on_runway])
		# ③ 道面正上方两格是空气——跑道上不能有水/冰。
		_check(above == BlockTypes.Block.AIR and above2 == BlockTypes.Block.AIR,
			"%s 道面上方两格是空气（%d / %d）" % [tag, above, above2])
		# ④ 出生点在跑道面上，且高于水面（否则玩家一开局就在水里）。
		_check(spawn.y > float(World.SEA_LEVEL),
			"%s 出生点在水面以上（y=%.1f）" % [tag, spawn.y])
		world.queue_free()
		await get_tree().process_frame

	print("LANDING_FIELD_TEST_DONE fails=%d" % _fail)
	if _fail == 0:
		print("LANDING_FIELD_TEST_OK")
	else:
		print("LANDING_FIELD_TEST_FAILED")
	get_tree().quit(0 if _fail == 0 else 1)
