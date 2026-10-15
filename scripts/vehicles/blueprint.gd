class_name Blueprint
extends Resource
## 飞机蓝图：零件清单的数据容器 + 序列化 + 合法性校验。
##
## 设计（D-032 Phase 2）：蓝图 = 一组已放置零件（PlacedPart）。它是建造编辑器
## 的产出与 Aircraft.from_loadout() 的输入，也是存档载体。存读走 JSON（数据驱动，
## 见 D-032「数据驱动」），不依赖 Godot .tres——这样蓝图可导入导出、可被 Mod 改写。
##
## 注意：parts 刻意不 @export（PlacedPart 是 RefCounted，不由 Resource 序列化），
## 统一用 to_dict/from_dict 走 JSON，存读语义清晰可控。

var title: String = "untitled"
## 已放置零件列表（机体局部坐标，格）。
var parts: Array[PlacedPart] = []


## ── 聚合派生（委托给 Airframe，单一数据源）──────────────
func aggregate() -> AircraftFlight.Airframe:
	return AircraftFlight.Airframe.aggregate(parts)

func center_of_gravity() -> Vector3:
	return aggregate().com

func lift_center() -> Vector3:
	return aggregate().lift_center

## 推力矢量（机体局部坐标）：引擎位置平均点为原点，沿机头 -Z 方向，
## 量级 = 总推力。无引擎时原点退回重心、量级 0。
func thrust_vector() -> Dictionary:
	var origin := Vector3.ZERO
	var mag := 0.0
	var n := 0
	for p in parts:
		if p.data.category == PartData.Category.ENGINE:
			origin += p.local_pos()
			mag += p.data.thrust
			n += 1
	if n > 0:
		origin /= float(n)
	else:
		origin = center_of_gravity()
	return {"origin": origin, "dir": Vector3(0.0, 0.0, -1.0), "magnitude": mag}


## ── 序列化 ────────────────────────────────────────────
func to_dict() -> Dictionary:
	var part_dicts: Array = []
	for p in parts:
		var d := {
			"id": p.data.id,
			"cell": [p.cell.x, p.cell.y, p.cell.z],
			"rot": p.rot,
		}
		if p.is_mirrored():
			d["msrc"] = [p.mirror_src.x, p.mirror_src.y, p.mirror_src.z]
		part_dicts.append(d)
	return {"version": SAVE_VERSION, "title": title, "parts": part_dicts}

## 存档格式版本（P2-15）：前瞻迁移占位。当前 1；读取时缺省按 1 兼容，
## 未知更高版本仍按最新已知格式尽力解析（儿童向单机，无强制迁移需求，
## 但版本号让将来改格式时有据可依、有处可判。
const SAVE_VERSION := 1


static func from_dict(d: Dictionary) -> Blueprint:
	var bp := Blueprint.new()
	bp.title = d.get("title", "untitled")
	# 缺键/畸形容错（P2-13）：手写或损坏的存档不该让读取崩栈——
	# 逐件校验，缺 id/cell 或类型不对就跳过该件，其余照常装入。
	for pd: Variant in d.get("parts", []):
		if pd is not Dictionary:
			continue
		var data := PartRegistry.by_id(String(pd.get("id", "")))
		if data == null:
			continue
		var c: Variant = pd.get("cell", [])
		if c is not Array or c.size() < 3:
			continue
		var cell := Vector3i(int(c[0]), int(c[1]), int(c[2]))
		var part := PlacedPart.make(data, cell, int(pd.get("rot", 0)))
		var ms: Variant = pd.get("msrc", [])
		if ms is Array and ms.size() == 3:
			part.mirror_src = Vector3i(int(ms[0]), int(ms[1]), int(ms[2]))
		bp.parts.append(part)
	return bp

## 落盘。返回是否成功（P2-14：失败时调用方要有所呈现——静默丢失存档
## 对儿童用户是不可理解的「我的飞机没了」）。
func save(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("Blueprint.save: 无法打开 %s" % path)
		return false
	f.store_string(JSON.stringify(to_dict()))
	f.close()
	return true

static func load(path: String) -> Blueprint:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if parsed == null or not parsed is Dictionary:
		return null
	return from_dict(parsed)


## ── 占用与合法性 ───────────────────────────────────────
## 所有零件占据的格子 → 所属 PlacedPart（rot 1/3 时宽深对调）。
func occupied() -> Dictionary:
	var occ: Dictionary = {}
	for p in parts:
		for c in _cells_of(p):
			occ[c] = p
	return occ

func _cells_of(p: PlacedPart) -> Array[Vector3i]:
	var s := p.data.size
	var sx := s.x if (p.rot % 2 == 0) else s.z
	var sz := s.z if (p.rot % 2 == 0) else s.x
	var sy := s.y
	var cells: Array[Vector3i] = []
	for dx in range(sx):
		for dy in range(sy):
			for dz in range(sz):
				cells.append(Vector3i(p.cell.x + dx, p.cell.y + dy, p.cell.z + dz))
	return cells

static func _neighbors(c: Vector3i) -> Array[Vector3i]:
	return [
		Vector3i(c.x + 1, c.y, c.z), Vector3i(c.x - 1, c.y, c.z),
		Vector3i(c.x, c.y + 1, c.z), Vector3i(c.x, c.y - 1, c.z),
		Vector3i(c.x, c.y, c.z + 1), Vector3i(c.x, c.y, c.z - 1),
	]

## 合法性校验：必须含机身（结构根），且所有零件经面邻接连通到机身。
## 返回 {ok:bool, errors:Array[String]}。
func validate() -> Dictionary:
	var errors: Array[String] = []
	if parts.is_empty():
		errors.append("empty")
		return {"ok": false, "errors": errors}

	var has_fuselage := false
	var start: Array[Vector3i] = []
	for p in parts:
		if p.data.category == PartData.Category.FUSELAGE:
			has_fuselage = true
			for c in _cells_of(p):
				start.append(c)
	if not has_fuselage:
		errors.append("no_fuselage")
		return {"ok": false, "errors": errors}

	var occ := occupied()
	var visited: Dictionary = {}
	var stack := start.duplicate()
	for c in stack:
		visited[c] = true
	while not stack.is_empty():
		var cur: Vector3i = stack.pop_back()
		for n in _neighbors(cur):
			if occ.has(n) and not visited.has(n):
				visited[n] = true
				stack.append(n)

	for c in occ.keys():
		if not visited.has(c):
			var part: PlacedPart = occ[c]
			errors.append("orphan:%s@%s" % [part.data.id, c])
	return {"ok": errors.is_empty(), "errors": errors}
