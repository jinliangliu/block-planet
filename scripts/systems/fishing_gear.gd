class_name FishingGear
extends RefCounted
## 钓具数据层：解析 `data/fishing/gear.json`，提供钓具查询、装配校验与
## 「抛投距离 / 水层 / 鱼饵适配度」三套纯计算。
##
## 为什么单独拆一层而不是塞进 FishingSystem：
##   ① 这些计算全是纯函数（给定输入必得同样输出），探针可以脱离状态机直接钉死；
##   ② FishingSystem 管「这一竿进行到哪一步」，钓具只管「这套装备行不行、
##      能抛多远、对什么鱼有效」，两者混在一起会让状态机多出一堆无关字段。
## 数据只读，不持有玩家拥有状态（owned 记在 FishingSystem 的日志里）。

## 抛投距离 = CAST_BASE + 铅坠 cast_distance × CAST_PER_UNIT × 力度(0~1)。
## 最轻的 10 g 也有 4 m 保底（近岸浅水钓点不至于抛不出去），
## 60 g 满力 29 m 才够得着深水（BAND_DEEP_MIN = 20 m）。
const CAST_BASE := 4.0
const CAST_PER_UNIT := 5.0

## 水层分界（米）：落点距离决定饵最终停在哪个水层，也就决定能碰到什么鱼。
const BAND_SHALLOW_MAX := 10.0
const BAND_MID_MAX := 20.0
const BAND_SHALLOW := "shallow"
const BAND_MID := "mid"
const BAND_DEEP := "deep"

## 稀有度权重：决定「同一水层里有多条候选时钓上哪条」。
## 咬不咬钩不看稀有度（见 FishingSystem.BITE_MIN_MATCH），
## 否则稀有鱼会永远不上钩——稀有度只压概率，不压门槛。
const RARITY_WEIGHT := {
	"common": 1.0,
	"uncommon": 0.6,
	"rare": 0.35,
	"epic": 0.15,
	"legendary": 0.07,
}

## 鱼饵与鱼的适配度三档：偏好饵 / 目标类群对得上 / 完全不对付。
const MATCH_PREFERRED := 1.0
const MATCH_TARGET := 0.6
const MATCH_POOR := 0.25

## 铅坠与水层的错配惩罚：重坠在中上层下沉太快会掠过鱼（5.3 节），
## 轻坠够不到深水。
const SINKER_HEAVY_PENALTY := 0.5
const SINKER_LIGHT_PENALTY := 0.35

const DATA_PATH := "res://data/fishing/gear.json"

## 五类钓具的键名与展示名（UI 按此顺序排五列）。
const KINDS := ["rods", "reels", "lines", "baits", "sinkers"]
const KIND_TITLES := {
	"rods": "海竿",
	"reels": "渔轮",
	"lines": "鱼线",
	"baits": "鱼饵",
	"sinkers": "铅坠",
}

var rods: Array = []
var reels: Array = []
var lines: Array = []
var baits: Array = []
var sinkers: Array = []
## 加载期问题（空 = 干净）。探针直接断言它为空。
var problems: PackedStringArray = PackedStringArray()


func _init() -> void:
	load_data()


func load_data() -> void:
	problems = PackedStringArray()
	rods = []
	reels = []
	lines = []
	baits = []
	sinkers = []
	var data := _read_json(DATA_PATH)
	if data.is_empty():
		_problem("gear.json 读取失败：" + DATA_PATH)
		return
	for kind: String in KINDS:
		var raw: Variant = data.get(kind, [])
		if typeof(raw) != TYPE_ARRAY:
			_problem("%s 不是数组" % kind)
			continue
		for item_value: Variant in raw:
			if typeof(item_value) != TYPE_DICTIONARY:
				_problem("%s 里有条目不是对象" % kind)
				continue
			var item: Dictionary = item_value
			var item_id := String(item.get("id", ""))
			if item_id.is_empty():
				_problem("%s 里有条目缺 id" % kind)
				continue
			if has(kind, item_id):
				_problem("%s 里 id 重复：%s" % [kind, item_id])
				continue
			items_of(kind).append(item)


## 按类别取该类的全部钓具数组（UI 直接遍历）。
func items_of(kind: String) -> Array:
	match kind:
		"rods":
			return rods
		"reels":
			return reels
		"lines":
			return lines
		"baits":
			return baits
		"sinkers":
			return sinkers
	return []


func has(kind: String, item_id: String) -> bool:
	for item_value: Variant in items_of(kind):
		var item: Dictionary = item_value
		if String(item.get("id", "")) == item_id:
			return true
	return false


func gear_of(kind: String, item_id: String) -> Dictionary:
	if item_id.is_empty():
		return {}
	for item_value: Variant in items_of(kind):
		var item: Dictionary = item_value
		if String(item.get("id", "")) == item_id:
			return item
	return {}


func rod(item_id: String) -> Dictionary:
	return gear_of("rods", item_id)


func reel(item_id: String) -> Dictionary:
	return gear_of("reels", item_id)


func line(item_id: String) -> Dictionary:
	return gear_of("lines", item_id)


func bait(item_id: String) -> Dictionary:
	return gear_of("baits", item_id)


func sinker(item_id: String) -> Dictionary:
	return gear_of("sinkers", item_id)


## 该钓具的解锁条件："" 或 "default" = 开局拥有；"quest:<id>" = 领了该任务奖励才有。
func unlock_of(item: Dictionary) -> String:
	return String(item.get("unlock", "default"))


func is_default_unlocked(item: Dictionary) -> bool:
	var unlock := unlock_of(item)
	return unlock.is_empty() or unlock == "default"


## "quest:q_fish_deep" → "q_fish_deep"；非任务解锁返回空串。
func quest_of(item: Dictionary) -> String:
	var unlock := unlock_of(item)
	if unlock.begins_with("quest:"):
		return unlock.substr("quest:".length())
	return ""


# ────────────────────────── 纯计算 ──────────────────────────

## 抛投距离（米）：力度 0~1，铅坠越重抛得越远。
static func cast_distance(sinker_item: Dictionary, power: float) -> float:
	var unit := float(sinker_item.get("cast_distance", 1))
	return CAST_BASE + unit * CAST_PER_UNIT * clampf(power, 0.0, 1.0)


## 该铅坠满力能抛到的水层（UI 预告「这颗坠能抛到哪」用）。
static func max_band_of(sinker_item: Dictionary) -> String:
	return band_of(cast_distance(sinker_item, 1.0))


## 落点距离 → 水层。
static func band_of(distance: float) -> String:
	if distance < BAND_SHALLOW_MAX:
		return BAND_SHALLOW
	if distance < BAND_MID_MAX:
		return BAND_MID
	return BAND_DEEP


static func band_title(band: String) -> String:
	match band:
		"shallow":
			return "浅水（上层）"
		"mid":
			return "中层"
		"deep":
			return "深水"
	return "未知水层"


## 鱼饵对这条鱼的适配度：偏好饵满分，目标类群对得上算半个，否则很低。
static func bait_match(bait_item: Dictionary, fish_item: Dictionary) -> float:
	if bait_item.is_empty() or fish_item.is_empty():
		return MATCH_POOR
	var preferred: Array = fish_item.get("preferred_bait", [])
	if preferred.has(String(bait_item.get("id", ""))):
		return MATCH_PREFERRED
	var targets: Array = bait_item.get("target", [])
	var tags: Array = fish_item.get("tags", [])
	for tag_value: Variant in tags:
		if targets.has(String(tag_value)):
			return MATCH_TARGET
	return MATCH_POOR


static func match_title(value: float) -> String:
	if value >= MATCH_PREFERRED:
		return "最爱"
	if value >= MATCH_TARGET:
		return "还行"
	return "不太对"


## 铅坠与水层的错配惩罚（1.0 = 无惩罚）。
static func sinker_factor(sinker_item: Dictionary, fish_depth: String) -> float:
	var unit := int(sinker_item.get("cast_distance", 1))
	if unit >= 5 and fish_depth != BAND_DEEP:
		return SINKER_HEAVY_PENALTY
	if unit <= 1 and fish_depth == BAND_DEEP:
		return SINKER_LIGHT_PENALTY
	return 1.0


## 该鱼在这套「饵 + 坠」下的综合权重（越大越容易碰上）。
## 权重只用于「多条候选里挑哪条」，与咬不咬钩无关。
static func weight_of(fish_item: Dictionary, bait_item: Dictionary, sinker_item: Dictionary) -> float:
	var rarity := String(fish_item.get("rarity", "common"))
	var rarity_w: float = float(RARITY_WEIGHT.get(rarity, 1.0))
	return rarity_w * bait_match(bait_item, fish_item) \
		* sinker_factor(sinker_item, String(fish_item.get("depth", BAND_SHALLOW)))


## 装配校验：返回问题清单（空数组 = 可以开钓）。
## 竿的 max_line 必须 ≥ 线的 strength，否则「竿线不配」——
## 宁可在开钓前挡住，也不要让玩家在收线时被隐性惩罚打懵。
func validate(gear_set: Dictionary) -> PackedStringArray:
	var issues := PackedStringArray()
	var rod_item := rod(String(gear_set.get("rod", "")))
	var reel_item := reel(String(gear_set.get("reel", "")))
	var line_item := line(String(gear_set.get("line", "")))
	if rod_item.is_empty():
		issues.append("还没选海竿")
	if reel_item.is_empty():
		issues.append("还没选渔轮")
	if line_item.is_empty():
		issues.append("还没选鱼线")
	if rod_item.is_empty() or line_item.is_empty():
		return issues
	if int(rod_item.get("max_line", 0)) < int(line_item.get("strength", 0)):
		issues.append("竿线不配：%s 最多配 %d 号线，%s 是 %d 号" % [
			String(rod_item.get("name_zh", "?")), int(rod_item.get("max_line", 0)),
			String(line_item.get("name_zh", "?")), int(line_item.get("strength", 0)),
		])
	return issues


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		_problem("文件不存在：" + path)
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_problem("无法打开：" + path)
		return {}
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		_problem("JSON 解析失败（%s 第 %d 行）" % [path, json.get_error_line()])
		return {}
	if typeof(json.data) != TYPE_DICTIONARY:
		_problem("顶层不是对象：" + path)
		return {}
	var data: Dictionary = json.data
	return data


func _problem(text: String) -> void:
	problems.append(text)
	push_error("fishing_gear: " + text)
