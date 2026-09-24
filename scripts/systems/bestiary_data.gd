extends Node
## 生物图鉴数据层（Autoload：BestiaryData）。
##
## 数据全部落在 `data/bestiary/*.json`：`manifest.json` 是唯一登记表
## （界→类分类树 + 区域文件清单 + 题库文件名），各区域文件是条目来源。
## 本节点只做「读盘 → 建索引 → 提供查询」，不含任何 UI 代码。
##
## 为什么是 JSON + Autoload，而不是像 RegionAtlas / QuestData 那样写成 .gd 常量表：
## 图鉴是纯内容数据（170+ 条、13 个区域、19 道题），且会持续追加。写进 .gd 会变成
## 几万行常量，改一条科普文案也要读一遍逻辑；放 JSON 则「加一个物种 = 加一行」。
## 代价是错误只能到运行时才暴露，所以 load_all() 会把全部问题收进 load_problems，
## 由 `life_probe` 阶段 S 一次性红出来（见 docs/assets.md 第八节）。
##
## 对外约定：
##   - `entries` 是全部条目的扁平数组，每条都补上了 `region_id / region_name_zh / type`；
##   - `filter()` 是 UI 的唯一筛选入口，四个条件都为「空即不过滤」；
##   - 图鉴的「区域」与可进入世界的「区域」（RegionAtlas 的 11 个）不是一回事：
##     极地在世界侧合成一片（北冰洋 / 南极洲），在知识侧拆成两片
##     （北冰洋 ↔ 北极地区、南极洲 ↔ 南极地区），映射见 ATLAS_REGIONS。

signal bestiary_loaded

const BESTIARY_ROOT := "res://data/bestiary"

const MANIFEST_FILE := "res://data/bestiary/manifest.json"

## 世界区域（RegionAtlas 区域号）→ 图鉴区域文件 id 列表。
## 一个世界区域可以对应多个知识区域：站在北极，既该查到「北冰洋」的物种，
## 也该查到「北极地区」的苔原物种——它们本来就是同一片地方的两个视角。
const ATLAS_REGIONS := {
	RegionAtlas.PACIFIC: ["pacific_ocean"],
	RegionAtlas.ATLANTIC: ["atlantic_ocean"],
	RegionAtlas.INDIAN: ["indian_ocean"],
	RegionAtlas.ARCTIC: ["arctic_ocean", "arctic_region"],
	RegionAtlas.ASIA: ["asia"],
	RegionAtlas.EUROPE: ["europe"],
	RegionAtlas.AFRICA: ["africa"],
	RegionAtlas.NORTH_AMERICA: ["north_america"],
	RegionAtlas.SOUTH_AMERICA: ["south_america"],
	RegionAtlas.OCEANIA: ["oceania"],
	RegionAtlas.ANTARCTICA: ["antarctica", "antarctic_region"],
}

## 条目必填字段与可选字段。`scientific` 允许缺省：北极苔藓、南极地衣这类
## 「一整类生物」没有单一拉丁学名，硬填一个反而是错的——缺了就少显示一行。
const REQUIRED_FIELDS := ["id", "kingdom", "category", "name_zh", "name_en", "fact_zh"]
const OPTIONAL_FIELDS := ["scientific"]

var manifest: Dictionary = {}
var kingdoms: Array = []
var regions: Array = []
var entries: Array = []
var entries_by_id: Dictionary = {}
## name_zh → 条目数组。同一中文名可能出现在多个区域文件里（如「南极地衣」同时
## 属于「南极洲」与「南极地区」），所以索引值是数组而不是单条。
var entries_by_name: Dictionary = {}
## category id → { name_zh, name_en, icon, color, kingdom }
var categories: Dictionary = {}
var quiz: Array = []
## 加载期的数据问题（空数组 = 干净）。探针阶段 S 直接断言它为空。
var load_problems: PackedStringArray = PackedStringArray()
var is_loaded := false


func _ready() -> void:
	load_all()


func load_all() -> void:
	load_problems = PackedStringArray()
	manifest = _load_json(MANIFEST_FILE)
	if manifest.is_empty():
		_problem("manifest.json 读取失败，图鉴不可用：" + MANIFEST_FILE)
		return

	kingdoms = manifest.get("kingdoms", [])
	categories.clear()
	_index_categories()

	regions.clear()
	entries.clear()
	entries_by_id.clear()
	entries_by_name.clear()

	var declared: PackedStringArray = PackedStringArray()
	for path: String in manifest.get("region_files", []):
		declared.append(path)
		var region := _load_json(path)
		if region.is_empty():
			continue
		for field: String in ["id", "name_zh", "type"]:
			if String(region.get(field, "")).is_empty():
				_problem("区域文件缺 %s：%s" % [field, path])
		regions.append(region)
		for entry_value: Variant in region.get("entries", []):
			if typeof(entry_value) != TYPE_DICTIONARY:
				_problem("条目不是对象：%s" % path)
				continue
			var entry: Dictionary = entry_value
			_index_entry(entry, region, path)

	# 反向检查：磁盘上躺着却没被 manifest 登记的条目文件 = 白写了（UI 永远看不到它）。
	for path: String in _list_region_files():
		if not declared.has(path):
			_problem("区域文件未登记进 manifest，加载不到：" + path)

	quiz = []
	var quiz_path := String(manifest.get("quiz_file", ""))
	if not quiz_path.is_empty():
		var quiz_data := _load_json(quiz_path)
		for item: Variant in quiz_data.get("quiz", []):
			if typeof(item) == TYPE_DICTIONARY:
				quiz.append(item)
		_check_quiz()

	is_loaded = true
	bestiary_loaded.emit()


## 把一条条目补上区域上下文后建索引，并校验必填字段与分类归属。
func _index_entry(entry: Dictionary, region: Dictionary, path: String) -> void:
	var entry_id := String(entry.get("id", ""))
	if entry_id.is_empty():
		_problem("条目缺 id：%s" % path)
		return
	if entries_by_id.has(entry_id):
		_problem("条目 id 重复：%s" % entry_id)
		return
	for field: String in REQUIRED_FIELDS:
		if String(entry.get(field, "")).is_empty():
			_problem("条目 %s 缺字段 %s" % [entry_id, field])
	var kingdom_id := String(entry.get("kingdom", ""))
	var category_id := String(entry.get("category", ""))
	if not _kingdom_ids().has(kingdom_id):
		_problem("条目 %s 的界「%s」未在 manifest 登记" % [entry_id, kingdom_id])
	elif not categories.has(category_id) or String(categories[category_id]["kingdom"]) != kingdom_id:
		_problem("条目 %s 的类「%s」不属于界「%s」" % [entry_id, category_id, kingdom_id])

	var enriched: Dictionary = entry.duplicate(true)
	enriched["region_id"] = String(region.get("id", ""))
	enriched["region_name_zh"] = String(region.get("name_zh", ""))
	enriched["region_name_en"] = String(region.get("name_en", ""))
	enriched["region_type"] = String(region.get("type", ""))
	entries.append(enriched)
	entries_by_id[entry_id] = enriched
	var name_zh := String(entry.get("name_zh", ""))
	if not name_zh.is_empty():
		var bucket: Array = entries_by_name.get(name_zh, [])
		bucket.append(enriched)
		entries_by_name[name_zh] = bucket


func _index_categories() -> void:
	for kingdom_value: Variant in kingdoms:
		if typeof(kingdom_value) != TYPE_DICTIONARY:
			continue
		var kingdom: Dictionary = kingdom_value
		for child_value: Variant in kingdom.get("children", []):
			if typeof(child_value) != TYPE_DICTIONARY:
				continue
			var child: Dictionary = child_value
			var child_id := String(child.get("id", ""))
			if child_id.is_empty():
				_problem("manifest 里有类缺 id")
				continue
			if categories.has(child_id):
				_problem("manifest 里类 id 重复：%s" % child_id)
			var record: Dictionary = child.duplicate(true)
			record["kingdom"] = String(kingdom.get("id", ""))
			categories[child_id] = record


func _check_quiz() -> void:
	for item: Dictionary in quiz:
		var qid := String(item.get("id", "?"))
		if String(item.get("question_zh", "")).is_empty():
			_problem("题目 %s 缺题干" % qid)
		var options: Array = item.get("options", [])
		if typeof(options) != TYPE_ARRAY or options.size() < 2:
			_problem("题目 %s 的选项少于 2 个" % qid)
		var answer := String(item.get("answer_zh", ""))
		if answer.is_empty():
			_problem("题目 %s 缺答案" % qid)
		elif not options.has(answer):
			_problem("题目 %s 的答案「%s」不在选项里" % [qid, answer])
		if String(item.get("explain_zh", "")).is_empty():
			_problem("题目 %s 缺讲解（答完看不到为什么）" % qid)


## 枚举 data/bestiary 下所有条目文件，供「有没有孤儿文件」的反向检查使用。
## 用 DirAccess 递归而不是写死清单：新增区域时只要丢文件进目录就会被发现漏登记。
func _list_region_files() -> PackedStringArray:
	var found: PackedStringArray = PackedStringArray()
	_scan_dir(BESTIARY_ROOT, found)
	return found


func _scan_dir(dir_path: String, found: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for child: String in dir.get_files():
		if child.ends_with(".json") and child != "manifest.json" and child != "quiz.json":
			found.append(dir_path.path_join(child))
	for child: String in dir.get_directories():
		_scan_dir(dir_path.path_join(child), found)


func _problem(text: String) -> void:
	load_problems.append(text)
	push_error("bestiary: " + text)


func _load_json(path: String) -> Dictionary:
	if path.is_empty():
		return {}
	if not FileAccess.file_exists(path):
		_problem("文件不存在：" + path)
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_problem("无法打开：" + path)
		return {}
	var json := JSON.new()
	var text := file.get_as_text()
	if json.parse(text) != OK:
		_problem("JSON 解析失败（%s 第 %d 行）" % [path, json.get_error_line()])
		return {}
	if typeof(json.data) != TYPE_DICTIONARY:
		_problem("顶层不是对象：" + path)
		return {}
	var data: Dictionary = json.data
	return data


# ────────────────────────────── 查询接口 ──────────────────────────────

func get_kingdoms() -> Array:
	return kingdoms


func get_regions() -> Array:
	return regions


func get_entries() -> Array:
	return entries


func get_entry(entry_id: String) -> Dictionary:
	var found: Variant = entries_by_id.get(entry_id, {})
	if typeof(found) != TYPE_DICTIONARY:
		return {}
	var entry: Dictionary = found
	return entry


func get_entries_by_id(entry_id: String) -> Dictionary:
	return get_entry(entry_id)


func get_quiz() -> Array:
	return quiz


func region_by_id(region_id: String) -> Dictionary:
	for region_value: Variant in regions:
		var region: Dictionary = region_value
		if String(region.get("id", "")) == region_id:
			return region
	return {}


## 某个世界区域（RegionAtlas 区域号）对应的图鉴区域 id 列表。
func region_ids_of_atlas(atlas_id: int) -> Array:
	return ATLAS_REGIONS.get(atlas_id, [])


func kingdom_name(kingdom_id: String) -> String:
	for kingdom_value: Variant in kingdoms:
		var kingdom: Dictionary = kingdom_value
		if String(kingdom.get("id", "")) == kingdom_id:
			return String(kingdom.get("name_zh", kingdom_id))
	return kingdom_id


func kingdom_color(kingdom_id: String) -> Color:
	for kingdom_value: Variant in kingdoms:
		var kingdom: Dictionary = kingdom_value
		if String(kingdom.get("id", "")) == kingdom_id:
			return Color.from_string(String(kingdom.get("color", "#888888")), Color(0.53, 0.53, 0.53))
	return Color(0.53, 0.53, 0.53)


## 某一界下的全部类（manifest 里 children 的顺序即展示顺序）。
func categories_of(kingdom_id: String) -> Array:
	var result: Array = []
	for kingdom_value: Variant in kingdoms:
		var kingdom: Dictionary = kingdom_value
		if not kingdom_id.is_empty() and String(kingdom.get("id", "")) != kingdom_id:
			continue
		for child_value: Variant in kingdom.get("children", []):
			result.append(child_value)
	return result


func category_name(category_id: String) -> String:
	var record: Dictionary = categories.get(category_id, {})
	return String(record.get("name_zh", category_id))


func category_color(category_id: String) -> Color:
	var record: Dictionary = categories.get(category_id, {})
	var raw := String(record.get("color", ""))
	if raw.is_empty():
		return Color(0.53, 0.53, 0.53)
	return Color.from_string(raw, Color(0.53, 0.53, 0.53))


func category_kingdom(category_id: String) -> String:
	var record: Dictionary = categories.get(category_id, {})
	return String(record.get("kingdom", ""))


## 统一筛选入口。四个条件都为「空串即不过滤」，
## `region_id` 收图鉴区域 id（如 "asia"），会按区域精确匹配。
func filter(kingdom_id: String = "", category_id: String = "", region_id: String = "", keyword: String = "") -> Array:
	return filter_entries(kingdom_id, category_id, keyword, region_id)


func filter_entries(
	kingdom_id: String = "",
	category_id: String = "",
	keyword: String = "",
	region_id: String = ""
) -> Array:
	var result: Array = []
	var kw := keyword.strip_edges().to_lower()
	for entry_value: Variant in entries:
		var entry: Dictionary = entry_value
		if not kingdom_id.is_empty() and String(entry.get("kingdom", "")) != kingdom_id:
			continue
		if not category_id.is_empty() and String(entry.get("category", "")) != category_id:
			continue
		if not region_id.is_empty() and String(entry.get("region_id", "")) != region_id:
			continue
		if not kw.is_empty():
			# 搜索范围含科普文案与地区名：孩子想找「会飞的」「南极」也能命中。
			var haystack := "%s %s %s %s %s" % [
				entry.get("name_zh", ""),
				entry.get("name_en", ""),
				entry.get("scientific", ""),
				entry.get("fact_zh", ""),
				entry.get("region_name_zh", ""),
			]
			if haystack.to_lower().find(kw) == -1:
				continue
		result.append(entry)
	result.sort_custom(_by_name)
	return result


func _by_name(a: Variant, b: Variant) -> bool:
	var left: Dictionary = a
	var right: Dictionary = b
	return String(left.get("name_zh", "")) < String(right.get("name_zh", ""))


## 图鉴条目 → 游戏里真实存在的物种（按中文名对齐）。
## 刻意用「名字相等」而不是维护一张 id 对照表：新增物种时只要两处中文名一致，
## 图鉴与游戏就自动接上，不必再记得改第三张表。同名多区域条目取第一条。
## 找不到时返回 -1（绝大多数条目在游戏里没有对应实体，这是正常的）。
func mob_of_entry(entry: Dictionary) -> int:
	return _mob_by_name(String(entry.get("name_zh", "")))


## 游戏物种 → 图鉴条目（可能为空：小僵尸、村民这类角色不写进图鉴）。
func entry_of_mob(mob_type: int) -> Dictionary:
	var name_zh := String(Mob.MOB_NAMES.get(mob_type, ""))
	var bucket: Variant = entries_by_name.get(name_zh, [])
	if typeof(bucket) != TYPE_ARRAY or (bucket as Array).is_empty():
		return {}
	var list: Array = bucket
	var first: Variant = list[0]
	if typeof(first) != TYPE_DICTIONARY:
		return {}
	var entry: Dictionary = first
	return entry


## 全部「游戏内可遇见」的条目，按名字排序（图鉴里给这些条目加标记）。
func game_mobs_in_bestiary() -> Dictionary:
	var linked := {}
	for name_zh: String in entries_by_name:
		var mob_type := _mob_by_name(name_zh)
		if mob_type >= 0:
			linked[name_zh] = mob_type
	return linked


func _mob_by_name(name_zh: String) -> int:
	for mob_type: int in Mob.MobType.values():
		if String(Mob.MOB_NAMES.get(mob_type, "")) == name_zh:
			return mob_type
	return -1


func _kingdom_ids() -> Array:
	var ids: Array = []
	for kingdom_value: Variant in kingdoms:
		var kingdom: Dictionary = kingdom_value
		ids.append(String(kingdom.get("id", "")))
	return ids


## 数据问题的可读汇总（给探针与调试打印用）。
func problem_report() -> String:
	if load_problems.is_empty():
		return "无"
	return "\n".join(load_problems)
