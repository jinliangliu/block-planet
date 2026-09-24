class_name Inventory
extends RefCounted
## 物品背包：玩家为 27 格（0~17 常用区 + 18~26 待售区），储物箱等可另指定容量。
## 每个槽位包含物品 ID 与数量。
## 自动入包（拾取/合成产物）只落在 fill_limit 之内的槽位，待售区由玩家手动放入。

signal changed

const SLOT_COUNT := 27
## 常用区容量：自动入包与手工整理的区域。
const COMMON_COUNT := 18
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


func add_item(item: int, count: int) -> int:
	if ItemTypes.is_tool_item(item):
		return _add_tool(item, count)

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


func _add_tool(item: int, count: int) -> int:
	for i in range(_fill_range()):
		if slots[i]["item"] == BlockTypes.Block.AIR:
			slots[i]["item"] = item
			slots[i]["count"] = 1
			slots[i]["durability"] = ItemTypes.tool_durability(item)
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
	for ingredient in recipe["ingredients"]:
		if count_item(ingredient) < int(recipe["ingredients"][ingredient]):
			return false
	# 预检产物空位，避免消耗材料后产物无处放入而丢失。
	return has_space_for(int(recipe["result"]))


func craft(recipe: Dictionary) -> bool:
	if not can_craft(recipe):
		return false
	for ingredient in recipe["ingredients"]:
		consume_item(ingredient, int(recipe["ingredients"][ingredient]))
	add_item(recipe["result"], 1)
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
