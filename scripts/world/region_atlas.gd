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

## 各区域地理知识卡片（按 region_id 索引，每区域 3 张）。
## art 为程序化剪影类型（map_selector._draw_art 分派），tint 为插图主色。
const REGION_CARDS := [
	[
		{"title": "马里亚纳海沟", "text": "地球最深处，深约 11 公里，能把珠穆朗玛峰整个放进去。", "art": "trench", "tint": Color(0.16, 0.30, 0.52)},
		{"title": "台风", "text": "温暖海水「喂大」的巨型空气旋涡，中心风眼安静得像操场。", "art": "storm", "tint": Color(0.30, 0.45, 0.70)},
		{"title": "环礁岛屿", "text": "海底火山顶上长出的珊瑚花环，岛屿中间围着蓝色的潟湖。", "art": "reef", "tint": Color(0.25, 0.62, 0.66)},
	],
	[
		{"title": "墨西哥湾流", "text": "一条海上「暖气管道」，把热带的温暖送到欧洲沿岸。", "art": "wave", "tint": Color(0.22, 0.48, 0.72)},
		{"title": "中大西洋海脊", "text": "海底的巨型山脉，板块在这里慢慢生长、把大西洋越撑越宽。", "art": "rift", "tint": Color(0.30, 0.42, 0.62)},
		{"title": "马尾藻海", "text": "会「长草原」的海，金色马尾藻聚成一片，海龟千里迢迢来产卵。", "art": "wave", "tint": Color(0.42, 0.58, 0.52)},
	],
	[
		{"title": "印度洋季风", "text": "古代商船靠着冬夏方向相反的风，往返于香料之路。", "art": "wave", "tint": Color(0.35, 0.55, 0.70)},
		{"title": "马达加斯加", "text": "约 8800 万年前与非洲分离，狐猴等动物只住在这座大岛上。", "art": "forest", "tint": Color(0.28, 0.55, 0.30)},
		{"title": "珍珠与珊瑚", "text": "温暖清澈的海水里，贝类孕育出珍贵的天然珍珠。", "art": "reef", "tint": Color(0.75, 0.55, 0.62)},
	],
	[
		{"title": "漂浮的海冰", "text": "北冰洋大部分洋面终年结冰，冰面随季节胀缩，北极熊在冰上捕猎。", "art": "ice", "tint": Color(0.55, 0.72, 0.88)},
		{"title": "北极熊", "text": "世界上最大的陆地食肉动物，毛发其实是透明中空的。", "art": "polar_bear", "tint": Color(0.88, 0.92, 0.96)},
		{"title": "极夜与极光", "text": "漫长黑夜里，太阳风点亮夜空，绿色光带翩翩起舞。", "art": "aurora", "tint": Color(0.35, 0.75, 0.60)},
	],
	[
		{"title": "珠穆朗玛峰", "text": "世界最高峰，高 8848.86 米，而且还在慢慢「长高」。", "art": "mountain", "tint": Color(0.62, 0.55, 0.48)},
		{"title": "大熊猫", "text": "只生活在中国山区的「活化石」，每天要吃 12 小时以上的竹子。", "art": "panda", "tint": Color(0.90, 0.90, 0.92)},
		{"title": "季风气候", "text": "夏天海风带来大雨滋润稻田，冬天则换成干燥的北风。", "art": "storm", "tint": Color(0.45, 0.60, 0.75)},
	],
	[
		{"title": "阿尔卑斯山", "text": "欧洲的屋脊，冰川把山谷刻成 U 形，融雪积成蓝绿色湖泊。", "art": "mountain", "tint": Color(0.55, 0.60, 0.72)},
		{"title": "多瑙河", "text": "流经 10 个国家的国际河流，沿岸响起过无数圆舞曲。", "art": "wave", "tint": Color(0.35, 0.55, 0.75)},
		{"title": "北极光", "text": "太阳风撞上地球磁场，高纬度的夜空舞动起彩带。", "art": "aurora", "tint": Color(0.45, 0.70, 0.85)},
	],
	[
		{"title": "撒哈拉沙漠", "text": "世界最大的热沙漠，面积接近整个中国，昼夜温差极大。", "art": "dune", "tint": Color(0.85, 0.64, 0.25)},
		{"title": "东非大裂谷", "text": "板块正在张裂的巨大伤痕，几百万年后可能变成新的大洋。", "art": "rift", "tint": Color(0.72, 0.48, 0.26)},
		{"title": "热带草原", "text": "狮子、长颈鹿和斑马的家园，每年上演百万角马大迁徙。", "art": "lion", "tint": Color(0.85, 0.68, 0.30)},
	],
	[
		{"title": "科罗拉多大峡谷", "text": "河流切割 500 万年凿出的深谷，岩层像千层蛋糕记录地球历史。", "art": "rift", "tint": Color(0.75, 0.45, 0.30)},
		{"title": "密西西比河", "text": "北美最大的河流体系，蜿蜒滋养着两岸的大平原。", "art": "wave", "tint": Color(0.30, 0.50, 0.68)},
		{"title": "龙卷风走廊", "text": "全球约八成的龙卷风发生在美国大平原上。", "art": "storm", "tint": Color(0.42, 0.48, 0.62)},
	],
	[
		{"title": "亚马逊雨林", "text": "被称为「地球之肺」，每平方公里住着上百种树木。", "art": "forest", "tint": Color(0.22, 0.55, 0.26)},
		{"title": "安第斯山脉", "text": "世界最长的山脉，南北绵延约 7000 公里。", "art": "mountain", "tint": Color(0.60, 0.52, 0.44)},
		{"title": "伊瓜苏瀑布", "text": "由 275 股瀑布组成的水帘墙，横跨两国边界。", "art": "waterfall", "tint": Color(0.38, 0.62, 0.78)},
	],
	[
		{"title": "大堡礁", "text": "世界最大的珊瑚礁群，全长 2000 多公里，从太空都能看见。", "art": "reef", "tint": Color(0.30, 0.68, 0.62)},
		{"title": "乌鲁鲁巨石", "text": "会随日照变色的红色巨石，是当地原住民的圣地。", "art": "rock", "tint": Color(0.75, 0.40, 0.24)},
		{"title": "袋鼠", "text": "只会向前跳、不会倒退的动物，还登上了澳大利亚国徽。", "art": "kangaroo", "tint": Color(0.78, 0.55, 0.34)},
	],
	[
		{"title": "巨厚冰盖", "text": "储存全球约七成淡水，冰盖最厚处超过 4700 米。", "art": "ice", "tint": Color(0.72, 0.84, 0.95)},
		{"title": "帝企鹅", "text": "唯一在南极过冬的企鹅，孵蛋的任务交给企鹅爸爸。", "art": "penguin", "tint": Color(0.25, 0.28, 0.36)},
		{"title": "极昼与极夜", "text": "夏天太阳整日不落，冬天黑夜一过就是好几个月。", "art": "sun", "tint": Color(0.92, 0.72, 0.30)},
	],
]


## 各区域地标（按 region_id 索引，条数不限，与 REGION_CARDS 同构）。
## 每个地标字段：
##   title  地标名
##   kind   类型（见下方 kind 说明），决定球面上的图钉形状与配色
##   lat/lon 真实经纬度（北纬/东经为正）的代表点；河流类同时给出 path
##   text   儿童向科普一句话（照抄 REGION_CARDS 的语气：一句大白话讲清一个知识点）
##   path   仅河流类：沿河道的若干采样点 [Vector2(纬, 经), ...]，地球上据此
##          串成一串小方块组成「流动光带」；lat/lon 取其中一处代表点（用于图钉与拾取）
##   tint   仅河流类：光带颜色（长江浅蓝 / 黄河土黄），字段名沿用 REGION_CARDS
##
## kind 的枚举（前五项是约定好的基本地貌，后两项是为了不歪曲事实而补的）：
##   "mountain"  山：方块阶梯状金字塔（本作画风）
##   "river"     江/河/洋流：沿 path 的一串小方块 + 脉冲透明度
##   "gorge"     谷（含海底海沟）：两块夹峙的窄高块
##   "plateau"   高而平的一大片（高原 / 冰盖 / 冰原）
##   "lake"      湖：扁圆盘
##   "reef"      珊瑚礁：一圈环形小方块（大堡礁、环礁岛用得上）
##   "monolith"  孤立的巨岩/石像：单个矮圆丘（乌鲁鲁、复活节岛石像）
##
## ── 为什么这里没有「地标 → 世界坐标」的字段 ──
## 设计文档要求把三山五岳按真实地理比例铺到 128 km 平面上。做不了：
## 玩家活动范围只在原点附近数百米（流送高模 64 m / 低模 256 m），
## 按真实比例换算出的落点玩家到不了、区块也不会加载，世界里更没有地标建筑。
## 所以地标只有两处呈现：① 地球上的图钉 + 脉冲光带；② 区域介绍页的知识卡。
## 「快速旅行」的语义因此改成「进入该地标所属区域」并落在该区域现成的
## 机场/降落场（走既有 region_entered 链路），而不是传送到地标精确坐标
## ——map_selector 的介绍页按钮文案必须写诚实（「去亚洲看看」而非「降落在泰山」）。
##
## ── 归档口径说明 ──
## 地标按「知识归属」归档，个别条目与 5° 粗掩码的判定不同，属已知且可接受：
##   · 马里亚纳海沟（142°E）：掩码的印度洋/太平洋分界画在 147°E，
##     真实坐标落在印度洋格上；两侧同为海蓝色球格，不影响观感判定。
##   · 马达加斯加：掩码把它并入非洲陆块（地理上它确属非洲），但本作印度洋的
##     知识卡原本就在讲它，故按知识归属挂在印度洋下。
const REGION_LANDMARKS := [
	[
		{"title": "马里亚纳海沟", "kind": "gorge", "lat": 11.35, "lon": 142.20,
			"text": "地球最深的地方，深约 11 公里——把珠穆朗玛峰整个放进去，山顶离水面还有 2 公里。"},
		{"title": "夏威夷群岛", "kind": "mountain", "lat": 19.60, "lon": -155.50,
			"text": "一串由「热点」造出来的火山岛：地幔里固定不动的热柱往上顶，板块慢慢漂过去，就串成一串。"},
		{"title": "复活节岛", "kind": "monolith", "lat": -27.10, "lon": -109.30,
			"text": "太平洋上最偏远的岛之一，数百尊巨大石像摩艾背海向着内陆站立；岛上森林曾被砍光，是生态课上的著名教训。"},
	],
	[
		{"title": "墨西哥湾流", "kind": "river", "lat": 37.00, "lon": -60.00,
			"tint": Color(0.32, 0.62, 0.86),
			"path": [Vector2(34.00, -68.00), Vector2(37.00, -60.00), Vector2(40.00, -52.00), Vector2(43.00, -45.00)],
			"text": "海里的一条「温水管道」：加勒比海的暖水沿北美东岸北上，再横穿大洋把温暖送到欧洲沿岸。"},
		{"title": "中大西洋海脊", "kind": "gorge", "lat": 0.00, "lon": -25.00,
			"text": "大西洋底下绵延上万公里的海底山脉，板块从这里向两侧生长，大洋正在一点点变宽。"},
	],
	[
		{"title": "马达加斯加", "kind": "plateau", "lat": -19.00, "lon": 46.80,
			"text": "约 8800 万年前从非洲旁边分家出来的大岛，狐猴这些动物只住在这里，一座岛上就有几万种别处没有的物种。"},
		{"title": "马尔代夫环礁", "kind": "reef", "lat": 3.50, "lon": 73.00,
			"text": "海底火山慢慢下沉，珊瑚一路往上长，最后留下一圈环形的珊瑚岛；全国平均海拔只有 1 米多。"},
	],
	[
		{"title": "北极点", "kind": "plateau", "lat": 89.90, "lon": 0.00,
			"text": "地球自转轴的最北端，站在那儿四周都是北；脚下是漂在海上的浮冰，没有一块陆地。"},
		{"title": "白令海峡", "kind": "gorge", "lat": 65.80, "lon": -168.50,
			"text": "亚洲与北美洲之间最窄的海峡，最窄处约 82 公里；冰期海平面下降时这里露出过陆桥，人类正是走过它进入美洲。"},
	],
	[
		{"title": "泰山", "kind": "mountain", "lat": 36.25, "lon": 117.10,
			"text": "五岳之首，历代帝王在这里祭天；从山脚到山顶有七千多级台阶，全程登顶要走一整天。"},
		{"title": "华山", "kind": "mountain", "lat": 34.48, "lon": 110.08,
			"text": "五岳里最陡的一座，整块花岗岩被抬起来形成近乎垂直的崖壁，最窄的路勉强只容一人通过。"},
		{"title": "衡山", "kind": "mountain", "lat": 27.28, "lon": 112.60,
			"text": "五岳里最靠南的一座，常年云雾缭绕，山上能同时看见茂密的竹林与冬天的雾凇。"},
		{"title": "恒山", "kind": "mountain", "lat": 39.66, "lon": 113.60,
			"text": "五岳里最靠北的一座，悬空寺靠几根木柱撑在崖壁上，已经立了一千五百多年。"},
		{"title": "嵩山", "kind": "mountain", "lat": 34.50, "lon": 113.00,
			"text": "五岳居中，少林寺就在山里；这里的岩层一层压一层，地质学家叫它「五代同堂」。"},
		{"title": "黄山", "kind": "mountain", "lat": 30.13, "lon": 118.16,
			"text": "「三山」之一（三山是哪三座说法不一，这里取黄山、庐山、雁荡山这一版）；花岗岩峰林配云海，迎客松就长在崖边上。"},
		{"title": "长江", "kind": "river", "lat": 30.60, "lon": 114.30,
			"tint": Color(0.38, 0.68, 0.95),
			"path": [Vector2(33.40, 91.00), Vector2(28.80, 104.60), Vector2(29.60, 106.50),
				Vector2(30.60, 114.30), Vector2(32.10, 118.80), Vector2(31.40, 121.80)],
			"text": "中国第一长河，6300 多公里，从青藏高原一路向东汇入东海；它和黄河一起被称为中华文明的母亲河。"},
		{"title": "黄河", "kind": "river", "lat": 36.10, "lon": 103.80,
			"tint": Color(0.88, 0.68, 0.24),
			"path": [Vector2(35.00, 96.00), Vector2(36.10, 103.80), Vector2(40.30, 107.00),
				Vector2(34.60, 110.30), Vector2(34.90, 113.60), Vector2(37.80, 119.00)],
			"text": "中国第二长河，中游流过黄土高原带走大量黄沙，河水常年发黄而得名；入海口每年还在向海里长出新陆地。"},
		{"title": "长江三峡", "kind": "gorge", "lat": 30.85, "lon": 111.00,
			"text": "瞿塘峡、巫峡、西陵峡的总称，长江切开巫山形成的三段深谷，两岸最窄处不足百米。"},
		{"title": "青藏高原", "kind": "plateau", "lat": 33.00, "lon": 88.00,
			"text": "世界最高最年轻的高原，平均海拔四千米以上，是长江与黄河共同的发源地，被称为「世界屋脊」。"},
		{"title": "珠穆朗玛峰", "kind": "mountain", "lat": 27.99, "lon": 86.93,
			"text": "位于喜马拉雅山脉的世界最高峰，海拔 8848.86 米；印度板块还在向北挤，它每年仍长高几毫米。"},
	],
	[
		{"title": "阿尔卑斯山", "kind": "mountain", "lat": 45.98, "lon": 6.88,
			"text": "欧洲的屋脊，横跨 8 个国家；冰川把山谷磨成 U 形，最高峰勃朗峰海拔 4808 米。"},
		{"title": "多瑙河", "kind": "river", "lat": 48.20, "lon": 16.40,
			"tint": Color(0.36, 0.56, 0.82),
			"path": [Vector2(48.20, 16.40), Vector2(47.50, 19.05), Vector2(43.70, 25.50)],
			"text": "流经 10 个国家的国际河流，全长约 2850 公里；它在三角洲汇入黑海，那里是欧洲最大的湿地。"},
		{"title": "挪威峡湾", "kind": "gorge", "lat": 60.50, "lon": 7.00,
			"text": "冰川掏出来的深长海谷，两侧崖壁直落上千米，最深的松恩峡湾深达 1300 米。"},
	],
	[
		{"title": "乞力马扎罗山", "kind": "mountain", "lat": -3.07, "lon": 37.35,
			"text": "非洲最高峰，海拔 5895 米，是赤道附近唯一常年积雪的山；山顶冰川正在一年年变薄。"},
		{"title": "尼罗河", "kind": "river", "lat": 24.00, "lon": 32.90,
			"tint": Color(0.40, 0.62, 0.80),
			"path": [Vector2(0.40, 33.20), Vector2(15.50, 32.50), Vector2(24.00, 32.90), Vector2(31.40, 30.40)],
			"text": "约 6650 公里长，一路向北穿过沙漠注入地中海；古埃及文明就诞生在它每年泛滥留下的沃土上。"},
		{"title": "撒哈拉沙漠", "kind": "plateau", "lat": 23.00, "lon": 13.00,
			"text": "世界最大的热沙漠，面积约 900 万平方公里；白天地面能烤到 60℃，夜里却又降到零度以下。"},
	],
	[
		{"title": "落基山脉", "kind": "mountain", "lat": 43.70, "lon": -110.80,
			"text": "北美西部的脊梁，南北绵延约 4800 公里；它挡住了西边的海风，山两边完全是两种气候。"},
		{"title": "密西西比河", "kind": "river", "lat": 38.80, "lon": -90.20,
			"tint": Color(0.34, 0.54, 0.78),
			"path": [Vector2(44.00, -93.00), Vector2(38.80, -90.20), Vector2(35.00, -90.05), Vector2(29.00, -89.30)],
			"text": "北美最大的河流体系，干流约 3766 公里；连同支流一共哺育了美国境内 31 个州的土地。"},
		{"title": "科罗拉多大峡谷", "kind": "gorge", "lat": 36.10, "lon": -112.10,
			"text": "科罗拉多河用几百万年切出的深谷，最深 1600 多米；两岸层层叠叠的岩石像一本摊开的地球历史书。"},
	],
	[
		{"title": "安第斯山脉", "kind": "mountain", "lat": -13.10, "lon": -72.50,
			"text": "世界最长的山脉，南北绵延约 7000 公里；它沿板块边界被顶起来，至今仍有大量活火山。"},
		{"title": "亚马逊河", "kind": "river", "lat": -3.10, "lon": -60.00,
			"tint": Color(0.30, 0.66, 0.72),
			"path": [Vector2(-4.50, -73.50), Vector2(-3.10, -60.00), Vector2(-2.00, -54.00), Vector2(-0.50, -50.00)],
			"text": "流量世界第一的河，每秒入海的水约 21 万立方米；两岸的热带雨林被称为「地球之肺」。"},
		{"title": "的的喀喀湖", "kind": "lake", "lat": -15.80, "lon": -69.30,
			"text": "世界最高的大型淡水湖，湖面海拔约 3812 米；因为空气稀薄，这里的阳光和昼夜温差都特别大。"},
	],
	[
		{"title": "大堡礁", "kind": "reef", "lat": -18.30, "lon": 147.70,
			"text": "世界最大的珊瑚礁群，由近 3000 个礁体组成，绵延 2300 多公里，是地球上最大的「活建筑」。"},
		{"title": "乌鲁鲁巨石", "kind": "monolith", "lat": -25.30, "lon": 131.00,
			"text": "一整块红色砂岩，露出地面 348 米，地下还埋着很大一截；日出日落时整块会变色，是当地原住民的圣地。"},
		{"title": "南阿尔卑斯山", "kind": "mountain", "lat": -43.60, "lon": 170.10,
			"text": "新西兰南岛的脊梁，最高峰库克山 3724 米；山顶四季积雪，冰川从两侧垂下来。"},
	],
	[
		{"title": "南极点", "kind": "plateau", "lat": -89.90, "lon": 0.00,
			"text": "地球自转轴的最南端，站在那儿朝哪个方向都是北；脚下是两千多米厚的冰层，底下才是陆地。"},
		{"title": "南极冰盖", "kind": "plateau", "lat": -80.00, "lon": 0.00,
			"text": "盖住整个南极洲的巨大冰层，储存着全球约七成的淡水；如果全部融化，海平面会上升约 58 米。"},
		{"title": "埃里伯斯火山", "kind": "mountain", "lat": -77.50, "lon": 167.20,
			"text": "地球最南端的活火山，海拔 3794 米；山顶常年冒着一柱蒸汽，火山口里有一小池不会凝固的岩浆。"},
	],
]


static func cards_of(region_id: int) -> Array:
	var clamped := clampi(region_id, 0, COUNT - 1)
	var cards: Array = REGION_CARDS[clamped]
	return cards


## 该区域的地标列表（带越界保护：越界返回空数组而不是崩溃）。
static func landmarks_of(region_id: int) -> Array:
	# 越界一律返回空，**不**做 clampi 夹取：夹取会把「调用方传错区域 id」这种
	# bug 静默伪装成「取到另一个区域的地标」（-3 → 太平洋、999 → 南极洲），
	# 出错时现象完全对不上原因。宁可返回空让上层立刻暴露。
	# （与 cards_of 的 clampi 口径不同——那份是既有实现且有探针依赖，不动。）
	if region_id < 0 or region_id >= COUNT:
		return []
	if REGION_LANDMARKS.size() != COUNT:
		return []
	var marks: Array = REGION_LANDMARKS[region_id]
	return marks

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
##   water                     水体策略："normal" 常规海平面注水；
##                             "dry" 沙漠不生河塘（非洲/大洋洲）；
##                             "iceberg" 极地一望无际的封冻冰海 + 冰山（北极/南极）
##   surface/surface_low       高于/低于 low_line 的地表方块
##   sub/sub_low               对应地下三格方块
##   low_line                  地表材质分界线
##   tree_density              每列生成树的概率
##   sky                       天空与光线的色调
##   passive/hostile           白天动物 / 夜晚敌对的加权生成表（空表即无该生态）
##   weather_profile           飞行气象参数（详见 weather_profile_of 上方注释）：
##                             surface_wind_mps 地面基准风速（m/s，风梯度从此值升到约 3 倍）、
##                             shear_probability 风切变触发概率（0..1）。
##                             由 scripts/flight/wind_model.gd 的 WindModel 读取，
##                             本文件只配数据，不在此实现风场。
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
		"water": "normal",
		"has_landing_field": true,
		"base_height": 18.0,
		"amplitude": 9.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 25,
		"tree_density": 0.03,
		"sky": Color(0.92, 0.97, 1.0),
		"passive": {"COW": 3, "SHEEP": 2, "CHICKEN": 3, "BUTTERFLY": 3},
		"hostile": {"ZOMBIE": 4, "SPIDER": 3},
		# 远洋信风带：海面摩擦力小、基础风速全图前列；暖水面午后雷雨对流旺，
		# 风切变概率高但仍在儿童可玩范围内（侧风约为巡航速度的一成多）。
		"weather_profile": {
			"surface_wind_mps": 7.0,
			"shear_probability": 0.6,
		},
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
		"water": "normal",
		"has_landing_field": true,
		"base_height": 19.0,
		"amplitude": 9.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 24,
		"tree_density": 0.035,
		"sky": Color(0.94, 0.98, 1.0),
		"passive": {"COW": 3, "SHEEP": 3, "CHICKEN": 2, "PIG": 2, "BUTTERFLY": 3},
		"hostile": {"ZOMBIE": 4, "SKELETON": 2, "WOLF": 2},
		# 第二大洋，风况略逊太平洋：湾流沿线多雾、温带气团交互频繁，切变概率次高。
		"weather_profile": {
			"surface_wind_mps": 6.5,
			"shear_probability": 0.55,
		},
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
		"water": "normal",
		"has_landing_field": true,
		"base_height": 18.5,
		"amplitude": 10.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.SAND,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 26,
		"tree_density": 0.04,
		"sky": Color(1.0, 0.97, 0.92),
		"passive": {"CHICKEN": 4, "PIG": 3, "COW": 2, "BUTTERFLY": 3},
		"hostile": {"SPIDER": 4, "ZOMBIE": 3},
		# 季风最典型的大洋：季风期风向风速反差极大、对流极旺，切变概率全图最高。
		"weather_profile": {
			"surface_wind_mps": 6.0,
			"shear_probability": 0.7,
		},
	},
	{
		"id": ARCTIC,
		"title": "北冰洋",
		"subtitle": "最小最浅的大洋",
		"intro": "四大洋中面积最小、深度最浅的一个，洋面大部分终年被海冰覆盖。",
		"vegetation": "冰原上不长任何植物，只有积雪与浮冰。",
		"creature": "没有动物长期停留，天地间只剩风声与你的脚印。",
		"climate": "极地海洋性气候，终年严寒，风雪不止。",
		"scenery": "一望无际的封冻冰海，巨大的冰山零零散散立在海面上。",
		"seed": 20260404,
		"water": "iceberg",
		"has_landing_field": true,
		"base_height": 16.0,
		"amplitude": 5.0,
		"surface": BlockTypes.Block.SNOW,
		"surface_low": BlockTypes.Block.SNOW,
		"sub": BlockTypes.Block.SNOW,
		"sub_low": BlockTypes.Block.SNOW,
		"low_line": 100,
		"tree_density": 0.0,
		"sky": Color(0.88, 0.94, 1.0),
		"passive": {"POLAR_BEAR": 3},
		"hostile": {},
		# 极地东风强劲、风雪不止；但冰海下垫面均匀、对流远弱于低纬洋面，
		# 切变概率取中等（低于三大洋）。
		"weather_profile": {
			"surface_wind_mps": 8.0,
			"shear_probability": 0.4,
		},
	},
	{
		"id": ASIA,
		"title": "亚洲",
		"subtitle": "面积最大的洲",
		"intro": "面积最大的洲，东临太平洋、南接印度洋，从北方雪原一直延伸到南方雨林。",
		"vegetation": "北方针叶林与草原相接，南方草木成片，森林疏密适中。",
		"creature": "牛、羊、鸡、猪成群游荡；夜里僵尸、骷髅与蜘蛛在黑暗中出没。",
		"climate": "季风气候显著，四季分明，雨季与干季交替。",
		"scenery": "青藏高原托起喜马拉雅与昆仑两大雪脊，长江黄河自高原切谷东流入海，"
			+ "平原丘陵上是经典方块大陆。",
		"seed": 12345,
		"water": "normal",
		"has_airport": true,
		"base_height": 28.0,
		"amplitude": 10.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 22,
		"tree_density": 0.02,
		# ── D-055 分层地形开关（其余区域仍走 classic 单一噪声） ──────────
		# "layered"：在丘陵基底上叠加青藏高原地基 + 喜马拉雅/昆仑山脊 +
		# 长江/黄河深切河谷，并按高度换地表材质（雪线积雪 / 裸岩坡 /
		# 河岸草甸 / 河床砾石）。世界高度同步升到 256 格以容纳雪山。
		"terrain": "layered",
		# 平整保护区 [x0, z0, x1, z1]：山脊与河谷一律不进入这些矩形，
		# 否则高山会顶掉机场选址（main._field_column_ok 从世界顶往下找可
		# 站立面，山顶只有一格可站 + 上方无四格空气）、或把村庄整平区
		# 变成悬崖。亚洲只建 (114,96) 的机场，(114,8) 那块留给其它区域。
		"flat_zones": [
			[84, 32, 144, 156],     # 机场（中心 114,96）：跑道 112×52 + 机库 + 施工缘
			[84, -56, 144, 64],     # 其它区域的机场（中心 114,8）
			[22, 28, 86, 84],       # 村庄 A（REGION_MIN/MAX + 施工缘）
			[-6, -6, 22, 22],       # 简易降落场（大洋/极地区域用）
		],
		# 树线：高于此高度不再长树（雪线附近长树不合直觉，也会让树干戳出盘外）。
		"tree_line": 118.0,
		"sky": Color(1.0, 1.0, 1.0),
		"passive": {"COW": 4, "SHEEP": 3, "CHICKEN": 2, "PIG": 2, "BUTTERFLY": 3,
			"PANDA": 1, "GOLDEN_MONKEY": 1, "CRESTED_IBIS": 1},
		"hostile": {"ZOMBIE": 4, "SKELETON": 3, "SPIDER": 2, "WOLF": 1},
		# 季风区中等地面风；青藏高原/喜马拉雅山口切变真实存在，但概率远低于洋面
		# （本区是默认出发区，儿童玩家第一站，风切变宁少勿多）。
		"weather_profile": {
			"surface_wind_mps": 5.0,
			"shear_probability": 0.2,
		},
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
		"water": "normal",
		"has_airport": true,
		"base_height": 29.0,
		"amplitude": 8.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 22,
		"tree_density": 0.035,
		"sky": Color(0.96, 0.98, 1.0),
		"passive": {"COW": 4, "SHEEP": 4, "CHICKEN": 2, "BUTTERFLY": 3},
		"hostile": {"ZOMBIE": 3, "WOLF": 4, "SKELETON": 3},
		# 温带海洋性气候风力温和（全图最低一档）；阿尔卑斯山口有地形切变但不剧烈。
		"weather_profile": {
			"surface_wind_mps": 4.0,
			"shear_probability": 0.25,
		},
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
		"water": "dry",
		"has_airport": true,
		"base_height": 28.0,
		"amplitude": 11.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 32,
		"tree_density": 0.012,
		"sky": Color(1.0, 0.95, 0.86),
		"passive": {"COW": 3, "SHEEP": 4, "CHICKEN": 2, "PIG": 1, "BUTTERFLY": 2},
		"hostile": {"SPIDER": 4, "ZOMBIE": 3, "SKELETON": 3},
		# 热带雷雨旺（撒哈拉午后对流、昼夜温差助推），切变概率为各区最高一档；
		# 地面风中等，不至于把沙丘 gameplay 吹乱。
		"weather_profile": {
			"surface_wind_mps": 5.0,
			"shear_probability": 0.45,
		},
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
		"water": "normal",
		"has_airport": true,
		"base_height": 28.0,
		"amplitude": 11.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 22,
		"tree_density": 0.028,
		"sky": Color(1.0, 1.0, 1.0),
		"passive": {"COW": 4, "PIG": 3, "SHEEP": 3, "CHICKEN": 2, "BUTTERFLY": 3, "BALD_EAGLE": 2},
		"hostile": {"ZOMBIE": 4, "SKELETON": 3, "SPIDER": 2, "WOLF": 3},
		# 温带大陆性中等风；落基山背风坡颠簸与中部平原干线带来一定切变，
		# 强度低于热带雷雨区。
		"weather_profile": {
			"surface_wind_mps": 4.5,
			"shear_probability": 0.3,
		},
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
		"water": "normal",
		"has_airport": true,
		"base_height": 27.0,
		"amplitude": 13.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 22,
		"tree_density": 0.05,
		"sky": Color(0.97, 1.0, 0.96),
		"passive": {"CHICKEN": 4, "PIG": 4, "COW": 3, "SHEEP": 2, "BUTTERFLY": 4},
		"hostile": {"SPIDER": 4, "ZOMBIE": 2, "SKELETON": 2},
		# 双来源切变：亚马逊雨林对流旺 + 安第斯山口地形风，地面风也偏高；
		# 均在儿童可玩范围内。
		"weather_profile": {
			"surface_wind_mps": 5.5,
			"shear_probability": 0.4,
		},
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
		"water": "dry",
		"has_airport": true,
		"base_height": 27.0,
		"amplitude": 9.0,
		"surface": BlockTypes.Block.GRASS,
		"surface_low": BlockTypes.Block.SAND,
		"sub": BlockTypes.Block.DIRT,
		"sub_low": BlockTypes.Block.SAND,
		"low_line": 30,
		"tree_density": 0.02,
		"sky": Color(1.0, 0.97, 0.9),
		"passive": {"SHEEP": 5, "COW": 3, "CHICKEN": 2, "KANGAROO": 3, "BUTTERFLY": 3},
		"hostile": {"SPIDER": 3, "ZOMBIE": 3, "SKELETON": 2},
		# 热带气旋与雷雨常经之路，午后对流强，切变概率偏高（任务书点名的大区之一）。
		"weather_profile": {
			"surface_wind_mps": 6.0,
			"shear_probability": 0.45,
		},
	},
	{
		"id": ANTARCTICA,
		"title": "南极洲",
		"subtitle": "终年冰封的大陆",
		"intro": "地球最南端的大陆，终年冰封，是平均海拔最高的一洲。",
		"vegetation": "冰原上没有任何植物，只有无边的雪层。",
		"creature": "没有陆生动物出没，雪地上只留下你自己的足迹。",
		"climate": "极地气候，酷寒干燥，风雪常年不歇。",
		"scenery": "无边冰海延伸到天际，巨大冰山与雪顶浮冰静静漂浮。",
		"seed": 20261010,
		"water": "iceberg",
		"has_landing_field": true,
		"base_height": 17.0,
		"amplitude": 5.0,
		"surface": BlockTypes.Block.SNOW,
		"surface_low": BlockTypes.Block.SNOW,
		"sub": BlockTypes.Block.SNOW,
		"sub_low": BlockTypes.Block.SNOW,
		"low_line": 100,
		"tree_density": 0.0,
		"sky": Color(0.9, 0.95, 1.0),
		"passive": {},
		"hostile": {},
		# 极地下降风全球最强，地面风触 9 m/s 上限（儿童向硬顶）；冰面下垫面均匀、
		# 对流弱，切变概率中等，不随风速一起封顶。
		"weather_profile": {
			"surface_wind_mps": 9.0,
			"shear_probability": 0.5,
		},
	},
]

## weather_profile 数据缺项时的保守默认值：陆地温和风 + 低切变。
## 新区域忘配天气参数也能正常飞，只是风按最稳妥的一档算——缺数据退默认，不崩。
const DEFAULT_WEATHER_PROFILE := {
	"surface_wind_mps": 3.0,
	"shear_probability": 0.15,
}


## 该区域的风物理参数（weather_profile），供 scripts/flight/wind_model.gd 的
## WindModel 读取（主理人编写中；本文件只配数据，不在此实现风场）。字段语义：
##   surface_wind_mps   地面基准风速（m/s）。风梯度从此值随高度升到约 3 倍；
##                       儿童向硬顶 9 m/s（本作巡航约 50 m/s，侧风 9 已明显可感）。
##   shear_probability  风切变触发概率（0..1）：洋面对流旺最高（0.5~0.7），
##                       山地/高原有切变但概率低（0.15~0.25）。
static func weather_profile_of(region_id: int) -> Dictionary:
	# 越界一律返回空 Dictionary，**不**做 clampi 夹取：夹取会把「调用方传错区域 id」
	# 这种 bug 静默伪装成「取到另一个区域的风参数」（-3 → 太平洋、999 → 南极洲），
	# 出错时现象完全对不上原因（D-066 记录在案）。返回空让上层走默认值。
	if region_id < 0 or region_id >= COUNT:
		return {}
	if REGIONS.size() != COUNT:
		return {}
	var region: Dictionary = REGIONS[region_id]
	if not region.has("weather_profile"):
		# 数据缺项时退默认而非崩：见 DEFAULT_WEATHER_PROFILE 注释。
		return DEFAULT_WEATHER_PROFILE.duplicate()
	# 返回副本：调用方即便误写，也不会污染 REGIONS 常量数据。
	var profile: Dictionary = region["weather_profile"]
	return profile.duplicate()


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


## 区域是否建有带跑道的机场（地图标注 + 世界生成共用）。
static func has_airport(region_id: int) -> bool:
	var p: Dictionary = profile(region_id)
	return bool(p.get("has_airport", false))


## 该区域是否布有简易降落场（大洋岛上 / 极地冰面的短跑道，无机库）。
static func has_landing_field(region_id: int) -> bool:
	var p: Dictionary = profile(region_id)
	return bool(p.get("has_landing_field", false))


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
