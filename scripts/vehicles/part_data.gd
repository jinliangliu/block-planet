class_name PartData
extends Resource
## 飞机零件的数据契约（数据驱动：新增零件只改 PartRegistry，不改物理代码）。
##
## 设计取向（探索模式重构 D-032）：机体 = 多个零件拼装，每个零件按自身属性
## 贡献 质量 / 升力 / 阻力 / 推力 / 耐久；物理层 Airframe.aggregate() 把这些
## 贡献求和得到整机特性。外观即体素块——size 指定占地格数，Phase 2 建造编辑器
## 据此在体素网格上摆放。
##
## 世界尺度：1 格 = 0.5 m（D-030），GRID_METERS 供 PlacedPart 折算式使用。

## 一格对应的米数（与 D-030 体素 0.5 m 化一致）。
const GRID_METERS := 0.5

enum Category {
	FUSELAGE,  ## 机身（承力主体，提供结构耐久与寄生阻力）
	WING,      ## 主翼（升力面，通常兼副翼→滚转）
	TAIL,      ## 尾翼（水平+垂直安定面，俯仰/偏航控制）
	ENGINE,    ## 发动机（推力、油耗）
	PROPELLER, ## 螺旋桨（推力前置，少量寄生阻力）
	GEAR,      ## 起落架（地面支撑，较大寄生阻力）
	FUEL_TANK, ## 油箱（载油质量，影响重心）
}

## ── 结构 ────────────────────────────────────────────────
@export var id: String = ""
@export var display: String = ""
@export var category: PartData.Category = PartData.Category.FUSELAGE
## 占地尺寸（格）：体素外观与建造网格占用；绕 Y 旋转时宽/深对调、中心不变。
@export var size: Vector3i = Vector3i(1, 1, 1)
## 质量（kg）。
@export var mass: float = 0.0
## 解锁成本（MVP 复用绿宝石作为货币）。
@export var cost: int = 0
## 耐久（结构强度）：过载/撞击损伤的上限，Phase 3 结构失效接入。
@export var durability: float = 100.0

## ── 气动（升力面）──────────────────────────────────────
## 是否为升力面；仅 WING / TAIL 为真。
@export var is_lifting: bool = false
## 升力面面积（m²）：聚合为整机翼面积，直接决定失速速度。
@export var lift_area: float = 0.0
## 寄生阻力系数贡献：聚合 cd0 = CD0_BASE + Σparasite_drag（起落架/撑杆抬阻力）。
@export var parasite_drag: float = 0.0

## ── 控制通道（Phase 3 接入：按面尺寸聚合操纵权限）──────
## 该零件对各轴操纵 authority 的贡献（0..1 量级）；MVP 存值，默认套件不改变手感。
@export var ctrl_pitch: float = 0.0
@export var ctrl_roll: float = 0.0
@export var ctrl_yaw: float = 0.0

## ── 动力 ────────────────────────────────────────────────
## 最大推力（N）：仅 ENGINE；聚合 Σthrust。
@export var thrust: float = 0.0
## 燃油消耗（kg/s）：满油门油耗，Phase 3 燃油系统接入。
@export var fuel_burn: float = 0.0
## 油箱容量（kg 燃油）：仅 FUEL_TANK；Phase 3 燃油质量/重心变化接入。
@export var fuel_capacity: float = 0.0
