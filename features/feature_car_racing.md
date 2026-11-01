# Block Planet 赛道竞速玩法实现文档

> 项目：Block Planet
> 引擎：Godot 4.6.3 / GDScript（Mobile 渲染器）
> 文档性质：**已实现现状说明书**（不是开发任务书）
> 事实来源：**代码**。本文与代码冲突时以代码为准，并应回头修订本文。
> 相关决策：`docs/decisions.md` D-036（竞速玩法）；载具蓝图见 `features/feature_flight.md` 载具章节与 `scripts/vehicles/`。

---

## 0. 文档定位与改版说明

本文件初稿是一份 **AI 生成的开发任务书**。该功能**已完整实现并合入 main**
（Autoload `RaceSystem` 已接线，`data/racing/` 五份 JSON 在位，独立竞速场景
`scenes/racing/race_scene.tscn`）。任务书的地形参数表、AI 难度四档、记录字段
几乎被原样实现；但**赛道解锁方式、记录存档位置、检查点实现、回放格式**等
处与任务书不同。本文按代码现状重写为**现状说明书**，任务书中有价值且仍成立
的设计已并入对应章节。**不要按任务书原文施工**——它假设的 `shop_1000` 商店
解锁、把 best_lap 写进 tracks.json、Area3D 检查点均未按此实现。

现状一句话：**竞速 = 地图选择器「🏁 赛道竞速」→ 赛道选择器（选赛道/赛车/
机器人数量与难度）→ 独立竞速场景：3 秒倒计时 → 门平面检查点 + 圈数 + 排名 →
结算写 `user://race_records.json` + 回放 JSONL + 任务计数；6 条赛道、4 辆玩家
赛车、AI 四档难度，赛道几何由形状公式程序化生成（不铺体素）。**

---

## 1. 概述与入口

```text
探索模式 → 地图选择器「🏁 赛道竞速」（hud.gd:3146）→ 赛道选择器（模态）
  → 选赛道 / 赛车（已拥有）/ 机器人数量 0-5 / 难度
  → RaceSystem.select_race(...) 寄存选择 → 切到竞速场景（独立场景）
  → 3-2-1 倒计时 → 比赛 → 结算界面 → 写记录 / 回放 / 任务
```

- 竞速是**独立 3D 场景**（平整竞技场 + 程序化赛道几何），不在体素大世界里
  跑——世界是流式加载的，一条 1200 m 赛道要跨约 150 个区块，远超加载窗口
  （`track_layout.gd` 头注释）。
- 从赛道返回主场景时可选直接重开赛道选择器（`RaceSystem.open_selector_on_return`）。

---

## 2. 架构与数据流

```text
data/racing/（五份 JSON，只读）
├── tracks.json     6 条赛道（形状/圈数/地形分段/AI 推荐/解锁）
├── terrain.json    6 种地形（抓地/极速/刹车/滚阻/颜色）
├── vehicles.json   7 辆车（4 玩家 + 3 ai_only）
├── ai_racers.json  AI 四档难度 + 6 个名字 + AI 用车池
└── teaching.json   5 条教学（起跑/检查点/圈速/地形/山坡）

RaceSystem（Autoload，scripts/systems/race_system.gd）
  ├── 数据加载与查询（tracks / terrains / vehicles / difficulties / teaching）
  ├── pending：上一场选择（选择器写 → 竞速场景读）
  ├── 解锁判定 is_unlocked()：default / wins:N / record:N
  └── submit_result() → RaceRecords 纯逻辑 + Events 广播
        │
        ▼
竞速场景（scripts/racing/race_scene.gd，386 行，总装）
  ├── TrackLayout（track_layout.gd）   赛道几何 + 地形分段 + 检查点下标（纯逻辑）
  ├── TrackLoader（track_loader.gd）   把 Layout 画成 3D（地板/路面/起跑线/拱门）
  ├── RaceSession（race_session.gd）   比赛规则引擎（纯逻辑）
  ├── CarPhysics（car_physics.gd）     车辆物理（地形/燃料/侧滑）
  ├── AiRacer（ai_racer.gd）           机器人决策（纯逻辑）
  └── UI：race_hud / race_result_ui / race_teaching_ui / track_selector_ui
```

三个关键约定：

1. **纯逻辑层可无头探针**：TrackLayout / RaceSession / RaceRecords / AiRacer /
   CarPhysics 全部不依赖节点，`racing_probe` 82 条断言直接钉死（标记
   `RACING_TEST_OK`）。
2. **检查点用「门平面穿越」而非 Area3D**：每个检查点是一条垂直于赛道的线段，
   车从后往前穿过平面且在门的横向宽度内（半宽 + 8 m）才算过门——高速掠过
   不漏判、不受帧率影响，且判定完全在纯逻辑层。场景里的拱门只是同一份数据
   的可视化（TrackLoader 画），不是判定源。
3. **静态与动态分开**：赛道定义是只读静态数据；玩家记录全部落
   `user://race_records.json`（RaceRecords 头注释明确拒绝了任务书
   「把 best_lap 写进 tracks.json」的方案）。

---

## 3. 赛道（9 条，tracks.json）

| id | 名称 | 主题 | 难度 | 圈数 | 长度 | 形状 | 解锁 |
|---|---|---|---|---|---|---|---|
| desert_ring | 沙丘环线 | desert | 2 | 3 | 1200 m | polar | default |
| forest_trail | 林间小径 | forest | 3 | 3 | 1500 m | polar | default |
| city_circuit | 城市街道 | city | 2 | 4 | 1000 m | polar | default |
| wetland_cross | 沼泽穿越 | wetland | 4 | 2 | 1800 m | polar | wins:1 |
| mountain_road | 盘山公路 | mountain | 5 | 2 | 2200 m | polar | wins:3 |
| all_terrain | 全地形挑战 | mixed | 4 | 3 | 2500 m | polar | record:1 |
| canyon_hairpin | 峡谷发卡弯 | mountain | 5 | 2 | 1700 m | waypoints | wins:4 |
| harbor_chicane | 海港减速弯 | city | 4 | 3 | 1300 m | waypoints | wins:1 |
| dune_slalom | 沙丘绕桩 | desert | 3 | 3 | 1500 m | waypoints | wins:2 |

> 上表以 `data/racing/tracks.json` 为准。此前文档里的解锁条件（wins:2 / record:2 /
> wins:5）与代码不一致，已按代码校正。

### 3.1 两种形状定义（D-085）

1. **polar（极坐标正弦环，前 6 条）**：`r(θ) = R·(1 + amp·sin(lobes·θ+phase)
   + amp2·sin(lobes2·θ+phase2))`，先密集采样反解 R 使周长落在 `length_m`，
   再每 4 m 等距重采样成中心线。`seed` 供形状微扰与 AI 犯错的确定性随机源。
   **局限是数学性的**：`r(θ)` 是星形曲线，任何方向只有唯一半径，因此永远做不出
   发卡弯（180° 回头）或减速弯（S 形快速反打）——6 条极坐标赛道在「弯的性格」
   上必然同质，只是正弦起伏的疏密不同。
2. **waypoints（控制点折线，后 3 条）**：显式控制点 → **Chaikin 切角**（3 轮）
   → 加密折线，之后与 polar 共用同一条「等比缩放到 `length_m` → 4 m 等距重采样
   → 地形分段 → 检查点」路径。选 Chaikin 不选 Catmull-Rom：均匀 CR 在控制点
   间距不均时会过冲，发卡弯上能自己绕出内环，路面带随即自交翻面；Chaikin 每轮
   把各边按 1:3 切两刀，结果永远落在控制多边形的凸包内，对简单闭合多边形不会自交。
   控制点少于 3 个时 `_raw_waypoints()` 返回空，`build()` 自动回落 polar。

**路面带自交翻面的判据**：路面是沿中心线两侧各偏 `half_width` 缝成的带状网格，
中心线曲率半径 < `half_width` 时内侧边线会翻过去（画面打结、顶点色错乱，而探针
数不出「难看」）。所以 `TrackLayout.min_curve_radius()`（相邻三点外接圆半径）
是一个必须可断言的值，闸门：**物理闸 `> half_width × 1.2`，新赛道设计线
`≥ half_width × 2.5`**。极坐标赛道实测最小 20.4 m（作对照基准），三条新赛道
15.5 / 18.4 / 16.6 m——更小，这正是「极坐标做不出的弯」的量化证据。`harbor_chicane`
的 18.4 m 距基准只剩 2 m 余量，它的形状证据不是曲率而是**拓扑**：闭合矩形街上
「先往里挪 26 m 再挪回来」的 jog，在单向 `r(θ)` 上不可能存在。

- **地形分段**按圈程百分比逐点贴标签（`terrain_segments`），CarPhysics 按所在
  段查抓地力/极速/刹车。
- **检查点**：起跑线在 0 号点，之后大致每 300 m 一个，至少 3 个、至多 8 个。
- **`length_m` 必须是 `SPACING`(4 m) 的整数倍**：重采样点数是 `floor(total/4)`，
  不是整数倍时最后一段会明显偏长（例如 1505 m → 闭合边 5 m），圈长记账悄悄偏 1 m。
  探针钉住这条。
- **解锁**：`default` 恒开 / `wins:N` 赢 N 场 / `record:N` 破 N 次最快圈速；
  空串与未知格式一律视为已解锁（儿童向：宁可多给，不把赛道锁死）。
  `unlock_hint()` 生成中文说明（「赢 2 场后解锁」等）。任务书的
  `quest_wetland` / `shop_1000` / `quest_mixed` **未实现**。

### 3.2 AI 可跑性（新赛道设计的硬约束）

新赛道不只要几何合法，还要 **AI 开得完**——`ai_racer.gd` 是纯 P 朝向控制器，有固定相位
滞后，弯越密越跟不上。`tmp/ai_new_tracks.gd` 每赛道实跑 120 s 量「在草地上的时间占比」：

| 赛道 | AI 难度 | 出界占比 | 最深越界 |
|---|---|---|---|
| canyon_hairpin | expert | 5.2 % | 5.5 m |
| harbor_chicane | normal | 7.7 % | 2.8 m |
| dune_slalom | normal | 0.0 % | — |
| city_circuit（对照） | easy | 0.0 % | — |
| mountain_road（对照，既有欠账） | expert | 25.2 % | 6.4 m |

`harbor_chicane` 第一版是「三段连续 S 形减速弯」，AI **19.8 %** 时间在草地上。加宽
5.5→6.5 降到 13.2 %，难度 hard→normal 降到 10.3 %，最后把形状改成「圆角矩形街道 +
一处 jog」才到 7.7 %——**加宽和降难度只是在容忍 P 控制的滞后，换弯型才是消除它**。

⇒ 设计约束：**新赛道的弯要「疏而深」，不要「密而浅」**。AI 开不稳比弯不够花哨更伤
儿童体验。

---

## 4. 地形与车辆

### 4.1 地形（terrain.json，6 种——与任务书数值完全一致）

| id | 名称 | grip | speed_factor | brake_factor | rolling_resistance | 颜色 |
|---|---|---|---|---|---|---|
| asphalt | 铺装路面 | 1.0 | 1.1 | 1.0 | 0.02 | #4A4A4A |
| gravel | 沙石 | 0.7 | 0.85 | 0.7 | 0.08 | #B89B72 |
| wetland | 湿地 | 0.4 | 0.75 | 0.5 | 0.12 | #3B5E4A |
| hill | 山坡 | 0.8 | 0.7 | 0.8 | 0.10 | #6B8E4E |
| forest | 森林 | 0.75 | 0.9 | 0.8 | 0.10 | #2E5B2E |
| grass | 草地 | 0.8 | 0.95 | 0.9 | 0.06 | #5C8A3C |

### 4.2 地形如何作用（CarPhysics.step）

```text
极速  = spec.max_speed_mps × 地形 speed_factor（阻力系数按此反解，全油门自然收敛）
抓地  = 地形 grip × spec.grip_base → 侧滑回正速率（低抓地 = 推头/甩尾）
刹车  = spec.brake_mps2 × 地形 brake_factor（湿地刹车距离明显变长）
滚阻  = rolling_resistance × ROLL_K（持续减速项）
漂移  = 手刹 × (DECEL 少掉速 + YAW 甩得出去 + GRIP 滑得久)，见 §4.2.1
```

即任务书 §4.3「轮胎摩擦力 / 发动机功率 / 刹车力度」的量化落地。沙尘/水花粒子
已在 D-079 落地（`race_car.gd` 的 `set_terrain_fx`，`dust`/`wet` 首次有消费方）。

### 4.2.1 手刹漂移三常量（D-084）

改前手刹只减 `brake_mps2 × 0.6` 的纵向速度、把侧滑回正降到 0.2，**转向率一点没变**
——同样 2 s 满舵，转角与不拉手刹完全一致（小三轮 230°），速度却掉 20~32%。
即「同样的弯、更慢的车」，手刹是纯惩罚。

| 常量 | 值 | 作用 |
|---|---|---|
| `HANDBRAKE_DECEL` | 0.18 | 纵向减速占 `brake_mps2` 的比例（原 0.60，急刹感） |
| `HANDBRAKE_YAW` | 1.35 | 手刹时转向权限倍率（原不存在；**这条才让车头甩得出去**） |
| `HANDBRAKE_GRIP` | 0.20 | 手刹时侧滑回正速率倍率（原硬编码 0.2） |

实测（柏油、极速后满舵 2 s）：

| 车 | 转角 | 速度保留 | 最大侧滑 | 单位速度转角 °/(m/s) |
|---|---|---|---|---|
| 小三轮 | 230° → 310° | 87% | 3.8° → 34.4° | 8.85 → 13.73 |
| 赛道方程式 | 181° → 245° | 91% | 2.8° → 25.8° | 4.16 → 6.16 |

「单位速度转角」是有效转弯半径的倒数——它变大，漂移才第一次成为过急弯的正解。
湿地漂移侧滑 40.0° ≥ 柏油 28.3°（低抓地放大甩尾）。直线上拉手刹不产生侧滑
（增益只经转向生效，不是凭空给横向冲量）。

### 4.3 车辆（vehicles.json，7 辆）

| id | 名称 | 极速 m/s | 加速 | 刹车 | 抓地 | 转向 °/s | 油箱 L | 油耗 L/s | 解锁 |
|---|---|---|---|---|---|---|---|---|---|
| tricycle | 小三轮 | 24 | 5.5 | 9.0 | 1.0 | 115 | 11 | 0.030 | default |
| buggy | 越野沙滩车 | — | — | — | — | — | — | — | default |
| motorcycle | 越野摩托 | — | — | — | — | — | — | — | default |
| racer | 赛道方程式 | 40 | 9.5 | 11.0 | 1.05 | 88 | 11 | 0.038 | wins:1 |
| ai_tricycle_red / ai_car_blue / ai_car_green | 机器人专用 | — | — | — | — | — | — | 0 | ai_only |

- **燃料**：玩家车 `fuel_burn_lps > 0`，油尽则无法给油（HUD 显示油量）；
  AI 油耗为 0（永不没油）。任务书 HUD 的燃料条由此实现。
- **载具蓝图关系**：比赛用车是 `vehicles.json` 的预制赛车，**不是**玩家在
  装配台搭的蓝图（任务书 §10.1「使用已保存蓝图」未按此实现——竞速与拼装
  是两套车）。

---

## 5. 比赛规则（RaceSession，纯逻辑）

```text
状态：COUNTDOWN（3 s，车不动不计时）→ RUNNING → FINISHED
进度：每帧 update_progress(racer, off_road, dt) 用「门平面穿越」推进检查点
      （dt 是真实帧长，用于累计出界时间；不传则按 1/60 s，仅供老调用方兼容）
圈数：穿过 0 号门（起跑线/终点）记一圈 + 圈速；够 laps 辆即完赛
名次：完赛者比完赛时间；未完赛比 圈数 → 过门数 → 距下一门距离
      （_rank_before，results() 按名次输出成绩表）
```

- **防抄近道**：必须按顺序过门（`next_gate` 环绕递增），掉头/切弯会被
  `nearest_index_forward` 的窗口搜索与门平面判定排除。
- **clean 判定**（结算传入）：全程未用手刹（`used_handbrake`）且未冲出
  路面（横向偏移 > half_width 记 `off_road_time`）——「湿地无手刹完赛」
  任务即用此标志。
- 任务书 §7 排名规则（同圈比检查点与距离、未完赛按完成度）已实现。

---

## 6. 机器人（AiRacer，纯逻辑）

策略：**前视点追线**（lookahead 随速度 10→46 m 增长，每帧只在前方 24 个
采样点 ≈96 m 内找最近点，抗抄近道/掉头），按转向误差收油/点刹
（弯越急越收）。难度四档直接改变四项参数（与任务书 ai_racers.json 一致）：

| 档 | speed_factor | steering_accuracy | reaction_time | mistake_chance |
|---|---|---|---|---|
| easy 简单 | 0.70 | 0.6 | 0.5 | 0.15 |
| normal 普通 | 0.85 | 0.8 | 0.3 | 0.08 |
| hard 困难 | 0.95 | 0.9 | 0.15 | 0.03 |
| expert 专家 | 1.00 | 1.0 | 0.05 | 0.0 |

- 犯错 = 按概率进入一段「手抖 + 收油」窗口（持续 reaction_time 秒）；
  转向噪声量 = (1 − accuracy) × 0.25。
- AI 名字池 6 个（闪电兔/岩石龟/风之子/小星尘/铁皮狗/彩虹狐）；AI 用车池
  数据里是 `["tricycle","buggy","racer"]`（`ai_vehicles` 键——任务书写的
  `ai_vehicle_blueprints` 三台 ai_only 车是另一批，仅作视觉备选）。
- AI 也吃地形 speed_factor，不耗油、从不拉手刹。
- **配速归一到「场地极速」（D-082）**：目标速度的上界是 `min(自己车极速, 玩家车极速)`，
  不再是 AI 自己车的极速。改动前 AI 车池里的 `racer`（40 m/s）开 easy（0.7）仍有
  28 m/s，而玩家开小三轮只有 24 m/s——孩子必输。归一后 easy 对 racer 是 24×0.7 = 16.8。
- **只减速侧橡皮筋（D-082）**：`AiRacer.pace_bias_for(gap_m)`，`gap_m` 正 = AI 领先玩家。
  领先 30 m 内不干预；30→150 m 线性降到 **0.82**；150 m 以上保持 0.82；**落后恒 1.0**，
  绝不加速追赶（保证任何难度都不越过玩家车的极速）。`race_scene` 每帧用
  `_track_progress_m()`（`gates_passed × 段长 + 段内里程`，开赛为 0）算差距喂进去。

---

## 6.1 触屏操控（D-082）

Android 上没有键盘：`race_hud.gd` 在 `DisplayServer.is_touchscreen_available()` 为真时
额外建一层触屏驾驶层，与键盘路径**互斥**（`touch_input()["active"]` 决定 `race_scene`
走哪条）。键盘/手柄玩家看到的界面与旧版逐像素一致。

| 区域 | 内容 | 尺寸 |
|---|---|---|
| 左下 | 「◀」「▶」转向（按住语义 `button_down`/`button_up`） | 132×132，边距 24，间距 12 |
| 右下 | 「刹车」红底 | 132×132 |
| 右下偏上 | 「手刹」橙底 | 104×104 |
| 右上 | 「↻ 重开」「✕ 退出」 | 96×56 |

- **自动油门**：触屏层存在且没按刹车 → `throttle = 1.0`；按刹车 → `throttle = 0`、
  `brake = 1.0`。手机上孩子只按左右就能开车，这是儿童向卡丁车的通行做法。
- 退出是必需品（Android 没有 `race_exit` 键），否则孩子会被困在比赛里。
- 触屏态下面板自动让位：左下油表 `offset_bottom → −168`、右上圈速 `offset_top → 92`、
  右下按键说明改触屏文案并抬到手刹之上（实测 6 个按钮全部落在 1280×720 内、互不重叠）。
- 松手状态清理：`clear_touch_input()`，由 `race_scene._set_teach_hint()` 在教学/成绩单
  等会吃掉触摸事件的模态出现时调用（抬指事件被拦住会残留「刹车按着」）。

---

## 7. 记录 / 回放 / 教学 / 任务

### 7.1 记录（user://race_records.json，RaceRecords 纯逻辑）

每条赛道一个 entry，字段与任务书 §8.1 一致：
`best_lap_time / best_lap_at / best_lap_vehicle / best_race_time /
best_race_at / total_races / wins / best_rank / last_rank`。
破纪录判定在 `apply()`（返回 `broke_lap / broke_race / first_race`），
完赛即存盘；选择器 UI 可清空记录（`clear_records()`）。

### 7.2 回放（user://race_replay.jsonl，JSON Lines）

每行一条事件，字段与任务书 §8.4 相同（tick / action / track_id /
vehicle_id / position[3] / player），但格式是 **JSONL 而非 CSV**，只留最近
**600 条**。事件：`race_start / checkpoint / lap_complete / race_finish`。
定位是「幽灵车回放的原始素材」——回放本身**未实现**。

### 7.3 教学（teaching.json，5 条）

| id | trigger | 内容 |
|---|---|---|
| race_start | first_race_start | 倒计时与基本操作 |
| race_checkpoint | first_checkpoint | 检查点作用 |
| race_lap | first_lap | 圈速概念 |
| race_terrain | first_race_start | 地形影响 |
| race_hill | first_race_start | 山坡驾驶 |

`RaceSystem.teachings_for(trigger)` 按触发点取条目，race_scene 在
起跑/首个检查点/首圈时 enqueue（与任务书 §14「首次比赛触发教学」一致）。
「之后可重看」的入口在赛道选择器（任务书 §7 的 fishing 式 teaching.json
结构此处简化为 trigger 匹配）。

### 7.4 任务（quest_data.gd，5 条）

| 任务 | 计数键 |
|---|---|
| q_race_first 完成第一场比赛 | race_finished_any |
| q_race_win_desert 沙丘环线夺冠 | race_win_desert_ring |
| q_race_record 打破任一圈速纪录 | race_new_record |
| q_race_wetland_clean 湿地无手刹完赛 | race_clean_wetland_cross |
| q_race_tricycle_win 小三轮夺冠 | race_win_vehicle_tricycle |

计数由 ProgressManager 监听 `Events.race_finished` / `race_record_beaten`
累加（键名规则见 progress_manager.gd:220 注释）。任务书 §10.2 五条任务
全部落地（「湿地无手刹」从愿望句变成了 clean 标志）。

---

## 8. 验证（探针）

| 探针 | 断言数 | 覆盖 | 标记 |
|---|---|---|---|
| `tests/racing_probe.gd` | **154** | 赛道几何（周长/采样/地形分段/检查点/**最小曲率半径**/**中心线不自交**/waypoints 模式/坏数据回落）/ 门平面过门与圈数 / 名次排序 / 记录读写与破纪录 / AI 追线与犯错与**配速归一** / CarPhysics 地形与燃料 / **手刹漂移** / 选择器卡片数与赛道数一致 | `RACING_TEST_OK` |
| `tests/race_touch_probe.gd` | 38 | 触屏层（自动油门 / 刹车互斥 / 按住语义 / 两个动作信号 / 面板让位） | `RACE_TOUCH_TEST_OK` |
| `tests/track_decor_probe.gd` | **44** | 主题装饰（6 主题色盘 / 9 条赛道组数 2~10 且实例 >0 / 离中心线 ≥ `half_width+KERB_WIDTH+2.9` / 不投影 / 确定性 / 重复 build 不残留）+ 红白路肩 10 条（节点唯一 / 顶点数 8×size / 红白都存在 / 内外沿偏移 / 高于路面 / 亮度差 ≥0.05） | `TRACK_DECOR_TEST_OK` |

**D-085 的两条探针坑（写探针前必读）**：
1. `--headless` 下 `RendererDummy` **不保存 MultiMesh 实例缓冲**，
   `MultiMesh.get_instance_transform()` 恒返回单位矩阵——直接读它会打出「y 实测 0.00，
   最差横向 142.98 m」这种一眼假的数字却**全 PASS**。`TrackLoader` 因此额外记一份
   纯数据镜像 `decor_instances`，探针读镜像并用 `instance_count` 之和交叉校验。
2. 顶点色是**线性值**（材质 `albedo_color` 才由引擎做 sRGB→线性），设计色值必须先
   `srgb_to_linear()`，否则红块渲染成粉红；且顶点色按 1/255 量化，比对不能 `==`。

D-010 合规：存档 `user://race_records.json` 与 `race_replay.jsonl` 由探针
读写时走 user:// 备份/还原；回归基线：日常无头 **54 探针** / 验收全量 **66 探针**
（`tmp/run_regression.sh` / `full` 档）。

---

## 9. 差距与已知问题（以代码为准）

1. **幽灵车回放未实现**：回放日志已在写（§7.2），「播放上一场轨迹」是后续
   迭代项（任务书亦列入后续）。
2. **地形粒子未实现**：terrain.json 的 `dust` / `wet` 标志位无消费方，
   扬尘/水花视觉效果空缺。
3. **竞速车 ≠ 拼装蓝图**：任务书 §10.1 的「用自己拼的车比赛」未实现，
   当前是预制赛车（§4.3）。
4. **联机竞速未实现**（任务书后续项，单机定位不变）。
5. **赛道选择器的记录面板**：记录查看/清空在选择器内，无独立「竞速记录」
   主菜单页（任务书 §8.3 的可选形态）。
