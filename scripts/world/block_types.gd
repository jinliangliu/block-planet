class_name BlockTypes
## 方块 ID 与静态属性注册表。
## 纹理瓦片索引对应 TextureAtlas 中的图集位置。

enum Block {
	AIR = 0,
	GRASS = 1,
	DIRT = 2,
	STONE = 3,
	SAND = 4,
	WOOD = 5,
	LEAVES = 6,
	WATER = 7,
	GLASS = 8,
	COBBLESTONE = 9,
	WOOL = 10,
	BREWING = 11,
	CHEST = 12,
	FARMLAND = 13,
	WHEAT_CROP = 14,
	COPPER_ORE = 15,
	TIN_ORE = 16,
	SMELTER = 17,
	WATERWEED = 18,
	ALGAE = 19,
	DUCKWEED = 20,
	LILY_PAD = 21,
	LOTUS = 22,
	SNOW = 23,
	IRON_ORE = 24,
	GOLD_ORE = 25,
}

const NAMES := {
	Block.AIR: "空气",
	Block.GRASS: "草方块",
	Block.DIRT: "泥土",
	Block.STONE: "石头",
	Block.SAND: "沙子",
	Block.WOOD: "木头",
	Block.LEAVES: "树叶",
	Block.WATER: "水",
	Block.GLASS: "玻璃",
	Block.COBBLESTONE: "圆石",
	Block.WOOL: "羊毛",
	Block.BREWING: "酿灶台",
	Block.CHEST: "储物箱",
	Block.FARMLAND: "耕地",
	Block.WHEAT_CROP: "小麦",
	Block.COPPER_ORE: "铜矿石",
	Block.TIN_ORE: "锡矿石",
	Block.SMELTER: "冶炼炉",
	Block.WATERWEED: "水草",
	Block.ALGAE: "藻类",
	Block.DUCKWEED: "浮萍",
	Block.LILY_PAD: "荷叶",
	Block.LOTUS: "莲花",
	Block.SNOW: "雪块",
	Block.IRON_ORE: "铁矿石",
	Block.GOLD_ORE: "金矿石",
}

const SOLID := {
	Block.AIR: false,
	Block.GRASS: true,
	Block.DIRT: true,
	Block.STONE: true,
	Block.SAND: true,
	Block.WOOD: true,
	Block.LEAVES: true,
	Block.WATER: false,
	Block.GLASS: true,
	Block.COBBLESTONE: true,
	Block.WOOL: true,
	Block.BREWING: true,
	Block.CHEST: true,
	Block.FARMLAND: true,
	Block.WHEAT_CROP: false,
	Block.COPPER_ORE: true,
	Block.TIN_ORE: true,
	Block.SMELTER: true,
	Block.WATERWEED: false,
	Block.ALGAE: false,
	Block.DUCKWEED: false,
	Block.LILY_PAD: false,
	Block.LOTUS: false,
	Block.SNOW: true,
	Block.IRON_ORE: true,
	Block.GOLD_ORE: true,
}

const TRANSPARENT := {
	Block.AIR: true,
	Block.GRASS: false,
	Block.DIRT: false,
	Block.STONE: false,
	Block.SAND: false,
	Block.WOOD: false,
	Block.LEAVES: true,
	Block.WATER: true,
	Block.GLASS: true,
	Block.COBBLESTONE: false,
	Block.WOOL: false,
	Block.BREWING: false,
	Block.CHEST: false,
	Block.FARMLAND: false,
	Block.WHEAT_CROP: true,
	Block.COPPER_ORE: false,
	Block.TIN_ORE: false,
	Block.SMELTER: false,
	Block.WATERWEED: true,
	Block.ALGAE: true,
	Block.DUCKWEED: true,
	Block.LILY_PAD: true,
	Block.LOTUS: true,
	Block.SNOW: false,
	Block.IRON_ORE: false,
	Block.GOLD_ORE: false,
}

# 每个方块的纹理瓦片：[顶面, 底面, 侧面]
const TILES := {
	Block.GRASS: Vector3i(0, 2, 1),
	Block.DIRT: Vector3i(2, 2, 2),
	Block.STONE: Vector3i(3, 3, 3),
	Block.SAND: Vector3i(4, 4, 4),
	Block.WOOD: Vector3i(6, 6, 5),
	Block.LEAVES: Vector3i(7, 7, 7),
	Block.WATER: Vector3i(8, 8, 8),
	Block.GLASS: Vector3i(9, 9, 9),
	Block.COBBLESTONE: Vector3i(10, 10, 10),
	Block.WOOL: Vector3i(11, 11, 11),
	Block.BREWING: Vector3i(12, 12, 12),
	Block.CHEST: Vector3i(13, 13, 13),
	Block.FARMLAND: Vector3i(14, 14, 14),
	Block.WHEAT_CROP: Vector3i(15, 15, 15),
	Block.COPPER_ORE: Vector3i(16, 16, 16),
	Block.TIN_ORE: Vector3i(17, 17, 17),
	Block.SMELTER: Vector3i(18, 18, 18),
	Block.WATERWEED: Vector3i(19, 19, 19),
	Block.ALGAE: Vector3i(20, 20, 20),
	Block.DUCKWEED: Vector3i(21, 21, 21),
	Block.LILY_PAD: Vector3i(22, 22, 22),
	Block.LOTUS: Vector3i(23, 23, 23),
	Block.SNOW: Vector3i(24, 24, 24),
	Block.IRON_ORE: Vector3i(25, 25, 25),
	Block.GOLD_ORE: Vector3i(26, 26, 26),
}

# 水生植物：生长在水中/水面的非固体装饰方块，徒手可采，可再放置。
const WATER_PLANTS := {
	Block.WATERWEED: true,
	Block.ALGAE: true,
	Block.DUCKWEED: true,
	Block.LILY_PAD: true,
	Block.LOTUS: true,
}

# 创造模式快捷栏显示的方块顺序。
const HOTBAR_BLOCKS := [
	Block.GRASS,
	Block.DIRT,
	Block.STONE,
	Block.SAND,
	Block.WOOD,
	Block.LEAVES,
	Block.GLASS,
	Block.COBBLESTONE,
	Block.WATER,
]

const SHORT_NAMES := {
	Block.GRASS: "草",
	Block.DIRT: "土",
	Block.STONE: "石",
	Block.SAND: "沙",
	Block.WOOD: "木",
	Block.LEAVES: "叶",
	Block.GLASS: "玻",
	Block.COBBLESTONE: "圆",
	Block.WATER: "水",
	Block.WOOL: "羊",
	Block.BREWING: "灶",
	Block.CHEST: "箱",
	Block.FARMLAND: "田",
	Block.WHEAT_CROP: "麦",
	Block.COPPER_ORE: "铜",
	Block.TIN_ORE: "锡",
	Block.SMELTER: "炉",
	Block.WATERWEED: "水草",
	Block.ALGAE: "藻",
	Block.DUCKWEED: "萍",
	Block.LILY_PAD: "荷",
	Block.LOTUS: "莲",
	Block.SNOW: "雪",
	Block.IRON_ORE: "铁",
	Block.GOLD_ORE: "金",
}

# 可堆叠物品（方块/材料/食物）的每格上限。
const STACK_SIZE := 100

# 徒手破坏时间（秒），用于“硬度”概念。
const HARDNESS := {
	Block.GRASS: 0.6,
	Block.DIRT: 0.5,
	Block.SAND: 0.5,
	Block.LEAVES: 0.2,
	Block.WOOD: 1.5,
	Block.STONE: 4.0,
	Block.COBBLESTONE: 3.0,
	Block.GLASS: 0.3,
	Block.WOOL: 0.4,
	Block.BREWING: 1.0,
	Block.CHEST: 1.5,
	Block.FARMLAND: 0.5,
	Block.WHEAT_CROP: 0.1,
	Block.COPPER_ORE: 3.0,
	Block.TIN_ORE: 3.5,
	Block.SMELTER: 2.0,
	Block.WATERWEED: 0.1,
	Block.ALGAE: 0.1,
	Block.DUCKWEED: 0.1,
	Block.LILY_PAD: 0.1,
	Block.LOTUS: 0.1,
	Block.SNOW: 0.4,
	Block.IRON_ORE: 4.5,
	Block.GOLD_ORE: 5.0,
}

# 有效工具类型；空字符串表示徒手/任意工具即可。
# 小麦与水草系改用镰刀：装备镰刀时破坏更快且收成更多。
const EFFECTIVE_TOOL := {
	Block.GRASS: "shovel",
	Block.DIRT: "shovel",
	Block.SAND: "shovel",
	Block.LEAVES: "",
	Block.WOOD: "axe",
	Block.STONE: "pickaxe",
	Block.COBBLESTONE: "pickaxe",
	Block.GLASS: "",
	Block.WOOL: "",
	Block.BREWING: "",
	Block.CHEST: "axe",
	Block.FARMLAND: "shovel",
	Block.WHEAT_CROP: "sickle",
	Block.COPPER_ORE: "pickaxe",
	Block.TIN_ORE: "pickaxe",
	Block.IRON_ORE: "pickaxe",
	Block.GOLD_ORE: "pickaxe",
	Block.SMELTER: "pickaxe",
	Block.WATERWEED: "sickle",
	Block.ALGAE: "sickle",
	Block.DUCKWEED: "sickle",
	Block.LILY_PAD: "",
	Block.LOTUS: "",
	Block.SNOW: "shovel",
}

# 采集该方块所需的最低工具等级（1 木 / 2 石 / 3 青铜 / 4 铁）。
# 未列出的方块无等级要求：徒手也能挖，只是慢且部分不给掉落。
const MIN_TIER := {
	Block.COPPER_ORE: 1,
	Block.TIN_ORE: 2,
	Block.IRON_ORE: 3,
	Block.GOLD_ORE: 4,
}

# 装备镰刀时收成翻倍的方块（一次收 3 束小麦、2 份水草）。
const SICKLE_BONUS := {
	Block.WHEAT_CROP: 2,
	Block.WATERWEED: 1,
	Block.ALGAE: 1,
	Block.DUCKWEED: 1,
}


static func is_solid(id: int) -> bool:
	return SOLID.get(id, false)


static func is_transparent(id: int) -> bool:
	return TRANSPARENT.get(id, true)


## 水生植物：长在水里/水面的装饰方块（不挡路、徒手可采）。
static func is_water_plant(id: int) -> bool:
	return WATER_PLANTS.has(id)


static func display_name(id: int) -> String:
	return NAMES.get(id, "未知")


static func short_name(id: int) -> String:
	return SHORT_NAMES.get(id, "?")


static func drop_for(id: int, tool_type: String) -> int:
	match id:
		Block.STONE:
			return Block.COBBLESTONE if tool_type == "pickaxe" else Block.AIR
		Block.COBBLESTONE:
			return Block.COBBLESTONE if tool_type == "pickaxe" else Block.AIR
		# 树叶与玻璃掉落自身，保证资源可以回收（儿童向：避免“挖了就没”的挫败感）。
		Block.LEAVES:
			return Block.LEAVES
		Block.GLASS:
			return Block.GLASS
		# 小麦作物收获物品小麦（可合成面包）。
		Block.WHEAT_CROP:
			return ItemTypes.WHEAT
		_:
			return id

## 一次破坏的掉落数量（成熟小麦掉 2 个，其余 1 个）。
## 装备镰刀时对 SICKLE_BONUS 列出的作物额外多掉，让镰刀有实用价值。
static func drop_count_for(id: int, tool: String = "") -> int:
	var base := 2 if id == Block.WHEAT_CROP else 1
	if tool == "sickle" and SICKLE_BONUS.has(id):
		return base + int(SICKLE_BONUS[id])
	return base


## 采集该方块所需的最低工具等级；0 表示无等级要求。
static func required_tier(id: int) -> int:
	return int(MIN_TIER.get(id, 0))


## 给定工具等级能否采下该方块：无等级要求恒为真，否则等级须达标。
static func tier_allows(id: int, tool_tier: int) -> bool:
	var required := required_tier(id)
	return required <= 0 or tool_tier >= required


## 采集该方块所需的工具中文名（用于提示），如「石镐」；无要求返回空串。
static func tier_hint(id: int) -> String:
	var required := required_tier(id)
	if required <= 0:
		return ""
	return "%s镐" % ItemTypes.tier_name(required)
