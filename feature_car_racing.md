
# Block Planet 赛道竞速玩法设计文档（开发任务书）

> 项目：Block Planet  
> 引擎：Godot 4.6 / GDScript  
> 目标：在载具玩法基础上增加赛道竞速。包含赛道选择器、地形材质、机器人玩家、圈速与完赛记录统计。  
> 文档用途：交给 AI 智能体按此实现，人类负责审查与试玩。

---

## 1. 概述

玩家在载具装配台搭建好摩托车、三轮车或汽车后，可进入“赛道选择器”，选择不同主题的赛道进行单机竞速。赛道包含沙石、湿地、铺装路面、山坡、森林等元素，不同地形影响载具的抓地力、速度与操控。由于是单机游戏，系统会根据赛道难度生成机器人玩家，与玩家同场竞赛。比赛结束后统计最快圈速、最短完赛时间、排名与胜场，并保存到本地记录。

---

## 2. 玩家流程

```text
探索模式
→ 地图选择器
→ 进入“赛道选择器”
→ 选择赛道主题（沙漠 / 森林 / 湿地 / 山地 / 城市 / 混合）
→ 选择载具（已保存蓝图）
→ 选择机器人数量与难度
→ 进入赛道
→ 倒计时起跑
→ 驾驶载具比赛
→ 经过检查点 / 完成圈数
→ 冲过终点
→ 结算界面：排名、圈速、完赛时间、是否破纪录
→ 保存记录到 user://race_records.json
→ 写入回放日志与任务进度
```text

---

3. 目录结构
---
```text
res://
├── data/
│   ├── bestiary/                # 已有
│   ├── fishing/                 # 已有
│   ├── vehicles/                # 已有载具数据
│   └── racing/
│       ├── tracks.json          # 赛道定义
│       ├── terrain.json         # 地形材质
│       ├── ai_racers.json       # 机器人配置
│       └── teaching.json        # 竞速教学
├── scenes/
│   ├── racing/
│   │   ├── track_base.tscn      # 赛道基类场景
│   │   ├── checkpoint.tscn      # 检查点
│   │   ├── start_line.tscn      # 起跑线
│   │   └── finish_line.tscn     # 终点线
│   └── ui/
│       ├── track_selector_ui.tscn
│       ├── race_hud.tscn
│       ├── race_result_ui.tscn
│       └── race_teaching_ui.tscn
└── scripts/
    ├── systems/
    │   ├── bestiary_data.gd     # 已有
    │   ├── fishing_system.gd    # 已有
    │   ├── vehicle_system.gd    # 已有
    │   ├── race_system.gd       # 竞速核心逻辑（Autoload）
    │   ├── track_loader.gd      # 赛道加载
    │   └── race_records.gd      # 记录管理
    ├── racing/
    │   ├── ai_racer.gd          # 机器人玩家
    │   ├── checkpoint.gd        # 检查点逻辑
    │   └── race_manager.gd      # 单场比赛管理
    └── ui/
        ├── track_selector_ui.gd
        ├── race_hud.gd
        ├── race_result_ui.gd
        └── race_teaching_ui.gd
4. 赛道地形与材质
4.1 地形类型
地形	抓地力	速度影响	特点	视觉
铺装路面	高	+10%	稳定，刹车距离短	灰色沥青
沙石	中低	-15%	扬尘，易打滑	黄褐色
湿地	低	-25%	打滑，刹车距离长	深色反光
山坡	中	上坡 -30%，下坡 +20%	需要扭矩，可能溜车	倾斜草地/岩石
森林	中	-10%	有树根、障碍，视线差	泥土 + 树木
草地	中	-5%	较平稳，略慢	绿色
4.2 terrain.json
json
{
  "terrains": [
    {
      "id": "asphalt",
      "name_zh": "铺装路面",
      "name_en": "Asphalt",
      "grip": 1.0,
      "rolling_resistance": 0.02,
      "speed_factor": 1.1,
      "brake_factor": 1.0,
      "dust": false,
      "wet": false,
      "color": "#4A4A4A"
    },
    {
      "id": "gravel",
      "name_zh": "沙石",
      "name_en": "Gravel",
      "grip": 0.7,
      "rolling_resistance": 0.08,
      "speed_factor": 0.85,
      "brake_factor": 0.7,
      "dust": true,
      "wet": false,
      "color": "#B89B72"
    },
    {
      "id": "wetland",
      "name_zh": "湿地",
      "name_en": "Wetland",
      "grip": 0.4,
      "rolling_resistance": 0.12,
      "speed_factor": 0.75,
      "brake_factor": 0.5,
      "dust": false,
      "wet": true,
      "color": "#3B5E4A"
    },
    {
      "id": "hill",
      "name_zh": "山坡",
      "name_en": "Hill",
      "grip": 0.8,
      "rolling_resistance": 0.1,
      "speed_factor": 0.7,
      "brake_factor": 0.8,
      "dust": false,
      "wet": false,
      "slope": true,
      "color": "#6B8E4E"
    },
    {
      "id": "forest",
      "name_zh": "森林",
      "name_en": "Forest",
      "grip": 0.75,
      "rolling_resistance": 0.1,
      "speed_factor": 0.9,
      "brake_factor": 0.8,
      "dust": false,
      "wet": false,
      "obstacles": true,
      "color": "#2E5B2E"
    },
    {
      "id": "grass",
      "name_zh": "草地",
      "name_en": "Grass",
      "grip": 0.8,
      "rolling_resistance": 0.06,
      "speed_factor": 0.95,
      "brake_factor": 0.9,
      "dust": false,
      "wet": false,
      "color": "#5C8A3C"
    }
  ]
}
4.3 地形影响实现
载具进入不同地形区域时，RaceManager 或 VehicleController 读取 terrain_id，调整：

轮胎摩擦力 wheel.friction_slip

发动机功率输出系数

刹车力度

视觉粒子（沙尘、水花）

可用 Area3D 标记地形区域，或使用高度图/材质图层。

5. 赛道定义与选择器
5.1 赛道主题
主题	主要地形	难度	示例赛道
沙漠	沙石、沙丘	★★	沙丘环线
森林	森林、泥土、草地	★★★	林间小径
湿地	湿地、草地、木桥	★★★★	沼泽穿越
山地	山坡、岩石、铺装	★★★★★	盘山公路
城市	铺装路面、隧道	★★	城市街道
混合	全部地形	★★★★	全地形挑战
5.2 tracks.json
json
{
  "tracks": [
    {
      "id": "desert_ring",
      "name_zh": "沙丘环线",
      "name_en": "Desert Ring",
      "theme": "desert",
      "difficulty": 2,
      "laps": 3,
      "length_m": 1200,
      "terrain_segments": [
        { "terrain_id": "gravel", "start": 0.0, "end": 0.6 },
        { "terrain_id": "grass", "start": 0.6, "end": 0.8 },
        { "terrain_id": "gravel", "start": 0.8, "end": 1.0 }
      ],
      "ai_count": 3,
      "ai_difficulty": "easy",
      "unlock": "default",
      "best_lap": null,
      "best_time": null
    },
    {
      "id": "forest_trail",
      "name_zh": "林间小径",
      "name_en": "Forest Trail",
      "theme": "forest",
      "difficulty": 3,
      "laps": 3,
      "length_m": 1500,
      "terrain_segments": [
        { "terrain_id": "forest", "start": 0.0, "end": 0.5 },
        { "terrain_id": "grass", "start": 0.5, "end": 0.7 },
        { "terrain_id": "gravel", "start": 0.7, "end": 1.0 }
      ],
      "ai_count": 4,
      "ai_difficulty": "normal",
      "unlock": "default",
      "best_lap": null,
      "best_time": null
    },
    {
      "id": "wetland_cross",
      "name_zh": "沼泽穿越",
      "name_en": "Wetland Cross",
      "theme": "wetland",
      "difficulty": 4,
      "laps": 2,
      "length_m": 1800,
      "terrain_segments": [
        { "terrain_id": "wetland", "start": 0.0, "end": 0.4 },
        { "terrain_id": "grass", "start": 0.4, "end": 0.6 },
        { "terrain_id": "wetland", "start": 0.6, "end": 0.9 },
        { "terrain_id": "gravel", "start": 0.9, "end": 1.0 }
      ],
      "ai_count": 4,
      "ai_difficulty": "hard",
      "unlock": "quest_wetland",
      "best_lap": null,
      "best_time": null
    },
    {
      "id": "mountain_road",
      "name_zh": "盘山公路",
      "name_en": "Mountain Road",
      "theme": "mountain",
      "difficulty": 5,
      "laps": 2,
      "length_m": 2200,
      "terrain_segments": [
        { "terrain_id": "asphalt", "start": 0.0, "end": 0.3 },
        { "terrain_id": "hill", "start": 0.3, "end": 0.7 },
        { "terrain_id": "asphalt", "start": 0.7, "end": 1.0 }
      ],
      "ai_count": 5,
      "ai_difficulty": "expert",
      "unlock": "shop_1000",
      "best_lap": null,
      "best_time": null
    },
    {
      "id": "city_circuit",
      "name_zh": "城市街道",
      "name_en": "City Circuit",
      "theme": "city",
      "difficulty": 2,
      "laps": 4,
      "length_m": 1000,
      "terrain_segments": [
        { "terrain_id": "asphalt", "start": 0.0, "end": 1.0 }
      ],
      "ai_count": 3,
      "ai_difficulty": "easy",
      "unlock": "default",
      "best_lap": null,
      "best_time": null
    },
    {
      "id": "all_terrain",
      "name_zh": "全地形挑战",
      "name_en": "All-Terrain Challenge",
      "theme": "mixed",
      "difficulty": 4,
      "laps": 3,
      "length_m": 2500,
      "terrain_segments": [
        { "terrain_id": "asphalt", "start": 0.0, "end": 0.2 },
        { "terrain_id": "gravel", "start": 0.2, "end": 0.4 },
        { "terrain_id": "forest", "start": 0.4, "end": 0.6 },
        { "terrain_id": "wetland", "start": 0.6, "end": 0.75 },
        { "terrain_id": "hill", "start": 0.75, "end": 0.9 },
        { "terrain_id": "asphalt", "start": 0.9, "end": 1.0 }
      ],
      "ai_count": 5,
      "ai_difficulty": "hard",
      "unlock": "quest_mixed",
      "best_lap": null,
      "best_time": null
    }
  ]
}
5.3 赛道选择器 UI
显示赛道卡片：主题图标、名称、难度星级、长度、圈数、最佳记录。

可选机器人数量：0–5。

可选机器人难度：简单 / 普通 / 困难 / 专家。

显示“开始比赛”按钮。

未解锁赛道显示锁图标与解锁条件。

6. 机器人玩家（AI 赛车手）
6.1 AI 控制方式
沿预设路径点（Path3D 或 waypoints 数组）行驶。

根据难度调整：

最高速度百分比

转向精度

反应时间

犯错概率（偏离路线、刹车过晚）

AI 也受地形影响，但可做简化。

6.2 ai_racers.json
json
{
  "difficulties": [
    {
      "id": "easy",
      "name_zh": "简单",
      "name_en": "Easy",
      "speed_factor": 0.7,
      "steering_accuracy": 0.6,
      "reaction_time": 0.5,
      "mistake_chance": 0.15
    },
    {
      "id": "normal",
      "name_zh": "普通",
      "name_en": "Normal",
      "speed_factor": 0.85,
      "steering_accuracy": 0.8,
      "reaction_time": 0.3,
      "mistake_chance": 0.08
    },
    {
      "id": "hard",
      "name_zh": "困难",
      "name_en": "Hard",
      "speed_factor": 0.95,
      "steering_accuracy": 0.9,
      "reaction_time": 0.15,
      "mistake_chance": 0.03
    },
    {
      "id": "expert",
      "name_zh": "专家",
      "name_en": "Expert",
      "speed_factor": 1.0,
      "steering_accuracy": 1.0,
      "reaction_time": 0.05,
      "mistake_chance": 0.0
    }
  ],
  "ai_names": [
    "闪电兔", "岩石龟", "风之子", "小星尘", "铁皮狗", "彩虹狐"
  ],
  "ai_vehicle_blueprints": [
    "ai_tricycle_red",
    "ai_car_blue",
    "ai_car_green"
  ]
}
6.3 AI 生成规则
根据赛道 ai_count 生成对应数量机器人。

根据 ai_difficulty 读取难度参数。

机器人使用预设蓝图或随机组合零件，外观与玩家不同。

机器人不消耗真实燃料，但速度受地形影响。

7. 竞赛模式与规则
7.1 比赛流程
text
加载赛道
→ 玩家与 AI 出现在起跑线
→ 倒计时 3-2-1-GO
→ 比赛开始
→ 每经过一个检查点记录进度
→ 完成规定圈数
→ 冲过终点
→ 结算排名
→ 保存记录
7.2 检查点
每条赛道设置多个检查点，防止抄近道。

玩家必须依次经过检查点，否则该圈无效。

检查点用 Area3D 实现，进入时触发。

7.3 排名判定
先完成规定圈数者排名靠前。

若同圈，则比较通过检查点顺序与距离。

未完赛者按完成圈数与检查点数量排名。

7.4 圈速与完赛时间
单圈时间：从起跑到完成一圈的时间。

最快圈速：所有圈中最短的单圈时间。

完赛时间：从起跑到冲过终点总时间。

最短完赛记录：该赛道历史最短完赛时间。

8. 统计与记录
8.1 记录内容
每条赛道独立保存：

json
{
  "track_id": "forest_trail",
  "best_lap_time": 45.32,
  "best_lap_at": "2026-10-14T16:30:00",
  "best_race_time": 142.18,
  "best_race_at": "2026-10-14T16:32:00",
  "total_races": 5,
  "wins": 2,
  "best_rank": 1,
  "last_rank": 2,
  "best_lap_vehicle": "my_tricycle"
}
8.2 保存路径
text
user://race_records.json
8.3 记录面板
在赛道选择器或主菜单增加“竞速记录”页面。

显示每条赛道的最佳圈速、最短完赛、胜场、总场次。

可清空记录。

8.4 回放日志
text
tick, action, track_id, vehicle_id, position, player
2000, race_start, forest_trail, my_tricycle, [0,0,0], daughter
2100, checkpoint, forest_trail, my_tricycle, [10,0,5], daughter
2200, lap_complete, forest_trail, my_tricycle, [0,0,0], daughter
2300, race_finish, forest_trail, my_tricycle, [0,0,0], daughter
9. UI 设计
9.1 赛道选择器
text
┌─────────────────────────────────────┐
│  选择赛道                            │
│  [沙漠] [森林] [湿地] [山地] [城市]  │
│                                     │
│  ┌─────────┐  ┌─────────┐          │
│  │ 沙丘环线 │  │ 林间小径 │          │
│  │ ★★      │  │ ★★★     │          │
│  │ 1200m   │  │ 1500m   │          │
│  │ 最佳: -- │  │ 最佳: -- │          │
│  └─────────┘  └─────────┘          │
│                                     │
│  机器人数量: [0] [1] [2] [3] [4] [5]│
│  机器人难度: [简单] [普通] [困难]    │
│                                     │
│  [ 开始比赛 ]                       │
└─────────────────────────────────────┘
9.2 比赛 HUD
text
┌─────────────────────────────────────┐
│ 圈数: 2/3    排名: 1/5              │
│ 速度: 25 km/h                       │
│ 当前圈: 00:45.32                    │
│ 最快圈: 00:43.10                    │
│ 燃料: ████████░░ 80%                │
│ [手刹] [车灯] [喇叭]                │
└─────────────────────────────────────┘
9.3 结算界面
text
┌─────────────────────────────────────┐
│  比赛结束！                          │
│  排名: 1 / 5                        │
│  完赛时间: 02:22.18                 │
│  最快圈速: 00:43.10                 │
│  是否打破记录: 是！                  │
│                                     │
│  [ 再来一次 ]  [ 返回赛道选择 ]      │
└─────────────────────────────────────┘
10. 与现有系统集成
10.1 载具系统
比赛使用玩家已保存的载具蓝图。

载具性能影响比赛表现。

不同地形对载具要求不同：湿地需要高抓地力轮胎，山坡需要大扭矩发动机。

10.2 任务面板
新增竞速任务：

完成第一场竞速比赛

在沙丘环线赢得第一名

打破一条赛道的最快圈速记录

在湿地赛道不使用手刹完成比赛

用三轮车赢得一场比赛

10.3 教育模式
地形与摩擦力：为什么湿地容易打滑？

安全驾驶：弯道减速、雨天慢行。

能量消耗：上坡更费油。

地图知识：不同主题赛道对应不同地理环境。

10.4 回放系统
记录比赛事件，支持回放与幽灵车。

11. 脚本设计
11.1 RaceSystem（Autoload）
职责：

加载 tracks.json、terrain.json、ai_racers.json

管理比赛状态

生成 AI 赛车手

统计圈速与排名

保存记录

信号：

gdscript
signal race_started(track_id: String)
signal lap_completed(lap: int, lap_time: float)
signal race_finished(results: Array)
signal new_record(track_id: String, record_type: String, value: float)
核心方法：

gdscript
func load_data() -> void
func get_tracks() -> Array
func start_race(track_id: String, vehicle_blueprint_id: String, ai_count: int, ai_difficulty: String) -> void
func register_checkpoint(racer_id: String, checkpoint_index: int) -> void
func finish_race(racer_id: String) -> void
func get_results() -> Array
func save_records() -> void
func load_records() -> void
11.2 TrackLoader
根据 track_id 实例化赛道场景。

设置地形区域、检查点、起跑线、终点线。

根据 terrain_segments 分配地形材质。

11.3 AIController
沿路径点行驶。

根据难度调整速度与转向。

受地形影响。

到达检查点与终点时通知 RaceManager。

11.4 RaceHUD
显示圈数、排名、速度、当前圈时间、最快圈、燃料。

显示小地图与检查点方向。

11.5 RaceResultUI
显示排名、完赛时间、最快圈速、是否破纪录。

按钮：再来一次、返回赛道选择。

12. MVP 最小可行方案
第一版只做：

3 条赛道：沙丘环线、林间小径、城市街道。

地形：沙石、森林、铺装路面。

机器人玩家：3 个，难度简单 / 普通。

比赛规则：3 圈，检查点，排名。

统计：最快圈速、完赛时间、胜场。

赛道选择器与结算界面。

教学：起跑、检查点、圈速。

保存记录到 user://race_records.json。

回放日志记录起跑与完赛。

后续迭代：

更多赛道主题：湿地、山地、混合。

更多 AI 难度与行为。

幽灵车回放。

天气与时间影响。

移动端触控优化。

多人联机竞速。

13. 开发任务拆分（给智能体的 Checklist）
□ 创建 data/racing/ 与四个 JSON 文件
□ 实现 RaceSystem Autoload，加载赛道与地形数据
□ 实现 TrackLoader，根据赛道 ID 生成场景
□ 实现地形区域：Area3D + terrain_id
□ 实现 VehicleController 读取地形参数
□ 实现 Checkpoint 与 StartLine / FinishLine
□ 实现 AIController，沿路径点行驶
□ 实现 RaceManager，管理圈数、检查点、排名
□ 实现 RaceHUD，显示圈数、排名、速度、计时
□ 实现 TrackSelectorUI，选择赛道、AI 数量与难度
□ 实现 RaceResultUI，显示排名与记录
□ 实现 RaceRecords，保存最快圈速与完赛记录
□ 任务面板增加竞速任务
□ 回放系统记录 race_start、checkpoint、lap_complete、race_finish
□ 编写最小测试用例，验证比赛流程
14. 验收标准
玩家能从赛道选择器选择赛道并开始比赛。

赛道包含至少 3 种地形，影响载具速度与操控。

机器人玩家能沿赛道行驶，难度不同表现不同。

比赛能正确计算圈数、检查点、排名。

结算界面显示排名、完赛时间、最快圈速。

最快圈速与最短完赛记录保存到本地。

首次比赛触发教学。

比赛事件写入回放日志。

游戏在 Godot 4.6 中无报错运行。

15. 给智能体的开发指令
请按本文档实现 Block Planet 赛道竞速玩法。
遵循 Godot 4.6 与 GDScript，使用现有目录结构：

系统脚本放 scripts/systems/

竞速脚本放 scripts/racing/

UI 脚本放 scripts/ui/

数据放 data/racing/

场景放 scenes/racing/ 和 scenes/ui/

优先完成 MVP：3 条赛道 + 地形影响 + 3 个 AI + 圈速统计 + 记录保存。
保持代码可读、可测试、可扩展。
每完成一个模块，写清注释与使用说明，并更新 docs/devlog/。

text

