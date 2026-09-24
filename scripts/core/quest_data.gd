class_name QuestData
extends RefCounted

## 任务与成就的静态定义表（与 RegionAtlas 同模式：纯数据 + 静态访问器）。
##
## 目标（goal）类型：
##   count         —— 计数器 key 达到 count（key 形如 mined_5 / crafted_100 / traded）
##   regions       —— 踏足过的区域数（regions_<id> 键的个数）达到 count
##   distinct_mined—— 挖掘过的不同方块种数（mined_<id> 键的个数）达到 count
##   quests_done   —— 已领取的新手任务数达到 count（用于毕业成就）
##
## 状态机：任务按 prerequisite 顺序解锁（前序领奖后下一环可见）；
## 成就无链式依赖，全部默认可见。ACTIVE → DONE（达成）→ CLAIMED（领奖）。

enum Category { QUEST, QUIZ, SURVIVAL, EXPLORE, CHALLENGE }

const QUIZ_REWARD_EVERY := 3
const QUIZ_REWARD_ITEM := 208   # BREAD
const QUIZ_REWARD_COUNT := 2

static var _quests: Array[Dictionary] = []
static var _achievements: Array[Dictionary] = []

## 新手引导链：按 prerequisite 串成 8 步，教会全部基础操作。
static func quests() -> Array[Dictionary]:
	if _quests.is_empty():
		_build()
	return _quests


## 成就：五类分组（知识问答 / 生存技能 / 地图探索 / 游戏闯关 / 新手毕业）。
static func achievements() -> Array[Dictionary]:
	if _achievements.is_empty():
		_build()
	return _achievements


static func entry_by_id(id: String) -> Dictionary:
	for entry in quests():
		if String(entry["id"]) == id:
			return entry
	for entry in achievements():
		if String(entry["id"]) == id:
			return entry
	return {}


static func category_title(category: int) -> String:
	match category:
		Category.QUEST:
			return "新手任务"
		Category.QUIZ:
			return "知识问答"
		Category.SURVIVAL:
			return "生存技能"
		Category.EXPLORE:
			return "地图探索"
		Category.CHALLENGE:
			return "游戏闯关"
	return "其他"


## 知识问答题库（儿童向，答案均可在说明书与知识卡片中找到线索）。
static func quiz_bank() -> Array[Dictionary]:
	return [
		{"q": "世界上最高的山峰是哪一座？", "options": ["珠穆朗玛峰", "富士山", "乞力马扎罗山"], "answer": 0},
		{"q": "帝企鹅主要生活在哪里？", "options": ["南极洲", "撒哈拉沙漠", "亚马逊雨林"], "answer": 0},
		{"q": "东非大裂谷在几百万年后会变成什么？", "options": ["新的大洋", "新的沙漠", "新的冰川"], "answer": 0},
		{"q": "世界上面积最大的海洋是？", "options": ["太平洋", "印度洋", "北冰洋"], "answer": 0},
		{"q": "撒哈拉沙漠位于哪个洲？", "options": ["非洲", "亚洲", "欧洲"], "answer": 0},
		{"q": "亚马逊雨林分布在哪个洲？", "options": ["南美洲", "北美洲", "大洋洲"], "answer": 0},
		{"q": "袋鼠主要生活在哪个洲？", "options": ["大洋洲", "欧洲", "亚洲"], "answer": 0},
		{"q": "大熊猫最爱吃什么？", "options": ["竹子", "蜂蜜", "小鱼"], "answer": 0},
		{"q": "北极熊主要捕猎什么动物？", "options": ["海豹", "树叶", "昆虫"], "answer": 0},
		{"q": "世界上面积最大的大洲是？", "options": ["亚洲", "非洲", "欧洲"], "answer": 0},
		{"q": "万里长城位于哪个国家？", "options": ["中国", "埃及", "印度"], "answer": 0},
		{"q": "尼罗河流经哪个大洲？", "options": ["非洲", "南美洲", "大洋洲"], "answer": 0},
		{"q": "夜晚出没的敌对生物是？", "options": ["僵尸", "奶牛", "绵羊"], "answer": 0},
		{"q": "哪种工具最适合砍树？", "options": ["斧头", "铲子", "锄头"], "answer": 0},
		{"q": "沙子放进冶炼炉可以烧成什么？", "options": ["玻璃", "铁锭", "面包"], "answer": 0},
		{"q": "游戏里按哪个键打开 3D 地球？", "options": ["M 键", "B 键", "G 键"], "answer": 0},
	]


static func _build() -> void:
	var mined_wood := "mined_%d" % BlockTypes.Block.WOOD
	_quests = [
		{
			"id": "newbie_wood", "category": Category.QUEST, "prerequisite": "",
			"title": "动手采集", "desc": "走到大树旁，按住左键挖到 3 块原木。",
			"goal": {"type": "count", "key": mined_wood, "count": 3},
			"reward": {"item": 208, "count": 2},
		},
		{
			"id": "newbie_place", "category": Category.QUEST, "prerequisite": "newbie_wood",
			"title": "小小建筑师", "desc": "把快捷栏里的方块用右键放到地上，共放置 5 个。",
			"goal": {"type": "count", "key": "placed_any", "count": 5},
			"reward": {"item": 208, "count": 2},
		},
		{
			"id": "newbie_craft", "category": Category.QUEST, "prerequisite": "newbie_place",
			"title": "初次合成", "desc": "按 E 打开合成台，把材料合成任意物品 1 次。",
			"goal": {"type": "count", "key": "crafted_any", "count": 1},
			"reward": {"item": 204, "count": 1},
		},
		{
			"id": "newbie_pick", "category": Category.QUEST, "prerequisite": "newbie_craft",
			"title": "工具匠", "desc": "合成一把木镐，挖石头会更快。",
			"goal": {"type": "count", "key": "crafted_100", "count": 1},
			"reward": {"item": 204, "count": 1},
		},
		{
			"id": "newbie_trade", "category": Category.QUEST, "prerequisite": "newbie_pick",
			"title": "以物易物", "desc": "去村庄按 B 打开交易面板，和村民换一次东西。",
			"goal": {"type": "count", "key": "traded", "count": 1},
			"reward": {"item": 204, "count": 2},
		},
		{
			"id": "newbie_map", "category": Category.QUEST, "prerequisite": "newbie_trade",
			"title": "打开世界地图", "desc": "按 M 转动 3D 地球，看看我们的世界有多大。",
			"goal": {"type": "count", "key": "map_opened", "count": 1},
			"reward": {"item": 204, "count": 1},
		},
		{
			"id": "newbie_region", "category": Category.QUEST, "prerequisite": "newbie_map",
			"title": "踏足新大陆", "desc": "在地球上选一个区域并进入，那里的一切都会焕然一新。",
			"goal": {"type": "regions", "count": 1},
			"reward": {"item": 204, "count": 2},
		},
		{
			"id": "newbie_smelt", "category": Category.QUEST, "prerequisite": "newbie_region",
			"title": "炉火初燃", "desc": "找到冶炼炉，右键打开并把沙子烧成玻璃。",
			"goal": {"type": "count", "key": "smelted", "count": 1},
			"reward": {"item": 204, "count": 2},
		},
	]

	_achievements = [
		# 知识问答
		{
			"id": "a_quiz_1", "category": Category.QUIZ, "prerequisite": "",
			"title": "初识世界", "desc": "在知识问答中答对 1 道题。",
			"goal": {"type": "count", "key": "quiz_correct", "count": 1},
			"reward": {"item": 204, "count": 1},
		},
		{
			"id": "a_quiz_2", "category": Category.QUIZ, "prerequisite": "",
			"title": "地理小学者", "desc": "在知识问答中答对 5 道题。",
			"goal": {"type": "count", "key": "quiz_correct", "count": 5},
			"reward": {"item": 208, "count": 3},
		},
		{
			"id": "a_quiz_3", "category": Category.QUIZ, "prerequisite": "",
			"title": "行走的百科全书", "desc": "在知识问答中答对 12 道题。",
			"goal": {"type": "count", "key": "quiz_correct", "count": 12},
			"reward": {"item": 205, "count": 1},
		},
		# 生存技能
		{
			"id": "a_surv_stone", "category": Category.SURVIVAL, "prerequisite": "",
			"title": "石器时代", "desc": "合成一把石镐。",
			"goal": {"type": "count", "key": "crafted_103", "count": 1},
			"reward": {"item": 204, "count": 2},
		},
		{
			"id": "a_surv_smelt", "category": Category.SURVIVAL, "prerequisite": "",
			"title": "点石成金", "desc": "使用冶炼炉炼制 1 次。",
			"goal": {"type": "count", "key": "smelted", "count": 1},
			"reward": {"item": 204, "count": 1},
		},
		{
			"id": "a_surv_hunter", "category": Category.SURVIVAL, "prerequisite": "",
			"title": "小小猎手", "desc": "击败 3 只敌对生物。",
			"goal": {"type": "count", "key": "killed_hostile", "count": 3},
			"reward": {"item": 208, "count": 3},
		},
		{
			"id": "a_surv_builder", "category": Category.SURVIVAL, "prerequisite": "",
			"title": "建筑师", "desc": "累计放置 100 个方块。",
			"goal": {"type": "count", "key": "placed_any", "count": 100},
			"reward": {"item": 204, "count": 3},
		},
		# 地图探索
		{
			"id": "a_exp_region3", "category": Category.EXPLORE, "prerequisite": "",
			"title": "旅行家", "desc": "踏足 3 个不同区域。",
			"goal": {"type": "regions", "count": 3},
			"reward": {"item": 204, "count": 3},
		},
		{
			"id": "a_exp_region_all", "category": Category.EXPLORE, "prerequisite": "",
			"title": "环球冒险家", "desc": "踏足全部 11 个区域。",
			"goal": {"type": "regions", "count": 11},
			"reward": {"item": 205, "count": 1},
		},
		{
			"id": "a_exp_blocks", "category": Category.EXPLORE, "prerequisite": "",
			"title": "收藏家", "desc": "挖掘过 8 种不同的方块。",
			"goal": {"type": "distinct_mined", "count": 8},
			"reward": {"item": 204, "count": 2},
		},
		# 游戏闯关
		{
			"id": "a_cha_mine200", "category": Category.CHALLENGE, "prerequisite": "",
			"title": "挖掘工人", "desc": "累计挖掘 200 个方块。",
			"goal": {"type": "count", "key": "mined_any", "count": 200},
			"reward": {"item": 204, "count": 3},
		},
		{
			"id": "a_cha_craft20", "category": Category.CHALLENGE, "prerequisite": "",
			"title": "能工巧匠", "desc": "累计合成 20 次。",
			"goal": {"type": "count", "key": "crafted_any", "count": 20},
			"reward": {"item": 204, "count": 3},
		},
		{
			"id": "a_cha_hunt10", "category": Category.CHALLENGE, "prerequisite": "",
			"title": "讨伐者", "desc": "击败 10 只敌对生物。",
			"goal": {"type": "count", "key": "killed_hostile", "count": 10},
			"reward": {"item": 205, "count": 1},
		},
		{
			"id": "a_cha_graduate", "category": Category.CHALLENGE, "prerequisite": "",
			"title": "新手毕业", "desc": "完成并领取全部 8 个新手任务。",
			"goal": {"type": "quests_done", "count": 8},
			"reward": {"item": 205, "count": 1},
		},
	]
