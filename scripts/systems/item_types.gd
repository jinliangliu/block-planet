class_name ItemTypes
## 物品与工具数据：工具 ID、属性、合成配方。
## 方块物品 ID 复用 BlockTypes.Block 的 1..25，工具 ID 从 100 开始，
## 食物与材料（不可放置）从 200 开始。
##
## 工具分级（1~4 级）：木 1 / 石 2 / 青铜 3 / 铁 4。等级决定采集速度、
## 耐久与「能否采集指定矿石」（见 BlockTypes.MIN_TIER）。
## 银/金工具为 4 级珍稀变体：不打乱等级表，靠个体速度与耐久区分，
## 材料只能通过交易与任务奖励获得，是长期收集目标。

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
# 收割工具：镰刀对小麦与水草有额外收成（见 BlockTypes.drop_count_for）。
const WOOD_SICKLE := 109
const STONE_SICKLE := 110
const BRONZE_SICKLE := 111
const IRON_SICKLE := 112
# 铁工具：4 级采集工具，可开采铁矿石。
const IRON_PICKAXE := 113
const IRON_AXE := 114
const IRON_SHOVEL := 115
# 珍稀工具：银（耐久最高）与金（速度最快、耐久最低）。
const SILVER_PICKAXE := 116
const SILVER_AXE := 117
const SILVER_SHOVEL := 118
const GOLD_PICKAXE := 119
const GOLD_AXE := 120
const GOLD_SHOVEL := 121
# 渔具与弓：鱼竿垂钓水生物，弓蓄力远程狩猎。
const WOOD_FISHING_ROD := 122
const IRON_FISHING_ROD := 123
const WOOD_BOW := 124
const IRON_BOW := 125

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
# 水生物掉落：下水捕鱼捉虾摸蟹，肉可食用。
const RAW_FISH := 212
const RAW_SHRIMP := 213
const CRAB_MEAT := 214
# 进阶材料：铁矿与金矿冶炼成锭；银锭/水晶/碳棒来自交易与任务奖励。
const IRON_INGOT := 215
const SILVER_INGOT := 216
const GOLD_INGOT := 217
const CRYSTAL := 218
const CARBON_ROD := 219
const ALLOY_INGOT := 220
# 狩猎产物：兽皮与獠牙来自中大型猎物，羽毛来自禽类（也是做箭的材料）。
const HIDE := 221
const FEATHER := 222
const FANG := 223
# 弹药：弓需要消耗箭（创造模式不消耗）。
const ARROW := 224
# 生活用品：桶可装水饮水；胡萝卜/土豆/白萝卜为可种植的蔬菜作物。
const BUCKET := 225
const WATER_BUCKET := 226
const CARROT := 227
const POTATO := 228
const RADISH := 229
## 飞行器：手持右键在身前平地上放下一架，走近按 F 登机驾驶（见 Aircraft）。
const AIRCRAFT := 230

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
	WOOD_SICKLE: "sickle",
	STONE_SICKLE: "sickle",
	BRONZE_SICKLE: "sickle",
	IRON_SICKLE: "sickle",
	IRON_PICKAXE: "pickaxe",
	IRON_AXE: "axe",
	IRON_SHOVEL: "shovel",
	SILVER_PICKAXE: "pickaxe",
	SILVER_AXE: "axe",
	SILVER_SHOVEL: "shovel",
	GOLD_PICKAXE: "pickaxe",
	GOLD_AXE: "axe",
	GOLD_SHOVEL: "shovel",
	WOOD_FISHING_ROD: "rod",
	IRON_FISHING_ROD: "rod",
	WOOD_BOW: "bow",
	IRON_BOW: "bow",
}

const TOOL_TIER := {
	WOOD_PICKAXE: 1,
	WOOD_AXE: 1,
	WOOD_SHOVEL: 1,
	WOOD_SICKLE: 1,
	STONE_PICKAXE: 2,
	STONE_AXE: 2,
	STONE_SHOVEL: 2,
	STONE_SICKLE: 2,
	BRONZE_PICKAXE: 3,
	BRONZE_AXE: 3,
	BRONZE_SHOVEL: 3,
	BRONZE_SICKLE: 3,
	IRON_PICKAXE: 4,
	IRON_AXE: 4,
	IRON_SHOVEL: 4,
	IRON_SICKLE: 4,
	SILVER_PICKAXE: 4,
	SILVER_AXE: 4,
	SILVER_SHOVEL: 4,
	GOLD_PICKAXE: 4,
	GOLD_AXE: 4,
	GOLD_SHOVEL: 4,
	WOOD_FISHING_ROD: 1,
	IRON_FISHING_ROD: 4,
	WOOD_BOW: 1,
	IRON_BOW: 4,
}

const TOOL_DURABILITY := {
	WOOD_PICKAXE: 60,
	WOOD_AXE: 60,
	WOOD_SHOVEL: 60,
	WOOD_SICKLE: 55,
	STONE_PICKAXE: 132,
	STONE_AXE: 132,
	STONE_SHOVEL: 132,
	STONE_SICKLE: 120,
	BRONZE_PICKAXE: 220,
	BRONZE_AXE: 220,
	BRONZE_SHOVEL: 220,
	BRONZE_SICKLE: 200,
	IRON_PICKAXE: 380,
	IRON_AXE: 380,
	IRON_SHOVEL: 380,
	IRON_SICKLE: 340,
	SILVER_PICKAXE: 520,
	SILVER_AXE: 520,
	SILVER_SHOVEL: 520,
	GOLD_PICKAXE: 180,
	GOLD_AXE: 180,
	GOLD_SHOVEL: 180,
	WOOD_FISHING_ROD: 65,
	IRON_FISHING_ROD: 210,
	WOOD_BOW: 120,
	IRON_BOW: 300,
}

const TOOL_NAMES := {
	WOOD_PICKAXE: "木镐",
	WOOD_AXE: "木斧",
	WOOD_SHOVEL: "木锹",
	WOOD_SICKLE: "木镰刀",
	STONE_PICKAXE: "石镐",
	STONE_AXE: "石斧",
	STONE_SHOVEL: "石锹",
	STONE_SICKLE: "石镰刀",
	BRONZE_PICKAXE: "青铜镐",
	BRONZE_AXE: "青铜斧",
	BRONZE_SHOVEL: "青铜锹",
	BRONZE_SICKLE: "青铜镰刀",
	IRON_PICKAXE: "铁镐",
	IRON_AXE: "铁斧",
	IRON_SHOVEL: "铁锹",
	IRON_SICKLE: "铁镰刀",
	SILVER_PICKAXE: "银镐",
	SILVER_AXE: "银斧",
	SILVER_SHOVEL: "银锹",
	GOLD_PICKAXE: "金镐",
	GOLD_AXE: "金斧",
	GOLD_SHOVEL: "金锹",
	WOOD_FISHING_ROD: "木鱼竿",
	IRON_FISHING_ROD: "铁鱼竿",
	WOOD_BOW: "木弓",
	IRON_BOW: "铁弓",
}

## 按等级的基础采集速度倍率（等级 1~4）。
const TIER_SPEED := {
	1: 2.0,
	2: 4.0,
	3: 6.5,
	4: 9.0,
}

## 珍稀工具的个体速度覆盖（高于同级普通工具）。
const TOOL_SPEED_BONUS := {
	SILVER_PICKAXE: 11.0,
	SILVER_AXE: 11.0,
	SILVER_SHOVEL: 11.0,
	GOLD_PICKAXE: 13.0,
	GOLD_AXE: 13.0,
	GOLD_SHOVEL: 13.0,
}

## 工具等级的中文称法（1~4 级）。
const TIER_NAMES := {
	1: "木",
	2: "石",
	3: "青铜",
	4: "铁",
}

# 合成配方（无形状，按原料数量合成）。
const RECIPES := [
	{"result": WOOD_PICKAXE, "ingredients": {BlockTypes.Block.WOOD: 5}},
	{"result": WOOD_AXE, "ingredients": {BlockTypes.Block.WOOD: 4}},
	{"result": WOOD_SHOVEL, "ingredients": {BlockTypes.Block.WOOD: 2}},
	{"result": WOOD_SICKLE, "ingredients": {BlockTypes.Block.WOOD: 3}},
	{"result": STONE_PICKAXE, "ingredients": {BlockTypes.Block.COBBLESTONE: 3, BlockTypes.Block.WOOD: 2}},
	{"result": STONE_AXE, "ingredients": {BlockTypes.Block.COBBLESTONE: 3, BlockTypes.Block.WOOD: 2}},
	{"result": STONE_SHOVEL, "ingredients": {BlockTypes.Block.COBBLESTONE: 1, BlockTypes.Block.WOOD: 2}},
	{"result": STONE_SICKLE, "ingredients": {BlockTypes.Block.COBBLESTONE: 3, BlockTypes.Block.WOOD: 2}},
	{"result": BRONZE_PICKAXE, "ingredients": {BRONZE_INGOT: 3, BlockTypes.Block.WOOD: 2}},
	{"result": BRONZE_AXE, "ingredients": {BRONZE_INGOT: 3, BlockTypes.Block.WOOD: 2}},
	{"result": BRONZE_SHOVEL, "ingredients": {BRONZE_INGOT: 1, BlockTypes.Block.WOOD: 2}},
	{"result": BRONZE_SICKLE, "ingredients": {BRONZE_INGOT: 2, BlockTypes.Block.WOOD: 2}},
	{"result": IRON_PICKAXE, "ingredients": {IRON_INGOT: 3, BlockTypes.Block.WOOD: 2}},
	{"result": IRON_AXE, "ingredients": {IRON_INGOT: 3, BlockTypes.Block.WOOD: 2}},
	{"result": IRON_SHOVEL, "ingredients": {IRON_INGOT: 1, BlockTypes.Block.WOOD: 2}},
	{"result": IRON_SICKLE, "ingredients": {IRON_INGOT: 2, BlockTypes.Block.WOOD: 2}},
	{"result": SILVER_PICKAXE, "ingredients": {SILVER_INGOT: 2, CRYSTAL: 1, BlockTypes.Block.WOOD: 2}},
	{"result": SILVER_AXE, "ingredients": {SILVER_INGOT: 2, CRYSTAL: 1, BlockTypes.Block.WOOD: 2}},
	{"result": SILVER_SHOVEL, "ingredients": {SILVER_INGOT: 1, CRYSTAL: 1, BlockTypes.Block.WOOD: 2}},
	{"result": GOLD_PICKAXE, "ingredients": {GOLD_INGOT: 2, ALLOY_INGOT: 1, BlockTypes.Block.WOOD: 2}},
	{"result": GOLD_AXE, "ingredients": {GOLD_INGOT: 2, ALLOY_INGOT: 1, BlockTypes.Block.WOOD: 2}},
	{"result": GOLD_SHOVEL, "ingredients": {GOLD_INGOT: 1, ALLOY_INGOT: 1, BlockTypes.Block.WOOD: 2}},
	{"result": WOOD_FISHING_ROD, "ingredients": {BlockTypes.Block.WOOD: 3, STRING: 2}},
	{"result": IRON_FISHING_ROD, "ingredients": {IRON_INGOT: 1, STRING: 3, BlockTypes.Block.WOOD: 2}},
	{"result": WOOD_BOW, "ingredients": {BlockTypes.Block.WOOD: 3, STRING: 3}},
	{"result": IRON_BOW, "ingredients": {IRON_INGOT: 2, STRING: 2, BlockTypes.Block.WOOD: 2}},
	# 箭按「一束 4 支」产出，配方用 count 字段描述产出数量（默认 1）。
	{"result": ARROW, "count": 4, "ingredients": {BlockTypes.Block.WOOD: 1, BlockTypes.Block.COBBLESTONE: 1, FEATHER: 1}},
	{"result": BlockTypes.Block.GLASS, "ingredients": {BlockTypes.Block.SAND: 2}},
	{"result": BlockTypes.Block.CHEST, "ingredients": {BlockTypes.Block.WOOD: 6}},
	{"result": BREAD, "ingredients": {WHEAT: 3}},
	# 床：2 羊毛 + 3 木板（木板用木头代指），夜晚右键睡觉跳到清晨。
	{"result": BlockTypes.Block.BED, "ingredients": {BlockTypes.Block.WOOL: 2, BlockTypes.Block.WOOD: 3}},
	# 水桶：对着水右键装水，喝水回复体力。
	{"result": BUCKET, "count": 1, "ingredients": {BlockTypes.Block.WOOD: 3}},
	# 飞行器：铁架子 + 木头骨架 + 线织蒙皮，成品直接放下一架能开的飞机。
	{"result": AIRCRAFT, "ingredients": {IRON_INGOT: 4, BlockTypes.Block.WOOD: 6, STRING: 2}},
	{"result": BlockTypes.Block.SMELTER, "ingredients": {BlockTypes.Block.COBBLESTONE: 8}},
]


## 配方的产出数量（未写 count 即为 1）。
static func recipe_count(recipe: Dictionary) -> int:
	return maxi(1, int(recipe.get("count", 1)))


## 配方在合成台的分页（0 工具 / 1 武器钓具 / 2 方块 / 3 食物）。
## 分类按「产物」判断，顺序即页面顺序；新增配方无需登记，自动归页。
static func recipe_page(recipe: Dictionary) -> int:
	var result: int = int(recipe["result"])
	if is_food(result):
		return 3
	if is_bow(result) or is_rod(result) or result == ARROW:
		return 1
	if category(result) == 0:
		return 2
	return 0

# 冶炼炉配方（右键冶炼炉打开）：矿石炼锭、铜锡合青铜、铁+碳+银炼合金。
const SMELT_RECIPES := [
	{"result": COPPER_INGOT, "ingredients": {BlockTypes.Block.COPPER_ORE: 2}},
	{"result": TIN_INGOT, "ingredients": {BlockTypes.Block.TIN_ORE: 2}},
	{"result": BRONZE_INGOT, "ingredients": {COPPER_INGOT: 1, TIN_INGOT: 1}},
	{"result": IRON_INGOT, "ingredients": {BlockTypes.Block.IRON_ORE: 2}},
	{"result": GOLD_INGOT, "ingredients": {BlockTypes.Block.GOLD_ORE: 2}},
	{"result": ALLOY_INGOT, "ingredients": {IRON_INGOT: 1, CARBON_ROD: 1, SILVER_INGOT: 1}},
]

# 食物 → 食用后恢复的饥饿值（半点制：8 = 4 格鸡腿图标）。
const FOOD := {
	RAW_BEEF: 8,
	RAW_CHICKEN: 5,
	RAW_PORK: 6,
	BREAD: 7,
	RAW_FISH: 6,
	RAW_SHRIMP: 4,
	CRAB_MEAT: 5,
	CARROT: 3,
	POTATO: 4,
	RADISH: 3,
}

# 蔬菜物品 → 对应的作物方块（在耕地上右键种植）。
const CROP_PLANTABLE := {
	WHEAT: BlockTypes.Block.WHEAT_CROP,
	CARROT: BlockTypes.Block.CARROT_CROP,
	POTATO: BlockTypes.Block.POTATO_CROP,
	RADISH: BlockTypes.Block.RADISH_CROP,
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
	RAW_FISH: "生鱼",
	RAW_SHRIMP: "生虾",
	CRAB_MEAT: "蟹肉",
	IRON_INGOT: "铁锭",
	SILVER_INGOT: "银锭",
	GOLD_INGOT: "金锭",
	CRYSTAL: "水晶",
	CARBON_ROD: "碳棒",
	ALLOY_INGOT: "合金锭",
	HIDE: "兽皮",
	FEATHER: "羽毛",
	FANG: "獠牙",
	ARROW: "箭",
	BUCKET: "木桶",
	WATER_BUCKET: "水桶",
	CARROT: "胡萝卜",
	POTATO: "土豆",
	RADISH: "白萝卜",
	AIRCRAFT: "轻型飞机",
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
	RAW_FISH: "鱼",
	RAW_SHRIMP: "虾",
	CRAB_MEAT: "蟹肉",
	IRON_INGOT: "铁",
	SILVER_INGOT: "银",
	GOLD_INGOT: "金",
	CRYSTAL: "水晶",
	CARBON_ROD: "碳",
	ALLOY_INGOT: "合金",
	HIDE: "皮",
	FEATHER: "羽",
	FANG: "牙",
	ARROW: "箭",
	BUCKET: "桶",
	WATER_BUCKET: "水桶",
	CARROT: "萝卜",
	POTATO: "土豆",
	RADISH: "萝",
	AIRCRAFT: "飞机",
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
	RAW_FISH: Color(0.58, 0.72, 0.82),
	RAW_SHRIMP: Color(0.94, 0.62, 0.52),
	CRAB_MEAT: Color(0.90, 0.45, 0.38),
	IRON_INGOT: Color(0.72, 0.73, 0.76),
	SILVER_INGOT: Color(0.88, 0.90, 0.93),
	GOLD_INGOT: Color(0.93, 0.78, 0.28),
	CRYSTAL: Color(0.60, 0.90, 0.96),
	CARBON_ROD: Color(0.26, 0.26, 0.29),
	ALLOY_INGOT: Color(0.56, 0.62, 0.72),
	HIDE: Color(0.62, 0.42, 0.26),
	FEATHER: Color(0.94, 0.94, 0.90),
	FANG: Color(0.92, 0.90, 0.82),
	ARROW: Color(0.66, 0.50, 0.30),
	BUCKET: Color(0.62, 0.45, 0.25),
	WATER_BUCKET: Color(0.30, 0.55, 0.85),
	CARROT: Color(0.90, 0.55, 0.20),
	POTATO: Color(0.80, 0.66, 0.38),
	RADISH: Color(0.92, 0.93, 0.86),
	AIRCRAFT: Color(0.87, 0.89, 0.92),
}

# 工具微缩图/3D 预览用的按材质着色（木/石/青铜/铁/银/金）。
const TOOL_COLORS := {
	WOOD_PICKAXE: Color(0.62, 0.45, 0.25),
	WOOD_AXE: Color(0.62, 0.45, 0.25),
	WOOD_SHOVEL: Color(0.62, 0.45, 0.25),
	WOOD_SICKLE: Color(0.62, 0.45, 0.25),
	STONE_PICKAXE: Color(0.58, 0.58, 0.61),
	STONE_AXE: Color(0.58, 0.58, 0.61),
	STONE_SHOVEL: Color(0.58, 0.58, 0.61),
	STONE_SICKLE: Color(0.58, 0.58, 0.61),
	BRONZE_PICKAXE: Color(0.72, 0.52, 0.30),
	BRONZE_AXE: Color(0.72, 0.52, 0.30),
	BRONZE_SHOVEL: Color(0.72, 0.52, 0.30),
	BRONZE_SICKLE: Color(0.72, 0.52, 0.30),
	IRON_PICKAXE: Color(0.62, 0.64, 0.68),
	IRON_AXE: Color(0.62, 0.64, 0.68),
	IRON_SHOVEL: Color(0.62, 0.64, 0.68),
	IRON_SICKLE: Color(0.62, 0.64, 0.68),
	SILVER_PICKAXE: Color(0.88, 0.90, 0.94),
	SILVER_AXE: Color(0.88, 0.90, 0.94),
	SILVER_SHOVEL: Color(0.88, 0.90, 0.94),
	GOLD_PICKAXE: Color(0.93, 0.78, 0.28),
	GOLD_AXE: Color(0.93, 0.78, 0.28),
	GOLD_SHOVEL: Color(0.93, 0.78, 0.28),
	WOOD_FISHING_ROD: Color(0.70, 0.55, 0.32),
	IRON_FISHING_ROD: Color(0.72, 0.73, 0.76),
	WOOD_BOW: Color(0.66, 0.48, 0.26),
	IRON_BOW: Color(0.70, 0.72, 0.76),
}

# 悬停简介：特殊条目查表，未列出的按分类生成通用说明。
const ITEM_DESCRIPTIONS := {
	BlockTypes.Block.STONE: "坚硬的石头，需要镐才能采集。",
	BlockTypes.Block.GLASS: "透明方块，两份沙子可合成。",
	BlockTypes.Block.WATER: "会流动的水，无法拾取。",
	BlockTypes.Block.BREWING: "村庄里的酿灶台。",
	BlockTypes.Block.CHEST: "可存放 36 组物品，右键打开。",
	BlockTypes.Block.FARMLAND: "村庄耕地，种着小麦。",
	BlockTypes.Block.WHEAT_CROP: "成熟后用镰刀收割，一份能收三束小麦。",
	BlockTypes.Block.COPPER_ORE: "石层中的有色金属矿，任意镐即可开采，炼成铜锭。",
	BlockTypes.Block.TIN_ORE: "更深岩层里的有色金属矿，需要石镐以上才能采下。",
	BlockTypes.Block.IRON_ORE: "地层深处的铁矿，青铜镐以上才能采下，炼成铁锭。",
	BlockTypes.Block.GOLD_ORE: "最深处偶见的金矿，铁镐才能采下，炼成金锭。",
	BlockTypes.Block.SMELTER: "右键打开冶炼炉，把矿石炼成金属锭。",
	BlockTypes.Block.WATERWEED: "大河底部的水草，用镰刀割得更多。",
	BlockTypes.Block.ALGAE: "深水里成片的藻类，可徒手采集。",
	BlockTypes.Block.DUCKWEED: "池塘水面上的细小浮萍。",
	BlockTypes.Block.LILY_PAD: "池塘水面的荷叶，青蛙喜欢蹲在上面。",
	BlockTypes.Block.LOTUS: "池塘里开出的莲花，很漂亮。",
	RAW_FISH: "河里的鱼，可食用，也能喂猫。",
	RAW_SHRIMP: "河里的虾，生吃也能填肚子。",
	CRAB_MEAT: "河底的蟹肉，鲜美的一餐。",
	EMERALD: "村民交易的货币。",
	TOTEM: "稀有材料，可向村民兑换。",
	IRON_INGOT: "铁矿石冶炼而成，4 级工具的主要材料。",
	SILVER_INGOT: "只能向村民换取的贵金属，做耐久最高的银工具。",
	GOLD_INGOT: "金矿石冶炼而成，金工具最快但最容易用坏。",
	CRYSTAL: "交易得来的晶体，银工具的必需材料。",
	CARBON_ROD: "交易得来的碳棒，与铁、银一起炼成合金锭。",
	ALLOY_INGOT: "铁 + 碳 + 银炼成的合金，金工具的关键材料。",
	HIDE: "中大型猎物身上剥下的兽皮，可售出好价钱。",
	FEATHER: "禽类掉落的羽毛，是制作箭的必备材料。",
	FANG: "凶猛猎物的獠牙，是勇敢者的收藏。",
	ARROW: "弓的弹药，四支一束，狩猎时会被消耗。",
	WOOD_FISHING_ROD: "手持后右键抛竿，等浮标下沉时再按右键收竿。",
	IRON_FISHING_ROD: "更耐用的鱼竿，咬钩时机的容错更宽松。",
	WOOD_BOW: "按住右键蓄力，松手射出箭，蓄得越满伤害越高。",
	IRON_BOW: "射得更快也更耐用的弓，狩猎大型猎物更从容。",
	BlockTypes.Block.BED: "夜晚右键睡觉，一觉睡到天亮。2 羊毛加 3 木板合成。",
	BUCKET: "对着水面右键装水。",
	WATER_BUCKET: "右键喝水，恢复体力还回一点血。喝完变回空桶。",
	CARROT: "可以生吃，也可以种在耕地上。",
	POTATO: "饱腹感比胡萝卜强，也能种回地里。",
	RADISH: "清脆的白萝卜，可食用可种植。",
	AIRCRAFT: "手持右键在身前的平地上放下一架。走近按 F 登机：W/S 油门，鼠标操纵杆，A/D 方向舵，空格刹车，再按 F 下机。",
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
	{"cost": 2, "result": FEATHER, "count": 5},
	{"cost": 3, "result": ARROW, "count": 8},
	{"cost": 3, "result": CARBON_ROD, "count": 2},
	{"cost": 6, "result": CRYSTAL, "count": 1},
	{"cost": 10, "result": SILVER_INGOT, "count": 1},
]

## 村庄收购（物资换绿宝石）：生存前期容易获得的物资打包出售。
## 与买入交易同一面板的「卖出」页签——前期砍树挖石收麦就能换到启动资金。
const SELL_TRADES := [
	{"item": BlockTypes.Block.WOOD, "count": 10},
	{"item": BlockTypes.Block.COBBLESTONE, "count": 12},
	{"item": BlockTypes.Block.SAND, "count": 12},
	{"item": WHEAT, "count": 6},
	{"item": FEATHER, "count": 6},
	{"item": STRING, "count": 4},
	{"item": RAW_BEEF, "count": 4},
	{"item": RAW_FISH, "count": 4},
]

## 收购打包价（绿宝石）：单件售价 × 件数 × 1.5 向上取整——
## 刻意比背包待售区的一键售卖划算 50%，奖励走村庄交易这条主动行为。
static func sell_bundle_price(item: int, count: int) -> int:
	return int(ceil(float(sell_price(item) * count) * 1.5))

## 珍稀材料的售价覆盖（按件计价，未列出的走分类默认价）。
const PRICE_OVERRIDE := {
	GOLD_INGOT: 12,
	SILVER_INGOT: 8,
	ALLOY_INGOT: 14,
	CRYSTAL: 10,
	EMERALD: 0,
	TOTEM: 9,
	HIDE: 5,
	FANG: 6,
}

## 垂钓可获得的战利品（权重抽取）：几乎都是鱼虾，偶尔混进水草。
const FISHING_LOOT := [
	{"item": RAW_FISH, "count": 2, "weight": 46},
	{"item": RAW_SHRIMP, "count": 2, "weight": 26},
	{"item": CRAB_MEAT, "count": 1, "weight": 16},
	{"item": BlockTypes.Block.WATERWEED, "count": 1, "weight": 8},
	{"item": CRYSTAL, "count": 1, "weight": 4},
]


## 创造模式快捷栏：建筑材料（虚拟满格供应）+ 常用工具（满耐久、不消耗）。
## 前 9 位与 BlockTypes.HOTBAR_BLOCKS 同序——探针与老玩家肌肉记忆都按
## 「1~9 号键 = 九种建材」依赖这个顺序，工具追加在其后。
const CREATIVE_HOTBAR: Array[int] = [
	BlockTypes.Block.GRASS,
	BlockTypes.Block.DIRT,
	BlockTypes.Block.STONE,
	BlockTypes.Block.SAND,
	BlockTypes.Block.WOOD,
	BlockTypes.Block.LEAVES,
	BlockTypes.Block.GLASS,
	BlockTypes.Block.COBBLESTONE,
	BlockTypes.Block.WATER,
	WOOD_PICKAXE,
	WOOD_AXE,
	WOOD_SHOVEL,
	WOOD_SICKLE,
	WOOD_BOW,
	WOOD_FISHING_ROD,
	BUCKET,
	AIRCRAFT,
]


static func is_tool_item(id: int) -> bool:
	return TOOL_TYPE.has(id)


static func tool_type(id: int) -> String:
	return TOOL_TYPE.get(id, "")


## 工具等级（1 木 / 2 石 / 3 青铜 / 4 铁）；非工具返回 -1。
static func tool_tier(id: int) -> int:
	return TOOL_TIER.get(id, -1)


static func tool_durability(id: int) -> int:
	return TOOL_DURABILITY.get(id, 0)


static func tool_speed(id: int) -> float:
	if TOOL_SPEED_BONUS.has(id):
		return float(TOOL_SPEED_BONUS[id])
	var tier := tool_tier(id)
	if tier <= 0:
		return 1.0
	return float(TIER_SPEED.get(tier, 1.0))


## 等级的中文称法（1~4 级）；越界返回空串。
static func tier_name(tier: int) -> String:
	return String(TIER_NAMES.get(tier, ""))


## 狩猎/采集工具的分类名（镐/斧/锹/镰刀/鱼竿/弓）。
static func tool_type_name(id: int) -> String:
	match tool_type(id):
		"pickaxe":
			return "镐"
		"axe":
			return "斧头"
		"shovel":
			return "铁锹"
		"sickle":
			return "镰刀"
		"rod":
			return "鱼竿"
		"bow":
			return "弓"
		_:
			return "工具"


static func is_bow(id: int) -> bool:
	return tool_type(id) == "bow"


static func is_rod(id: int) -> bool:
	return tool_type(id) == "rod"


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


## 蔬菜/小麦物品对应的作物方块；不可种植返回 AIR。
static func crop_of(id: int) -> int:
	return CROP_PLANTABLE.get(id, BlockTypes.Block.AIR)


## 非方块、非工具的普通物品（肉/骨/线/锭/材料），用于掉落物与手持模型着色。
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


## 可售卖给交易中心的物品：绿宝石本身与空气不可售，其余均可（含工具与食物）。
static func is_sellable(id: int) -> bool:
	if id == BlockTypes.Block.AIR or id == EMERALD:
		return false
	return id > 0


## 单件售价（绿宝石）：珍稀材料查覆盖表，其余按分类定价
## ——材料 3、工具 4、食物 2、方块 1。
static func sell_price(id: int) -> int:
	if PRICE_OVERRIDE.has(id):
		return int(PRICE_OVERRIDE[id])
	match category(id):
		1:
			return 4
		2:
			return 2
		3:
			return 3
		_:
			return 1


## 物品/方块的展示基色：工具按材质、普通物品查表、方块取顶面瓦片色。
static func item_color(id: int) -> Color:
	if is_tool_item(id):
		return TOOL_COLORS.get(id, Color(0.7, 0.7, 0.7))
	if ITEM_COLORS.has(id):
		return ITEM_COLORS.get(id, Color.WHITE)
	if BlockTypes.TILES.has(id):
		return TextureAtlas.tile_color(BlockTypes.TILES[id].x)
	return Color(0.8, 0.8, 0.8)


## 悬停简介文本：特殊条目查表，其余按分类生成。
static func item_description(id: int) -> String:
	if ITEM_DESCRIPTIONS.has(id):
		return ITEM_DESCRIPTIONS.get(id, "")
	if is_tool_item(id):
		if is_bow(id):
			return "%s：按住右键蓄力后松手射箭，伤害随蓄力提升，耐久 %d。" % [
				item_name(id), tool_durability(id)
			]
		if is_rod(id):
			return "%s：右键抛竿垂钓，耐久 %d。" % [item_name(id), tool_durability(id)]
		return "%d 级采集工具：速度 ×%d，耐久 %d。" % [
			tool_tier(id), int(tool_speed(id)), tool_durability(id)
		]
	if is_food(id):
		return "食用可恢复 %d 点饥饿。" % food_value(id)
	if is_plain_item(id):
		return "合成与交易用的材料。"
	return "可放置的建筑方块。"


static func is_placeable(id: int) -> bool:
	return BlockTypes.TILES.has(id) and id != BlockTypes.Block.AIR


## 垂钓战利品：按权重抽一件（返回 {item, count}）。
static func roll_fishing_loot() -> Dictionary:
	var total := 0
	for entry: Dictionary in FISHING_LOOT:
		total += int(entry["weight"])
	var r := randi() % maxi(total, 1)
	for entry: Dictionary in FISHING_LOOT:
		r -= int(entry["weight"])
		if r < 0:
			return {"item": int(entry["item"]), "count": int(entry["count"])}
	return {"item": RAW_FISH, "count": 1}
