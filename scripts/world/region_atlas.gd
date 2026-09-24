class_name RegionAtlas
## 世界地图册：11 个可进入区域（七大洲四大洋）的元数据 + 地形生成配置 + 地球掩码。
##
## 陆地掩码为 36×72 的等距圆柱网格（5° 一格）：第 0 行对应 85~90°N，
## 第 35 行对应 90~85°S；第 0 列对应 180~175°W，第 71 列对应 175~180°E。
## 掩码字母 N/S/E/A/F/O/T 分别对应北美洲/南美洲/欧洲/亚洲/非洲/大洋洲/南极洲，
## 其余格（'.'）按经纬度归入四大洋。
##
## 球面网格与鼠标点选共用 lat_lon_to_dir / dir_to_lat_lon 这一对逆函数，
## 因此“屏幕上看到的色块”与“点中的区域”严格一致，不会因投影方向差异错位。

const COLS := 72
const ROWS := 36
const CELL_DEG := 5.0
const LAT_TOP := 90.0
const LON_LEFT := -180.0

const PACIFIC := 0
const ATLANTIC := 1
const INDIAN := 2
const ARCTIC := 3
const ASIA := 4
const EUROPE := 5
const AFRICA := 6
const NORTH_AMERICA := 7
const SOUTH_AMERICA := 8
const OCEANIA := 9
const ANTARCTICA := 10
const COUNT := 11
const DEFAULT_REGION := ASIA

## 各区域在球体上的名称标签锚点（纬度, 经度）。
## 选在区域视觉中心附近，并与相邻区域/两极标记拉开距离避免文字重叠。
const REGION_ANCHORS := [
	Vector2(0.0, -150.0),    # 太平洋
	Vector2(10.0, -35.0),    # 大西洋
	Vector2(-25.0, 80.0),    # 印度洋
	Vector2(78.0, -45.0),    # 北冰洋
	Vector2(42.0, 95.0),     # 亚洲
	Vector2(53.0, 22.0),     # 欧洲
	Vector2(4.0, 18.0),      # 非洲
	Vector2(45.0, -101.0),   # 北美洲
	Vector2(-15.0, -60.0),   # 南美洲
	Vector2(-25.0, 140.0),   # 大洋洲
	Vector2(-76.0, 60.0),    # 南极洲
]

## 四大洋归属判据（仅用于掩码中的海洋格）。
const ARCTIC_MIN_LAT := 66.0
const ATLANTIC_LON := Vector2(-70.0, 20.0)
const INDIAN_LON := Vector2(20.0, 147.0)

const LAND_MASK := [
	"........................................................................",
	"....................NNNNNNNN............................................",
	"...............NNNNNNNNNNNNNNNNN........................................",
	"...........NNNNNNNNNNNNNNNNNNNNN.....EEEE.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
	"...NNNNNNNNNNNNNNNNNNNNNNNNNNNNNEEEEEEEEEEEAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
	"...NNNNNNNNNNNNNNNNNNNNNNNNNN..EEEEEEEEEEEEAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
	"...NNNNNNNNNNNNNNNNNNNNNNNNN......EEEEEEEEEAAAAAAAAAAAAAAAAAAAAAAAAAAAA.",
	".........NNNNNNNNNNNNNNNNN........EEEEEEEEEAAAAAAAAAAAAAAAAAAAAAAAAAAAA.",
	"...........NNNNNNNNNNNNNNN.........EEEEEEEEAAAAAAAAAAAAAAAAAAAAAA.......",
	"...........NNNNNNNNNNNNN..........EEEEEEEEEEAAAAAAAAAAAAAAAAAAAAAA......",
	"...........NNNNNNNNNNN............EEEEEEEAAAAAAAAAAAAAAAAAAAAAAAAAA.....",
	"............NNNNNNNNNN............FFFFFFFFFFAAAAAAAAAAAAAAAAAAAAAAA.....",
	".............NNNNNNNN............FFFFFFFFFFFAAAAAAAAAAAAAAAAA...........",
	"..............NNNN.NNN..........FFFFFFFFFFFFAAAAAAAAAAAAAAAAA...........",
	"...............NNNN.NNN.........FFFFFFFFFFFFFAA..AAAAAAAAAA.............",
	".................NNN.SSSS.......FFFFFFFFFFFFFF.....AA...AAA.............",
	"...................NNSSSSSS......FFFFFFFFFFFFFF...AA...AAA..AA..........",
	"....................SSSSSSS.......FFFFFFFFFFF........AAA.AA...OOOOO.....",
	"....................SSSSSSSSSS....FFFFFFFFFFF........AAA.AA...OOOOO.....",
	"....................SSSSSSSSSS...FFFFFFFFFFFF.FF......AAA..AAAOOOOO.....",
	".....................SSSSSSSS....FFFFFFFFFFFF.FF.........AAA.OOOOO......",
	"......................SSSSSSS....FFFFFFFFFFF.FF...........OOOOOOOO......",
	"......................SSSSSSS....FFFFFFFFFFFFF............OOOOOOOOO.....",
	"......................SSSSS.....FFFFFFFFFFF...............OOOOOOOOO.....",
	".....................SSSSS......FFFFFFFFFFF................OOOOOOOO...OO",
	".....................SSSS.......FFFFFFFFFF.....................OOO....OO",
	".....................SSS........................................OO...OO.",
	".....................SS..............................................OO.",
	".....................SS.................................................",
	".....................SS.................................................",
	".......................TTT..............................................",
	"TTTTTTTTTTTTTTTTTTTTTTTTT......TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
	"TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
	"TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
	"TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
	"TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
]

## 掩码字母 → 区域 ID。
const MASK_TO_REGION := {
	"N": NORTH_AMERICA,
	"S": SOUTH_AMERICA,
	"E": EUROPE,
	"A": ASIA,
	"F": AFRICA,
	"O": OCEANIA,
	"T": ANTARCTICA,
}

## 地球球体与图例配色（大陆偏绿/沙，海洋偏蓝，极地近白）。
const REGION_COLORS := [
	Color(0.16, 0.38, 0.66),
	Color(0.13, 0.32, 0.58),
	Color(0.14, 0.42, 0.62),
	Color(0.55, 0.72, 0.85),
	Color(0.45, 0.62, 0.28),
	Color(0.38, 0.68, 0.34),
	Color(0.78, 0.68, 0.34),
	Color(0.40, 0.60, 0.30),
	Color(0.30, 0.62, 0.32),
	Color(0.72, 0.62, 0.32),
	Color(0.86, 0.90, 0.94),
]

## 区域配置。字段说明：
##   title/subtitle/intro      区域名、地貌一句话、地理介绍
##   vegetation/creature/climate/scenery  加载页的四段介绍
##   seed                      本区独立随机种子（矿脉、树木、水体均已复现）
##   base_height/amplitude     地形基准高度与起伏幅度（海平面固定 22）
##   surface/surface_low       高于/低于 low_line 的地表方块
##   sub/sub_low               对应地下三格方块
##   low_line                  地表材质分界线
##   tree_density              每列生成树的概率
##   sky                       天空与光线的色调
##   passive/hostile           白天动物 / 夜晚敌对的加权生成表（空表即无该生态）
const REGIONS := [
	{
		"id": PACIFIC,
		"title": "太平洋",
		"subtitle": "世界最大的海洋",
		"intro": "地球上最大的海洋，面积约占地球表面的三分之一，海面上散布着无数岛屿。",
		"vegetation": "岛屿草木丛生、棕榈成片，浅滩处水草与藻类随波摇曳。",
		"creature": "岛上牛、羊、鸡栖息，近海水域可见鱼、虾与蟹。",
		"climate": "热带海洋性气候，温暖潮湿，午后多雷雨。",
		"scenery": "碧海环绕零星沙洲与绿岛，视野开阔。",
		"seed": 20260101,
		"base_height": 18.0,
		"amplitude": 9.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 25,
		"tree_density": 0.03,
		"sky": Color(0.92, 0.97, 1.0),
		"passive": {"COW": 3, "SHEEP": 2, "CHICKEN": 3},
		"hostile": {"ZOMBIE": 4, "SPIDER": 3},
	},
	{
		"id": ATLANTIC,
		"title": "大西洋",
		"subtitle": "呈 S 形的第二大洋",
		"intro": "世界第二大洋，南北狭长呈 S 形横贯地球，两岸海岸线曲折。",
		"vegetation": "岛屿多为温带草地与密林，林木比热带岛屿更密。",
		"creature": "牛、羊、鸡、猪俱全，近海鱼虾成群。",
		"climate": "温带海洋性气候，温和湿润，多雾。",
		"scenery": "深蓝海面托起苍翠岛屿，天色沉静。",
		"seed": 20260202,
		"base_height": 19.0,
		"amplitude": 9.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 24,
		"tree_density": 0.035,
		"sky": Color(0.94, 0.98, 1.0),
		"passive": {"COW": 3, "SHEEP": 3, "CHICKEN": 2, "PIG": 2},
		"hostile": {"ZOMBIE": 4, "SKELETON": 2, "WOLF": 2},
	},
	{
		"id": INDIAN,
		"title": "印度洋",
		"subtitle": "季风最典型的大洋",
		"intro": "世界第三大洋，大部分位于南半球，是季风气候最典型的大洋。",
		"vegetation": "岛礁以沙地与稀疏植被为主，池塘水面点缀荷叶与莲花。",
		"creature": "鸡与猪在沙滩上游荡，蜘蛛藏身礁石之间。",
		"climate": "热带气候，季风盛行，水温终年偏高。",
		"scenery": "碧绿海水与金色沙洲相接，明亮温暖。",
		"seed": 20260303,
		"base_height": 18.5,
		"amplitude": 10.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.SAND,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 26,
		"tree_density": 0.04,
		"sky": Color(1.0, 0.97, 0.92),
		"passive": {"CHICKEN": 4, "PIG": 3, "COW": 2},
		"hostile": {"SPIDER": 4, "ZOMBIE": 3},
	},
	{
		"id": ARCTIC,
		"title": "北冰洋",
		"subtitle": "最小最浅的大洋",
		"intro": "四大洋中面积最小、深度最浅的一个，洋面大部分终年被海冰覆盖。",
		"vegetation": "冰原上不长任何植物，只有积雪与浮冰。",
		"creature": "没有动物长期停留，天地间只剩风声与你的脚印。",
		"climate": "极地海洋性气候，终年严寒，风雪不止。",
		"scenery": "浮冰与雪岛散落海面，一片素白。",
		"seed": 20260404,
		"base_height": 21.0,
		"amplitude": 7.0,
		"surface": BlockTypes.Block.SNOW,
		"surface_low": BlockTypes.Block.SNOW,
		"sub": BlockTypes.Block.SNOW,
		"sub_low": BlockTypes.Block.SNOW,
		"low_line": 100,
		"tree_density": 0.0,
		"sky": Color(0.88, 0.94, 1.0),
		"passive": {},
		"hostile": {},
	},
	{
		"id": ASIA,
		"title": "亚洲",
		"subtitle": "面积最大的洲",
		"intro": "面积最大的洲，东临太平洋、南接印度洋，从北方雪原一直延伸到南方雨林。",
		"vegetation": "北方针叶林与草原相接，南方草木成片，森林疏密适中。",
		"creature": "牛、羊、鸡、猪成群游荡；夜里僵尸、骷髅与蜘蛛在黑暗中出没。",
		"climate": "季风气候显著，四季分明，雨季与干季交替。",
		"scenery": "连绵丘陵、开阔草原与成片树林交错，是最经典的方块大陆。",
		"seed": 12345,
		"base_height": 28.0,
		"amplitude": 10.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 22,
		"tree_density": 0.02,
		"sky": Color(1.0, 1.0, 1.0),
		"passive": {"COW": 4, "SHEEP": 3, "CHICKEN": 2, "PIG": 2},
		"hostile": {"ZOMBIE": 4, "SKELETON": 3, "SPIDER": 2, "WOLF": 1},
	},
	{
		"id": EUROPE,
		"title": "欧洲",
		"subtitle": "海岸线最曲折的洲",
		"intro": "位于亚欧大陆西端，海岸线曲折，半岛与岛屿密布，几乎没有荒漠。",
		"vegetation": "温带落叶林覆盖低地，林木密度明显高于其他大陆。",
		"creature": "牛羊成群，林间狼群活跃，夜晚须当心。",
		"climate": "温带海洋性气候，温和湿润，冬季少见酷寒。",
		"scenery": "平缓丘陵与密林相连，天空清冷明亮。",
		"seed": 20260505,
		"base_height": 29.0,
		"amplitude": 8.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 22,
		"tree_density": 0.035,
		"sky": Color(0.96, 0.98, 1.0),
		"passive": {"COW": 4, "SHEEP": 4, "CHICKEN": 2},
		"hostile": {"ZOMBIE": 3, "WOLF": 4, "SKELETON": 3},
	},
	{
		"id": AFRICA,
		"title": "非洲",
		"subtitle": "沙漠与热带草原",
		"intro": "横跨赤道的大陆，北部是世界最大的撒哈拉沙漠，南部为高原与草原。",
		"vegetation": "沙漠区寸草不生，草原上点缀着稀疏的树木。",
		"creature": "羊群与牛群在草原游荡，蜘蛛在沙丘间伺机而动。",
		"climate": "热带气候，干燥炎热，昼夜温差大。",
		"scenery": "金色沙丘与稀疏草原相接，天空泛暖黄。",
		"seed": 20260606,
		"base_height": 28.0,
		"amplitude": 11.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 32,
		"tree_density": 0.012,
		"sky": Color(1.0, 0.95, 0.86),
		"passive": {"COW": 3, "SHEEP": 4, "CHICKEN": 2, "PIG": 1},
		"hostile": {"SPIDER": 4, "ZOMBIE": 3, "SKELETON": 3},
	},
	{
		"id": NORTH_AMERICA,
		"title": "北美洲",
		"subtitle": "山脉纵贯的大陆",
		"intro": "西临太平洋、东濒大西洋，中部是辽阔平原，两侧山脉纵贯南北。",
		"vegetation": "针叶林与阔叶林混生，林带连绵不断。",
		"creature": "牛、猪、羊、鸡俱全，狼群在夜间结队巡行。",
		"climate": "温带大陆性气候，冬冷夏热，降水自东向西递减。",
		"scenery": "起伏山脊与平原交错，地形起伏最为丰富。",
		"seed": 20260707,
		"base_height": 28.0,
		"amplitude": 11.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 22,
		"tree_density": 0.028,
		"sky": Color(1.0, 1.0, 1.0),
		"passive": {"COW": 4, "PIG": 3, "SHEEP": 3, "CHICKEN": 2},
		"hostile": {"ZOMBIE": 4, "SKELETON": 3, "SPIDER": 2, "WOLF": 3},
	},
	{
		"id": SOUTH_AMERICA,
		"title": "南美洲",
		"subtitle": "安第斯与亚马孙",
		"intro": "美洲大陆南部，西侧是狭长的安第斯山脉，东部是茂密的亚马孙雨林。",
		"vegetation": "热带雨林极其茂密，树木密度为全图最高。",
		"creature": "鸡、猪、牛成群，蜘蛛在雨林中大量出没。",
		"climate": "热带雨林气候，高温多雨，全年湿润。",
		"scenery": "高耸山脊与浓密雨林相接，天光微绿。",
		"seed": 20260808,
		"base_height": 27.0,
		"amplitude": 13.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 22,
		"tree_density": 0.05,
		"sky": Color(0.97, 1.0, 0.96),
		"passive": {"CHICKEN": 4, "PIG": 4, "COW": 3, "SHEEP": 2},
		"hostile": {"SPIDER": 4, "ZOMBIE": 2, "SKELETON": 2},
	},
	{
		"id": OCEANIA,
		"title": "大洋洲",
		"subtitle": "荒漠与草原之洲",
		"intro": "位于南半球，由澳大利亚大陆与众多岛屿组成，中部是大片荒漠。",
		"vegetation": "内陆荒漠植被稀疏，沿海与岛屿草木较盛。",
		"creature": "羊群数量最多，牛与鸡零星分布在草原上。",
		"climate": "热带与亚热带气候，干旱少雨，日照强烈。",
		"scenery": "低矮沙地与零散草原相接，天空泛暖。",
		"seed": 20260909,
		"base_height": 27.0,
		"amplitude": 9.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 30,
		"tree_density": 0.02,
		"sky": Color(1.0, 0.97, 0.9),
		"passive": {"SHEEP": 5, "COW": 3, "CHICKEN": 2},
		"hostile": {"SPIDER": 3, "ZOMBIE": 3, "SKELETON": 2},
	},
	{
		"id": ANTARCTICA,
		"title": "南极洲",
		"subtitle": "终年冰封的大陆",
		"intro": "地球最南端的大陆，终年冰封，是平均海拔最高的一洲。",
		"vegetation": "冰原上没有任何植物，只有无边的雪层。",
		"creature": "没有陆生动物出没，雪地上只留下你自己的足迹。",
		"climate": "极地气候，酷寒干燥，风雪常年不歇。",
		"scenery": "纯白雪原起伏延伸，天地一片素白。",
		"seed": 20261010,
		"base_height": 26.0,
		"amplitude": 8.0,
		"surface": BlockTypes.Block.SNOW,
		"surface_low": BlockTypes.Block.SNOW,
		"sub": BlockTypes.Block.SNOW,
		"sub_low": BlockTypes.Block.SNOW,
		"low_line": 100,
		"tree_density": 0.0,
		"sky": Color(0.9, 0.95, 1.0),
		"passive": {},
		"hostile": {},
	},
]


## 经纬度（度，北纬/东经为正）→ 单位方向向量。
## 与 dir_to_lat_lon 互为逆函数，球体网格与点选共用，保证几何与拾取一致。
static func lat_lon_to_dir(lat_deg: float, lon_deg: float) -> Vector3:
	var la := deg_to_rad(lat_deg)
	var lo := deg_to_rad(lon_deg)
	return Vector3(cos(la) * sin(lo), sin(la), cos(la) * cos(lo))


## 单位方向向量 → Vector2(纬度, 经度)，单位为度。
static func dir_to_lat_lon(dir: Vector3) -> Vector2:
	var d := dir.normalized()
	return Vector2(rad_to_deg(asin(clampf(d.y, -1.0, 1.0))), rad_to_deg(atan2(d.x, d.z)))


## 经纬度 → 区域 ID（含四大洋归属判定）。
static func region_at_lat_lon(lat: float, lon: float) -> int:
	var row := clampi(int(floor((LAT_TOP - lat) / CELL_DEG)), 0, ROWS - 1)
	var col := clampi(int(floor((lon - LON_LEFT) / CELL_DEG)), 0, COLS - 1)
	return region_of_cell(row, col)


## 掩码格 → 区域 ID：陆地取掩码字母，海洋按经纬度归入四大洋。
static func region_of_cell(row: int, col: int) -> int:
	var ch: String = LAND_MASK[row].substr(col, 1)
	if MASK_TO_REGION.has(ch):
		return MASK_TO_REGION[ch]
	var lat := LAT_TOP - (float(row) + 0.5) * CELL_DEG
	var lon := LON_LEFT + (float(col) + 0.5) * CELL_DEG
	if lat > ARCTIC_MIN_LAT:
		return ARCTIC
	if lon > ATLANTIC_LON.x and lon <= ATLANTIC_LON.y:
		return ATLANTIC
	if lon > INDIAN_LON.x and lon <= INDIAN_LON.y:
		return INDIAN
	return PACIFIC


static func profile(region_id: int) -> Dictionary:
	return REGIONS[clampi(region_id, 0, COUNT - 1)]


static func title_of(region_id: int) -> String:
	return String(profile(region_id)["title"])


static func color_of(region_id: int) -> Color:
	return REGION_COLORS[clampi(region_id, 0, COUNT - 1)]


## 掩码自检：每行必须恰好 COLS 个字符，且不含有未知字母。
static func mask_is_valid() -> bool:
	if LAND_MASK.size() != ROWS:
		return false
	for row: String in LAND_MASK:
		if row.length() != COLS:
			return false
		for i in COLS:
			var ch := row.substr(i, 1)
			if ch != "." and not MASK_TO_REGION.has(ch):
				return false
	return true
