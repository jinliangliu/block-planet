class_name PartRegistry
extends RefCounted
## MVP 零件库：七种零件的唯一定义（数据驱动，新增零件只改这里）。
##
## 默认套件的聚合目标与 D-031 旧标定逐项一致，保证重构后飞行动作不变：
##   Σ质量 = 240 kg · Σ翼面积 = 14 m² · Σ推力 = 1650 N ·
##   Σ寄生阻力 = 0.015 → cd0 = CD0_BASE(0.06) + 0.015 = 0.075
## 这几项目标值由 flight_probe 的聚合断言守护，改零件数值会被探针抓到。

## 便捷取用：按 id 查零件。
static func by_id(id: String) -> PartData:
	for part in all():
		if part.id == id:
			return part
	return null


## 全部零件定义。
static func all() -> Array[PartData]:
	var parts: Array[PartData] = []

	var fuselage := PartData.new()
	fuselage.id = "fuselage"
	fuselage.display = "机身"
	fuselage.category = PartData.Category.FUSELAGE
	fuselage.size = Vector3i(3, 3, 12)
	fuselage.mass = 119.0
	fuselage.cost = 0
	fuselage.durability = 120.0
	fuselage.parasite_drag = 0.008
	parts.append(fuselage)

	var wing := PartData.new()
	wing.id = "wing"
	wing.display = "机翼"
	wing.category = PartData.Category.WING
	wing.size = Vector3i(24, 1, 4)
	wing.mass = 30.0
	wing.cost = 5
	wing.durability = 40.0
	wing.is_lifting = true
	wing.lift_area = 12.0
	wing.ctrl_roll = 1.0
	parts.append(wing)

	var tail := PartData.new()
	tail.id = "tail"
	tail.display = "尾翼"
	tail.category = PartData.Category.TAIL
	tail.size = Vector3i(10, 1, 3)
	tail.mass = 8.0
	tail.cost = 3
	tail.durability = 30.0
	tail.is_lifting = true
	tail.lift_area = 2.0
	tail.ctrl_pitch = 1.0
	tail.ctrl_yaw = 1.0
	parts.append(tail)

	var engine := PartData.new()
	engine.id = "engine"
	engine.display = "发动机"
	engine.category = PartData.Category.ENGINE
	engine.size = Vector3i(3, 3, 3)
	engine.mass = 45.0
	engine.cost = 12
	engine.durability = 80.0
	engine.thrust = 1650.0
	engine.fuel_burn = 0.02
	parts.append(engine)

	var propeller := PartData.new()
	propeller.id = "propeller"
	propeller.display = "螺旋桨"
	propeller.category = PartData.Category.PROPELLER
	propeller.size = Vector3i(3, 3, 1)
	propeller.mass = 6.0
	propeller.cost = 4
	propeller.durability = 15.0
	propeller.parasite_drag = 0.002
	parts.append(propeller)

	var gear := PartData.new()
	gear.id = "gear"
	gear.display = "起落架"
	gear.category = PartData.Category.GEAR
	gear.size = Vector3i(5, 2, 6)
	gear.mass = 12.0
	gear.cost = 3
	gear.durability = 25.0
	gear.parasite_drag = 0.005
	parts.append(gear)

	var tank := PartData.new()
	tank.id = "fuel_tank"
	tank.display = "油箱"
	tank.category = PartData.Category.FUEL_TANK
	tank.size = Vector3i(3, 3, 4)
	tank.mass = 20.0
	tank.cost = 4
	tank.durability = 30.0
	tank.fuel_capacity = 40.0
	parts.append(tank)

	# ── 进阶零件（默认套件之外，需花绿宝石解锁）──────────────
	var turbine := PartData.new()
	turbine.id = "turbine"
	turbine.display = "涡轮发动机"
	turbine.category = PartData.Category.ENGINE
	turbine.size = Vector3i(3, 3, 3)
	turbine.mass = 55.0
	turbine.cost = 30          # 绿宝石解锁价
	turbine.durability = 90.0
	# 比默认发动机(1650)略强，且满油门平飞平衡解 ≈52 m/s < 结构限速 55，
	# 避免「买最贵的零件反而必超速解体」（D-032 修复：原 2600 N 平衡解 63.5 m/s > VNE）。
	# 余量 3 m/s 是故意的：密度随高度衰减慢于阻力（推力 ∝ρ^0.7），且富波摆动会
	# 瞬时超速——贴线值（1850→54.1 / 1900→54.8）实测都会触限，1750 留足余量。
	turbine.thrust = 1750.0
	# 不弱于默认件(55)；若以后加入更脆的零件，整机 VNE 会取零件下限（Airframe.aggregate）。
	turbine.vne_limit = 55.0
	turbine.fuel_burn = 0.035
	parts.append(turbine)

	var long_wing := PartData.new()
	long_wing.id = "long_wing"
	long_wing.display = "长航程机翼"
	long_wing.category = PartData.Category.WING
	long_wing.size = Vector3i(28, 1, 4)
	long_wing.mass = 42.0
	long_wing.cost = 20
	long_wing.durability = 45.0
	long_wing.is_lifting = true
	long_wing.lift_area = 18.0   # 比默认机翼(12)更大，失速更慢
	long_wing.ctrl_roll = 1.0
	parts.append(long_wing)

	return parts


## 默认可飞套件：一架凑齐「机身+机翼+尾翼+发动机+螺旋桨+起落架+油箱」的小飞机。
## 机体局部坐标：机头朝 −Z，关于 X 轴基本对称，重心落在原点附近（碰撞盒保持居中）。
static func default_loadout() -> Array[PlacedPart]:
	var loadout: Array[PlacedPart] = []
	loadout.append(PlacedPart.make(by_id("fuselage"), Vector3i(-1, 0, -6)))
	loadout.append(PlacedPart.make(by_id("wing"), Vector3i(-12, 1, -2)))
	loadout.append(PlacedPart.make(by_id("tail"), Vector3i(-5, 1, 5)))
	loadout.append(PlacedPart.make(by_id("engine"), Vector3i(-1, 0, -9)))
	loadout.append(PlacedPart.make(by_id("propeller"), Vector3i(-1, 1, -10)))
	loadout.append(PlacedPart.make(by_id("gear"), Vector3i(-2, -2, -3)))
	loadout.append(PlacedPart.make(by_id("fuel_tank"), Vector3i(-1, 0, -3)))
	return loadout
