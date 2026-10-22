# Block Planet 地图系统架构与 UI 命名规范

> 项目：Block Planet
> 引擎：Godot 4.6 / GDScript
> 模块：UI/UX 架构、地图系统、全局状态管理
> 目标：明确「启动地球」与「游戏内地图」的定位差异，规范代码命名，优化玩家从选择出生地到进入无缝大世界的体验流程。
>
> **⚠️ 本文档性质：架构与命名规范（想清楚该怎么叫、该谁负责）。**
> 代码是唯一事实来源。本文 §4 的「文档术语 ↔ 代码实体」对照表以**代码现状**为准，
> 两者冲突时以代码为准并回头修订本文（D-066 已做一轮回订）。

---

## 1. 概念界定与层级对比

在游戏开发中，"地图"一词极易产生歧义。对于《Block Planet》这种无缝体素沙盒游戏，我们需要严格区分以下三种界面：

| 界面 | 玩家视角的称呼 | 严格开发术语 | 核心功能 | 视觉表现 |
| :--- | :--- | :--- | :--- | :--- |
| **启动时的地球** | 世界沙盘 / 选服界面 | **世界选择器 (World Selector)** | 决定出生区域、选择模式、加载对应区块 | 3D 旋转地球，点击洲/洋进入区域介绍 |
| **游戏内按 M** | 国家地图 / 大地图 | **世界地图 (World Map / In-Game Map)** | 查看当前位置、航点导航、地标打卡、迷雾解锁 | 俯视视角的 2D/3D 局部地图 |
| **驾驶舱内** | 导航雷达 / MFD | **战术地图 (Tactical Map / Minimap)** | 实时导航、偏航距离、气象雷达 | 飞行员仪表盘上的小屏幕或 HUD 角落 |

> **本作现状：第 2 层「世界地图」未独立存在**，非飞行态按 M 键复用世界选择器（见 §4.3 的理由）。
> 第 3 层战术地图是飞行态的主要导航界面，另有常驻 HUD 小地图。

---

## 2. 设计逻辑解析：为什么启动界面是"世界选择器"？

"地图选择器（Map Selector）"通常用于传统关卡制游戏（如选择独立的地图文件）。但在本项目中，整个世界是无缝的大世界。

启动时的地球，是为了让玩家**选择从地球的哪个区域开始游戏**。选中"亚洲"→ 进入该区域介绍 → 开始探索，系统把 `GameState.current_region` 设为该区域并重载主场景，玩家落在该区域的机场/降落场/村庄空场。**不是**加载一张叫"上海"的独立地图。因此，定义为 **世界选择器（Region Selector）** 最为严谨。

---

## 3. UI/UX 体验流程设计

为了让玩家（尤其是儿童）不感到困惑，地图系统的操作流程设计如下：

### 第一步：启动游戏（地域选择）
- **界面标题**：探索地球。
- **操作**：拖动旋转 3D 地球 → 悬停显示区域名 → 点击进入区域介绍页。
- 介绍页：区域名 + 地理介绍 + 3 张知识卡 + **地标分区**（D-066 新增，见 `feature_World Selector UI-Landmark_CHINA.md`）+ 模式三选一（生存/创造/探索）。

### 第二步：进入游戏（过场动画）
- 点"进入"后进加载页：逐条揭示该区域的植被/生物/气候/风貌，进度满后"开始探索"。
- 发出 `region_entered(region_id)` → `GameState.set_region()` → 主场景重载 → 玩家落在机场/村庄空场。

### 第三步：游戏中按 M
- **非飞行态**：打开世界选择器（地球页）。注意它同时也是「换区域」的入口，需走完加载页才生效，**不是一点就换区域**，破坏性可控。
- **飞行态**：打开战术地图（`FlightTacticalMap`），33×33 网格、`RANGE_M = 180`、缩放 0.5~2×，显示地形分档、跑道、任务航点与**航线折线**（D-066 新增）。

---

## 4. 代码架构与命名规范

### 4.1 文档术语 ↔ 代码实体对照表（**以代码为准**）

初稿按理想架构给了四个名字，代码里一个都不存在。下表是订正后的对照，开发时**以"代码实体"列为准**：

| 文档术语（初稿） | 代码实体（现状） | 说明 |
|---|---|---|
| `WorldSelectorUI` / `scenes/ui/world_selector_ui.tscn` | **`MapSelector`**（`scripts/ui/map_selector.gd`） | 无 `.tscn`，由 `hud.gd:2633` `MapSelector.new()` 内联创建 |
| （地球 3D 渲染，初稿未单列） | **`MapGlobe`**（`scripts/ui/map_globe.gd`） | `Node3D`，由 `map_selector.gd:312` 内联创建；顶点色球面网格，只转不缩放 |
| `InGameWorldMapUI` / `in_game_world_map_ui.tscn` | **不存在** | 按 M 键复用 `MapSelector`，见 §4.3 |
| `TacticalRadar` / `tactical_radar.tscn` | **`FlightTacticalMap`**（`scripts/ui/flight_tactical_map.gd`） | `CanvasLayer`，`hud.gd:255` 创建；飞行态 M 键 / 移动端"地图"按钮 |
| （初稿未单列） | **`MiniMap`**（`scripts/ui/minimap.gd`） | 常驻 HUD **右上角**，仅登机/开船时隐藏，不按键开关 |
| `MapManager` autoload | **不存在，且不新建** | 见 §4.2 |
| `lat_lon_to_world()` / `start_game_at()` | `RegionAtlas.lat_lon_to_dir()` / `region_entered` 信号 | 球面方向映射（非世界坐标）；世界坐标映射见 §4.4 |
| `set_player_position()` / `add_custom_waypoint()` | 无对应实现 | 玩家位置由 `MiniMap` / 战术地图直读机体，不经过中间层 |
| `selected_spawn_coords: Vector3` | `GameState.current_region: int` | **存区域 id 而非坐标** |

### 4.2 为什么不新建 `MapManager` autoload

初稿要求建 `MapManager` 单例存 `selected_spawn_coords` 并对外提供 `set_spawn_point/get_spawn_point`。**不建**，理由：

1. **双份真相**：出生区域已由 `GameState.current_region`（`game_state.gd:19`）+ `RegionAtlas` 承担，再建一个存坐标的单例，两份状态迟早不一致。
2. **本作存的是区域 id，不是坐标**：选中区域后玩家落点由 `main._airport_center()` / `_find_spawn_position()` 在运行时算（机场/降落场/村庄空场），不是一个静态坐标——"spawn point"这个概念在本作不成立。
3. **YAGNI**：真正需要跨系统共享的地图状态（当前航线、当前航点）体量很小，已就近落在 `main._route`（D-066）与战术地图内部，不值得抬到 autoload。

> 若未来做「跨区域自由旅行」，届时再评估是否引入统一中枢。

### 4.3 为什么不独立做「游戏内大地图」

- 玩家活动半径受流式限制（高模 64 m、低模 256 m），本作**单区域无缝、无跨区域自由移动**，一张俯瞰全区的地图信息量很低。
- 导航需求已由两层覆盖：常驻 `MiniMap`（周边）+ 飞行态战术地图（180 m 视野，含航线图层）。
- 现状按 M 打开的选择器需走完加载页才生效，不是「一点就换区域」，误操作成本可控——但**它同时承担"看世界"和"换区域"两件事**是个已知的语义负担，未来若要拆分，优先在这里下手。

### 4.4 坐标与数据流转

```
MapSelector（地球页，RegionAtlas 掩码判定区域）
  → region_entered(region_id)            [map_selector.gd:10]
  → hud._on_region_entered → Events.region_entered
  → main._on_region_entered → GameState.set_region() + reload_current_scene()
  → world.set_region() → main 算 spawn（机场/降落场/村庄空场）→ player.global_position
```

- **经纬度 ↔ 球面**：`RegionAtlas.lat_lon_to_dir()` / `dir_to_lat_lon()`（严格互逆，D-066 已加探针断言）。
- **经纬度 → 世界坐标**：**不提供**。世界是程序化生成的、零地标建筑，且远处区块不加载，按真实比例映射出来的坐标玩家到不了也看不到内容。详见 `feature_World Selector UI-Landmark_CHINA.md`。

### 4.5 命名规范（新代码必须遵守）

- 地图 UI 脚本统一放 `scripts/ui/`，前缀按层级：`map_*`（选择器/地球）、`flight_*`（飞行相关）、`minimap`。
- 飞行相关一律带 `flight_` 前缀（`flight_tactical_map.gd`、`flight_instrument_hud.gd`），避免与通用 UI 混淆。
- 纯逻辑（无节点）放 `scripts/flight/` 或 `scripts/systems/`，`extends RefCounted`，不进场景树。
- 地图类**不写 `.tscn`**（本项目惯例：UI 由 HUD 代码内联组装），但探针场景必须有 `.tscn`。

---

## 5. 验收标准

- [x] 游戏启动后显示世界选择器（`MapSelector`），且无法直接进入游戏。
- [x] 拖动旋转地球、悬停显示区域名、点击进入区域介绍页。
- [x] 区域介绍页含地理介绍、知识卡、地标分区、模式三选一。
- [x] 进入后有过场加载页（植被/生物/气候/风貌逐条揭示）。
- [x] 玩家出生点与所选区域一致（落在该区域机场/降落场/村庄空场）。
- [x] 飞行态按 M 唤出 `FlightTacticalMap`，显示玩家位置、任务航点与航线折线。
- [x] 非飞行态按 M 唤出 `MapSelector`。
- [ ] （未做）独立的游戏内大地图 —— 见 §4.3，收益有限，暂不实施。
- [ ] （未做）迷雾解锁 / 自定义航点标记 —— 待跨区域旅行需求出现再评。

### 回归覆盖

| 探针 | 断言 | 覆盖 |
|---|---|---|
| `life_probe` | 421（地图段 18） | 经纬度往返、拾取旋转、三页切换、知识卡 |
| `globe_marker_probe` | 20 | 机场/降落场/钓点标记 |
| `landmark_probe`（D-066） | 44 | 投影互逆、地标数据、图钉、河流光带、拾取 |
| `flight_view_probe` | 48 | 战术地图开关与网格缓存 |
| `crash_recover_probe` | 42 | 战术地图开关与鼠标模式还原 |
