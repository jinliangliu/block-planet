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
## D-086：不再是 const。无槽时按 Profile.slot_dir() 派生回旧根路径
## "user://boats.json"；建槽后落到 user://profiles/<id>/，切槽即重算并重载。
var JOURNAL_PATH: String = "user://boats.json"

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

## 持久化日志（version 2，D-089）：{"version": 2, "owned": [...],
##              "current": "...", "fuel": {boat_id: 升},
##              "sail": {"total_m", "farthest_m", "bands", "badges"}}。
## 扩展的是 D-086 八份之一，不新增第 9 份 user:// 文件；旧档缺 sail 键由
## _load_journal() 逐字段兜底，不需要迁移脚本。
var journal: Dictionary = {}
var journal_ok := false

## 里程防抖（同 Progress.SAVE_INTERVAL_MS）：record_sail() 只改内存 + 标脏，
## _process() 合并到至多每 1.5 s 一次落盘；_exit_tree（仅标脏时）/ claim_badge 仍立即写。
const SAVE_INTERVAL_MS: int = 1500
const JOURNAL_KEYS: Array[String] = ["owned", "current", "fuel"]
const SAIL_BANDS: Array[String] = ["near", "mid", "far"]
## 里程碑徽章（累计里程阈值，米）。badges 里存一次性标记，随槽持久、可回看；
## 不写 Progress.counters（避开 slot_changed 早于 Progress._load() 的串档陷阱）。
const SAIL_BADGES: Array[String] = ["sail_100", "sail_500", "sail_1000"]
const SAIL_BADGE_TARGETS: Dictionary = {
	"sail_100": 100.0, "sail_500": 500.0, "sail_1000": 1000.0,
}
var _dirty: bool = false
var _last_save_msec: int = 0

## 模态面板打开时为真：Boat 不读输入（地图选择器 / 钓具界面/ 教学浮层）。
var input_suspended := false


func _ready() -> void:
	load_data()
	_refresh_path()
	_load_journal()
	_grant_default_boat()
	if Profile != null:
		Profile.slot_changed.connect(_on_slot_changed)


func _exit_tree() -> void:
	# D-089 / D-010：只在本次会话确实改过 journal 时补写。version 1 旧档由
	# _load_journal() 在内存里宽容升级为 version 2，「读到旧档」不等于「玩家改过
	# 存档」；无条件写盘会让玩家只是打开游戏再退出就被改写存档，探针在
	# SaveGuard.restore() 逐字节还原文件后，Autoload 退出期又把内存态覆盖回去
	# （回归 diff -r 报假 DIFF）。未标脏时磁盘文件就是权威；标脏时仍立即
	# flush，保证 1.5 s 防抖窗口没到就退出也不丢里程。
	if _dirty:
		_save_journal()


## 里程落盘防抖：record_sail() 每 0.1 s 一拍，不能每拍都写盘。
## journal_ok=false（损坏档保护 / 探针拒写闸）时直接跳过，别空转。
func _process(_delta: float) -> void:
	if not _dirty or not journal_ok:
		return
	if Time.get_ticks_msec() - _last_save_msec < SAVE_INTERVAL_MS:
		return
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


## D-086：路径随档案槽重算（无槽逐字节等于旧根路径）。
func _refresh_path() -> void:
	if Profile != null:
		JOURNAL_PATH = Profile.slot_file("boats.json")


## 换槽等价于重新开局：换路径 → 重载内存态 → 补发默认木筏，与 _ready() 尾部
## 三行严格一致。只重跑 _load_journal() 会让新槽「一艘船都没有」。
## 注意别误引 FishingSystem 的同名 _load_journal()——两者数据源与形状不同。
func _on_slot_changed(_id: String) -> void:
	_refresh_path()
	_load_journal()
	_grant_default_boat()


## 宽容读档（D-089 version 1 → 2 不需要迁移脚本）：缺 sail 键 / 类型错 /
## 子键缺失一律逐字段填默认，不抛错、不写盘。缺文件仍直接 return
## （journal_ok=true）；损坏 JSON 保持 push_error + return、journal_ok 保持
## false ⇒ _save_journal() 拒写，保护原档（同 flight_teaching.gd:134-136）。
## 顺带清脏位：_on_slot_changed() 必须严格保持三行，清脏放这里才不会在
## 换槽后下一帧把 A 槽状态补写进 B 槽文件。
func _load_journal() -> void:
	journal = {
		"version": 2, "owned": [], "current": "", "fuel": {},
		"sail": _default_sail(),
	}
	journal_ok = false
	_dirty = false
	_last_save_msec = Time.get_ticks_msec()
	if not FileAccess.file_exists(JOURNAL_PATH):
		journal_ok = true
		return
	var file: FileAccess = FileAccess.open(JOURNAL_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("BoatSystem: %s 解析失败，本次不回写以保护原档" % JOURNAL_PATH)
		return
	var data: Dictionary = parsed
	for key: String in JOURNAL_KEYS:
		if data.has(key):
			journal[key] = data[key]
	journal["sail"] = _parse_sail(data.get("sail", null))
	journal_ok = true


static func _default_sail() -> Dictionary:
	return {
		"total_m": 0.0, "farthest_m": 0.0,
		"bands": {"near": 0, "mid": 0, "far": 0},
		"badges": {},
	}


static func _num_or_zero(value: Variant) -> float:
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return maxf(0.0, float(value))
	return 0.0


static func _int_or_zero(value: Variant) -> int:
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return maxi(0, int(value))
	return 0


## 只认结构、不信任类型：老档缺 sail 时整块用默认值，坏子键单独兜底。
static func _parse_sail(value: Variant) -> Dictionary:
	var out: Dictionary = _default_sail()
	if typeof(value) != TYPE_DICTIONARY:
		return out
	var src: Dictionary = value
	out["total_m"] = _num_or_zero(src.get("total_m", null))
	out["farthest_m"] = _num_or_zero(src.get("farthest_m", null))
	var bands_value: Variant = src.get("bands", null)
	if typeof(bands_value) == TYPE_DICTIONARY:
		var bands_src: Dictionary = bands_value
		var bands: Dictionary = out["bands"]
		for key: String in SAIL_BANDS:
			bands[key] = _int_or_zero(bands_src.get(key, null))
		out["bands"] = bands
	var badges_value: Variant = src.get("badges", null)
	if typeof(badges_value) == TYPE_DICTIONARY:
		var badges_src: Dictionary = badges_value
		var badges: Dictionary = {}
		for key_value: Variant in badges_src.keys():
			badges[String(key_value)] = _int_or_zero(badges_src[key_value])
		out["badges"] = badges
	return out


## 原子写（先 .tmp 再 rename，同 FishingSystem）：FileAccess WRITE 会先把
## 原文件截断，进程被信号打断就会丢档。D-089 只补脏位 / 时间戳，不重造原子写。
func _save_journal() -> void:
	if not journal_ok:
		return
	var text: String = JSON.stringify(journal)
	var tmp: String = JOURNAL_PATH + ".tmp"
	var file: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp),
		ProjectSettings.globalize_path(JOURNAL_PATH))
	_dirty = false
	_last_save_msec = Time.get_ticks_msec()


# ────────────────────────── 出海里程与里程碑徽章（D-089） ──────────────────────────

## 返回**拷贝**（bands / badges 子字典也是新建），绝不返回 journal["sail"]
## 内部引用——D-086 §2 的整体替换陷阱：换槽后缓存的旧引用会静默指向旧槽对象。
func sail_state() -> Dictionary:
	var out: Dictionary = _default_sail()
	var sail_value: Variant = journal.get("sail", null)
	if typeof(sail_value) != TYPE_DICTIONARY:
		return out
	var src: Dictionary = sail_value
	out["total_m"] = float(src.get("total_m", 0.0))
	out["farthest_m"] = float(src.get("farthest_m", 0.0))
	var bands_src: Variant = src.get("bands", null)
	if typeof(bands_src) == TYPE_DICTIONARY:
		var bands: Dictionary = out["bands"]
		for key: String in SAIL_BANDS:
			bands[key] = _int_or_zero((bands_src as Dictionary).get(key, null))
		out["bands"] = bands
	var badges_src: Variant = src.get("badges", null)
	if typeof(badges_src) == TYPE_DICTIONARY:
		var badges: Dictionary = out["badges"]
		for k: Variant in (badges_src as Dictionary).keys():
			badges[String(k)] = _int_or_zero((badges_src as Dictionary)[k])
		out["badges"] = badges
	return out


## 唯一累计入口。step_m 是**相邻两次采样的船体 XZ 位移长度**（不是离港距离）；
## harbor_distance_m < 0（无港口）时不更新 farthest_m。bands 只在有位移的采样
## （step_m > 0）累加一次，语义是「有位移的采样拍数」，不是「到访次数」，也不做
## 独立收集册——停泊时 boat.gd 仍以 step_m=0 上报以刷新 farthest_m，若照常 +1
## 会把计数刷成「0.1 s 采样次数」。只改内存 + 标脏，落盘交给 _process() 防抖。
func record_sail(step_m: float, harbor_distance_m: float, band: String) -> void:
	var sail_value: Variant = journal.get("sail", null)
	if typeof(sail_value) != TYPE_DICTIONARY:
		journal["sail"] = _default_sail()
	var sail: Dictionary = journal["sail"]
	sail["total_m"] = float(sail.get("total_m", 0.0)) + maxf(0.0, step_m)
	if harbor_distance_m >= 0.0:
		sail["farthest_m"] = maxf(float(sail.get("farthest_m", 0.0)), harbor_distance_m)
	if step_m > 0.0:
		var bands_value: Variant = sail.get("bands", null)
		var bands: Dictionary = bands_value if typeof(bands_value) == TYPE_DICTIONARY else {}
		var band_key: String = band if SAIL_BANDS.has(band) else "near"
		bands[band_key] = int(bands.get(band_key, 0)) + 1
		sail["bands"] = bands
	journal["sail"] = sail
	_dirty = true


func badge_of(key: String) -> int:
	var state: Dictionary = sail_state()
	var badges: Dictionary = state["badges"]
	return int(badges.get(key, 0))


## 幂等闸门（对齐 FishingSystem.bundle_claimed()）：未达标 / 已领过 / 非法 key
## 均返回 false。领取是一次性事件，落标记后立即写盘，不丢关键进度。
func claim_badge(key: String) -> bool:
	if not SAIL_BADGES.has(key):
		return false
	if badge_of(key) > 0:
		return false
	var state: Dictionary = sail_state()
	if float(state.get("total_m", 0.0)) < float(SAIL_BADGE_TARGETS.get(key, 0.0)):
		return false
	var sail_value: Variant = journal.get("sail", null)
	if typeof(sail_value) != TYPE_DICTIONARY:
		journal["sail"] = _default_sail()
	var sail: Dictionary = journal["sail"]
	var badges_value: Variant = sail.get("badges", null)
	var badges: Dictionary = badges_value if typeof(badges_value) == TYPE_DICTIONARY else {}
	badges[key] = 1
	sail["badges"] = badges
	journal["sail"] = sail
	_save_journal()
	journal_changed.emit()
	return true


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
