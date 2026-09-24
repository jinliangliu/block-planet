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

var mode: Mode = Mode.SURVIVAL
## 当前区域 ID（RegionAtlas 常量）；默认亚洲，随场景重载读取。
var current_region := RegionAtlas.DEFAULT_REGION
## 首次进入游戏需先弹出地图选择器；选定后置否。
var needs_region_pick := true
## 换图时暂存的玩家背包：Main 在重载场景前置入，新实例取出后清空，
## 避免切换地图丢光工具与材料。
var carried_inventory: Inventory = null


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
		return "保留生存机制但不生成敌对生物，可飞行观察"
	return "有生命与饥饿，夜里要提防敌对生物"


func set_mode(value: Mode) -> void:
	if value == mode:
		return
	mode = value
	mode_changed.emit(mode)


func set_region(region_id: int) -> void:
	current_region = clampi(region_id, 0, RegionAtlas.COUNT - 1)
	needs_region_pick = false
	region_changed.emit(current_region)


func region_title() -> String:
	return RegionAtlas.title_of(current_region)
