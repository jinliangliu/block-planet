class_name BuildEditor
extends RefCounted
## 建造编辑器模型（D-032 Phase 2）：在体素网格上放置/删除/旋转零件，
## 支持 X 轴对称镜像、清空、占用查询、合法性校验与蓝图存读。
##
## 纯数据模型，不含输入与渲染——输入在 Phase 3 接入玩家控制，渲染由
## BuildVisualizer 负责。本类只保证「网格操作的几何正确性」，全部可被探针断言。

var blueprint := Blueprint.new()


## ── 几何辅助 ───────────────────────────────────────────
static func _span_x(p: PlacedPart) -> int:
	var s := p.data.size
	return s.x if (p.rot % 2 == 0) else s.z

## X=0 平面镜像后的锚格：原占 [x, x+span-1] → 镜像占 [-(x+span-1), -x]。
static func _mirror_anchor(p: PlacedPart) -> Vector3i:
	return Vector3i(-(p.cell.x + _span_x(p) - 1), p.cell.y, p.cell.z)


## ── 操作 ───────────────────────────────────────────────
## 放置一个零件；mirror=true 时同步在 X=0 另一侧镜像放置（轴对称建造）。
func place(data: PartData, cell: Vector3i, rot: int, mirror: bool) -> void:
	blueprint.parts.append(PlacedPart.make(data, cell, rot))
	if mirror:
		var probe := PlacedPart.make(data, cell, rot)
		blueprint.parts.append(PlacedPart.make(data, _mirror_anchor(probe), rot))

## 删除锚格处的零件；mirror=true 时连同其 X 镜像件一并删除。
func remove_at(cell: Vector3i, mirror: bool) -> void:
	var remove_idx: Array[int] = []
	for i in blueprint.parts.size():
		var p := blueprint.parts[i]
		if p.cell == cell:
			remove_idx.append(i)
		elif mirror and p.cell == _mirror_anchor(PlacedPart.make(p.data, cell, p.rot)):
			remove_idx.append(i)
	remove_idx.sort()
	remove_idx.reverse()
	for i in remove_idx:
		blueprint.parts.remove_at(i)

## 绕 Y 旋转锚格处零件一个 90° 步进；mirror=true 时同步旋转其镜像件。
func rotate_at(cell: Vector3i, mirror: bool) -> void:
	for p in blueprint.parts:
		if p.cell == cell:
			p.rot = wrapi(p.rot + 1, 0, 4)
		elif mirror and p.cell == _mirror_anchor(PlacedPart.make(p.data, cell, p.rot)):
			p.rot = wrapi(p.rot + 1, 0, 4)

func clear() -> void:
	blueprint.parts.clear()


## ── 查询与校验 ─────────────────────────────────────────
func occupied() -> Dictionary:
	return blueprint.occupied()

func validate() -> Dictionary:
	return blueprint.validate()


## ── 存读 ───────────────────────────────────────────────
func save(path: String) -> void:
	blueprint.save(path)

static func load(path: String) -> BuildEditor:
	var bp := Blueprint.load(path)
	if bp == null:
		return null
	var e := BuildEditor.new()
	e.blueprint = bp
	return e
