extends Node
## 航海系统（Autoload：BoatSystem）——四大洋航海玩法（D-042）的中枢。
##
## 不写 class_name：同 RaceSystem/FishingSystem，Godot 不允许脚本类名与
## autoload 单例同名。
##
## 职责边界（与 RaceSystem 对齐：数据 + 拥有 + 派生状态，不含 UI 与节点）：
##   - 加载 data/boating/boats.json（船型表，带校验）；
##   - 管「拥有哪些船」与「当前驾驶哪艘」：user://boats.json 持久化，
##     开局默认发放一艘木筏（系统默认提供，玩家进大洋就有船可划）；
##   - 海况模型：由天气 × 时刻 × 区域派生浪高与风（ BoatPhysics 与
##     航海 HUD 共用同一份，勿各算一套）；
##   - 出海距离 → 钓点分带：near/mid/far 三档，对应 spots.json 里的
##     12 个出海钓点（四大洋 × 3 带）；
##   - 输入挂起：模态面板（地图选择器/钓具界面）打开时锁舵，船不乱跑。
##
## 船在世界里的实体是 Boat 节点（scripts/vehicles/boat.gd），本类不持有
## 节点引用——Main 负责摆船，HUD 通过 Player.boat() 找当前驾驶的船。

signal journal_changed
## 拥有列表变化（默认发放 / 任务奖励解锁）时广播。
signal boat_unlocked(boat_id: String)

const DATA_PATH := "res://data/boating/boats.json"
const JOURNAL_PATH := "user://boats.json"

## 出海距离分带（米；D-062 P1 起 1 格 = 1 m，格距离即米，HUD 与探针都读这两个阈值）。
const NEAR_MAX_M := 100.0
const MID_MAX_M := 250.0
## 分带 → 钓点 id 后缀（spots.json 里 <ocean>_near/_mid/_far）。
const BAND_SUFFIX := {"near": "near", "mid": "mid", "far": "far"}
## 分带显示名（HUD 与钓具界面共用）。
const BAND_TITLES := {
	"near": "近海渔场",
	"mid": "中海渔场",
	"far": "远海渔场",
}

## 海况模型参数（设计值，米）：
##   基础浪高按区域（北冰洋封冻海面浪高、其余大洋平静），
##   天气加成（阴 +0.3 / 雨 +0.8），长周期涌浪 sin 叠加（±0.25 m）。
const SEA_BASE_WAVE := {RegionAtlas.ARCTIC: 1.2}
const SEA_WEATHER_WAVE := {"clear": 0.0, "cloudy": 0.3, "rain": 0.8}
## 风的区间（m/s）与风向基准（度，0 = 北）。风向按「区域种子 × 时刻」
## 缓慢旋转，不是随机数——同一秒进同一片海，风是一致的。
const WIND_MIN_MPS := 2.0
const WIND_MAX_MPS := 9.0
## 风向旋转周期（秒）：约 4 分钟转一圈，比涌浪慢一个量级。
const WIND_TURN_PERIOD := 240.0

var boats: Array = []
var load_problems: PackedStringArray = PackedStringArray()

## 持久化日志：{"version": 1, "owned": [...], "current": "...",
##              "fuel": {boat_id: 升}}。
var journal: Dictionary = {}
var journal_ok := false

## 模态面板打开时为真：Boat 不读输入（地图选择器 / 钓具界面/ 教学浮层）。
var input_suspended := false


func _ready() -> void:
	load_data()
	_load_journal()
	_grant_default_boat()


func _exit_tree() -> void:
	_save_journal()


# ────────────────────────── 数据加载 ──────────────────────────

func load_data() -> void:
	load_problems = PackedStringArray()
	boats = []
	if not FileAccess.file_exists(DATA_PATH):
		_problem("文件不存在：" + DATA_PATH)
		return
	var file := FileAccess.open(DATA_PATH, FileAccess.READ)
	if file == null:
		_problem("无法打开：" + DATA_PATH)
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		_problem("JSON 解析失败（%s 第 %d 行）" % [DATA_PATH, json.get_error_line()])
		return
	if typeof(json.data) != TYPE_DICTIONARY:
		_problem("顶层不是对象：" + DATA_PATH)
		return
	var raw: Variant = (json.data as Dictionary).get("boats", [])
	if typeof(raw) != TYPE_ARRAY:
		_problem("boats 不是数组")
		return
	for item_value: Variant in raw:
		if typeof(item_value) != TYPE_DICTIONARY:
			_problem("boats 里有条目不是对象")
			continue
		var boat: Dictionary = item_value
		var boat_id := String(boat.get("id", ""))
		if boat_id.is_empty():
			_problem("船型缺 id")
			continue
		if not boat_by_id(boat_id).is_empty():
			_problem("船型 id 重复：%s" % boat_id)
			continue
		if float(boat.get("max_speed_mps", 0.0)) <= 0.0:
			_problem("船型 %s 的极速非正" % boat_id)
		boats.append(boat)


func _problem(text: String) -> void:
	load_problems.append(text)
	push_error("boating: " + text)


## 船型表查询（空字典 = 不存在）。
func boat_by_id(boat_id: String) -> Dictionary:
	for item_value: Variant in boats:
		var boat: Dictionary = item_value
		if String(boat.get("id", "")) == boat_id:
			return boat
	return {}


# ────────────────────────── 拥有与默认发放 ──────────────────────────

## 已拥有的船型 id（按数据表顺序，UI 直接遍历）。
func owned_ids() -> Array:
	var out: Array = []
	var owned_value: Variant = journal.get("owned", [])
	if typeof(owned_value) != TYPE_ARRAY:
		return out
	var owned: Array = owned_value
	for item_value: Variant in boats:
		if owned.has(String((item_value as Dictionary).get("id", ""))):
			out.append(String((item_value as Dictionary).get("id", "")))
	return out


func owns(boat_id: String) -> bool:
	var owned_value: Variant = journal.get("owned", [])
	if typeof(owned_value) != TYPE_ARRAY:
		return false
	return (owned_value as Array).has(boat_id)


## 默认船（开局提供的那艘）：unlock=default 的第一型，表为空时退回 "raft"。
func default_boat_id() -> String:
	for item_value: Variant in boats:
		var boat: Dictionary = item_value
		if String(boat.get("unlock", "")) == "default":
			return String(boat.get("id", ""))
	return "raft"


func grant_boat(boat_id: String) -> bool:
	if boat_by_id(boat_id).is_empty() or owns(boat_id):
		return false
	var owned_value: Variant = journal.get("owned", [])
	var owned: Array = owned_value if typeof(owned_value) == TYPE_ARRAY else []
	owned.append(boat_id)
	journal["owned"] = owned
	if String(journal.get("current", "")).is_empty():
		journal["current"] = boat_id
	_save_journal()
	boat_unlocked.emit(boat_id)
	journal_changed.emit()
	return true


## 当前默认驾驶/使用的船型（没有则发默认船）。
func current_boat_id() -> String:
	var cur := String(journal.get("current", ""))
	if not cur.is_empty() and owns(cur):
		return cur
	return default_boat_id()


func set_current_boat(boat_id: String) -> void:
	if not owns(boat_id):
		return
	journal["current"] = boat_id
	_save_journal()
	journal_changed.emit()


func _grant_default_boat() -> void:
	var default_id := default_boat_id()
	if not default_id.is_empty() and not owns(default_id):
		var owned_value: Variant = journal.get("owned", [])
		var owned: Array = owned_value if typeof(owned_value) == TYPE_ARRAY else []
		owned.append(default_id)
		journal["owned"] = owned
		if String(journal.get("current", "")).is_empty():
			journal["current"] = default_id


## 某船型的持久化油量（升）；没记过则满油。
func fuel_of(boat_id: String) -> float:
	var cap := float(boat_by_id(boat_id).get("fuel_l", 0.0))
	if cap <= 0.0:
		return 0.0
	var fuel_value: Variant = journal.get("fuel", {})
	if typeof(fuel_value) != TYPE_DICTIONARY:
		return cap
	var stored: Variant = (fuel_value as Dictionary).get(boat_id, cap)
	return clampf(float(stored), 0.0, cap)


func set_fuel_of(boat_id: String, liters: float) -> void:
	var cap := float(boat_by_id(boat_id).get("fuel_l", 0.0))
	if cap <= 0.0:
		return
	var fuel_value: Variant = journal.get("fuel", {})
	var fuel: Dictionary = fuel_value if typeof(fuel_value) == TYPE_DICTIONARY else {}
	fuel[boat_id] = clampf(liters, 0.0, cap)
	journal["fuel"] = fuel
	_save_journal()


func _load_journal() -> void:
	journal = {"version": 1, "owned": [], "current": "", "fuel": {}}
	journal_ok = false
	if not FileAccess.file_exists(JOURNAL_PATH):
		journal_ok = true
		return
	var file := FileAccess.open(JOURNAL_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("BoatSystem: %s 解析失败，本次不回写以保护原档" % JOURNAL_PATH)
		return
	var data: Dictionary = parsed
	for key: String in ["owned", "current", "fuel"]:
		if data.has(key):
			journal[key] = data[key]
	journal_ok = true


## 原子写（先 .tmp 再 rename，同 FishingSystem）：FileAccess WRITE 会先把
## 原文件截断，进程被信号打断就会丢档。
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


# ────────────────────────── 海况模型 ──────────────────────────

## 当前海况。参数：
##   region_id  RegionAtlas 区域号（极地浪高基数不同）；
##   weather    DayNightCycle.Weather（晴/阴/雨）；
##   day_t      当日时刻（秒，0~86400）：驱动长周期涌浪与风向旋转；
##   at_harbor  靠近港口时为真：港内浪高减半（避风塘）。
## 返回 {"wave_m", "wind_mps", "wind_deg", "wind_along_mps", "label"}，
## BoatPhysics 与航海 HUD 共用。确定性：同输入同输出（无随机）。
func sea_state(region_id: int, weather: int, day_t: float, at_harbor: bool = false) -> Dictionary:
	var base: float = float(SEA_BASE_WAVE.get(region_id, 0.6))
	var weather_key := "clear"
	match weather:
		DayNightCycle.Weather.CLOUDY:
			weather_key = "cloudy"
		DayNightCycle.Weather.RAIN:
			weather_key = "rain"
	var wave := base + float(SEA_WEATHER_WAVE.get(weather_key, 0.0))
	# 长周期涌浪：约 90 s 一周期，幅度 ±0.25 m。
	wave += 0.25 * sin(day_t * TAU / 90.0)
	wave = maxf(0.0, wave)
	if at_harbor:
		wave *= 0.5  # 避风塘内浪减半
	# 风：强度随时间在区间内起伏，方向约 4 分钟转一圈（区域种子定初相）。
	var seed_phase := float(region_id) * 1.7
	var strength := WIND_MIN_MPS + (WIND_MAX_MPS - WIND_MIN_MPS) \
		* (0.5 + 0.5 * sin(day_t * TAU / WIND_TURN_PERIOD + seed_phase))
	var wind_deg := rad_to_deg(wrapf(day_t * TAU / WIND_TURN_PERIOD + seed_phase, 0.0, TAU))
	return {
		"wave_m": snappedf(wave, 0.01),
		"wind_mps": snappedf(strength, 0.1),
		"wind_deg": snappedf(wind_deg, 1.0),
		"label": sea_label(wave, weather_key),
	}


## 海况一句话（HUD 显示）：浪高 × 天气。
func sea_label(wave_m: float, weather_key: String) -> String:
	var level := "平静"
	if wave_m >= 1.6:
		level = "大浪"
	elif wave_m >= 1.0:
		level = "中浪"
	elif wave_m >= 0.5:
		level = "轻浪"
	match weather_key:
		"rain":
			return "风雨交加 · %s" % level
		"cloudy":
			return "阴 · %s" % level
	return "晴 · %s" % level


## 风的罗经名（HUD 显示「西北风 5 级」式）。
static func wind_name(wind_deg: float) -> String:
	const NAMES := ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
	var idx := int(round(wrapf(wind_deg, 0.0, 360.0) / 45.0)) % 8
	return NAMES[idx]


# ────────────────────────── 出海距离 → 钓点分带 ──────────────────────────

## 距岸距离（米）→ 分带 id（near/mid/far）。
static func band_of(distance_m: float) -> String:
	if distance_m <= NEAR_MAX_M:
		return "near"
	if distance_m <= MID_MAX_M:
		return "mid"
	return "far"


## 分带 → 显示名。
static func band_title(band: String) -> String:
	return String(BAND_TITLES.get(band, band))


## 某大洋在某一分带下的出海钓点 id（spots.json 里预注册）。
static func spot_id_for(region_id: int, band: String) -> String:
	return "%s_%s" % [_ocean_prefix(region_id), String(BAND_SUFFIX.get(band, "near"))]


## RegionAtlas 大洋区域号 → spots.json 的 id 前缀（与静态钓点一致：
## pacific / atlantic / indian / arctic）。
static func _ocean_prefix(region_id: int) -> String:
	match region_id:
		RegionAtlas.PACIFIC:
			return "pacific"
		RegionAtlas.ATLANTIC:
			return "atlantic"
		RegionAtlas.INDIAN:
			return "indian"
		RegionAtlas.ARCTIC:
			return "arctic"
	return "pacific"


## 距岸距离（米）→ 钓点 id（钓鱼入口用）。
static func spot_for_distance(region_id: int, distance_m: float) -> String:
	return spot_id_for(region_id, band_of(distance_m))
