# Block Planet 飞行线路规划与动态导航开发任务书

项目：Block Planet ｜ 引擎：Godot 4.6 / GDScript
目标：补齐「登机规划 → 航线生成 → 飞行中导航」的闭环。**核心不是新建导航 UI，而是把已有的 HSI/CDI、战术地图、飞行指引十字串成一条航线**，并补上初稿遗漏的「多航路点」能力。

> **本文档性质：开发任务书（要做什么）。** 现状与数值事实以 `features/feature_flight.md` 为准；
> 代码是唯一事实来源，两者冲突时以代码为准并回头修订本文。

---

## 0. 开工前必读：已有能力与初稿的冲突

初稿（AI 生成）把大量**已实现的功能**当成需要从零开发。照做会重复建设，且把已验证过的仪表改坏。开工前必须知道：

| 初稿要求 | 代码现状（实测） | 本任务的正确做法 |
|---|---|---|
| 「结合已有的 AutoPilot」实现 LNAV | **不存在 AutoPilot**。只有 D-034「自动改平」（`aircraft.gd:93`），无航向保持、无自动转弯 | **本任务不引入自动驾驶**。改为「航线 = 依次多个 `set_navigation` 目标」，玩家自己飞；每个航路点飞越后由导航系统切下一个 |
| 「HUD 罗盘目标指针 + 偏航距离条（XTE）」 | **HSI/CDI 已实现**：`flight_instruments.gd:150 set_navigation()`，`nav_bearing_deg` / `nav_dev_deg` / `nav_dots` / `nav_distance_m` 全有（`CDI_DEG_PER_DOT` 点数化偏差） | **不重画罗盘与偏航条**，直接把航线接入现有 HSI/CDI |
| 「全览地图（MFD）显示航线与飞机图标」 | **战术地图已实现**：`flight_tactical_map.gd`，33×33 网格、`RANGE_M = 180`、缩放 0.5~2×、跑道扫描、地形分档着色 | **只加航线图层**，不重做地图。地图已有 `_estimate_block()` 与地形配色，新增图层须与之一致 |
| 「HUD 十字指引线」 | **D-054 飞行指引十字已实现**：`flight_director.gd`，模式 `OFF/ROLL/TAKEOFF/APPROACH/CRUISE`，11 px/度、三档配色、动作词标签 | 扩展 `CRUISE` 模式的横向导引（当前垂直导引为主），**不新增第二套十字** |
| 「按 M 键打开全览地图」 | **M 键已是战术地图**（`aircraft_camera.set_map_view`） | 沿用，不改键位 |

另注：目标点复用 `set_navigation`，**`main.gd` 零改动**是既有设计（见 D-054）。

---

## 1. 尺度前提（决定所有数值，先读）

> **D-066 订正**：本节原值是 D-063 之前的旧尺度，**已作废**。现行值如下，照抄旧值会做出飞不到的东西。

- **1 格 = 1 m**（D-063）；世界总高 **256 格 = 256 m**（D-055）。
- 分层地形实测最高 **188 m**（原为 188 格 × 0.5 m = 94 m，改尺度后同一地形 = 188 m）。巡航高度必须**按航线净空算**，不能拍一个固定 AGL——山有 188 m 高。
- 流式：**高模 `LOAD_RADIUS = 4` 区块（64 m）、低模 `LOW_RADIUS = 16` 区块（256 m）**（D-064）。世界是无限流式生成的，**航线只能规划在几百米量级**——飞出去没有加载的区块，也没有内容。
- 战术地图 `RANGE_M = 180`，缩放 0.5~2× → 最远可视 **360 m**。
- 初稿的「距目的地 5 km 触发准备降落」「偏离航线 2 km 告警」按本作尺度应为 **约 400 m**（与 D-054 `APPROACH_DIST` 一致）与 **约 120 m**（与 `DEV_CLAMP` 同量级）。

> 结论：所有距离阈值按「米/百米」给。**初稿的 km 级数字一律作废。**
> 另注：内容（机场、村庄）全在原点附近数百米内（亚洲机场中心格 `(114,96)`），规划航线时不要假设玩家在世界的任意位置。

---

## 2. 本任务真正要做的三件事

已有导航仪表、地图、指引十字都很完整，缺的是**把它们串成航线**。范围收敛为：

### 2.1 航线数据结构（多航路点）

现有 `set_navigation(target)` 只支持**单个**目标。本任务引入航路点序列：

```gdscript
# NavigationSystem（Autoload 或挂在 World）
var _waypoints: Array[Dictionary] = []   # [{pos: Vector3, name: String, kind: int}]
var _active_index := -1

func set_route(points: Array) -> void
func advance() -> void            # 飞越当前点后切下一个
func current_target() -> Vector3# 给 set_navigation 用
func route_progress() -> float    # 0..1，进度条用
```

**飞越判定**：水平距离 < `WP_CAPTURE_R`（约 40 m）且已过该点，或直接由玩家/指引十字确认。**不做「必须飞越」的硬拦截**——儿童向，允许飞过再回来。

### 2.2 航线生成（避开高山 —— 这是本作的核心玩法）

初稿说「生成 1-2 个中间航路点避开高山」，方向正确但没说怎么避。**本作必须避开山**（D-055 最高 94 m，而巡航只有 50~90 m）。

生成算法（在规划时一次性算好，非运行时）：
1. 起降两点连线，采样 N 个等距点。
2. 每点取 `world.get_surface_height()`，得地形高度曲线。
3. **在超限段插入侧向绕行点**：把该段的航点沿垂直方向平移，直到地形高度降到阈值以下。
4. 平滑相邻航点，避免锯齿航线（**视觉与手感都要顺**）。

> 判据用 `get_surface_height`（读已生成地形，不依赖区块加载），不要用 `get_block` 逐格查（慢且要求区块已加载）。

### 2.3 地图航线图层（唯一的新 UI）

在**已有战术地图**上叠加：起降点标记、航路点连线、当前航段高亮、飞机图标与航向。
- 航线用现有地图的坐标转换绘制，**不要新建 SubViewport 俯视相机**（初稿的方案）——战术地图已经是这个功能，且是 2D 的，省一个渲染目标。
- 地图外仍显示航线进度（距离下一个航点、剩余航段数），复用现有 `_bottom_panel`。

---

## 3. 刻意不做的事（避免范围膨胀）

- **不做自动驾驶/LNAV**（无 AutoPilot，且儿童向应让玩家自己飞）。
- **不做 SubViewport MFD**（战术地图已覆盖；座舱内低头看屏幕可作为后续独立任务）。
- **不做 km 级长途航线**（世界无限流式，长距离规划无意义且易卡）。
- **不做多机场选择器**（本作 `has_airport` 仅 8 个区域各一处，起点唯一；多机场是未来扩展）。
- **不重画 HSI/CDI / 战术地图 / 指引十字**。

---

## 4. 关键数值（按本作尺度）

| 项 | 值 | 说明 |
|---|---|---|
| 航路点捕获半径（自由航线） | 40 m | `RoutePlan.WP_CAPTURE_R`，水平距离。**任务航点不用它**——任务用 `MissionData.radius()`（默认 30 m），见 §6.1 |
| 地形净空阈值 | 地形高度 + 30 m | `RouteGenerator` 规划时保证的 AGL 裕度 |
| 航线规划高度 | ≥ 该点地形 + 30 m，且 ≥ 两端较高者 + 增量 | **不要拍固定 AGL**：地形最高 188 m |
| 偏航告警阈值 | 120 m | 与 `flight_director.DEV_CLAMP` 同量级 |
| 准备降落提示距离 | 约 400 m | 与 D-054 `APPROACH_DIST = 400` 一致 |
| 航线采样点数 | 16~32（默认 24） | 两点间等距采样，供绕行计算 |

---

## 5. 与气象的联动

航路气象简报（初稿第 2 节）**保留**，但数据来源改为实际的 `weather` 系统（见 `feature_flight-aviation_weather.md`）：
- 规划时读当前区域气象 → 提示「目的地侧风较大」等。
- 遇到特情时，航线系统可**重规划**（绕开雷暴区），复用 §2.2 的绕行算法。

---

## 6. 开发 Checklist（D-066 实施结果）

- [x] **航线数据结构**：`scripts/flight/route_plan.gd`（`RoutePlan`，`RefCounted` 纯逻辑）。
      接口 `set_route / has_route / advance / set_current_index / current_index /
      current_target / remaining / total / progress / is_complete / clear`。
- [x] **航线生成（避山）**：`scripts/flight/route_generator.gd`（`RouteGenerator`）。
      `plan_between(world, from, to, clearance_m=30, samples=24)`：等距采样
      `get_surface_height` → 超限段沿水平法向插侧向绕行点（外推有上限防死循环）→
      三点平滑。**world 走鸭子类型**（只要 `get_surface_height`），避免解析期循环依赖。
- [x] **接线**：`main._sync_mission_navigation()`（每帧，带 `_nav_sync_key` 去重短路）
      + `hud.current_mission_waypoints()` / `current_mission_waypoint_index()` /
      `set_tactical_route()`。坐标统一在 main 侧 `to_render` 一次再注入。
- [x] **飞越判定**：见 §6.1 —— **任务链路不自己判定**，对齐 `MissionManager`。
- [x] **扩展 CRUISE 横向导引**：经查 D-054 已实现（`flight_director.gd:151` 直接用
      `fi.nav_dev_deg`），**未重做**。本项原本就是「已实现被误当成待做」。
- [x] **战术地图航线图层**：`flight_tactical_map.set_route()` + 折线绘制，复用既有
      `_world_to_screen()`，未新建 SubViewport 相机。
- [ ] HUD 航线进度（距离下一航点 / 剩余航段数）——**未做**：仪表已有
      `nav_distance_m` 与「航点 i/n」标签，再在 bottom panel 加一份是重复信息。
- [ ] 准备降落提示 —— **沿用** D-054 `APPROACH`（`APPROACH_DIST = 400`），未另加。
- [ ] 偏航告警 —— **沿用**既有 CDI 点数与指引十字三档配色，未另加文字告警。
- [ ] 航路气象简报 —— 未做，依赖 `feature_flight-aviation_weather.md` 的推进。
- [x] **探针**：`route_nav_probe`（36 断言，纯逻辑）+ `route_wiring_probe`（36 断言，
      端到端接线）。均带 `SaveGuard.snapshot()/restore()`（D-010）。

### 6.1 关键设计：任务链路不让 `RoutePlan` 自己判定飞越

任务航点的飞越真相在 `MissionManager._step_circuit()`（用任务自带的 `mission.radius()`，
默认 30 m）。若 `RoutePlan` 再按自己的 `WP_CAPTURE_R = 40 m` 推进一次，就是**双份真相**——
会出现「地图已切下一个点、仪表还指着上一个点」。

故：`MissionManager` 推进后 emit `waypoint_advanced(index, pos)`；main 每帧读
`current_mission_waypoint_index()` 并调 `_route.set_current_index()` **对齐**，
`RoutePlan` 只负责回答「当前该飞哪 / 进度多少」。
`advance()`（40 m 自判定）只留给**无任务的自由航线**与未来 A→B 规划。

## 7. 验收标准

- [x] 能规划一条**避开高山**的航线：`route_nav_probe` 逐点断言全程净空 ≥ 30 m（穿山测试）。
- [x] 飞越航路点后导航自动切下一目标：`route_wiring_probe` 端到端断言目标从
      `waypoints[0]` 切到 `waypoints[1]`，HSI/CDI 随之更新。
- [x] 打开战术地图能看到完整航线（折线 + 当前航段高亮 + 已飞航段淡化）。
- [ ] 偏离航线超 120 m 有提示 —— 沿用 CDI 点数与指引十字配色，未另加。
- [ ] 距目的地约 400 m 出现准备降落提示 —— 沿用 D-054 `APPROACH`，机制已存在。
- [x] 全量回归 0 FAIL 0 SCRIPT ERROR，`user://` 零 DIFF（D-010）。