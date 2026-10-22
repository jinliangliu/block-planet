extends RefCounted
## 探针起飞场地准备（takeoff_coach_shot / coach_cockpit_shot /
## cockpit_instruments_shot 共用）：在玩家出生点周围铺一块强制平整平台，
## 并返回一个**安全落位点**给 Aircraft.spawn。
##
## 只做场地，不含断言、不持有状态——三份取证探针原本各抄一份，同一个坑踩了三遍：
##
## 1. **落位必须横向偏开玩家**。机体碰撞盒 6.6×4.8×15.6 m、底面在原点下
##    `AircraftModel.GROUND_CLEARANCE = 2.55 m`，在玩家所站点位落位会把玩家
##    整只包进碰撞盒。两者重叠时物理首帧就做分离——实测把机体顶起 1.60 m
##    （39.60→41.20）并给出 **7.07 m/s** 分离速度，越过解体阈值 Δv 7.0，
##    于是「登机前一刻机毁」。连锁后果：`_refresh_flight_panel` 见
##    `is_wrecked()` 直接 return → 教练卡片整卡隐藏（UI 断言全假）；
##    残骸 4 s 自消散后 `_craft.*` 全变成对已释放实例发消息 → SCRIPT ERROR
##    杀掉协程 → `SaveGuard.restore()` 与 `quit()` 都跑不到 → 进程挂到超时
##    rc=124 **且进度计数器写盘污染存档**（D-010）。main.gd 的试飞放机同样
##    放在玩家身前 10 m，同一道理。
## 2. **平台高度必须实心面扫描**。`World.get_surface_height` 只是噪声地形基准，
##    看不见机场整平垫高与自建平台；出生点正好在机场里，噪声基准比实际停机坪
##    低 2 格，按它当平台高度会连垫层一起削掉。
## 3. **脚下无条件铺一层**。原写法「只在 AIR 时铺」会留下比平台高的列（机场
##    垫层），那些列的顶面浮在平台之上、直接顶穿机体碰撞盒。
## 4. **落位传平台顶面**，不要再加机体离地高度：`Aircraft.place()` 内部已经
##    加 `GROUND_CLEARANCE + 0.05`，重复抬升等于让飞机从 2.6 m 高空落下。

## 平台半径（格）：机体碰撞盒 15.6 m 长，±16 足够整机落在平台内。
const PAD_RADIUS := 16
## 平台往上清空的格数（树/建筑/机场设施）。
const CLEAR_HEIGHT := 12
## 落位横向偏移（格）：> 碰撞盒半宽 3.3 m，把玩家彻底让开。
const SIDE_OFFSET := 8.5


## 场地准备（会改方块并重建区块网格，调用方随后需 `await` 物理帧）。
## 返回 {"spawn": Vector3, "ground_y": int}：spawn 是**平台顶面**上的机体落位点，
## 直接传给 `Aircraft.spawn(parent, spawn, heading)`。
static func prepare(world: World, player: Player) -> Dictionary:
	var base := player.global_position
	var ox := int(base.x)
	var oz := int(base.z)
	# 实心面扫描（对齐 main.gd:_on_test_fly_requested）：自头顶 20 格往下找
	# 首个实块，取它所在的 y（该方块顶面 = y + 1）。
	var ground_y := int(base.y) - 1
	var scan_top := int(base.y) + 20
	for i in range(40):
		var probe_y := scan_top - i
		if BlockTypes.is_solid(world.get_block(Vector3i(ox, probe_y, oz))):
			ground_y = probe_y
			break
	var min_cell := Vector3i(ox - PAD_RADIUS, 0, oz - PAD_RADIUS)
	var max_cell := Vector3i(ox + PAD_RADIUS, 0, oz + PAD_RADIUS)
	world.ensure_chunks_in_region(min_cell, max_cell)
	for x in range(ox - PAD_RADIUS, ox + PAD_RADIUS + 1):
		for z in range(oz - PAD_RADIUS, oz + PAD_RADIUS + 1):
			world.set_block_deferred(Vector3i(x, ground_y, z),
				BlockTypes.Block.COBBLESTONE)
			for h in range(1, CLEAR_HEIGHT + 1):
				world.set_block_deferred(Vector3i(x, ground_y + h, z),
					BlockTypes.Block.AIR)
	world.rebuild_chunks_in_region(min_cell, max_cell)
	return {
		"spawn": Vector3(float(ox) + SIDE_OFFSET, float(ground_y + 1), float(oz) + 0.5),
		"ground_y": ground_y,
	}
