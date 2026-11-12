class_name Inventory
extends RefCounted
## 物品背包：玩家为 36 格（0~26 常用区 + 27~35 待售区），储物箱等可另指定容量。
## 每个槽位包含物品 ID 与数量。
## 自动入包（拾取/合成产物）只落在 fill_limit 之内的槽位，待售区由玩家手动放入。

signal changed

const SLOT_COUNT := 36
## 常用区容量：自动入包与手工整理的区域（面板按 9 格一行排布）。
const COMMON_COUNT := 27
## 待售区容量：可整区一键售卖给交易中心。
const SELL_COUNT := 9
## 快捷栏位数：映射到背包槽索引（hotbar_map），物品本体仍存在背包中。
const HOTBAR_SIZE := 9

var slots: Array[Dictionary] = []
## 快捷栏第 i 位引用的背包槽索引；默认顺序指向背包前 9 格。
var hotbar_map: Array[int] = []
## 自动入包可用的槽位数（-1 表示全部，储物箱等容器用全部）。
var fill_limit := -1


func _init(slot_count: int = SLOT_COUNT, auto_fill_limit: int = -1) -> void:
	for i in range(slot_count):
		slots.append({"item": BlockTypes.Block.AIR, "count": 0, "durability": -1})
	fill_limit = auto_fill_limit if auto_fill_limit > 0 else slot_count
	for i in range(HOTBAR_SIZE):
		hotbar_map.append(i)


## 自动入包扫描的上界。
func _fill_range() -> int:
	return mini(fill_limit, slots.size())


## 待售区是否包含该槽位。
func is_sell_slot(slot: int) -> bool:
	return slot >= COMMON_COUNT and slot < COMMON_COUNT + SELL_COUNT


## 该槽位所在分区的显示名。
func zone_name(slot: int) -> String:
	if is_sell_slot(slot):
		return "待售区"
	if slot < COMMON_COUNT:
		return "常用区"
	return "未使用"


func get_item(slot: int) -> int:
	if slot < 0 or slot >= slots.size():
		return BlockTypes.Block.AIR
	return slots[slot]["item"]


func get_count(slot: int) -> int:
	if slot < 0 or slot >= slots.size():
		return 0
	return slots[slot]["count"]


## 快捷栏第 i 位所引用的背包槽索引。
func hotbar_slot(i: int) -> int:
	if i < 0 or i >= hotbar_map.size():
		return -1
	return hotbar_map[i]


## 快捷栏第 i 位的物品 ID。
func hotbar_item(i: int) -> int:
	return get_item(hotbar_slot(i))


## 快捷栏第 i 位的数量。
func hotbar_count(i: int) -> int:
	return get_count(hotbar_slot(i))


## 把快捷栏第 i 位指派到背包槽 inv_slot；若该槽已被其他位占用则两者互换。
func assign_hotbar(i: int, inv_slot: int) -> bool:
	if i < 0 or i >= hotbar_map.size():
		return false
	if inv_slot < 0 or inv_slot >= slots.size():
		return false
	if hotbar_map[i] == inv_slot:
		return false
	var previous := hotbar_map[i]
	var swapped_at := hotbar_map.find(inv_slot)
	if swapped_at != -1:
		hotbar_map[swapped_at] = previous
	hotbar_map[i] = inv_slot
	changed.emit()
	return true


## 交换快捷栏两位。
func swap_hotbar(a: int, b: int) -> bool:
	if a < 0 or a >= hotbar_map.size() or b < 0 or b >= hotbar_map.size():
		return false
	if a == b:
		return false
	var tmp := hotbar_map[a]
	hotbar_map[a] = hotbar_map[b]
	hotbar_map[b] = tmp
	changed.emit()
	return true


## 把 from 槽的 amount 件搬到 to 槽：同物合并，异则整格互换（仅 amount 为整栈时）。
## 返回 true 表示背包内容发生变化。
func move_between(from: int, to: int, amount: int) -> bool:
	if from < 0 or to < 0 or from >= slots.size() or to >= slots.size() or from == to:
		return false
	var item := get_item(from)
	var held := get_count(from)
	if item == BlockTypes.Block.AIR or held <= 0:
		return false
	var moved := clampi(amount, 1, held)
	var target_item := get_item(to)
	var target_count := get_count(to)

	if target_item == item and not ItemTypes.is_tool_item(item):
		var space := BlockTypes.STACK_SIZE - target_count
		if space <= 0:
			return false
		var put := mini(space, moved)
		slots[to]["count"] = target_count + put
		_remove_amount(from, put)
		changed.emit()
		return true

	if target_item == BlockTypes.Block.AIR:
		slots[to] = slots[from].duplicate()
		slots[to]["count"] = moved
		_remove_amount(from, moved)
		changed.emit()
		return true

	if moved == held:
		var tmp: Dictionary = slots[to].duplicate()
		slots[to] = slots[from].duplicate()
		slots[from] = tmp
		changed.emit()
		return true
	return false


## 内部：从槽位扣减数量，归零则清空。
func _remove_amount(slot: int, amount: int) -> void:
	slots[slot]["count"] = int(slots[slot]["count"]) - amount
	if int(slots[slot]["count"]) <= 0:
		slots[slot] = {"item": BlockTypes.Block.AIR, "count": 0, "durability": -1}


## 清空待售区并返回结算结果：{ "emeralds": 总价, "sold": 售出件数, "leftover": 未能入库的绿宝石数 }。
func sell_all() -> Dictionary:
	var emeralds := 0
	var sold := 0
	for slot in range(COMMON_COUNT, COMMON_COUNT + SELL_COUNT):
		if slot >= slots.size():
			break
		var item := get_item(slot)
		var count := get_count(slot)
		if item == BlockTypes.Block.AIR or count <= 0:
			continue
		if not ItemTypes.is_sellable(item):
			continue
		emeralds += ItemTypes.sell_price(item) * count
		sold += count
		slots[slot] = {"item": BlockTypes.Block.AIR, "count": 0, "durability": -1}
	changed.emit()
	var leftover := 0
	if emeralds > 0:
		leftover = add_item(ItemTypes.EMERALD, emeralds)
	return {"emeralds": emeralds, "sold": sold, "leftover": leftover}


## durability：工具入包时保留的耐久（<0 取满耐久）。容器间搬运须传源格耐久，
## 否则磨旧的镐子搬个家就修满了。
func add_item(item: int, count: int, durability: int = -1) -> int:
	if ItemTypes.is_tool_item(item):
		return _add_tool(item, count, durability)

	var remaining := count

	for i in range(_fill_range()):
		if remaining <= 0:
			break
		if slots[i]["item"] == item and slots[i]["count"] < BlockTypes.STACK_SIZE:
			var space: int = BlockTypes.STACK_SIZE - int(slots[i]["count"])
			var add := mini(space, remaining)
			slots[i]["count"] += add
			remaining -= add

	for i in range(_fill_range()):
		if remaining <= 0:
			break
		if slots[i]["item"] == BlockTypes.Block.AIR:
			var add := mini(BlockTypes.STACK_SIZE, remaining)
			slots[i]["item"] = item
			slots[i]["count"] = add
			slots[i]["durability"] = -1
			remaining -= add

	if remaining != count:
		changed.emit()
	return remaining


func _add_tool(item: int, count: int, durability: int = -1) -> int:
	for i in range(_fill_range()):
		if slots[i]["item"] == BlockTypes.Block.AIR:
			slots[i]["item"] = item
			slots[i]["count"] = 1
			slots[i]["durability"] = durability if durability >= 0 else ItemTypes.tool_durability(item)
			changed.emit()
			return count - 1
	return count


func remove_item(slot: int, count: int) -> bool:
	if slot < 0 or slot >= slots.size():
		return false
	if slots[slot]["count"] < count:
		return false

	slots[slot]["count"] -= count
	if slots[slot]["count"] <= 0:
		slots[slot]["item"] = BlockTypes.Block.AIR
		slots[slot]["count"] = 0
	changed.emit()
	return true


func get_durability(slot: int) -> int:
	if slot < 0 or slot >= slots.size():
		return 0
	return int(slots[slot]["durability"])


func damage_tool(slot: int, amount: int) -> bool:
	if slot < 0 or slot >= slots.size():
		return false
	if not ItemTypes.is_tool_item(slots[slot]["item"]):
		return false

	var durability := int(slots[slot]["durability"]) - amount
	if durability <= 0:
		slots[slot]["item"] = BlockTypes.Block.AIR
		slots[slot]["count"] = 0
		slots[slot]["durability"] = -1
	else:
		slots[slot]["durability"] = durability
	changed.emit()
	return true


func count_item(item: int) -> int:
	var total := 0
	for i in range(slots.size()):
		if slots[i]["item"] == item:
			total += int(slots[i]["count"])
	return total


## 按当前持有材料推算「还能合成出多少个成品」（合成台成品格角标用）。
## 各材料取 可合成次数 的最小值，再乘配方单次产出数。
## 口径与 craft() 完全一致：count_item/consume_item 覆盖全部格位
## （常用区 + 待售区），所以这里算出的就是真去点合成能得到的数量。
func craftable_count(recipe: Dictionary) -> int:
	var times := -1
	for ingredient in recipe["ingredients"]:
		var need := int(recipe["ingredients"][ingredient])
		if need <= 0:
			continue
		var t := count_item(ingredient) / need
		times = t if times < 0 else mini(times, t)
	return maxi(0, times) * ItemTypes.recipe_count(recipe)


func consume_item(item: int, count: int) -> bool:
	if count_item(item) < count:
		return false

	var remaining := count
	for i in range(slots.size()):
		if remaining <= 0:
			break
		if slots[i]["item"] == item:
			var take := mini(int(slots[i]["count"]), remaining)
			slots[i]["count"] = int(slots[i]["count"]) - take
			remaining -= take
			if int(slots[i]["count"]) <= 0:
				slots[i]["item"] = BlockTypes.Block.AIR
				slots[i]["count"] = 0
				slots[i]["durability"] = -1
	changed.emit()
	return true


## 背包是否放得下该物品（工具不可堆叠，方块可堆叠）；只看可自动入包的区域。
func has_space_for(item: int) -> bool:
	for i in range(_fill_range()):
		if slots[i]["item"] == BlockTypes.Block.AIR:
			return true
		if (
			item == slots[i]["item"]
			and not ItemTypes.is_tool_item(item)
			and int(slots[i]["count"]) < BlockTypes.STACK_SIZE
		):
			return true
	return false


func can_craft(recipe: Dictionary) -> bool:
	# 材料总量足够是前提。
	for ingredient in recipe["ingredients"]:
		if count_item(ingredient) < int(recipe["ingredients"][ingredient]):
			return false
	# 空位预检要模拟「先扣材料、再放产物」：扣料可能清空某一堆而腾出格子
	# （例如两堆木头 5+4，合成耗 5 后空出一格），直接查现状会误判背包已满。
	var virt_items: Array[int] = []
	var virt_counts: Array[int] = []
	for i in range(_fill_range()):
		virt_items.append(int(slots[i]["item"]))
		virt_counts.append(int(slots[i]["count"]))
	for ingredient in recipe["ingredients"]:
		var remaining := int(recipe["ingredients"][ingredient])
		for i in range(virt_items.size()):
			if remaining <= 0:
				break
			if virt_items[i] == ingredient:
				var take := mini(virt_counts[i], remaining)
				virt_counts[i] -= take
				remaining -= take
	var result := int(recipe["result"])
	for i in range(virt_items.size()):
		if virt_items[i] == BlockTypes.Block.AIR or virt_counts[i] <= 0:
			return true
		if (
			result == virt_items[i]
			and not ItemTypes.is_tool_item(result)
			and virt_counts[i] < BlockTypes.STACK_SIZE
		):
			return true
	return false


func craft(recipe: Dictionary) -> bool:
	if not can_craft(recipe):
		return false
	for ingredient in recipe["ingredients"]:
		consume_item(ingredient, int(recipe["ingredients"][ingredient]))
	add_item(recipe["result"], ItemTypes.recipe_count(recipe))
	return true


## 按分类标签整理背包：同类物品合并（每格最多 STACK_SIZE），
## 排序为 方块(0) → 工具(1) → 食物(2) → 材料(3)，同类内按 ID 升序，空槽沉底。
## 仅整理自动入包区（玩家背包即常用区），待售区由玩家自行安排，不参与整理。
## 工具不合并，保留各自耐久。整理后发出 changed 刷新 UI。
func sort_by_category() -> void:
	var limit := _fill_range()
	var merged: Array[Dictionary] = []
	for i in range(limit):
		var slot: Dictionary = slots[i]
		if int(slot["item"]) != BlockTypes.Block.AIR and int(slot["count"]) > 0:
			if ItemTypes.is_tool_item(int(slot["item"])):
				merged.append(slot.duplicate())
			else:
				_merge_stack(merged, slot)

	merged.sort_custom(_sort_key_less)

	for i in range(limit):
		slots[i] = {"item": BlockTypes.Block.AIR, "count": 0, "durability": -1}
	for i in range(merged.size()):
		slots[i] = merged[i]
	changed.emit()


## 把一格物品并入目标数组：先填未满的同物栈，超出部分开新栈。
func _merge_stack(merged: Array[Dictionary], entry: Dictionary) -> void:
	var item := int(entry["item"])
	var remaining := int(entry["count"])
	for target: Dictionary in merged:
		if remaining <= 0:
			return
		if int(target["item"]) == item and int(target["count"]) < BlockTypes.STACK_SIZE:
			var add := mini(BlockTypes.STACK_SIZE - int(target["count"]), remaining)
			target["count"] = int(target["count"]) + add
			remaining -= add
	while remaining > 0:
		var add := mini(BlockTypes.STACK_SIZE, remaining)
		merged.append({"item": item, "count": add, "durability": -1})
		remaining -= add


## 排序键：分类标签优先，同类内按物品 ID 升序。
func _sort_key_less(a: Dictionary, b: Dictionary) -> bool:
	var cat_a := ItemTypes.category(int(a["item"]))
	var cat_b := ItemTypes.category(int(b["item"]))
	if cat_a != cat_b:
		return cat_a < cat_b
	return int(a["item"]) < int(b["item"])


## ── 持久化（D-092：user://inventory.json 按存档槽派生）──────────────
## 只序列化背包自身四字段（version / slots / hotbar_map / fill_limit），不含
## 任何区块 / 地形 / 世界数据。save() 走 tmp + rename 原子写；load_or_new()
## 对缺文件 / 坏 JSON / 顶层非字典 / 槽数异常 / 字段类型错一律退回 36 槽 AIR
## 默认，且读路径**绝不写盘**（D-010 铁律 3）。
## 换槽时 main 用 hydrate_from() 原地覆盖，不替换 _player.inventory 对象引用
## ——hud.gd:218/220 与 inventory_panel.gd:82 都连了 changed，替换引用会断连。

## 生产侧拒写闸（同 FishingSystem.journal_ok / BoatSystem.journal_ok）：
## SaveGuard.restore() 与 7 个内联快照探针的还原函数在 quit 前置 false，挡住
## main._exit_tree() 关停期二次写盘把逐字节还原的文件覆盖回内存态（D-010 假 DIFF）。
static var io_ok: bool = true

## 按槽派生路径。save() / load_or_new() 都读它 → static var（同 PartUnlocks）。
## 默认值是旧根路径；_refresh_path() 在有槽时覆盖为 Profile.slot_file(...)。
static var SAVE_PATH: String = "user://inventory.json"


static func _refresh_path() -> void:
	if Profile != null:
		SAVE_PATH = Profile.slot_file("inventory.json")


## 数字类型判定：Godot 的 JSON.parse_string 把 JSON 数字一律解析为 float，
## 故 int 与 float 都认（同 BoatSystem._int_or_zero:323-326）。
static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT


## payload 结构校验：槽数 / 快捷栏位数 / 每格三字段类型 / fill_limit 类型。
## 任一不符即整份退回默认，绝不半吊子覆盖（字段类型错也算损坏档）。
static func _valid_payload(d: Dictionary) -> bool:
	var slots_value: Variant = d.get("slots", null)
	if typeof(slots_value) != TYPE_ARRAY:
		return false
	var raw_slots: Array = slots_value
	if raw_slots.size() != SLOT_COUNT:
		return false
	for s_value: Variant in raw_slots:
		if typeof(s_value) != TYPE_DICTIONARY:
			return false
		var s: Dictionary = s_value
		if not (s.has("item") and s.has("count") and s.has("durability")):
			return false
		if not (_is_number(s["item"]) and _is_number(s["count"])
				and _is_number(s["durability"])):
			return false
	var map_value: Variant = d.get("hotbar_map", null)
	if typeof(map_value) != TYPE_ARRAY:
		return false
	var raw_map: Array = map_value
	if raw_map.size() != HOTBAR_SIZE:
		return false
	for idx_value: Variant in raw_map:
		if not _is_number(idx_value):
			return false
	return _is_number(d.get("fill_limit", null))


## 序列化：逐格 duplicate，避免外部持有引用被后续改写污染。
func to_dict() -> Dictionary:
	var out_slots: Array = []
	for s: Dictionary in slots:
		out_slots.append(s.duplicate())
	var out_map: Array = []
	for idx: int in hotbar_map:
		out_map.append(idx)
	return {
		"version": 1,
		"slots": out_slots,
		"hotbar_map": out_map,
		"fill_limit": fill_limit,
	}


## 从字典构造新实例（校验失败则退回 36 槽 AIR 默认）。
static func from_dict(d: Dictionary) -> Inventory:
	var inv: Inventory = Inventory.new(SLOT_COUNT, COMMON_COUNT)
	inv.hydrate_from(d)
	return inv


## 原地覆盖 slots / hotbar_map / fill_limit + changed.emit()。**不替换对象引用**。
## 校验失败退回默认 36 槽 AIR（fill_limit=COMMON_COUNT，与玩家背包一致）。
func hydrate_from(d: Dictionary) -> void:
	if _valid_payload(d):
		var new_slots: Array[Dictionary] = []
		for s_value: Variant in (d["slots"] as Array):
			var s: Dictionary = s_value
			new_slots.append({
				"item": int(s["item"]),
				"count": int(s["count"]),
				"durability": int(s["durability"]),
			})
		slots = new_slots
		var new_map: Array[int] = []
		for idx_value: Variant in (d["hotbar_map"] as Array):
			new_map.append(int(idx_value))
		hotbar_map = new_map
		fill_limit = int(d["fill_limit"])
	else:
		slots = []
		for i in range(SLOT_COUNT):
			slots.append({"item": BlockTypes.Block.AIR, "count": 0, "durability": -1})
		hotbar_map = []
		for i in range(HOTBAR_SIZE):
			hotbar_map.append(i)
		fill_limit = COMMON_COUNT
	changed.emit()


## 写入 JSON（tmp + rename 原子写）；io_ok=false / 打不开临时文件返回 false。
## 显式传 path 的探针调用不触发 _refresh_path()；默认空串才按槽派生。
func save(path: String = "") -> bool:
	if not io_ok:
		return false
	var target: String = path
	if target.is_empty():
		_refresh_path()
		target = SAVE_PATH
	var text: String = JSON.stringify(to_dict())
	var tmp: String = target + ".tmp"
	var file: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp),
		ProjectSettings.globalize_path(target))
	return true


## 读档：缺文件 / 坏 JSON / 顶层非字典一律退回默认实例，且**绝不写盘**。
## from_dict() 内部再校验槽数 / 字段类型，异常同样退回默认。
static func load_or_new(path: String = "") -> Inventory:
	var target: String = path
	if target.is_empty():
		_refresh_path()
		target = SAVE_PATH
	if not FileAccess.file_exists(target):
		return Inventory.new(SLOT_COUNT, COMMON_COUNT)
	var file: FileAccess = FileAccess.open(target, FileAccess.READ)
	if file == null:
		return Inventory.new(SLOT_COUNT, COMMON_COUNT)
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return Inventory.new(SLOT_COUNT, COMMON_COUNT)
	return from_dict(parsed)
