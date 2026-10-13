class_name AircraftLivery
extends RefCounted
## 飞机涂装（配色方案）：一组 {name, body 机身色, accent 强调色}。
##
## 纯数据 + 静态查询，供 AircraftModel 按角色（机身/强调）改色、AircraftModel
## 重建或换色时复用。涂装索引持久化在 FlightSettings.livery_index，随蓝图/设置
## 存档保留。默认 0「经典红白」与重构前的硬编码 BODY/ACCENT 一致。

## 涂装表（顺序即索引；0 为默认，不得随意重排——已存档里存的是索引）。
const LIVERIES := [
	{"name": "经典红白", "body": Color(0.93, 0.94, 0.96), "accent": Color(0.84, 0.26, 0.22)},
	{"name": "深海蓝", "body": Color(0.20, 0.34, 0.52), "accent": Color(0.90, 0.92, 0.95)},
	{"name": "丛林绿", "body": Color(0.30, 0.42, 0.26), "accent": Color(0.85, 0.80, 0.35)},
	{"name": "落日橙", "body": Color(0.95, 0.62, 0.24), "accent": Color(0.25, 0.22, 0.24)},
]


static func count() -> int:
	return LIVERIES.size()


## 取第 i 套涂装；越界夹回合法范围。
static func by_index(i: int) -> Dictionary:
	return LIVERIES[clampi(i, 0, LIVERIES.size() - 1)]


static func body_of(i: int) -> Color:
	return by_index(i)["body"]


static func accent_of(i: int) -> Color:
	return by_index(i)["accent"]


static func name_of(i: int) -> String:
	return String(by_index(i)["name"])


## 供 UI 生成一排涂装按钮的显示名列表。
static func names() -> Array:
	var out: Array = []
	for livery: Dictionary in LIVERIES:
		out.append(String(livery["name"]))
	return out
