class_name FlightSettings
extends RefCounted
## 飞行手感设置：辅助稳定等级 + 难度预设，持久化 user://settings.json。
##
## 设计（D-032 打磨 Phase 5-a）：MVP 的「飞行（简化气动 + 辅助稳定）」要求儿童向
## 的温和手感，故把「辅助稳定」坐实为一个可调等级；难度预设只决定辅助等级的
## 出发点，玩家仍可在设置面板里单独覆盖。本类纯逻辑、易于无头探针验证。
##
## 全局生效实例走类级单例 `current()`：首次访问从 user://settings.json 读档，
## 无文件则退回默认；main 也可在启动早期显式 set_current 以统一注入。飞机节点
## 每帧读 `FlightSettings.current().gains()`，运行时改设置即时生效。

enum Difficulty { CASUAL, NORMAL, EXPERT }
enum Assist { OFF, PARTIAL, FULL }


const SAVE_PATH := "user://settings.json"

## 各辅助等级的增益（详见 AircraftFlight._update_rates 的 assist 分支）：
## roll_level —— 松杆时把坡度往水平摆平的增益（1/s·rad），正数即向 0 坡度收敛；
## yaw_damp —— 松杆时偏航角速度的阻尼（1/s），压住荷兰滚式摆动。
## 刻意不含俯仰自动配平（见 aircraft_flight.gd 同处注释）。
const ASSIST_GAINS := {
	Assist.OFF: {"roll_level": 0.0, "yaw_damp": 0.0},
	Assist.PARTIAL: {"roll_level": 0.9, "yaw_damp": 0.8},
	Assist.FULL: {"roll_level": 1.8, "yaw_damp": 1.5},
}

## 难度预设 → 默认辅助等级（玩家之后可单独覆盖）。
const DIFFICULTY_ASSIST := {
	Difficulty.CASUAL: Assist.FULL,
	Difficulty.NORMAL: Assist.PARTIAL,
	Difficulty.EXPERT: Assist.OFF,
}

const DIFFICULTY_NAMES := {
	Difficulty.CASUAL: "休闲",
	Difficulty.NORMAL: "标准",
	Difficulty.EXPERT: "硬核",
}
const ASSIST_NAMES := {
	Assist.OFF: "关闭",
	Assist.PARTIAL: "半开",
	Assist.FULL: "全开",
}


var difficulty: int = Difficulty.NORMAL
var assist_level: int = Assist.PARTIAL
## 涂装索引（AircraftLivery.LIVERIES 的下标，默认经典红白）。
var livery_index := 0
## 儿童友好镜头开关（D-033）：抖动默认开（微量），松手自动回正默认开——
## 两者都可在飞行设置面板里关掉（防晕动症）。
var camera_shake := true
var auto_recenter := true
## HUD 详细模式（D-034）：默认简单（儿童优先，信息少 = 不晕），H 键切换，
## 随 settings.json 落盘（与涂装/抖动同机制）。
var hud_detail := false
## 自动改平开关（D-034 双击左键）：默认开，设置面板可关。
var auto_level := true
## 警告蜂鸣码开关（D-034）：默认开（听到也能玩）；设置面板可关。
var beeper_enabled := true

static var _current: FlightSettings = null


## 全局生效实例：首次访问时从 SAVE_PATH 读档（无则默认）。
static func current() -> FlightSettings:
	if _current == null:
		_current = load_or_new()
	return _current


static func set_current(s: FlightSettings) -> void:
	_current = s


static func default_settings() -> FlightSettings:
	return FlightSettings.new()


## 按难度取一份预设：难度决定默认辅助等级，玩家可在此之上单独改辅助。
static func for_difficulty(d: int) -> FlightSettings:
	var s := FlightSettings.new()
	s.set_difficulty(d)
	return s


## 当前辅助增益表（共享常量引用，不每帧分配）。越界等级安全退回关闭档。
func gains() -> Dictionary:
	if ASSIST_GAINS.has(assist_level):
		return ASSIST_GAINS[assist_level]
	return ASSIST_GAINS[Assist.OFF]


## 切换难度会同时把辅助等级重置为该难度的默认（先设难度、再按需单独覆盖辅助）。
func set_difficulty(d: int) -> void:
	difficulty = clampi(d, Difficulty.CASUAL, Difficulty.EXPERT)
	assist_level = DIFFICULTY_ASSIST[difficulty]


func set_assist_level(a: int) -> void:
	assist_level = clampi(a, Assist.OFF, Assist.FULL)


func set_livery(index: int) -> void:
	livery_index = clampi(index, 0, AircraftLivery.count() - 1)


func livery_name() -> String:
	return AircraftLivery.name_of(livery_index)


func difficulty_name() -> String:
	return DIFFICULTY_NAMES.get(difficulty, "标准")


func assist_name() -> String:
	return ASSIST_NAMES.get(assist_level, "半开")


func to_dict() -> Dictionary:
	return {
		"difficulty": difficulty,
		"assist_level": assist_level,
		"livery_index": livery_index,
		"camera_shake": camera_shake,
		"auto_recenter": auto_recenter,
		"hud_detail": hud_detail,
		"auto_level": auto_level,
		"beeper_enabled": beeper_enabled,
	}


static func from_dict(d: Dictionary) -> FlightSettings:
	var s := FlightSettings.new()
	s.set_difficulty(int(d.get("difficulty", Difficulty.NORMAL)))
	# 辅助等级允许被单独覆盖：读档时若显式带 assist_level 以后者为准。
	var a: int = int(d.get("assist_level", s.assist_level))
	s.set_assist_level(a)
	s.set_livery(int(d.get("livery_index", 0)))
	s.camera_shake = bool(d.get("camera_shake", true))
	s.auto_recenter = bool(d.get("auto_recenter", true))
	s.hud_detail = bool(d.get("hud_detail", false))
	s.auto_level = bool(d.get("auto_level", true))
	s.beeper_enabled = bool(d.get("beeper_enabled", true))
	return s


## 写入 JSON；失败（只读/磁盘满）返回 false，不抛异常。
func save(path: String = SAVE_PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict()))
	f.close()
	return true


## 读档：文件不存在 / 损坏时安全退回默认（难度标准、辅助半开）。
static func load_or_new(path: String = SAVE_PATH) -> FlightSettings:
	if not FileAccess.file_exists(path):
		return FlightSettings.new()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return FlightSettings.new()
	var text: Variant = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) == TYPE_DICTIONARY:
		return from_dict(parsed)
	return FlightSettings.new()
