extends Node
## 全局事件总线（Autoload 单例，随应用存续）。
## 各系统通过信号解耦，避免互相直接引用。
## 仅收录真正跨场景的事件；单场景内通信请用节点信号。

## 玩家破坏方块后广播。碎屑粒子特效由 BreakFx 监听（main.tscn 挂载）。
signal block_broken(block_id: int, cell: Vector3i)

## 玩家放置方块后广播。
signal block_placed(block_id: int, cell: Vector3i)

## 玩家飞行状态切换后广播（当前创造模式专属能力）。
signal player_mode_changed(flying: bool)

## 右键命中村民或酿灶台时发出，HUD 监听后打开交易面板。
signal request_trade

## 右键命中储物箱方块时发出，HUD 监听后打开该箱的储物面板。
signal request_box_open(cell: Vector3i)

## 右键命中冶炼炉方块时发出，HUD 监听后打开冶炼面板。
signal request_smelt

