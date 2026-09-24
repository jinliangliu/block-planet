class_name HuntRules
extends RefCounted

## 狩猎规则引擎（M8.3）。
## 三件事：① 每种猎物要求的工具类别与最低等级；② 结算近战伤害与提示语；
## ③ 保护动物/幼体的拦截判定（拦截委托 Mob.is_huntable，避免重复口径）。
##
## 依赖方向刻意保持单向：hunt_rules → Mob（读取类型与保护名录），
## Mob 不反向引用本文件——掉落表因此留在 Mob.MOB_STAGES 中，
## 避免 GDScript 的 class_name 循环引用。
##
## 设计取向（儿童向）：用错工具不禁止，只把伤害折半并给出「该用什么」的提示，
## 让孩子自己发现正确的工具，而不是被硬性拦住。

## 徒手/无法判定工具时的基础伤害。
const BARE_DAMAGE := 1
## 工具不匹配时伤害折半（向下取整，至少 1）。
const WRONG_TOOL_DIVISOR := 2
## 弓的蓄力伤害区间（蓄满 100% 时为最大值）。
const BOW_DAMAGE_MIN := 2
const BOW_DAMAGE_MAX := 6

## 狩猎规则：生物 → {tool 所需工具类别, tier 最低等级, damage 达标伤害, hint 提示语}。
## tool 取值与 ItemTypes.TOOL_TYPE 一致（axe / rod / pickaxe / shovel / bow）。
## 未列出的敌对生物（僵尸、骷髅、蜘蛛、掠夺者）走通用规则：任意工具皆可。
const HUNT_RULES := {
	Mob.MobType.COW: {"tool": "axe", "tier": 1, "damage": 4, "hint": "斧头"},
	Mob.MobType.SHEEP: {"tool": "axe", "tier": 1, "damage": 4, "hint": "斧头"},
	Mob.MobType.PIG: {"tool": "axe", "tier": 1, "damage": 4, "hint": "斧头"},
	Mob.MobType.CHICKEN: {"tool": "axe", "tier": 1, "damage": 3, "hint": "斧头"},
	Mob.MobType.WOLF: {"tool": "axe", "tier": 2, "damage": 4, "hint": "石斧以上"},
	Mob.MobType.FISH: {"tool": "rod", "tier": 1, "damage": 5, "hint": "鱼竿"},
	Mob.MobType.SHRIMP: {"tool": "rod", "tier": 1, "damage": 4, "hint": "鱼竿"},
	Mob.MobType.CRAB: {"tool": "rod", "tier": 1, "damage": 4, "hint": "鱼竿"},
	Mob.MobType.FROG: {"tool": "rod", "tier": 1, "damage": 4, "hint": "鱼竿"},
	Mob.MobType.ZOMBIE: {"tool": "axe", "tier": 1, "damage": 4, "hint": "斧头"},
	Mob.MobType.SKELETON: {"tool": "axe", "tier": 1, "damage": 4, "hint": "斧头"},
	Mob.MobType.SPIDER: {"tool": "axe", "tier": 1, "damage": 4, "hint": "斧头"},
	Mob.MobType.PILLAGER: {"tool": "axe", "tier": 2, "damage": 4, "hint": "石斧以上"},
}


## 该生物的狩猎规则；未列出时返回空字典（走通用规则）。
static func rule_for(mob_type: int) -> Dictionary:
	var rule: Variant = HUNT_RULES.get(mob_type, {})
	if typeof(rule) != TYPE_DICTIONARY:
		return {}
	return rule


## 该生物要求的工具提示名（用于提示语）；未配置时返回「任意工具」。
static func required_hint(mob_type: int) -> String:
	var rule := rule_for(mob_type)
	if rule.is_empty():
		return "任意工具"
	return String(rule.get("hint", "任意工具"))


## 保护该生物时的提示语。
static func protected_message(mob_type: int) -> String:
	return "🛡 %s 是受保护的动物，请不要伤害它。" % Mob.protected_note(mob_type)


## 结算一次近战攻击：返回
## { ok: bool, damage: int, protection: bool, stage_blocked: bool, toast: String }
## ok 为 false 表示不造成伤害（保护动物或幼体）。
static func evaluate(mob: Mob, tool_id: int) -> Dictionary:
	var result := {"ok": false, "damage": 0, "protection": false, "stage_blocked": false, "toast": ""}
	if mob == null:
		return result

	# ① 保护动物与益虫：只提示，不伤害。
	if Mob.is_protected(mob.type):
		result["protection"] = true
		result["toast"] = protected_message(mob.type)
		return result

	# ② 未成年（卵/幼体）：长大后才可狩猎。
	if not mob.is_adult():
		result["stage_blocked"] = true
		result["toast"] = "%s 还小，等它长大再来吧。" % mob.stage_name()
		return result

	var rule := rule_for(mob.type)
	var need_tool := String(rule.get("tool", ""))
	var need_tier := int(rule.get("tier", 0))
	var full_damage := int(rule.get("damage", BARE_DAMAGE))

	var tool_type := ItemTypes.tool_type(tool_id) if tool_id != -1 else ""
	var tool_tier := ItemTypes.tool_tier(tool_id) if tool_id != -1 else 0

	result["ok"] = true
	if need_tool.is_empty():
		result["damage"] = maxi(BARE_DAMAGE, full_damage)
		return result

	if tool_type == need_tool and tool_tier >= need_tier:
		result["damage"] = full_damage
		return result

	# 工具不匹配或等级不够：伤害折半 + 提示该用什么。
	result["damage"] = maxi(1, full_damage / WRONG_TOOL_DIVISOR)
	if tool_type == need_tool:
		result["toast"] = "工具等级不够，%s 打起来更省力。" % String(rule.get("hint", ""))
	else:
		result["toast"] = "狩猎%s 用%s 更有效。" % [mob.stage_name(), required_hint(mob.type)]
	return result


## 是否需要消耗一次工具耐久（用对的工具才会磨损）。
static func wears_tool(mob: Mob, tool_id: int) -> bool:
	if tool_id == -1 or mob == null:
		return false
	var rule := rule_for(mob.type)
	if rule.is_empty():
		return false
	return ItemTypes.tool_type(tool_id) == String(rule.get("tool", ""))


## 弓的蓄力伤害：ratio 为 0..1 的蓄力比例。
static func bow_damage(ratio: float) -> int:
	var span := BOW_DAMAGE_MAX - BOW_DAMAGE_MIN
	return BOW_DAMAGE_MIN + int(round(float(span) * clampf(ratio, 0.0, 1.0)))


## 箭矢命中生物时的判定：保护动物与幼体同样免伤（返回 0 表示不伤害）。
static func arrow_damage(mob: Mob, damage: int) -> int:
	if mob == null:
		return 0
	if Mob.is_protected(mob.type) or not mob.is_adult():
		return 0
	return damage
