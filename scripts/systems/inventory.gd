class_name Inventory
extends RefCounted
## 物品背包：默认 9 个槽位（玩家快捷栏），可扩容（储物箱 27 格）。
## 每个槽位包含物品 ID 与数量。

signal changed

const SLOT_COUNT := 9

var slots: Array[Dictionary] = []


func _init(slot_count: int = SLOT_COUNT) -> void:
	for i in range(slot_count):
		slots.append({"item": BlockTypes.Block.AIR, "count": 0, "durability": -1})


func get_item(slot: int) -> int:
	if slot < 0 or slot >= slots.size():
		return BlockTypes.Block.AIR
	return slots[slot]["item"]


func get_count(slot: int) -> int:
	if slot < 0 or slot >= slots.size():
		return 0
	return slots[slot]["count"]


func add_item(item: int, count: int) -> int:
	if ItemTypes.is_tool_item(item):
		return _add_tool(item, count)

	var remaining := count

	for i in range(slots.size()):
		if remaining <= 0:
			break
		if slots[i]["item"] == item and slots[i]["count"] < BlockTypes.STACK_SIZE:
			var space: int = BlockTypes.STACK_SIZE - int(slots[i]["count"])
			var add := mini(space, remaining)
			slots[i]["count"] += add
			remaining -= add

	for i in range(slots.size()):
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
	for i in range(slots.size()):
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


## 背包是否放得下该物品（工具不可堆叠，方块可堆叠）。
func has_space_for(item: int) -> bool:
	for i in range(slots.size()):
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
## 工具不合并，保留各自耐久。整理后发出 changed 刷新 UI。
func sort_by_category() -> void:
	var merged: Array[Dictionary] = []
	for slot: Dictionary in slots:
		if int(slot["item"]) != BlockTypes.Block.AIR and int(slot["count"]) > 0:
			if ItemTypes.is_tool_item(int(slot["item"])):
				merged.append(slot.duplicate())
			else:
				_merge_stack(merged, slot)

	merged.sort_custom(_sort_key_less)

	for i in range(slots.size()):
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
