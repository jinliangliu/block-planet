extends Node
## 钓鱼系统（Autoload：FishingSystem）——四大洋探钓玩法的核心。
##
## 不写 class_name：Godot 不允许脚本类名与 autoload 单例同名
## （Parse Error: Class "FishingSystem" hides an autoload singleton），
## 项目里其余 autoload（Progress / BestiaryData）同样不声明类名。
##
## 职责边界：
##   - 加载 data/fishing 四份 JSON（钓点 / 鱼种 / 钓具 / 教学）；
##   - 管「这一竿」的状态机：选饵 → 配坠 → 抛投 → 等咬钩 → 收线 → 结算；
##   - 写 user://fishing_journal.json（钓获记录、已解锁钓具、看过的教学、回放日志）；
##   - 把钓获折算成 Progress 计数器，供任务与成就判定。
##
## 不含任何 UI：界面（FishingGearUI / FishingUI / FishingTeachingUI）只读本类的
## 状态与查询接口，不反过来改状态机字段——UI 与逻辑之间只有方法调用一条路。
##
## 数值设计（实现依据见 features/feature_fishing.md §5）：
##   抛投距离 = 4 + 铅坠档 × 5 × 力度；<10 m 浅水 / 10~20 m 中层 / >20 m 深水。
##   咬钩看「饵 × 坠」的最大匹配度（≥ 0.3 才咬），稀有度只影响钓上哪一条。
##   收线：张力随「鱼的拉力 + 卸力」上升，卸力太松鱼会跑、太紧会断线。
## 运行验证：tests/fishing_probe.tscn（数据自检 + 抛投/水层/咬钩纯计算 +
##   等咬钩→收线→结算全状态机 + 收线三败局 + 日志与 Progress 折算；开局
##   SaveGuard 隔离、钓鱼日志单独快照还原，D-010 合规）。

signal fish_caught(fish_id: String, spot_id: String, gear: Dictionary)
signal new_species_unlocked(fish_id: String)
signal fishing_failed(reason: String)
signal fishing_state_changed(state: int)
signal journal_changed

enum State {
	IDLE,
	SELECT_GEAR,
	SELECT_BAIT,
	SELECT_SINKER,
	CASTING,
	WAITING,
	HOOKED,
	REELING,
	RESULT,
}

const DATA_ROOT := "res://data/fishing/"
const SPOTS_PATH := DATA_ROOT + "spots.json"
const FISH_PATH := DATA_ROOT + "fish.json"
## D-086：不再是 const。无槽时按 Profile.slot_dir() 派生回旧根路径；
## 建槽后落到 user://profiles/<id>/，切槽即重算并整体重载内存态。
var JOURNAL_PATH: String = "user://fishing_journal.json"

## 等待咬钩：基础时长 + 该水层最难那条鱼的难度 × 系数。
const WAIT_BASE := 2.5
const WAIT_PER_DIFFICULTY := 0.25
## 无鱼咬钩的等待倍率（超过这个时间还没动静才提示「这里没鱼上钩」）。
const NO_BITE_FACTOR := 2.0
## 咬钩门槛：饵与坠的最大匹配度低于此值，等再久也不咬（饵不对就是钓不到）。
const BITE_MIN_MATCH := 0.3

## 收线小游戏。
##
## 三条「可钓性」常量（D-083）：此前**入门套装一竿抛出的鱼可能是必败的**——
## 拉力 7~10 的大鱼哪怕操作全对也会在 5~13 s 内跑掉（见下三处注释的实测表）。
## 目标玩家 6~12 岁，且 fish_escaped 是「白费一趟」的挫败，不是有代价的失败，
## 所以本轮把这三条整体放宽，让「拉满操作」能换来结果。
const REEL_RATE := 0.12          # 进度速率 = 渔轮 speed × 本值 × (1 - 0.4·张力)
## 松手时进度回退 = 鱼挣扎力 × 本值。0.012 → 0.006：原来一次「该松手」的
## 安全区窗口就吃掉刚收上来的 3 成进度，孩子会以为「松手=白干」。
const SLIP_RATE := 0.006
const TENSION_FIGHT := 0.10      # 鱼的拉力系数
const TENSION_DRAG := 0.12       # 卸力越紧，线受力越大
## 收线时的自然泄力。0.60 → 0.72：小鱼的张力余量更宽，大鱼靠「松手泄力」
## 也能把张力压回去（原来 0.45/s 的泄力追不上 0.30~0.44/s 的涨速）。
const TENSION_RELIEF := 0.72
const TENSION_SCALE := 0.35
const TENSION_RELEASE := 0.45    # 松手时张力每秒下降
const LINE_WEAK_FACTOR := 1.25   # 线拉力 < 鱼挣扎力时的断线加速
## 卸力太松 → 鱼越跑越远。0.04 → 0.028：入门鼓轮上限 drag_max=2，
## 原值下 fight 7/8/9 的逃逸速度是 0.16/0.20/0.24 每秒（6~8 s 必跑），
## 而同等条件下收满盘要 13~20 s——**数学上不可能钓上来**。
const ESCAPE_FIGHT := 0.028
const ESCAPE_DRAG := 0.10        # 卸力越紧 → 拉得住，但张力上得更快（见上）
const HARD_PULL_FACTOR := 1.5    # 鱼不在安全区还硬收 → 张力加速
const SAFE_HALF_WIDTH := 0.18    # 安全区半宽（鱼位置 0~1）
const STRUGGLE_HZ := 1.7         # 挣扎摆动频率
const STRUGGLE_SWIM_HZ := 1.3    # 鱼左右游动频率

## 回放日志里的玩家列（HUD 左上角显示的名字，两处同一份措辞）。
const PLAYER_LABEL := "小方块"

## 回报数量（M9 钓鱼完善）：稀有度 → 生鱼条数。此前无论钓上 0.05 kg 的小丑鱼
## 还是 1100 kg 的大白鲨都只给 1 条，「我费这么大劲换来了什么」没有答案。
## 破个人最佳再加 1 条，让「这条特别大」有实际回报。
const RARITY_LOOT := {
	"common": 1,
	"uncommon": 2,
	"rare": 3,
	"epic": 4,
	"legendary": 5,
}

var gear: FishingGear
var teaching: FishingTeaching
var spots: Array = []
var fish_list: Array = []
var load_problems: PackedStringArray = PackedStringArray()

var state: int = State.IDLE
## 持久化日志：records / gear / lessons_seen / replay / stats。
var journal: Dictionary = {}
## 读档是否成功：失败时禁止回写，避免用默认模板覆盖真实存档（见 _load_journal）。
var journal_ok := false
## 最近一次成功钓获的完整结算快照（try_catch 的 result）。
## 存在的理由：`fish_caught` 信号只带 (fish_id, spot_id, gear)，**重量在信号层就丢了**，
## 而 HUD 要按重量/是否破纪录决定回报条数。改信号签名会破坏 fishing_probe 的既有
## lambda 连接，故用这份只读快照把信息带过去。
var _last_catch: Dictionary = {}

var _spot_id := ""
var _gear_set: Dictionary = {}
var _bait_id := ""
var _sinker_id := ""
var _cast_distance := 0.0
var _band := ""
var _pool: Array = []
var _wait_total := 0.0
var _wait_left := 0.0
var _hooked: Dictionary = {}
var _hooked_id := ""
var _progress := 0.0
var _tension := 0.0
var _escape := 0.0
var _elapsed := 0.0
var _drag := 1.0
var _phase := 0.0


func _ready() -> void:
	gear = FishingGear.new()
	teaching = FishingTeaching.new()
	load_data()
	_refresh_path()
	_load_journal()
	_refresh_gear_unlocks()
	if Progress != null:
		Progress.quest_claimed.connect(_on_quest_claimed)
	if Profile != null:
		Profile.slot_changed.connect(_on_slot_changed)


func _exit_tree() -> void:
	_save_journal()


# ────────────────────────── 数据加载 ──────────────────────────

func load_data() -> void:
	load_problems = PackedStringArray()
	spots = []
	fish_list = []
	_load_spots()
	_load_fish()
	if gear != null:
		for text: String in gear.problems:
			load_problems.append(text)
	if teaching != null:
		for text: String in teaching.problems:
			load_problems.append(text)


func _load_spots() -> void:
	var data := _read_json(SPOTS_PATH)
	var raw: Variant = data.get("spots", [])
	if typeof(raw) != TYPE_ARRAY:
		_problem("spots 不是数组")
		return
	for item_value: Variant in raw:
		if typeof(item_value) != TYPE_DICTIONARY:
			_problem("spots 里有条目不是对象")
			continue
		var spot: Dictionary = item_value
		var spot_id := String(spot.get("id", ""))
		if spot_id.is_empty():
			_problem("钓点缺 id")
			continue
		if get_spot(spot_id).is_empty():
			spots.append(spot)
		else:
			_problem("钓点 id 重复：%s" % spot_id)


func _load_fish() -> void:
	var data := _read_json(FISH_PATH)
	var raw: Variant = data.get("fish", [])
	if typeof(raw) != TYPE_ARRAY:
		_problem("fish 不是数组")
		return
	for item_value: Variant in raw:
		if typeof(item_value) != TYPE_DICTIONARY:
			_problem("fish 里有条目不是对象")
			continue
		var entry: Dictionary = item_value
		var fish_id := String(entry.get("id", ""))
		if fish_id.is_empty():
			_problem("鱼种缺 id")
			continue
		if not get_fish(fish_id).is_empty():
			_problem("鱼种 id 重复：%s" % fish_id)
			continue
		if not FishingGear.RARITY_WEIGHT.has(String(entry.get("rarity", "common"))):
			_problem("鱼种 %s 的稀有度未登记：%s" % [fish_id, String(entry.get("rarity", ""))])
		fish_list.append(entry)
	# 反向检查：钓点鱼池里写了不存在的鱼 = 永远钓不到，当场报错而不是静默空池。
	for spot_value: Variant in spots:
		var spot: Dictionary = spot_value
		for fish_value: Variant in spot.get("fish_pool", []):
			if get_fish(String(fish_value)).is_empty():
				_problem("钓点 %s 的鱼池里有不存在的鱼种：%s" % [
					String(spot.get("id", "?")), String(fish_value)])


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
	load_problems.append(text)
	push_error("fishing: " + text)


# ────────────────────────── 查询接口 ──────────────────────────

func get_spot(spot_id: String) -> Dictionary:
	for item_value: Variant in spots:
		var spot: Dictionary = item_value
		if String(spot.get("id", "")) == spot_id:
			return spot
	return {}


## 某世界区域（RegionAtlas 区域号）下的钓点。
func get_spots_for_atlas(atlas_region: int) -> Array:
	var out: Array = []
	for item_value: Variant in spots:
		var spot: Dictionary = item_value
		if int(spot.get("atlas_region", -1)) == atlas_region:
			out.append(spot)
	return out


## 岸边垂钓钓点（unlock=default）：地图页「去钓鱼」只列这些。
## 出海钓点（unlock=boat，D-042）不在此列——它们由距港距离定位，
## 见 BoatSystem.spot_for_distance() 与 FishingGearUI.open_for_boat()。
func get_shore_spots_for_atlas(atlas_region: int) -> Array:
	var out: Array = []
	for item_value: Variant in spots:
		var spot: Dictionary = item_value
		if int(spot.get("atlas_region", -1)) != atlas_region:
			continue
		if String(spot.get("unlock", "default")) != "default":
			continue
		out.append(spot)
	return out


## 某图鉴区域 id 下的钓点。
func get_spots_for_region(region_id: String) -> Array:
	var out: Array = []
	for item_value: Variant in spots:
		var spot: Dictionary = item_value
		if String(spot.get("region_id", "")) == region_id:
			out.append(spot)
	return out


func get_fish(fish_id: String) -> Dictionary:
	for item_value: Variant in fish_list:
		var entry: Dictionary = item_value
		if String(entry.get("id", "")) == fish_id:
			return entry
	return {}


## 该钓点在当前「饵 + 水层」下的候选鱼（不排序，顺序同鱼池）。
## depth 传空串表示不限水层（选饵阶段预览用）。
func get_fish_pool(spot_id: String, bait_id: String, depth: String = "") -> Array:
	var spot := get_spot(spot_id)
	if spot.is_empty():
		return []
	var out: Array = []
	for fish_value: Variant in spot.get("fish_pool", []):
		var entry := get_fish(String(fish_value))
		if entry.is_empty():
			continue
		if not depth.is_empty() and String(entry.get("depth", "")) != depth:
			continue
		out.append(entry)
	return out


## 候选鱼 + 权重（UI 显示适配度、hook_fish 抽取都用它）。
## sinker_id 为空时按无惩罚计算（选饵阶段还没配坠）。
func weighted_pool(spot_id: String, bait_id: String, depth: String, sinker_id: String = "") -> Array:
	var bait_item := gear.bait(bait_id)
	var sinker_item := gear.sinker(sinker_id)
	var out: Array = []
	for item_value: Variant in get_fish_pool(spot_id, bait_id, depth):
		var entry: Dictionary = item_value
		out.append({
			"fish": entry,
			"id": String(entry.get("id", "")),
			"weight": FishingGear.weight_of(entry, bait_item, sinker_item),
			"match": FishingGear.bait_match(bait_item, entry),
		})
	return out


## 这套「饵 + 坠」在该水层的最高匹配度（< BITE_MIN_MATCH 就是钓不动）。
func best_match(spot_id: String, bait_id: String, depth: String, sinker_id: String) -> float:
	var best := 0.0
	for item_value: Variant in weighted_pool(spot_id, bait_id, depth, sinker_id):
		var item: Dictionary = item_value
		best = maxf(best, float(item["match"]) * FishingGear.sinker_factor(
			gear.sinker(sinker_id), String((item["fish"] as Dictionary).get("depth", ""))))
	return best


## 抛投前的「这一竿会碰上谁」（D-083）：当前力度落在哪个水层、那一层最猛的是哪条鱼、
## 手上这根线扛不扛得住它。
##
## 为什么要预告：收线是「拉力越高压得越难」的博弈，孩子没法从「深水」两个字反推出
## 「这里有拉力 9 的大白鲨」。原来只有先失败一次才知道自己打不过——而 `fish_escaped`
## 是纯粹白费一趟，没有任何「下次更聪明」的线索。预告把这一步提前到松手之前。
##
## 纯查询：只读数据表，不改任何状态，UI 每帧调用也安全（池子只有 2~3 条鱼）。
func cast_preview(power: float) -> Dictionary:
	var distance := FishingGear.cast_distance(gear.sinker(_sinker_id), power)
	# 只算**这套饵 + 这个坠真的能招来**的鱼（权重 0 = 诱不来），
	# 否则会用一条不会上钩的大鱼吓退孩子。
	var reachable := {}
	for item_value: Variant in weighted_pool(_spot_id, _bait_id,
			FishingGear.band_of(distance), _sinker_id):
		var item: Dictionary = item_value
		if float(item.get("weight", 0.0)) <= 0.0:
			continue
		var fish: Dictionary = item["fish"]
		reachable[String(fish.get("id", ""))] = fish
	return _preview_of(distance, reachable)


## cast_preview 的纯函数版本（探针直接喂 fish 名单，不必开一场 session）。
func _preview_of(distance: float, pool_by_id: Dictionary) -> Dictionary:
	var band := FishingGear.band_of(distance)
	var hardest: Dictionary = {}
	for key: Variant in pool_by_id:
		var entry: Dictionary = pool_by_id[key]
		if hardest.is_empty() or int(entry.get("fight_power", 1)) \
				> int(hardest.get("fight_power", 1)):
			hardest = entry
	var out := {
		"distance_m": distance,
		"band": band,
		"band_title": FishingGear.band_title(band),
		"hardest_id": "",
		"hardest_name": "",
		"hardest_fight": 0,
		"line_short": false,
	}
	if hardest.is_empty():
		return out
	var fight := int(hardest.get("fight_power", 0))
	var line_strength := int(gear.line(String(_gear_set.get("line", ""))).get("strength", 0))
	out["hardest_id"] = String(hardest.get("id", ""))
	out["hardest_name"] = String(hardest.get("name_zh", ""))
	out["hardest_fight"] = fight
	out["line_short"] = line_strength < fight
	return out


# ────────────────────────── 状态机 ──────────────────────────

func set_state(next: int) -> void:
	state = next
	fishing_state_changed.emit(next)


## 开钓：校验装配，记录钓点与装备，进入选饵阶段。
func start_fishing(spot_id: String, gear_set: Dictionary) -> bool:
	if get_spot(spot_id).is_empty():
		fishing_failed.emit("spot_missing")
		return false
	var issues := gear.validate(gear_set)
	if not issues.is_empty():
		fishing_failed.emit(String(issues[0]))
		return false
	_spot_id = spot_id
	_gear_set = gear_set.duplicate(true)
	_bait_id = ""
	_sinker_id = ""
	_cast_distance = 0.0
	_band = ""
	_pool = []
	_hooked = {}
	_hooked_id = ""
	_progress = 0.0
	_tension = 0.0
	_escape = 0.0
	_elapsed = 0.0
	_drag = float(gear.reel(String(gear_set.get("reel", ""))).get("drag_max", 2)) * 0.5
	_bump_stat("casts")
	set_state(State.SELECT_BAIT)
	return true


func select_bait(bait_id: String) -> void:
	_bait_id = bait_id
	set_state(State.SELECT_SINKER)


func select_sinker(sinker_id: String) -> void:
	_sinker_id = sinker_id
	set_state(State.CASTING)


## 抛投：power 0~1，返回落点距离（米），并把落点折算成水层与候选鱼。
## 匹配度不足时直接判定「这一竿没鱼」，不走等待阶段。
func cast_power(power: float) -> float:
	_cast_distance = FishingGear.cast_distance(gear.sinker(_sinker_id), power)
	_band = FishingGear.band_of(_cast_distance)
	_pool = weighted_pool(_spot_id, _bait_id, _band, _sinker_id)
	var match_value := best_match(_spot_id, _bait_id, _band, _sinker_id)
	if _pool.is_empty() or match_value < BITE_MIN_MATCH:
		_wait_total = 0.0
		_wait_left = 0.0
		fishing_failed.emit("no_bite")
		set_state(State.RESULT)
		return _cast_distance
	var hardest := 0
	for item_value: Variant in _pool:
		var item: Dictionary = item_value
		hardest = maxi(hardest, int((item["fish"] as Dictionary).get("difficulty", 1)))
	_wait_total = WAIT_BASE + float(hardest) * WAIT_PER_DIFFICULTY
	_wait_left = _wait_total
	_progress = 0.0
	_tension = 0.0
	_escape = 0.0
	_elapsed = 0.0
	_log_replay("cast", "")
	set_state(State.WAITING)
	return _cast_distance


## 推进等待：返回 0（还在等）/ 1（咬钩了）/ -1（等超时，没鱼）。
func update_wait(delta: float) -> int:
	if state != State.WAITING:
		return 0
	_wait_left -= delta
	if _wait_left > 0.0:
		return 0
	if _wait_total <= 0.0:
		return -1
	if _wait_left <= -_wait_total * (NO_BITE_FACTOR - 1.0):
		fishing_failed.emit("no_bite")
		set_state(State.RESULT)
		return -1
	set_state(State.HOOKED)
	return 1


## 咬钩：按权重抽一条鱼，进入收线阶段。返回鱼的数据字典。
func hook_fish() -> Dictionary:
	_hooked = _pick_weighted(_pool)
	_hooked_id = String(_hooked.get("id", ""))
	_progress = 0.0
	_tension = 0.0
	_escape = 0.0
	_elapsed = 0.0
	var fish_item := get_fish(_hooked_id)
	_phase = float(_hooked_id.hash() % 628) / 100.0
	set_state(State.REELING)
	return fish_item


## 收线：input = 1 按住收线 / 0 松开放线。返回当前进度（0~1）。
## 断线或跑鱼时发出 fishing_failed 并切到 RESULT。
func update_reel(delta: float, input: float) -> float:
	if state != State.REELING:
		return _progress
	var fish_item := get_fish(_hooked_id)
	var fight := float(fish_item.get("fight_power", 1))
	var reel_item := gear.reel(String(_gear_set.get("reel", "")))
	var line_item := gear.line(String(_gear_set.get("line", "")))
	_elapsed += delta

	var struggle := 0.5 + 0.5 * sin(_elapsed * STRUGGLE_HZ + _phase)
	var reeling := input > 0.5
	var fish_pos := fish_position()

	if reeling:
		var net := fight * TENSION_FIGHT * (0.75 + 0.5 * struggle) \
			+ _drag * TENSION_DRAG - TENSION_RELIEF
		if int(line_item.get("strength", 0)) < int(fish_item.get("fight_power", 0)):
			net *= LINE_WEAK_FACTOR
		if absf(fish_pos - 0.5) > SAFE_HALF_WIDTH:
			net *= HARD_PULL_FACTOR
		net *= TENSION_SCALE
		_tension = clampf(_tension + net * delta, 0.0, 1.0)
		_progress += float(reel_item.get("speed", 2)) * REEL_RATE * (1.0 - 0.4 * _tension) * delta
	else:
		_tension = maxf(0.0, _tension - TENSION_RELEASE * delta)
		_progress = maxf(0.0, _progress - fight * SLIP_RATE * delta)

	_escape += maxf(0.0, fight * ESCAPE_FIGHT - _drag * ESCAPE_DRAG) * delta

	if _tension >= 1.0:
		_bump_stat("escapes")
		fishing_failed.emit("line_broke")
		_log_replay("break", _hooked_id)
		set_state(State.RESULT)
		return _progress
	if _escape >= 1.0:
		_bump_stat("escapes")
		fishing_failed.emit("fish_escaped")
		_log_replay("escape", _hooked_id)
		set_state(State.RESULT)
		return _progress
	if _progress >= 1.0:
		_progress = 1.0
		set_state(State.RESULT)
	return _progress


## 鱼在移动条上的位置（0~1，0.5 居中）。与安全区一起决定能不能硬收。
func fish_position() -> float:
	return clampf(0.5 + 0.36 * sin(_elapsed * STRUGGLE_SWIM_HZ + _phase), 0.0, 1.0)


## 收线阶段的全部可视状态（UI 每帧读这一份，不要各自算一套）。
func reel_state() -> Dictionary:
	return {
		"progress": _progress,
		"tension": _tension,
		"escape": _escape,
		"fish_pos": fish_position(),
		"safe_min": 0.5 - SAFE_HALF_WIDTH,
		"safe_max": 0.5 + SAFE_HALF_WIDTH,
		"drag": _drag,
		"drag_max": float(gear.reel(String(_gear_set.get("reel", ""))).get("drag_max", 2)),
		"fish_id": _hooked_id,
	}


## 调整卸力（0 ~ 渔轮 drag_max）。
func set_drag(value: float) -> void:
	var drag_max := float(gear.reel(String(_gear_set.get("reel", ""))).get("drag_max", 2))
	_drag = clampf(value, 0.0, drag_max)


func add_drag(delta_value: float) -> void:
	set_drag(_drag + delta_value)


## 结算：进度满才算钓上来。写入日志、图鉴记录与任务计数器。
func try_catch() -> Dictionary:
	if _progress < 1.0 or _hooked_id.is_empty():
		return {}
	var fish_item := get_fish(_hooked_id)
	var weight := _roll_weight(fish_item)
	var records_value: Variant = journal.get("records", {})
	if typeof(records_value) != TYPE_DICTIONARY:
		records_value = {}
	var records: Dictionary = records_value
	var is_new := not records.has(_hooked_id)
	var now_text := _now_text()
	var record_value: Variant = records.get(_hooked_id, {})
	var record: Dictionary = record_value if typeof(record_value) == TYPE_DICTIONARY else {}
	record["first_caught_at"] = String(record.get("first_caught_at", now_text))
	record["first_caught_spot"] = String(record.get("first_caught_spot", _spot_id))
	record["first_caught_gear"] = record.get("first_caught_gear", _gear_snapshot())
	# 个人最佳：更新前先取旧值，用来判定「这一条是不是新纪录」。
	var prev_best := float(record.get("max_weight_kg", 0.0))
	record["last_caught_at"] = now_text
	record["catch_count"] = int(record.get("catch_count", 0)) + 1
	record["max_weight_kg"] = maxf(prev_best, weight)
	record["released"] = int(record.get("released", 0))
	records[_hooked_id] = record
	journal["records"] = records
	_bump_stat("catches")
	_log_replay("catch", _hooked_id)
	_notify_catch(fish_item)
	var result := {
		"fish_id": _hooked_id,
		"fish": fish_item,
		"spot_id": _spot_id,
		"spot_name_zh": String(get_spot(_spot_id).get("name_zh", "")),
		"gear": _gear_snapshot(),
		"weight_kg": weight,
		"depth": _band,
		"distance_m": _cast_distance,
		"is_new_species": is_new,
		"is_personal_best": weight > prev_best,
		"catch_count": int(record["catch_count"]),
	}
	_last_catch = result
	fish_caught.emit(_hooked_id, _spot_id, _gear_snapshot())
	if is_new:
		new_species_unlocked.emit(_hooked_id)
	_save_journal()
	journal_changed.emit()
	return result


## 最近一次成功钓获的完整结算（含 weight_kg / is_personal_best / catch_count）。
## HUD 据此计算回报条数——`fish_caught` 信号刻意不加参数，以免破坏既有探针连接。
func last_catch() -> Dictionary:
	return _last_catch


## 一条鱼该给多少条生鱼（M9 钓鱼完善）。稀有度定基础值，破个人最佳 +1。
## 纯函数，便于探针直接断言；result 缺省时按「不是新纪录」处理。
func loot_count_for(fish_id: String, result: Dictionary = {}) -> int:
	var entry := get_fish(fish_id)
	var rarity := String(entry.get("rarity", "common"))
	var count := int(RARITY_LOOT.get(rarity, 1))
	if bool(result.get("is_personal_best", false)):
		count += 1
	return count


## 放生：只记次数与任务计数，不删图鉴记录（钓到过就是钓到过）。
func release_fish(fish_id: String) -> void:
	var records_value: Variant = journal.get("records", {})
	if typeof(records_value) != TYPE_DICTIONARY:
		return
	var records: Dictionary = records_value
	var record_value: Variant = records.get(fish_id, {})
	if typeof(record_value) != TYPE_DICTIONARY:
		return
	var record: Dictionary = record_value
	record["released"] = int(record.get("released", 0)) + 1
	records[fish_id] = record
	_bump_stat("releases")
	_log_replay("release", fish_id)
	if Progress != null:
		Progress.notify("fish_released")
	_save_journal()
	journal_changed.emit()


## 收工：回到 IDLE，清空这一竿。
func end_session() -> void:
	_hooked_id = ""
	_hooked = {}
	_pool = []
	_progress = 0.0
	_tension = 0.0
	_escape = 0.0
	set_state(State.IDLE)


func _notify_catch(fish_item: Dictionary) -> void:
	if Progress == null:
		return
	Progress.notify("fish_caught")
	var spot := get_spot(_spot_id)
	Progress.notify("fished_region_%d" % int(spot.get("atlas_region", -1)))
	if String(fish_item.get("depth", "")) == FishingGear.BAND_DEEP:
		Progress.notify("fish_deep")
	var rarity := String(fish_item.get("rarity", "common"))
	if rarity == "rare" or rarity == "epic" or rarity == "legendary":
		Progress.notify("fish_rare")
	var bait_item := gear.bait(_bait_id)
	if String(bait_item.get("type", "")) == "lure" and (fish_item.get("tags", []) as Array).has("predator"):
		Progress.notify("fish_lure_predator")


func _pick_weighted(pool: Array) -> Dictionary:
	var total := 0.0
	for item_value: Variant in pool:
		var item: Dictionary = item_value
		total += float(item.get("weight", 0.0))
	if total <= 0.0 or pool.is_empty():
		return {}
	var roll := randf() * total
	for item_value2: Variant in pool:
		var item2: Dictionary = item_value2
		roll -= float(item2.get("weight", 0.0))
		if roll <= 0.0:
			return item2
	var last: Dictionary = pool[pool.size() - 1]
	return last


func _roll_weight(fish_item: Dictionary) -> float:
	var raw: Variant = fish_item.get("weight_kg", [1.0, 1.0])
	if typeof(raw) != TYPE_ARRAY or (raw as Array).size() < 2:
		return 1.0
	var range_arr: Array = raw
	return snappedf(randf_range(float(range_arr[0]), float(range_arr[1])), 0.01)


func _gear_snapshot() -> Dictionary:
	return {
		"rod": String(_gear_set.get("rod", "")),
		"reel": String(_gear_set.get("reel", "")),
		"line": String(_gear_set.get("line", "")),
		"bait": _bait_id,
		"sinker": _sinker_id,
	}


## 当前这竿的上下文（UI 显示用）。
func session_info() -> Dictionary:
	return {
		"spot_id": _spot_id,
		"spot_name_zh": String(get_spot(_spot_id).get("name_zh", "")),
		"band": _band,
		"band_title": FishingGear.band_title(_band),
		"distance_m": _cast_distance,
		"bait_id": _bait_id,
		"sinker_id": _sinker_id,
		"gear": _gear_set.duplicate(true),
		"state": state,
		"wait_left": _wait_left,
		"wait_total": _wait_total,
	}


# ────────────────────────── 日志（按槽派生的 fishing_journal.json） ──────────────────────────

## D-086：路径随档案槽重算。无槽时 Profile.slot_file() 逐字节产出旧根路径
## "user://fishing_journal.json"，有槽时落到 user://profiles/<id>/。
func _refresh_path() -> void:
	if Profile != null:
		JOURNAL_PATH = Profile.slot_file("fishing_journal.json")


## 换槽 = 换路径 + 整体重载内存态。_load_journal() 里的 journal = {...} 是全文件
## 唯一的 Dictionary 整体替换（其余都是 journal["key"] = ... 原地 mutate），因此
## 任何缓存过 journal / journal["records"] / record_of() 子字典的旧引用都会在此刻
## 失效——这正是下一批「钓鱼收集册」要依赖的语义，别把它改成原地清空。
## 不额外 _save_journal()：每次改动都已即时落盘（见各 _save_journal 调用），换槽
## 时没有待刷盘的脏态，多写一次只会在 create_slot 这类「未选中任何槽」的事件里
## 制造一次无谓写盘。也刻意不重跑 _refresh_gear_unlocks()：slot_changed 是在
## Progress._load() 之前 emit 的，此刻 Progress 还挂着上一槽的已领任务，重跑会把
## A 槽解锁的渔具误授进 B 槽（新槽的 gear 列表应以该槽 journal 为准）。
func _on_slot_changed(_id: String) -> void:
	_refresh_path()
	_load_journal()


func _load_journal() -> void:
	journal = {"version": 1, "records": {}, "gear": [], "lessons_seen": [], "replay": [],
		"stats": {}}
	# 读档成功与否要记住：读失败（文件被写坏 / 半截 JSON）时绝不能再把默认状态
	# 写回盘——否则一次瞬时读失败就会永久抹掉孩子的钓鱼图鉴（实测踩过）。
	journal_ok = false
	if not FileAccess.file_exists(JOURNAL_PATH):
		_grant_default_gear()
		journal_ok = true
		return
	var file := FileAccess.open(JOURNAL_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("FishingSystem: %s 解析失败，本次不回写以保护原档" % JOURNAL_PATH)
		return
	var data: Dictionary = parsed
	for key: String in ["records", "gear", "lessons_seen", "replay", "stats"]:
		if data.has(key):
			journal[key] = data[key]
	_grant_default_gear()
	journal_ok = true


## 落盘。原子写（先写 .tmp 再改名覆盖）+ 读档失败时拒写：
##   · 原子写：FileAccess WRITE 会先把原文件截成 0 字节，若此刻进程被信号打断
##     （本工程 headless 退出期偶发段错误），存档就被清空了——改成先写临时文件、
##     再 rename 覆盖，任何时刻盘上都有一份完整存档。
##   · 拒写：_load_journal 失败时 journal 只是默认模板，回写等于抹档，直接跳过。
func _save_journal() -> void:
	if not journal_ok:
		return
	var text := JSON.stringify(journal)
	var tmp := JOURNAL_PATH + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp),
		ProjectSettings.globalize_path(JOURNAL_PATH))


func _bump_stat(key: String) -> void:
	var stats_value: Variant = journal.get("stats", {})
	if typeof(stats_value) != TYPE_DICTIONARY:
		stats_value = {}
	var stats: Dictionary = stats_value
	stats[key] = int(stats.get(key, 0)) + 1
	journal["stats"] = stats


func stat_of(key: String) -> int:
	var stats_value: Variant = journal.get("stats", {})
	if typeof(stats_value) != TYPE_DICTIONARY:
		return 0
	var stats: Dictionary = stats_value
	return int(stats.get(key, 0))


## 某鱼种的钓获记录（没钓到过返回空字典）。
func record_of(fish_id: String) -> Dictionary:
	var records_value: Variant = journal.get("records", {})
	if typeof(records_value) != TYPE_DICTIONARY:
		return {}
	var records: Dictionary = records_value
	var record_value: Variant = records.get(fish_id, {})
	if typeof(record_value) != TYPE_DICTIONARY:
		return {}
	var record: Dictionary = record_value
	return record


func catch_count(fish_id: String) -> int:
	return int(record_of(fish_id).get("catch_count", 0))


func discovered_count() -> int:
	var records_value: Variant = journal.get("records", {})
	if typeof(records_value) != TYPE_DICTIONARY:
		return 0
	var records: Dictionary = records_value
	return records.size()


# ────────────────────────── 四大洋收集册（D-087） ──────────────────────────
## 收集册按 data/fishing/fish.json 的 region_id（字符串）分组，**不用 spot_ids**
## 反推：二者有 12 处不一致（如 great_white_shark 声明在近岸、实际只在远海
## fish_pool 里），用 spot_ids 会把远海鱼错分到近岸组。分组是静态表计算，
## 不随存档槽变；「是否集齐」一律从 journal["records"] 现算，「是否已领奖」
## 才落 journal["stats"] 的一次性标记（见 claim_bundle）。
const BUNDLE_REGIONS: Array[String] = [
	"pacific_ocean", "atlantic_ocean", "indian_ocean", "arctic_ocean",
]
## 海域中文名（奖励称号用；UI 组标题另用 FishingCollectionUI.REGION_TITLES，
## 二者取值一致但各管一处，均不复用 RegionAtlas 的 int 键——裁决 5）。
const BUNDLE_TITLES := {
	"pacific_ocean": "太平洋",
	"atlantic_ocean": "大西洋",
	"indian_ocean": "印度洋",
	"arctic_ocean": "北冰洋",
	"all": "四大洋",
}
## 集齐奖励的即时惊喜量级（与现有任务链 1~6 绿宝石同量级，D-087 默认假设）。
## 注意 inventory 不落盘（main.gd 仅跨场景内存携带 GameState.carried_inventory），
## 绿宝石是「这一局」的惊喜；真正随存档槽持久、可回看的是 stat_of 徽章状态。
const BUNDLE_REWARD_SINGLE := 3
const BUNDLE_REWARD_ALL := 8


## 某海域的 5 个 fish_id（从静态 fish_list 现算，顺序同 JSON）。
func bundle_ids(region_id: String) -> Array[String]:
	var out: Array[String] = []
	for item_value: Variant in fish_list:
		var entry: Dictionary = item_value
		if String(entry.get("region_id", "")) == region_id:
			out.append(String(entry.get("id", "")))
	return out


## 是否集齐：从 records 现算，绝不落盘。空组（如 region_id="all"）视为未集齐。
func bundle_complete(region_id: String) -> bool:
	var ids := bundle_ids(region_id)
	if ids.is_empty():
		return false
	for id: String in ids:
		if catch_count(id) <= 0:
			return false
	return true


## 「已领取」是一次性事件：必须落标记才能跨会话 / 跨切槽幂等。标记放在既有
## journal["stats"]，随 JOURNAL_PATH 按槽落盘、随 _load_journal 整体替换归零。
func bundle_claimed(region_id: String) -> bool:
	return stat_of("bundle_" + region_id) > 0


func all_bundles_complete() -> bool:
	for region_id: String in BUNDLE_REGIONS:
		if not bundle_complete(region_id):
			return false
	return true


## 唯一写入点。未集齐 / 已领过 / 非法海域均返回空字典（幂等闸门）。返回的
## reward 交给 HUD 发绿宝石 + Toast；称号 / 徽章的「永久点亮」不靠这条字典，
## 而是收集册每次 open() 现取 bundle_claimed() 显示，随 journal 按槽持久。
func claim_bundle(region_id: String) -> Dictionary:
	var is_all := region_id == "all"
	if not is_all and not BUNDLE_REGIONS.has(region_id):
		return {}
	var complete := all_bundles_complete() if is_all else bundle_complete(region_id)
	if not complete or bundle_claimed(region_id):
		return {}
	_bump_stat("bundle_" + region_id)
	_save_journal()
	journal_changed.emit()
	return {
		"item": ItemTypes.EMERALD,
		"count": BUNDLE_REWARD_ALL if is_all else BUNDLE_REWARD_SINGLE,
		"title": "◆ %s收藏家" % String(BUNDLE_TITLES.get(region_id, "海洋")),
		"badge": region_id,
		"region_id": region_id,
	}


## 回放日志（最近 REPLAY_CAP 条，先发生的在前）。
const REPLAY_CAP := 300


func _log_replay(action: String, fish_id: String) -> void:
	var replay_value: Variant = journal.get("replay", [])
	if typeof(replay_value) != TYPE_ARRAY:
		replay_value = []
	var replay: Array = replay_value
	replay.append({
		"tick": Time.get_ticks_msec(),
		"action": action,
		"spot": _spot_id,
		"fish_id": fish_id,
		"player": PLAYER_LABEL,
	})
	while replay.size() > REPLAY_CAP:
		replay.remove_at(0)
	journal["replay"] = replay


func replay_log() -> Array:
	var replay_value: Variant = journal.get("replay", [])
	if typeof(replay_value) != TYPE_ARRAY:
		return []
	var replay: Array = replay_value
	return replay


# ────────────────────────── 钓具拥有与解锁 ──────────────────────────

func owned_ids(kind: String) -> PackedStringArray:
	var out := PackedStringArray()
	var owned_value: Variant = journal.get("gear", [])
	if typeof(owned_value) != TYPE_ARRAY:
		owned_value = []
	var owned: Array = owned_value
	for item_value: Variant in gear.items_of(kind):
		var item: Dictionary = item_value
		if owned.has(String(item.get("id", ""))):
			out.append(String(item.get("id", "")))
	return out


## 已拥有的钓具（按类别，UI 直接遍历）。
func owned_items(kind: String) -> Array:
	var out: Array = []
	var owned_value: Variant = journal.get("gear", [])
	if typeof(owned_value) != TYPE_ARRAY:
		owned_value = []
	var owned: Array = owned_value
	for item_value: Variant in gear.items_of(kind):
		var item: Dictionary = item_value
		if owned.has(String(item.get("id", ""))):
			out.append(item)
	return out


func owns(item_id: String) -> bool:
	var owned_value: Variant = journal.get("gear", [])
	if typeof(owned_value) != TYPE_ARRAY:
		return false
	var owned: Array = owned_value
	return owned.has(item_id)


func grant_gear(item_id: String) -> bool:
	if owns(item_id):
		return false
	var owned_value: Variant = journal.get("gear", [])
	if typeof(owned_value) != TYPE_ARRAY:
		owned_value = []
	var owned: Array = owned_value
	owned.append(item_id)
	journal["gear"] = owned
	_save_journal()
	journal_changed.emit()
	return true


func _grant_default_gear() -> void:
	for kind: String in FishingGear.KINDS:
		for item_value: Variant in gear.items_of(kind):
			var item: Dictionary = item_value
			if gear.is_default_unlocked(item):
				var owned_value: Variant = journal.get("gear", [])
				if typeof(owned_value) != TYPE_ARRAY:
					owned_value = []
				var owned: Array = owned_value
				if not owned.has(String(item.get("id", ""))):
					owned.append(String(item.get("id", "")))
					journal["gear"] = owned


## 任务领奖后按 unlock 发放钓具（unlock = "quest:<任务id>"）。
func _refresh_gear_unlocks() -> void:
	if Progress == null:
		return
	for kind: String in FishingGear.KINDS:
		for item_value: Variant in gear.items_of(kind):
			var item: Dictionary = item_value
			var quest_id := gear.quest_of(item)
			if quest_id.is_empty():
				continue
			if int(Progress.state_of(quest_id)) == Progress.State.CLAIMED:
				grant_gear(String(item.get("id", "")))


func _on_quest_claimed(_id: String, _reward: Dictionary) -> void:
	_refresh_gear_unlocks()


# ────────────────────────── 教学 ──────────────────────────

func lessons_seen() -> Array:
	var seen_value: Variant = journal.get("lessons_seen", [])
	if typeof(seen_value) != TYPE_ARRAY:
		return []
	var seen: Array = seen_value
	return seen


func has_seen_lesson(lesson_id: String) -> bool:
	return lessons_seen().has(lesson_id)


func mark_lesson_seen(lesson_id: String) -> void:
	if has_seen_lesson(lesson_id):
		return
	var seen_value: Variant = journal.get("lessons_seen", [])
	if typeof(seen_value) != TYPE_ARRAY:
		seen_value = []
	var seen: Array = seen_value
	seen.append(lesson_id)
	journal["lessons_seen"] = seen
	_save_journal()
	journal_changed.emit()


## 该触发时机要不要弹教学：看过就不弹。
func pending_lesson(trigger: String) -> Dictionary:
	if teaching == null:
		return {}
	var lesson := teaching.lesson_for_trigger(trigger)
	if lesson.is_empty():
		return {}
	if has_seen_lesson(String(lesson.get("id", ""))):
		return {}
	return lesson


## 重看教学：清空已看记录，返回第一课。
func reset_lessons() -> Dictionary:
	journal["lessons_seen"] = []
	_save_journal()
	journal_changed.emit()
	if teaching == null:
		return {}
	return teaching.next_unseen([])


func _now_text() -> String:
	var d := Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02dT%02d:%02d:%02d" % [
		int(d["year"]), int(d["month"]), int(d["day"]),
		int(d["hour"]), int(d["minute"]), int(d["second"]),
	]


func state_name(state_value: int = -1) -> String:
	var which := state if state_value < 0 else state_value
	match which:
		State.IDLE:
			return "待机"
		State.SELECT_GEAR:
			return "选钓具"
		State.SELECT_BAIT:
			return "选鱼饵"
		State.SELECT_SINKER:
			return "配铅坠"
		State.CASTING:
			return "抛投"
		State.WAITING:
			return "等咬钩"
		State.HOOKED:
			return "咬钩"
		State.REELING:
			return "收线"
		State.RESULT:
			return "结算"
	return "?"
