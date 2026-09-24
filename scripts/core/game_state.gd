extends Node
## 全局游戏状态（Autoload 单例，随应用存续）。
## 维护生存/创造模式与当前地图区域；后续可扩展存档与设置。
## 区域切换通过重载主场景生效（见 Main._on_region_entered），
## 因此本单例是新场景唯一的跨场景状态载体。

enum Mode {
	SURVIVAL,
	CREATIVE,
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


func is_survival() -> bool:
	return mode == Mode.SURVIVAL


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
