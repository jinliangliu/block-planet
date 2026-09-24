class_name ItemTypes
## 物品与工具数据：工具 ID、属性、合成配方。
## 方块物品 ID 复用 BlockTypes.Block 的 1..10，工具 ID 从 100 开始，
## 食物与材料（不可放置）从 200 开始。

const WOOD_PICKAXE := 100
const WOOD_AXE := 101
const WOOD_SHOVEL := 102
const STONE_PICKAXE := 103
const STONE_AXE := 104
const STONE_SHOVEL := 105
# 金属工具：铜+锡矿石经冶炼炉得到锭，锭合成青铜工具。
const BRONZE_PICKAXE := 106
const BRONZE_AXE := 107
const BRONZE_SHOVEL := 108

# 动物掉落：肉可食用恢复饥饿，骨头/线为收集材料。
const RAW_BEEF := 200
const RAW_CHICKEN := 201
const BONE := 202
const STRING := 203
# 村庄经济：绿宝石为交易货币，掠夺者掉落；不死图腾可在致命伤时自动拯救。
const EMERALD := 204
const TOTEM := 205
# 农耕与储物：猪掉生猪排；小麦收自农田作物，可合成面包。
const RAW_PORK := 206
const WHEAT := 207
const BREAD := 208
# 冶炼产物：矿石→锭→青铜（有色合金），用于合成金属工具。
const COPPER_INGOT := 209
const TIN_INGOT := 210
const BRONZE_INGOT := 211

const TOOL_TYPE := {
	WOOD_PICKAXE: "pickaxe",
	WOOD_AXE: "axe",
	WOOD_SHOVEL: "shovel",
	STONE_PICKAXE: "pickaxe",
	STONE_AXE: "axe",
	STONE_SHOVEL: "shovel",
	BRONZE_PICKAXE: "pickaxe",
	BRONZE_AXE: "axe",
	BRONZE_SHOVEL: "shovel",
}

const TOOL_TIER := {
	WOOD_PICKAXE: 0,
	WOOD_AXE: 0,
	WOOD_SHOVEL: 0,
	STONE_PICKAXE: 1,
	STONE_AXE: 1,
	STONE_SHOVEL: 1,
	BRONZE_PICKAXE: 2,
	BRONZE_AXE: 2,
	BRONZE_SHOVEL: 2,
}

const TOOL_DURABILITY := {
	WOOD_PICKAXE: 60,
	WOOD_AXE: 60,
	WOOD_SHOVEL: 60,
	STONE_PICKAXE: 132,
	STONE_AXE: 132,
	STONE_SHOVEL: 132,
	BRONZE_PICKAXE: 220,
	BRONZE_AXE: 220,
	BRONZE_SHOVEL: 220,
}

const TOOL_NAMES := {
	WOOD_PICKAXE: "木镐",
	WOOD_AXE: "木斧",
	WOOD_SHOVEL: "木锹",
	STONE_PICKAXE: "石镐",
	STONE_AXE: "石斧",
	STONE_SHOVEL: "石锹",
	BRONZE_PICKAXE: "青铜镐",
	BRONZE_AXE: "青铜斧",
	BRONZE_SHOVEL: "青铜锹",
}

# 按工具 tier 对应的采集速度倍率（青铜 tier 2 最快）。
const TOOL_SPEED := [2.0, 4.0, 6.0]

# 合成配方（无形状，按原料数量合成）。
const RECIPES := [
	{"result": WOOD_PICKAXE, "ingredients": {BlockTypes.Block.WOOD: 5}},
	{"result": WOOD_AXE, "ingredients": {BlockTypes.Block.WOOD: 4}},
	{"result": WOOD_SHOVEL, "ingredients": {BlockTypes.Block.WOOD: 2}},
	{"result": STONE_PICKAXE, "ingredients": {BlockTypes.Block.COBBLESTONE: 3, BlockTypes.Block.WOOD: 2}},
	{"result": STONE_AXE, "ingredients": {BlockTypes.Block.COBBLESTONE: 3, BlockTypes.Block.WOOD: 2}},
	{"result": STONE_SHOVEL, "ingredients": {BlockTypes.Block.COBBLESTONE: 1, BlockTypes.Block.WOOD: 2}},
	{"result": BlockTypes.Block.GLASS, "ingredients": {BlockTypes.Block.SAND: 2}},
	{"result": BlockTypes.Block.CHEST, "ingredients": {BlockTypes.Block.WOOD: 6}},
	{"result": BREAD, "ingredients": {WHEAT: 3}},
	{"result": BlockTypes.Block.SMELTER, "ingredients": {BlockTypes.Block.COBBLESTONE: 8}},
	{"result": BRONZE_PICKAXE, "ingredients": {BRONZE_INGOT: 3, BlockTypes.Block.WOOD: 2}},
	{"result": BRONZE_AXE, "ingredients": {BRONZE_INGOT: 3, BlockTypes.Block.WOOD: 2}},
	{"result": BRONZE_SHOVEL, "ingredients": {BRONZE_INGOT: 1, BlockTypes.Block.WOOD: 2}},
]

# 冶炼炉配方（右键冶炼炉打开）：矿石炼锭、铜锡合青铜。
const SMELT_RECIPES := [
	{"result": COPPER_INGOT, "ingredients": {BlockTypes.Block.COPPER_ORE: 2}},
	{"result": TIN_INGOT, "ingredients": {BlockTypes.Block.TIN_ORE: 2}},
	{"result": BRONZE_INGOT, "ingredients": {COPPER_INGOT: 1, TIN_INGOT: 1}},
]

# 食物 → 食用后恢复的饥饿值（半点制：8 = 4 格鸡腿图标）。
const FOOD := {
	RAW_BEEF: 8,
	RAW_CHICKEN: 5,
	RAW_PORK: 6,
	BREAD: 7,
}

# 非方块物品的名称（工具与方块之外的 ID）。
const ITEM_NAMES := {
	RAW_BEEF: "生牛排",
	RAW_CHICKEN: "生鸡肉",
	BONE: "骨头",
	STRING: "线",
	EMERALD: "绿宝石",
	TOTEM: "不死图腾",
	RAW_PORK: "生猪排",
	WHEAT: "小麦",
	BREAD: "面包",
	COPPER_INGOT: "铜锭",
	TIN_INGOT: "锡锭",
	BRONZE_INGOT: "青铜锭",
}

const ITEM_SHORT_NAMES := {
	RAW_BEEF: "牛排",
	RAW_CHICKEN: "鸡肉",
	BONE: "骨",
	STRING: "线",
	EMERALD: "绿宝石",
	TOTEM: "图腾",
	RAW_PORK: "猪排",
	WHEAT: "麦",
	BREAD: "面包",
	COPPER_INGOT: "铜",
	TIN_INGOT: "锡",
	BRONZE_INGOT: "青铜",
}

# 非方块物品在掉落物/手持模型上使用的平涂颜色。
const ITEM_COLORS := {
	RAW_BEEF: Color(0.72, 0.26, 0.24),
	RAW_CHICKEN: Color(0.93, 0.75, 0.70),
	BONE: Color(0.92, 0.91, 0.84),
	STRING: Color(0.85, 0.85, 0.83),
	EMERALD: Color(0.20, 0.80, 0.45),
	TOTEM: Color(0.90, 0.72, 0.25),
	RAW_PORK: Color(0.96, 0.62, 0.64),
	WHEAT: Color(0.85, 0.74, 0.30),
	BREAD: Color(0.76, 0.55, 0.28),
	COPPER_INGOT: Color(0.83, 0.51, 0.30),
	TIN_INGOT: Color(0.78, 0.78, 0.82),
	BRONZE_INGOT: Color(0.68, 0.50, 0.30),
}

# 村民交易配方：cost 为绿宝石数量，result/count 为产出。
# 交易执行走 Inventory.consume_item + add_item，与合成面板同源。
const TRADES := [
	{"cost": 2, "result": RAW_BEEF, "count": 3},
	{"cost": 3, "result": WOOD_PICKAXE, "count": 1},
	{"cost": 2, "result": BlockTypes.Block.GLASS, "count": 8},
	{"cost": 4, "result": BlockTypes.Block.WOOL, "count": 6},
	{"cost": 8, "result": TOTEM, "count": 1},
	{"cost": 2, "result": RAW_PORK, "count": 2},
	{"cost": 3, "result": BREAD, "count": 2},
	{"cost": 2, "result": WHEAT, "count": 4},
]


static func is_tool_item(id: int) -> bool:
	return TOOL_TYPE.has(id)


static func tool_type(id: int) -> String:
	return TOOL_TYPE.get(id, "")


static func tool_tier(id: int) -> int:
	return TOOL_TIER.get(id, -1)


static func tool_durability(id: int) -> int:
	return TOOL_DURABILITY.get(id, 0)


static func tool_speed(id: int) -> float:
	var tier := tool_tier(id)
	if tier < 0 or tier >= TOOL_SPEED.size():
		return 1.0
	return TOOL_SPEED[tier]


static func item_name(id: int) -> String:
	if is_tool_item(id):
		return TOOL_NAMES.get(id, "?")
	if ITEM_NAMES.has(id):
		return ITEM_NAMES.get(id, "?")
	return BlockTypes.display_name(id)


static func item_short_name(id: int) -> String:
	if is_tool_item(id):
		return TOOL_NAMES.get(id, "?")
	if ITEM_SHORT_NAMES.has(id):
		return ITEM_SHORT_NAMES.get(id, "?")
	return BlockTypes.short_name(id)


## 食物类物品：手持时右键/放置键食用。
static func is_food(id: int) -> bool:
	return FOOD.has(id)


static func food_value(id: int) -> int:
	return FOOD.get(id, 0)


## 非方块、非工具的普通物品（肉/骨/线），用于掉落物与手持模型着色。
static func is_plain_item(id: int) -> bool:
	return ITEM_COLORS.has(id)


## 物品分类标签（储物箱排列用）：0=方块 1=工具 2=食物 3=材料。
static func category(id: int) -> int:
	if is_tool_item(id):
		return 1
	if is_food(id):
		return 2
	if is_plain_item(id):
		return 3
	return 0


static func is_placeable(id: int) -> bool:
	return id >= BlockTypes.Block.GRASS and id <= BlockTypes.Block.SMELTER

