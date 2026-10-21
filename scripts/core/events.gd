extends Node
## 全局事件总线（Autoload 单例，随应用存续）。
## 各系统通过信号解耦，避免互相直接引用。
## 仅收录真正跨场景的事件；单场景内通信请用节点信号。

## 玩家破坏方块后广播。碎屑粒子特效由 BreakFx 监听（main.tscn 挂载）。
signal block_broken(block_id: int, cell: Vector3i)

## 玩家放置方块后广播。
signal block_placed(block_id: int, cell: Vector3i)

## 玩家飞行状态切换后广播（创造与探索模式都具备的能力）。
signal player_mode_changed(flying: bool)

## 玩家登机 / 下机后广播，HUD 据此显隐飞行仪表。
signal aircraft_ride_changed(riding: bool)

## 坠机弹射且玩家生还后广播（D-056，reason 为坠机原因）：Main 监听后自动
## 执行飞行重置——退出驾驶舱界面，玩家与飞机回到本地图初始停机坪。
## 死亡不广播：_begin_death 已接管飞机交还，复活流程会把玩家送回出生点，
## 坠机救援不抢死亡流程的戏（否则墓碑处看不到残骸、复活点被抢先改写）。
signal aircraft_crash_survived(reason: String)

## 玩家登船 / 下船后广播（D-042 航海玩法），HUD 据此显隐航海界面。
signal boat_ride_changed(riding: bool)

## 飞行器机轮离地（起飞）时广播，进度核心据此累计首飞。
signal aircraft_took_off

## 飞行器到达新的离地高度里程碑（每 20 m 一次）时广播。
signal aircraft_altitude(altitude: float)

## 飞行器累计飞行距离每满 100 m 广播一次（参数为该段里程）。
signal aircraft_distance(meters: float)

## 飞行器一次落地滑跑停稳后广播（U-7 接地质量评分）：result 为 LandingQuality.score()
## 的输出（total/grade/emoji + roll_distance 滑跑距离），HUD 据此 Toast 落地评价。
## 残骸摔倒、任务外坠机解体不广播（那不是「降落」）。
signal aircraft_landed(result: Dictionary)

## 浮动原点搬迁后广播（128 km 大世界，D-062）：delta 为「同一世界位置的渲染
## 坐标变化量」（= 旧 origin − 新 origin）。订阅方两类：
##   - 世界锚定节点（World/MobSpawner/BreakFx/Player/飞行标记/船/箭/倒树/浮漂）：
##     position += delta（其下绝对坐标子节点随之平移，无需逐个处理）；
##   - 库存锚点（玩家 spawn_position、Main._craft_park/_mission_anchor 等渲染
##     空间存量）：同样 += delta 完成重基。
## 世界节点自身位置 = −origin，其下区块/结构/树木自动跟随，不经过本信号。
signal origin_shifted(delta: Vector3)

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

## 一场竞速比赛结算后广播（track_id / vehicle_id / 名次 rank / 圈数 laps /
## 最快圈 best_lap / 完赛时间 total_time / 是否全程未用脚刹 clean）。
## 进度核心据此累计竞速任务与成就；记录落盘由 RaceSystem 负责。
signal race_finished(track_id: String, vehicle_id: String, rank: int, laps: int,
	best_lap: float, total_time: float, clean: bool)

## 刷新某条赛道记录时广播（record_type 取 "best_lap" / "best_time"）。
## 与 race_finished 分开：破纪录才发，进度核心据此累计「更快一圈」类任务。
signal race_record_beaten(track_id: String, record_type: String)

