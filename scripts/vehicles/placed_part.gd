class_name PlacedPart
extends RefCounted
## 建造网格上的一个已放置零件：零件模板(PartData) + 所占锚格 + 绕 Y 旋转。
## 与 PartData（模板）分离：同一零件可在蓝图里放置多份、位置/朝向各异。

var data: PartData
## 所占最小角锚格（体素坐标，整格）。
var cell: Vector3i = Vector3i.ZERO
## 绕 Y 轴 90° 步进数（0..3）。
var rot: int = 0
## 镜像链接：轴对称放置时记录「原装件的锚格」（无链接为哨兵值）。
## 旋转会改变零件的宽/深跨度，按锚格反推镜像关系会失效——
## 故放置时把链接写死，删除/旋转镜像件时按链接找回原装件（D-032 Phase 4a 修）。
const NO_LINK := Vector3i(-99999, -99999, -99999)
var mirror_src: Vector3i = NO_LINK


static func make(part: PartData, at: Vector3i, rotation: int = 0) -> PlacedPart:
	var placed := PlacedPart.new()
	placed.data = part
	placed.cell = at
	placed.rot = wrapi(rotation, 0, 4)
	return placed


## 是否为某零件的镜像件（放置时由 BuildEditor 写入链接）。
func is_mirrored() -> bool:
	return mirror_src != NO_LINK


## 零件的米制中心（机体局部坐标）：用于重心/升力中心聚合。
## 绕 Y 旋转只对调宽/深，AABB 中心不变，故与 rot 无关。
func local_pos() -> Vector3:
	var half := Vector3(data.size) * 0.5
	return (Vector3(cell) + half) * PartData.GRID_METERS
