class_name FlightTeaching
extends RefCounted
## 飞行一次性教学提示的进度层（U-9 / D-069）：记「看过没有」，不绘制任何界面。
## 与 FishingTeaching（内容层）/ RaceTeachingUI（竞速教学）同范式，但进度
## 形状与落盘方式都不同：
##   · 进度形状是 `{"seen": [id, ...]}` 数组（不是 {id: bool} 字典）；
##   · 落盘是 tmp + rename 原子写（不是直写）——headless 退出期偶发段错误
##     （rc=139），直写在截断时刻会留下空文件，原子写任何时刻盘上都有一份
##     完整存档（fishing_system.gd:_save_journal 同款教训）。
##
## 为什么独立文件而不并进 settings.json / progress.json：
##   · settings.json 恢复默认会把它清掉（提示复发，烦人但无害——可接受的是
##     「复发」，不可接受的是「别处被牵连」，故不并）；
##   · progress.json 耦合任务 schema 与 SaveGuard 内存态陷阱，不并。
## 独立文件 + SaveGuard EXTRA_FILES 纳入，探针跑完原样还原（D-010）。
##
## 当前只有一条提示（U-9）：座舱视角已离地后教「低头可以看 3D 仪表台」——
## D-065 补了 CockpitPanel，但儿童玩家不知道第一人称可以低头看仪表台。
## 触屏设备没有鼠标环顾手段，「低头」无从谈起（U-12 只记录不实现）。

## D-086：按槽派生。探针以 FlightTeaching.SAVE_PATH 做类级读取（stall_coach_probe
## / stall_coach_shot 共 12 处），因此必须是 static var 而非实例 var——const 改
## 成实例 var 会让那些 `FlightTeaching.SAVE_PATH` 直接取不到值。
static var SAVE_PATH: String = "user://flight_teaching.json"

## 提示 id → 课文案。加新提示只改这里 + should_fire 的触发条件。
const HINT_LOOKDOWN := "lookdown_panel"
const HINTS := {
	HINT_LOOKDOWN: "💡 低头可以看 3D 仪表台",
}

## U-9 触发高度（m AGL）：低于此值不提示——起飞/着陆阶段教练区正忙，
## 且「低头看仪表」在起降滑跑期间是危险建议；15 m 约等于起飞教练
## 「起飞成功」的判定高度（TakeoffCoach.TAKEOFF_ALT），正好接在后面。
const LOOKDOWN_TRIGGER_AGL := 15.0

## 已看过的提示 id 列表（内存态；_init 时从磁盘加载）。
var _seen: Array[String] = []

## 已弹出但**尚未确认看过**的提示 id（内存态，**不落盘**）。
## F-13：原实现是「投递即消耗」——hint_for 命中就 mark_seen 写盘，但 Toast
## 是覆盖式的（hud.gd 共 11 处 _show_toast 调用），提示投出去后 2.8 s 内若
## 被坠机「💥」之类的提示顶掉，它就被永久消耗掉了，玩家再也看不到。
## 正确语义是「看过才消耗」：投递只记 pending，由 HUD 在 Toast 完整播完
## （tween 自然结束、未被顶掉）后回调 confirm_shown() 才落盘。
var _pending_id := ""


## D-086：路径随档案槽重算。本类由场景按需 new()，没有 _ready()，故在每次
## 读写入口现算；无槽时逐字节等于旧根路径。
static func _refresh_path() -> void:
	if Profile != null:
		SAVE_PATH = Profile.slot_file("flight_teaching.json")


func _init() -> void:
	_load()


## 某条提示是否看过（探针 / 复用入口）。
func is_seen(hint_id: String) -> bool:
	return _seen.has(hint_id)


## 标记看过并立即落盘（去重追加；落盘失败仅内存态生效——最坏后果是
## 下次开局提示再演一次，无害，故不向上抛错）。
func mark_seen(hint_id: String) -> void:
	if _seen.has(hint_id):
		return
	_seen.append(hint_id)
	_save()


## 有提示已弹出、正等待「看过」确认（探针 / HUD 判重入口）。
func has_pending() -> bool:
	return not _pending_id.is_empty()


func pending_id() -> String:
	return _pending_id


## 确认看过（HUD 在 Toast tween 自然结束时回调）：此时才落盘。
## 幂等：重复调用无副作用。
func confirm_shown() -> void:
	if _pending_id.is_empty():
		return
	var id := _pending_id
	_pending_id = ""
	mark_seen(id)


## 取消待确认（Toast 被后续提示顶掉 = 没看全）：不落盘，下次条件满足时重演。
## 这是一次性提示「不因一次遮挡而永久丢失」的另一半保障。
func cancel_pending() -> void:
	_pending_id = ""


## 每帧由 HUD 的 _refresh_flight_panel 调用：满足全部触发条件时返回课文案，
## 否则返回空串。F-13：命中**只记 pending 不落盘**，等 HUD 回调
## confirm_shown() 才算看过（详见 _pending_id 的注释）。
## `snap` 为 Aircraft.snapshot()；`ctx` 由 HUD 填环境事实：
##   cockpit_view  —— 座舱视角（含自由观察底层为座舱，fp 同款判据）；
##   coach_busy    —— 教练区正被起飞/失速教案占用（不抢话筒）；
##   blueprint_built —— 蓝图试飞机（契约不建座舱几何，无从「低头」）；
##   touch         —— 触屏设备（无鼠标环顾，U-12 缺口）。
func hint_for(snap: Dictionary, ctx: Dictionary) -> String:
	# 已弹出待确认：不再重复占用 Toast（否则每帧都会顶掉自己，永远看不到）。
	if not _pending_id.is_empty():
		return ""
	if not should_fire(snap, ctx, _seen):
		return ""
	_pending_id = HINT_LOOKDOWN
	return String(HINTS[HINT_LOOKDOWN])


## 纯静态触发判据（无 IO、无 DisplayServer，探针可逐条钉死）：
## 非触屏 + 非蓝图机 + 座舱视角 + AGL≥15 m + 教练区空闲 + 未看过。
static func should_fire(snap: Dictionary, ctx: Dictionary, seen: Array) -> bool:
	if bool(ctx.get("touch", false)):
		return false
	if bool(ctx.get("blueprint_built", false)):
		return false
	if not bool(ctx.get("cockpit_view", false)):
		return false
	if bool(ctx.get("coach_busy", false)):
		return false
	if float(snap.get("altitude_agl", 0.0)) < LOOKDOWN_TRIGGER_AGL:
		return false
	var ids: Array = seen
	return not ids.has(HINT_LOOKDOWN)


## 读档：文件不存在 / JSON 损坏 / 顶层不是对象 / seen 不是数组 / 条目不是
## 字符串，一律按「什么都没看过」处理。最坏后果 = 提示复发，无害；
## 只有原子写在截断时可能留下坏文件，所以读档必须宽容。
func _load() -> void:
	_refresh_path()
	_seen = []
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_warning("flight_teaching: 存档损坏，按未看过处理（%s）" % SAVE_PATH)
		return
	if typeof(json.data) != TYPE_DICTIONARY:
		push_warning("flight_teaching: 顶层不是对象，按未看过处理")
		return
	var raw: Variant = (json.data as Dictionary).get("seen", [])
	if typeof(raw) != TYPE_ARRAY:
		push_warning("flight_teaching: seen 不是数组，按未看过处理")
		return
	for item: Variant in raw as Array:
		if typeof(item) != TYPE_STRING:
			continue
		var id := String(item)
		if not id.is_empty() and not _seen.has(id):
			_seen.append(id)


## 落盘：原子写（先写 .tmp 再 rename 覆盖）。FileAccess WRITE 会先把原文件
## 截成 0 字节，若此刻进程被信号打断（headless 退出期偶发段错误），存档就被
## 清空——tmp + rename 保证任何时刻盘上都有一份完整存档。
func _save() -> void:
	_refresh_path()
	var text := JSON.stringify({"seen": _seen})
	var tmp := SAVE_PATH + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp),
		ProjectSettings.globalize_path(SAVE_PATH))
