extends RefCounted
## 探针「读前确保加载」工具（① 工具层欠账）：把「先 ensure 再读」的套路收口成
## 可复用静态方法，避免各探针各抄一遍、并防止「未加载区块 get_block 一律返 AIR」
## 造成的假绿断言。
##
## 硬约束（D-010 工具层纪律）：
## - ensure 只保证调用当帧该 chunk 已加载；跨 await 循环读同一区域须玩家常驻，
##   或在循环内重复 ensure（世界按玩家位置流式装卸区块）。
## - 对 ==AIR 的断言务必用 read_block_loaded / is_loaded 先确保加载，
##   否则未加载区块会返回 AIR 导致假绿。
## - 不引入 class_name（D-010：禁新增 class_name），范式同 tests/probe_pad.gd。
const PROBE_WORLD := preload("res://tests/probe_world.gd")

## 确保 [min_cell, max_cell] 世界空间格覆盖的区块已加载（同步加载，调用后即可读）。
static func ensure_region(world: World, min_cell: Vector3i, max_cell: Vector3i) -> void:
	world.ensure_chunks_in_region(min_cell, max_cell)

## 先确保 cell 所在区块已加载，再返回 get_block 的真值（不会因未加载而假返 AIR）。
static func read_block_loaded(world: World, cell: Vector3i) -> int:
	world.ensure_chunks_in_region(cell, cell)
	return world.get_block(cell)

## 读前守卫：确保 cell 所在区块已加载并返回 true，供 ==AIR 类断言前调用，
## 避免未加载区块导致的假绿。返回值恒为 true（加载动作已同步完成）。
static func is_loaded(world: World, cell: Vector3i) -> bool:
	world.ensure_chunks_in_region(cell, cell)
	return true
