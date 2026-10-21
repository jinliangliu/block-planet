class_name WorldAnchor
extends RefCounted
## 浮动原点（D-062，128 km 大世界）：世界锚定实体的注册组。
##
## 坐标分工（见 World 顶部注释与 feature_world_128km.md）：
##   世界空间（绝对整数，真相）←→ 渲染空间（= 世界 − origin，节点持有）
##   World 节点位置 = −origin，其下区块/结构/树木保持绝对坐标自动跟随；
##   Main 级实体（玩家/飞机/船/箭/浮漂/村民/飞行相机/飞行标注/刷怪笼）
##   与渲染空间锚点（player.spawn_position 等）不随 World 自动平移，须在
##   Events.origin_shifted 时整体搬迁 delta（= 旧 origin − 新 origin）。
##
## 用法：实体出生后调 WorldAnchor.register(node)；main 在信号回调里遍历
## 本组统一 position += delta。
## 铁律：register 自带祖先去重——父链上已有本组成员时跳过（随父自动搬迁，
## 重复登记会双重平移）。区块/结构/树木挂在 World 下，无需注册。

## 组名（main.gd 的 _on_origin_shifted 按此遍历）。
const GROUP := "world_anchor"


## 把实体登记进搬迁组。祖先去重：父亲（或更上层）已登记则跳过——子节点
## 随父平移，再登记一次就会搬两倍距离。
static func register(node: Node3D) -> void:
	if node == null:
		return
	var p := node.get_parent()
	while p != null:
		if p.is_in_group(GROUP):
			return
		p = p.get_parent()
	if not node.is_in_group(GROUP):
		node.add_to_group(GROUP)
