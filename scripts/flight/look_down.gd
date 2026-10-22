class_name LookDown
extends RefCounted
## ⚠️ 已作废（D-065 起）：本文件实现的是「3D 仪表台仅低头时出现」的旧路线，
## 用户已拍板否掉，现行路线是「第一人称就显示、正视时与 2D 簇重合」（反转），
## 语义与本文件相反。**禁止接线**：谁按这里的 ENTER_DEG/EXIT_DEG 去 gate 面板
## 可见性，会同时打破 flight_panel_shot:103、对齐断言与内装探针 B1。
## 保留仅供追溯；确认无价值后可直接删除（当前全库零引用）。
## L2「3D 仪表台仅低头时出现」判据（feature_cockpit_3d.md）：相机世界前向
## 俯角 + 滞环。纯函数、无场景依赖——无头探针直接可测，HUD 每帧只保有帧计数。
##
## 为什么用「相机世界前向俯角」而不用机体姿态角：自由观察下 _look_pitch
## 使视线相对机体独立偏转——平飞低头时机体 pitch 恒 0，用姿态角判据功能
## 死；且仪表出现应随「玩家看哪」而非「飞机俯仰」。相机前向在第一人称
## （机头 + COCKPIT_LOOK_UP 固定上仰）与座舱底自由观察（机头 + _look_pitch）
## 下都等于实际视线，同一式子统一适用。
##
## 为什么只在「座舱底层的自由观察」判：第一人称相机无玩家视线控制且投影
## 必落屏底 2D dash 带（几何证明见 feature_cockpit_3d 实施记录），会违反
## 「不与 2D 簇重合显示」的用户决策；故第一人称维持 D-050 现状（只有 2D 簇），
## 3D 仪表台是自由观察的 payoff。

## 低头进入阈值（度）：超过 → 3D 仪表台弹出。18° = 明确故意的低头，远高于
## 鼠标抖动（数度）与第一人称 6.26° 固有上仰（平飞永不误触）。
const ENTER_DEG := 18.0
## 退出阈值（度）：滞环下侧沿。6° 带吸收相机阻尼帧间跳变（RATE_ROT=10，
## τ≈0.1 s）与气流俯仰振荡；12° > 6.26° + 5.7° 余量，平飞复位可靠收起。
const EXIT_DEG := 12.0

## 相机世界前向的「低头角」（度，正 = 朝下）。Godot 相机看局部 −Z，
## 故前向 = -basis.z；clampf 防竖直朝向时 asin 越界（无 NaN）。
static func down_deg(forward: Vector3) -> float:
	return rad_to_deg(asin(clampf(-forward.y, -1.0, 1.0)))


## 滞环步进：已激活时低于退出阈值才收起；未激活时达到进入阈值才弹出。
## enter > exit 构成滞环——阈值附近抖动不翻态。
static func step(active: bool, down: float,
		enter: float = ENTER_DEG, exit: float = EXIT_DEG) -> bool:
	if active:
		return down >= exit
	return down >= enter
