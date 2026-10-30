extends Node
## 全局游戏状态（Autoload 单例，随应用存续）。
## 维护生存/创造/探索模式与当前地图区域；后续可扩展存档与设置。
## 区域切换通过重载主场景生效（见 Main._on_region_entered），
## 因此本单例是新场景唯一的跨场景状态载体。

enum Mode {
	SURVIVAL,
	CREATIVE,
	EXPLORE,
}

signal mode_changed(mode: int)
## 玩家选定新区域时发出；Main 在收到后重载场景。
signal region_changed(region_id: int)
## 和平模式开关变更（D-078）；参数是新的开关值。启动/切槽的灌值**不走这里**
## （那是 _hydrate_peaceful），否则一开机就弹 Toast。
signal peaceful_changed(enabled: bool)

var mode: Mode = Mode.SURVIVAL
## 和平模式（D-078，M9）：与 Mode 正交的布尔开关——在哪一种模式下都能单独
## 开关。真值属于**当前档案槽**（user://profiles/<id>/world.json），由 Profile
## 在 _ready / select_slot 时 push 进来；本单例仍是纯内存态，全文不碰 FileAccess。
## 默认关：保证既有行为与全部回归探针一字不变。
var peaceful := false
## 当前区域 ID（RegionAtlas 常量）；默认亚洲，随场景重载读取。
var current_region := RegionAtlas.DEFAULT_REGION
## 首次进入游戏需先弹出地图选择器；选定后置否。
var needs_region_pick := true
## 换图时暂存的玩家背包：Main 在重载场景前置入，新实例取出后清空，
## 避免切换地图丢光工具与材料。
var carried_inventory: Inventory = null
## 探索模式开局赠送是否已发放（每局一次）：切换进探索模式即时补发，
## 重载场景/切换区域不重复。见 Main._ready 与 HUD 模式切换处理。
var explore_aircraft_given := false


func is_creative() -> bool:
	return mode == Mode.CREATIVE


## 是否处于生存规则之下（生命、饥饿、掉落、工具耐久、放置消耗方块）。
## 探索模式**保留**全部生存机制——它只是不生成敌对生物、开放飞行、禁止切创造，
## 所以这里与生存模式同为真；唯一不受约束的是创造模式。
## 若需严格判断「就是生存模式这一种」，用 `mode == Mode.SURVIVAL`。
func is_survival() -> bool:
	return mode != Mode.CREATIVE


## 探索模式：安心观察世界的温和模式——生存机制照常，但没有夜间敌对生物。
func is_explore() -> bool:
	return mode == Mode.EXPLORE


## 是否允许飞行（创造与探索都开放；探索模式借此自由俯瞰地形与生态）。
func can_fly() -> bool:
	return is_creative() or is_explore()


## 和平模式（D-078）：正交于 Mode 的布尔开关，只管怪物三件事——夜里不刷敌对、
## 场上敌对立刻清场、生物伤害（含箭矢与被动反击）免疫。
## ⚠️ 和平 ≠ 无敌：饥饿下降、饥饿归零扣血、跌落、坠机、卡死全部照常——
## 那些路径一律不查这里（它们走 _damage / 各专项扣血入口）。要彻底无风险请用创造模式。
func is_peaceful() -> bool:
	return peaceful


## 模式显示名，供 HUD 状态标签与提示文案共用。
func mode_name() -> String:
	if is_creative():
		return "创造"
	if is_explore():
		return "探索"
	return "生存"


## 模式一句话说明，地图选择器的模式三选一与说明书共用同一份措辞。
func mode_hint() -> String:
	if is_creative():
		return "无限资源、无敌、可飞行，自由搭建"
	if is_explore():
		return "保留生存机制但不生成敌对生物，送一架飞机自由观察"
	return "有生命与饥饿，夜里要提防敌对生物"


func set_mode(value: Mode) -> void:
	if value == mode:
		return
	mode = value
	mode_changed.emit(mode)


## 玩家切换和平模式（设置面板的唯一入口）。同值直接 return——重复点击不该
## 反复弹 Toast。这里不落盘：落盘在调用方（Profile.write_slot_settings），
## 本单例是纯内存态，全文不做任何 FileAccess。
func set_peaceful(value: bool) -> void:
	if value == peaceful:
		return
	peaceful = value
	peaceful_changed.emit(peaceful)


## 由 Profile 灌值（启动 / 切槽）：只赋值、不 emit 信号——这两种时机都不该弹
## 提示。push 而非 pull 的理由：Autoload 顺序是 GameState 在 Profile 之前，
## 若反过来在 GameState._ready 里读 Profile，那时 Profile 还没跑 _load_index()，
## _current 为空会错退到 legacy 路径。改 Autoload 顺序的代价远大于这里的一次
## 反向调用（D-078）。
func _hydrate_peaceful(value: bool) -> void:
	peaceful = value


func set_region(region_id: int) -> void:
	current_region = clampi(region_id, 0, RegionAtlas.COUNT - 1)
	needs_region_pick = false
	region_changed.emit(current_region)


## 领取探索模式的开局赠送：首次返回 true（调用方当场发放一架飞机），
## 之后一律 false。放在单例里是为了「重载场景」与「即时切模式」两条
## 进入路径共用同一个一次性标记，不会重复发、也不会漏发。
func claim_explore_aircraft() -> bool:
	if explore_aircraft_given:
		return false
	explore_aircraft_given = true
	return true


func region_title() -> String:
	return RegionAtlas.title_of(current_region)
