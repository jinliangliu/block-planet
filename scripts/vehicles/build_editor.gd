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
## 镜像件记录 mirror_src 链接指向原装件锚格——旋转改变跨度后按锚格反推
## 镜像关系会失效，故链接在放置时写死（删除/旋转均按链接配对）。
func place(data: PartData, cell: Vector3i, rot: int, mirror: bool) -> void:
	blueprint.parts.append(PlacedPart.make(data, cell, rot))
	if mirror:
		var probe := PlacedPart.make(data, cell, rot)
		var twin := PlacedPart.make(data, _mirror_anchor(probe), rot)
		twin.mirror_src = cell
		blueprint.parts.append(twin)

## 删除锚格处的零件；mirror=true 时按镜像链接连同伴侣一并删除
## （删原装件 → 连带其镜像件；删镜像件 → 连带其原装件）。
func remove_at(cell: Vector3i, mirror: bool) -> void:
	var remove_idx: Array[int] = []
	for i in blueprint.parts.size():
		var p := blueprint.parts[i]
		if p.cell == cell:
			remove_idx.append(i)
	if not mirror or remove_idx.is_empty():
		_remove_indices(remove_idx)
		return
	var target := blueprint.parts[remove_idx[0]]
	# 目标是原装件：删所有 mirror_src 指向它的镜像件。
	for i in blueprint.parts.size():
		var p := blueprint.parts[i]
		if p.is_mirrored() and p.mirror_src == target.cell:
			remove_idx.append(i)
	# 目标本身是镜像件：删它的原装件。
	if target.is_mirrored():
		for i in blueprint.parts.size():
			if blueprint.parts[i].cell == target.mirror_src:
				remove_idx.append(i)
	_remove_indices(remove_idx)


func _remove_indices(indices: Array[int]) -> void:
	indices.sort()
	indices.reverse()
	for i in indices:
		if i >= 0 and i < blueprint.parts.size():
			blueprint.parts.remove_at(i)


## 绕 Y 旋转锚格处零件一个 90° 步进；mirror=true 时按链接同步旋转伴侣，
## 保持轴对称对装（两侧同时转，才不会越改越歪）。
func rotate_at(cell: Vector3i, mirror: bool) -> void:
	var target: PlacedPart = null
	for p in blueprint.parts:
		if p.cell == cell:
			target = p
			break
	if target == null:
		return
	target.rot = wrapi(target.rot + 1, 0, 4)
	if not mirror:
		return
	for p in blueprint.parts:
		if p == target:
			continue
		if (p.is_mirrored() and p.mirror_src == target.cell) \
				or (target.is_mirrored() and p.cell == target.mirror_src):
			p.rot = target.rot

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
