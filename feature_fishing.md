
# Block Planet 钓鱼玩法设计文档（开发任务书）
> 项目：Block Planet
> 引擎：Godot 4.6 / GDScript
> 目标：为探索模式增加四大洋钓鱼玩法，接入生物图鉴、任务、回放与教育系统。
> 文档用途：交给 AI 智能体按此实现，人类负责审查与试玩。

---

## 1. 概述
在探索模式的地图选择器中，为四大洋增加“可钓鱼标志”。玩家选择某个大洋钓点后，进入针对该地区的探钓玩法。玩家从背包选择钓具，进入渔猎操作界面，完成鱼饵搭配、铅坠配重、抛投、渔轮收线等操作，钓到该地区特有鱼种。

钓到新鱼种时弹出“新鱼种解锁卡片”，并写入生物图鉴，记录首次钓获时间、钓点、钓具等信息。

---

## 2. 玩家流程
```text
探索模式 → 地图选择器 → 四大洋钓鱼标志 → 选择钓点 → 选择钓具（海竿、渔轮、鱼线、鱼饵、铅坠） → 渔猎操作界面 → 鱼饵搭配 → 铅坠配重 → 抛投 → 等待咬钩 → 渔轮收线 → 成功钓获 / 跑鱼 → 新鱼种解锁卡片 → 写入图鉴 + 回放日志 + 任务进度
```

## 3. 目录结构

```
res://
├── data/
│   ├── bestiary/                # 已有生物图鉴
│   └── fishing/
│       ├── spots.json           # 钓点
│       ├── gear.json            # 钓具
│       ├── fish.json            # 鱼种
│       └── teaching.json        # 教学步骤
├── scenes/
│   └── ui/
│       ├── fishing_ui.tscn      # 渔猎操作界面
│       ├── fishing_gear_ui.tscn # 钓具选择
│       └── fishing_teaching_ui.tscn # 教学弹窗
└── scripts/
    ├── systems/
    │   ├── bestiary_data.gd     # 已有
    │   ├── fishing_system.gd    # 钓鱼核心逻辑（Autoload）
    │   ├── fishing_gear.gd      # 钓具数据与配置
    │   └── fishing_teaching.gd  # 教学管理
    └── ui/
        ├── bestiary_ui.gd       # 已有
        ├── fishing_ui.gd        # 渔猎操作界面控制
        ├── fishing_gear_ui.gd   # 钓具选择控制
        └── fishing_teaching_ui.gd # 教学弹窗控制
```

## 4. 地图选择器与钓点

### 4.1 四大洋钓点

表格

| 大洋 | 钓点标志 | 特色鱼种 |
| --- | --- | --- |
| 太平洋 | 🎣 太平洋钓点 | 蓝鲸、座头鲸、大白鲨、鲸鲨、太平洋鲑鱼 |
| 大西洋 | 🎣 大西洋钓点 | 蓝鳍金枪鱼、大西洋鳕鱼、灰海豹 |
| 印度洋 | 🎣 印度洋钓点 | 鲸鲨、儒艮、蝠鲼、狮子鱼、小丑鱼 |
| 北冰洋 | 🎣 北冰洋钓点 | 北极鳕鱼、格陵兰鲨、独角鲸 |

每个大洋可细分子钓点：

```
太平洋
├── 近岸浅水     → 小丑鱼、狮子鱼
├── 珊瑚礁       → 鲸鲨、绿海龟
└── 深海         → 蓝鲸、大白鲨、座头鲸
```

### 4.2 spots.json

```
{
  "spots": [
    {
      "id": "pacific_shallow",
      "region_id": "pacific_ocean",
      "name_zh": "太平洋近岸浅水",
      "name_en": "Pacific Shallow",
      "depth": "shallow",
      "fish_pool": ["clownfish", "lionfish", "green_sea_turtle"],
      "unlock": "default"
    },
    {
      "id": "pacific_deep",
      "region_id": "pacific_ocean",
      "name_zh": "太平洋深海",
      "name_en": "Pacific Deep Sea",
      "depth": "deep",
      "fish_pool": ["blue_whale", "great_white_shark", "humpback_whale"],
      "unlock": "need_deep_rod"
    }
  ]
}
```

`unlock` 可选值：`default`、`need_deep_rod`、`quest_deep_sea`、`shop_500` 等。

## 5. 钓具系统

### 5.1 钓具组成

```
海竿 Sea Rod       → 长度、强度、适用钓法
渔轮 Reel          → 卸力上限、收线速度、线容量
鱼线 Fishing Line  → 拉力值、耐磨度、可见度
鱼饵 Bait          → 假饵 Lure / 活饵 Live Bait
铅坠 Sinker        → 重量影响抛投距离
```

### 5.2 gear.json

```
{
  "rods": [
    { "id": "basic_sea_rod", "name_zh": "入门海竿", "name_en": "Basic Sea Rod", "strength": 1, "max_line": 2, "unlock": "default" },
    { "id": "deep_sea_rod", "name_zh": "深海船竿", "name_en": "Deep Sea Rod", "strength": 3, "max_line": 4, "unlock": "quest_deep_sea" }
  ],
  "reels": [
    { "id": "basic_reel", "name_zh": "基础纺车轮", "name_en": "Basic Spinning Reel", "drag_max": 2, "speed": 2, "unlock": "default" },
    { "id": "heavy_reel", "name_zh": "重型鼓轮", "name_en": "Heavy Baitcasting Reel", "drag_max": 5, "speed": 3, "unlock": "shop_500" }
  ],
  "lines": [
    { "id": "nylon_line", "name_zh": "尼龙线", "name_en": "Nylon Line", "strength": 2, "visibility": "high", "unlock": "default" },
    { "id": "fluorocarbon_line", "name_zh": "碳氟线", "name_en": "Fluorocarbon Line", "strength": 3, "visibility": "low", "unlock": "shop_300" }
  ],
  "baits": [
    { "id": "live_shrimp", "name_zh": "活虾", "name_en": "Live Shrimp", "type": "live", "target": ["small_fish", "reef_fish"], "unlock": "default" },
    { "id": "metal_lure", "name_zh": "金属假饵", "name_en": "Metal Lure", "type": "lure", "target": ["predator"], "unlock": "shop_200" },
    { "id": "soft_lure", "name_zh": "软虫假饵", "name_en": "Soft Lure", "type": "lure", "target": ["bottom_fish"], "unlock": "shop_200" }
  ],
  "sinkers": [
    { "id": "sinker_10g", "name_zh": "10克铅坠", "name_en": "10g Sinker", "weight": 10, "cast_distance": 1, "unlock": "default" },
    { "id": "sinker_30g", "name_zh": "30克铅坠", "name_en": "30g Sinker", "weight": 30, "cast_distance": 3, "unlock": "default" },
    { "id": "sinker_60g", "name_zh": "60克铅坠", "name_en": "60g Sinker", "weight": 60, "cast_distance": 5, "unlock": "shop_100" }
  ]
}
```

### 5.3 规则

- 铅坠越重，抛投越远，但下沉越快，可能错过中上层鱼。
- 假饵适合掠食性鱼类，活饵适合杂食和小鱼。
- 鱼线拉力要大于目标鱼挣扎力，否则断线。
- 渔轮卸力决定能否拉住大鱼，卸力太低会 “炸线”。

## 6. 渔猎操作界面

从背包选择装备后，进入渔猎操作界面。分四个阶段：

### 6.1 鱼饵搭配

从背包选择鱼饵。
显示目标鱼种提示、鱼饵适配度。
教学提示：“不同的鱼爱吃不同的饵。”

### 6.2 铅坠配重

选择铅坠。
显示预计抛投距离。
教学提示：“铅坠越重，抛得越远。”

### 6.3 抛投

力量条蓄力，参考 FishMasters。
松手时机决定落点。
落点影响能钓到的鱼种。

```
落点范围：
近岸 → 浅水鱼
中距 → 珊瑚礁鱼
远投 → 深海鱼
```

### 6.4 渔轮收线

鱼咬钩后进入收线小游戏，参考 Fishdew 的移动条机制。
玩家控制收线速度，鱼会挣扎。
渔轮卸力可调，太高会断线，太低会跑鱼。

```
收线小游戏：
[========|=====]  鱼的位置
[======|=======]  安全区
按住收线，松开放线
```

## 7. 引导教学

每条教学做成独立步骤，首次进入时触发，之后可在设置里重看。

### teaching.json

```
{
  "lessons": [
    {
      "id": "lesson_bait",
      "title_zh": "鱼饵搭配",
      "steps": [
        "不同的鱼爱吃不同的饵。",
        "假饵适合掠食性鱼类，活饵适合杂食和小鱼。",
        "选对鱼饵，鱼才更容易上钩。"
      ],
      "trigger": "first_time_bait"
    },
    {
      "id": "lesson_sinker",
      "title_zh": "铅坠配重",
      "steps": [
        "铅坠越重，抛得越远。",
        "但铅坠太重，饵下沉太快，可能错过中上层鱼。",
        "试试不同重量的铅坠吧。"
      ],
      "trigger": "first_time_sinker"
    },
    {
      "id": "lesson_drag",
      "title_zh": "渔轮卸力",
      "steps": [
        "渔轮卸力太紧，鱼线容易断。",
        "卸力太松，鱼会跑掉。",
        "大鱼上钩时，要一边收线一边调整卸力。"
      ],
      "trigger": "first_time_drag"
    },
    {
      "id": "lesson_cast",
      "title_zh": "抛投",
      "steps": [
        "按住蓄力，松手抛投。",
        "力度决定距离，时机决定落点。",
        "想钓深海鱼，就用力抛远一点。"
      ],
      "trigger": "first_time_cast"
    },
    {
      "id": "lesson_reel",
      "title_zh": "渔轮收线",
      "steps": [
        "鱼咬钩后，按住收线。",
        "让鱼保持在安全区内，进度条满就钓上来了。",
        "别一直收，鱼挣扎时要放线。"
      ],
      "trigger": "first_time_reel"
    }
  ]
}
```

## 8. 鱼种设定

每个大洋鱼种池独立，钓到的鱼自动写入图鉴。

### fish.json

```
{
  "fish": [
    {
      "id": "pacific_salmon",
      "region_id": "pacific_ocean",
      "spot_ids": ["pacific_shallow", "pacific_deep"],
      "habitat": "ocean",
      "depth": "mid",
      "rarity": "common",
      "difficulty": 2,
      "preferred_bait": ["live_shrimp", "metal_lure"],
      "fight_power": 3,
      "name_zh": "太平洋鲑鱼",
      "name_en": "Pacific Salmon",
      "scientific": "Oncorhynchus",
      "fact_zh": "逆流而上回到出生地产卵，被称为洄游。"
    },
    {
      "id": "bluefin_tuna",
      "region_id": "atlantic_ocean",
      "spot_ids": ["atlantic_open"],
      "habitat": "ocean",
      "depth": "deep",
      "rarity": "rare",
      "difficulty": 5,
      "preferred_bait": ["metal_lure"],
      "fight_power": 8,
      "name_zh": "蓝鳍金枪鱼",
      "name_en": "Atlantic Bluefin Tuna",
      "scientific": "Thunnus thynnus",
      "fact_zh": "游得极快，是海洋里的高速猎手。"
    }
  ]
}
```

稀有度表

表格

| 稀有度 | 颜色 | 难度 | 说明 |
| --- | --- | --- | --- |
| common | 白 | 1–2 | 常见，容易钓 |
| uncommon | 绿 | 3 | 需要合适鱼饵 |
| rare | 蓝 | 4–5 | 需要远投和好装备 |
| epic | 紫 | 6–7 | 需要特定钓点和鱼饵 |
| legendary | 金 | 8–10 | 极难，有特殊条件 |

## 9. 生物图鉴补充

### 9.1 图鉴增加海钓鱼类

在 bestiary 的海洋区域里，补充可钓的鱼类条目。建议字段：

```
{
  "id": "bluefin_tuna",
  "kingdom": "animalia",
  "category": "fish",
  "region_id": "atlantic_ocean",
  "catchable": true,
  "fishing_difficulty": 5,
  "name_zh": "蓝鳍金枪鱼",
  "name_en": "Atlantic Bluefin Tuna",
  "scientific": "Thunnus thynnus",
  "fact_zh": "游得极快，是海洋里的高速猎手。"
}
```

`catchable: true` 表示可钓，图鉴 UI 加 “钓鱼” 图标。

### 9.2 新鱼种解锁卡片

首次钓到新鱼种时弹出：

```
┌─────────────────────────┐
│   🎉 新鱼种解锁！        │
│                         │
│   [鱼图标]               │
│   蓝鳍金枪鱼             │
│   Atlantic Bluefin Tuna  │
│                         │
│   “游得极快，是海洋里的   │
│    高速猎手。”           │
│                         │
│   首次钓获：2026-10-14   │
│   钓点：大西洋外海        │
│   钓具：深海船竿 + 金属假饵│
│                         │
│   [ 收入图鉴 ]           │
└─────────────────────────┘
```

### 9.3 图鉴标记钓获时间

玩家存档中记录：

```
{
  "id": "bluefin_tuna",
  "first_caught_at": "2026-10-14T15:30:00",
  "first_caught_spot": "atlantic_open",
  "first_caught_gear": {
    "rod": "deep_sea_rod",
    "reel": "heavy_reel",
    "line": "fluorocarbon_line",
    "bait": "metal_lure",
    "sinker": "sinker_60g"
  },
  "catch_count": 1,
  "max_weight_kg": 180
}
```

这些数据存 `user://fishing_journal.json`，不写进 `fish.json`。

## 10. 脚本设计

### 10.1 FishingSystem（Autoload）

职责：

- 加载 spots.json、gear.json、fish.json、teaching.json
- 提供钓点、鱼种、钓具查询
- 管理钓鱼状态机
- 发出信号

信号：

```
signal fish_caught(fish_id: String, spot_id: String, gear: Dictionary)
signal new_species_unlocked(fish_id: String)
signal fishing_failed(reason: String)
signal fishing_state_changed(state: int)
```

状态枚举：

```
enum State {
    IDLE,
    SELECT_GEAR,
    SELECT_BAIT,
    SELECT_SINKER,
    CASTING,
    WAITING,
    HOOKED,
    REELING,
    RESULT
}
```

核心方法：

```
func load_data() -> void
func get_spots_for_region(region_id: String) -> Array
func get_fish_pool(spot_id: String, bait_id: String, depth: String) -> Array
func start_fishing(spot_id: String, gear: Dictionary) -> void
func cast_power(power: float) -> float          # 返回距离
func hook_fish() -> Dictionary                  # 返回鱼实例
func update_reel(delta: float, input: float) -> float  # 返回进度
func try_catch() -> Dictionary
func release_fish(fish_id: String) -> void
```

### 10.2 FishingUI

控制渔猎操作界面
四个阶段：鱼饵、铅坠、抛投、收线
显示力量条、鱼位置、安全区、进度条
成功后调用 `FishingSystem.try_catch()`

### 10.3 FishingGearUI

从背包选择海竿、渔轮、鱼线、鱼饵、铅坠
显示适配度与预计抛投距离
返回 gear 字典

### 10.4 FishingTeachingUI

根据 teaching.json 显示教学步骤
首次触发，记录已看教学

## 11. 任务与回放

### 11.1 任务面板

新增钓鱼任务：

- 钓到你的第一条鱼
- 在四大洋各钓到 1 种鱼
- 钓到 1 条稀有鱼
- 用假饵钓到 1 条掠食性鱼类
- 放生 3 条鱼

### 11.2 回放日志

```
tick, action, position, fish_id, player
1200, cast, [10,64,20], null, daughter
1300, catch, [10,64,20], pacific_salmon, daughter
1400, release, [10,64,20], pacific_salmon, daughter
```

## 12. MVP 最小可行方案

第一版只做：

- 四大洋各 1 个钓点，地图选择器显示 🎣 标志
- 基础海竿 + 基础渔轮 + 尼龙线 + 活虾 + 10g/30g 铅坠
- 钓鱼流程：选饵 → 选铅坠 → 抛投 → 收线
- 每个大洋 3 种鱼，共 12 种
- 首次钓到新鱼种弹出解锁卡片
- 图鉴标记首次钓获时间
- 5 条引导教学
- 写入回放日志

后续迭代：

- 鱼竿 / 渔轮 / 鱼线升级
- 假饵与活饵区分
- 稀有度与天气 / 时间
- 深海钓点与大型鱼
- 移动端触控优化
- 水族馆展示

## 13. 开发任务拆分（给智能体的 Checklist）

- 创建 data/fishing/ 目录与四个 JSON 文件
- 实现 FishingSystem Autoload，加载所有 JSON
- 实现 FishingGearUI，从背包选择钓具
- 实现 FishingUI 状态机：鱼饵 → 铅坠 → 抛投 → 收线
- 实现抛投力量条与距离计算
- 实现收线小游戏，鱼挣扎与卸力
- 实现鱼种判定：地区、钓点、鱼饵、深度
- 实现 FishingTeachingUI，首次触发教学
- 扩展 BestiaryData，支持 catchable 与钓鱼记录
- 实现新鱼种解锁卡片
- 将钓获时间、钓点、钓具写入 user://fishing_journal.json
- 地图选择器增加四大洋钓鱼标志
- 任务面板增加钓鱼任务
- 回放系统记录 cast、catch、release 事件
- 编写最小测试用例，验证钓到鱼与图鉴解锁

## 14. 验收标准

1. 玩家能从地图选择器进入四大洋钓点。
2. 能从背包选择海竿、渔轮、鱼线、鱼饵、铅坠。
3. 能完成鱼饵搭配、铅坠配重、抛投、收线四个操作。
4. 不同铅坠影响抛投距离，不同鱼饵影响鱼种。
5. 首次钓到新鱼种弹出解锁卡片，图鉴中记录首次钓获时间。
6. 教学环节首次触发，之后可重看。
7. 钓获事件写入回放日志。
8. 游戏在 Godot 4.6 中无报错运行。

## 15. 给智能体的开发指令

请按本文档实现 Block Planet 钓鱼玩法。
遵循 Godot 4.6 与 GDScript，使用现有目录结构：

- 系统脚本放 `scripts/systems/`
- UI 脚本放 `scripts/ui/`
- 数据放 `data/fishing/`
- 场景放 `scenes/ui/`

优先完成 MVP，保持代码可读、可测试、可扩展。
每完成一个模块，写清注释与使用说明，并更新 `docs/devlog/`。