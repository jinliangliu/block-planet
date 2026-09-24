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

## 地图选择器确认区域后发出（region_id 为 RegionAtlas 常量）；
## Main 监听后记录到 GameState 并重载主场景，使新区域生效。
signal region_entered(region_id: int)

## 右键命中冶炼炉方块时发出，HUD 监听后打开冶炼面板。
signal request_smelt

## 生物死亡后广播（mob_type 为 Mob.MobType 常量），进度核心据此累计击杀。
signal mob_killed(mob_type: int)

## 玩家死亡后广播（Main 转发 Player.died）。
signal player_died

## 玩家在合成台完成一次合成后广播，进度核心据此累计。
signal craft_done(item_id: int)

## 玩家在冶炼炉完成一次冶炼后广播，进度核心据此累计。
signal smelt_done(item_id: int)

## 通用提示通道：任意系统（狩猎拦截、工具等级不足、垂钓结果等）发出后
## 由 HUD 以 Toast 呈现，避免各模块各自持有界面引用。
signal notice(text: String)

## 生物长大一个阶段后广播，进度核心据此累计「观察成长」类成就。
signal mob_grown(mob_type: int, stage: int)

