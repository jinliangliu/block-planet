# Block Planet 钓鱼玩法实现文档

> 项目：Block Planet
> 引擎：Godot 4.6.3 / GDScript（Mobile 渲染器）
> 文档性质：**已实现现状说明书**（不是开发任务书）
> 事实来源：**代码**。本文与代码冲突时以代码为准，并应回头修订本文。
> 相关决策：`docs/decisions.md` D-042（出海钓点：距港距离决定鱼种）、D-044（球面 3D 小鱼标记）、D-063（1 格 = 1 m）；任务书原文的存档 `user://fishing_journal.json` 非原子写缺陷已修（见 §8）。

---

## 0. 文档定位与改版说明

本文件初稿是一份 **AI 生成的开发任务书**（四大洋子钓点 / 商店解锁钓具 / CSV 回放等）。
该功能**已完整实现并合入 main**（Autoload `FishingSystem` 已接线，`data/fishing/` 四份
JSON 在位），但实现与任务书在钓点模型、解锁方式、日志格式等多处分叉。本文按代码
现状重写为**现状说明书**；任务书中有价值且仍成立的设计取向已并入对应章节。
**不要按任务书原文施工**——它假设的基础设施（子钓点树、`shop_500` 商店解锁、
bestiary `catchable` 字段）并不存在。

现状一句话：**钓鱼 = 地图选择器四大洋 🎣 标记进入 → 选钓具（竿/轮/线/饵/坠）→
选饵 → 配坠 → 抛投蓄力 → 等咬钩 → 收线小游戏（张力/逃鱼/断线）→ 结算入册；
16 个钓点（4 岸钓 + 12 出海，D-042）、20 种鱼、12 件钓具、5 课教学；
钓获记录落 `user://fishing_journal.json`（原子写），任务计数走 `Progress`。**

---

## 1. 概述

在探索模式的地图选择器（地球页）上，四大洋各有一枚 **3D 小鱼标记**（D-044，
判据与图例 🎣、「去钓鱼」按钮同源，读 `FishingSystem` 钓点表）。点进去选
「去钓鱼」即进入钓鱼流程：

```text
地图选择器四大洋 🎣 → 「去钓鱼」→ 选钓点（岸钓 4 / 出海 12，D-042）
  → 选钓具（海竿 + 渔轮 + 鱼线）→ 选鱼饵 → 配铅坠 → 抛投蓄力
  → 等咬钩 → 收线小游戏 → 成功钓获 / 跑鱼 / 断线 → 写入日志 + 任务计数
  → 新鱼种首次解锁提示
```

- 岸钓点（`unlock=default`）：四大洋各 1 个，步行在地图页直接可去。
- 出海钓点（`unlock=boat`，D-042）：四大洋 × 近/中/远海共 12 个，**只在船上**
  按「距港距离」定位唯一可下竿钓点，其余在界面上置灰并标注「需航行 X m」。
  开船默认在离岛不远的海域（见 BoatSystem）。

---

## 2. 架构与数据流

```text
data/fishing/（四份 JSON，只读）
├── spots.json     钓点（16：4 岸钓 + 12 出海）
├── gear.json      钓具（12 件：竿 2 / 轮 2 / 线 2 / 饵 3 / 坠 3）
├── fish.json      鱼种（20）
└── teaching.json  教学（5 课）

FishingSystem（Autoload，scripts/systems/fishing_system.gd）
  ├── FishingGear（fishing_gear.gd）      钓具数据 + 纯计算（距离/水层/适配度）
  ├── FishingTeaching（fishing_teaching.gd）教学数据
  ├── 状态机：选饵 → 配坠 → 抛投 → 等咬钩 → 收线 → 结算
  └── user://fishing_journal.json（原子写）
        │
        ▼ 信号
UI（scripts/ui/，只读状态、不改状态机字段）
├── fishing_gear_ui.gd    钓点 + 钓具选择（岸钓 open_for_atlas / 出海 open_for_boat）
├── fishing_ui.gd         渔猎操作界面（抛投/等待/收线三阶段可视化）
├── fishing_teaching_ui.gd 教学弹窗
└── player/fishing_bobber.gd  3D 浮漂（咬钩抖动 + 鱼线牵引）
```

三个关键约定：

1. **不写 `class_name`**：Godot 不允许脚本类名与 autoload 单例同名
   （`Class "FishingSystem" hides an autoload singleton`），与 Progress /
   BestiaryData 一致。
2. **UI 与逻辑单向**：UI 只读 `session_info()` / `reel_state()` 等查询接口和
   信号，不反向写状态机字段——两者之间只有方法调用一条路。
3. **读档失败拒写盘**：`_load_journal()` 解析失败时 `journal_ok=false`，
   本次会话**不回写**，避免用默认模板覆盖真实存档（实测踩过：竞速探针运行时
   日志被清空，根因是非原子写，已修，见 §8）。

---

## 3. 钓点模型（16 个）

`atlas_region` 对应 RegionAtlas 区域号：**0 太平洋 / 1 大西洋 / 2 印度洋 /
3 北冰洋**；`region_id` 对应生物图鉴区域 id。`fish_pool` 里的鱼 id 必须在
fish.json 存在，否则加载期 `push_error`（反向检查，永不静默空池）。

| 钓点 | 区域 | 水层 | 解锁 | 鱼池 |
|---|---|---|---|---|
| pacific_coast 太平洋近岸 | 0 | shallow | default | 小丑鱼 / 太平洋鲑鱼 / 大白鲨 |
| atlantic_open 大西洋外海 | 1 | deep | default | 大西洋鳕鱼 / 大西洋鲭鱼 / 蓝鳍金枪鱼 |
| indian_reef 印度洋珊瑚礁 | 2 | shallow | default | 小丑鱼 / 狮子鱼 / 鲸鲨 |
| arctic_edge 北冰洋冰缘 | 3 | shallow | default | 北极鳕鱼 / 独角鲸 / 格陵兰鲨 |
| {大洋}_near 近海 ×4 | 0-3 | shallow | boat | 各 2 种（练手点） |
| {大洋}_mid 中海 ×4 | 0-3 | mid | boat | 各 2 种 |
| {大洋}_far 远海 ×4 | 0-3 | deep | boat | 各 1~2 种（大家伙） |

> 任务书初稿的「每洋细分子钓点（近岸浅水/珊瑚礁/深海）+ `need_deep_rod` 解锁」
> **未按此实现**：岸钓只有 4 个一级钓点，细分改由「抛投落点水层」承担（§5），
> 深海鱼种由出海距离解锁（D-042）。

---

## 4. 鱼种（20 种）

字段：`id`（与图鉴条目同 id）、`region_id`、`spot_ids`、`habitat`、`depth`、
`rarity`、`difficulty`(1-9)、`tags`、`preferred_bait`、`fight_power`(1-10)、
`weight_kg`（**[min, max] 区间**，钓获时随机滚动）、`name_zh/en`、`scientific`、
`fact_zh`。

| 稀有度 | 抽取权重 | 难度区间 | 实例 |
|---|---|---|---|
| common | 1.0 | 1-2 | 小丑鱼、北极鳕鱼、大西洋鲱鱼 |
| uncommon | 0.6 | 2-3 | 太平洋鲭鱼、狮子鱼、北极鳐 |
| rare | 0.35 | 5-6 | 蓝鳍金枪鱼、太平洋枪鱼、巨石斑鱼 |
| epic | 0.15 | 6-7 | 大白鲨、鲸鲨、独角鲸 |
| legendary | 0.07 | 9 | 格陵兰鲨 |

**稀有度只压抽取概率，不压咬钩门槛**——否则稀有鱼永远不上钩。咬不咬钩看
「饵 × 坠」匹配度（§5）。

分布：四大洋各 5 种（岸钓 3 + 出海 2）。任务书 MVP 写的「共 12 种」已超额
完成；任务书 `max_weight_kg: 180` 式的定值体重也未按此实现（改为区间滚动，
记录里保存历史最大值）。

---

## 5. 钓具与数值规则

### 5.1 钓具（gear.json，12 件）

| 类 | 默认拥有 | 任务解锁（`quest:<id>`） |
|---|---|---|
| 海竿 ×2 | basic_sea_rod（max_line 3） | deep_sea_rod（max_line 4，`q_fish_deep`） |
| 渔轮 ×2 | basic_reel（卸力 2 / 速度 2） | heavy_reel（卸力 5 / 速度 3，`q_fish_five`） |
| 鱼线 ×2 | nylon_line（拉力 2 / 可见度高） | fluorocarbon_line（拉力 3 / 可见度低，`q_fish_first`） |
| 鱼饵 ×3 | live_shrimp、metal_lure | soft_lure（`q_fish_deep`） |
| 铅坠 ×3 | sinker_10g / 30g / 60g（抛投档 1/3/5） | — |

- **装配校验**（`FishingGear.validate`）：竿的 `max_line` 必须 ≥ 线的
  `strength`，否则 UI 拒绝开钓（「竿线不配」）——宁可在开钓前挡住，也不让玩家
  在收线时被隐性惩罚打懵。任务书的 `shop_500` 等商店解锁**未实现**，解锁统一走
  任务奖励（`quest:` 前缀，领奖即发）。
- **卸力初始值** = 该渔轮 `drag_max` × 0.5，收线中可调（0 ~ drag_max）。

### 5.2 抛投与水层

```text
落点距离（m）= 4 + 铅坠抛投档 × 5 × 力度(0~1)     # 10 g 保底 4 m，60 g 满力 29 m
水层：< 10 m 浅水（shallow）/ 10~20 m 中层（mid）/ > 20 m 深水（deep）
```

水层决定这一竿能碰到哪条鱼（`get_fish_pool` 按 depth 过滤）。任务书
「近岸→浅水鱼 / 中距→珊瑚礁鱼 / 远投→深海鱼」的三段式**成立**，只是珊瑚礁
鱼不在独立中距层，而是随各钓点鱼池分布。

### 5.3 鱼饵适配与铅坠惩罚

```text
bait_match：偏好饵 1.0 / 目标类群(tags∩target)对上 0.6 / 不对付 0.25
sinker_factor：重坠(档≥5)抛非深水 ×0.5（掠过去）/ 轻坠(档≤1)抛深水 ×0.35（够不到）
综合权重 = 稀有度权重 × bait_match × sinker_factor     # 只决定多条候选里挑哪条
咬钩门槛：best_match < 0.3 → 这一竿直接判「没鱼咬」，不进等待
```

等待时长 = 2.5 s + 0.25 s × 该水层最难鱼的 difficulty；超过 2 倍时长仍无咬钩
才提示「这里没鱼上钩」。

### 5.4 收线小游戏

鱼在移动条 0~1 游动（安全区 = 0.5 ± 0.18），**按住收线 / 松手放线**：

```text
张力：鱼的拉力(fight×0.10×挣扎波动) + 卸力(×0.12) − 自然泄力(0.72)，×0.35 累积
      线拉力 < 鱼挣扎力 → 加速 ×1.25；鱼在安全区外还硬收 → 再 ×1.5
      张力 ≥ 1 → 断线（line_broke）
逃逸：挣扎(×0.028) − 卸力(×0.10) 持续累积，≥ 1 → 跑鱼（fish_escaped）
进度：+ 渔轮 speed × 0.12 × (1 − 0.4×张力) / 松手回退 fight × 0.006
进度满 → 结算（try_catch）
```

即任务书「卸力太紧会断线、太松会跑鱼」的量化版；大鱼需要更强的线 + 更大
卸力 + 看着鱼的位置收放。

**可钓性下限（D-083）**：三个常量（`SLIP_RATE` / `TENSION_RELIEF` /
`ESCAPE_FIGHT`）在本轮整体放宽，目标是「同一套操作下结果从不可能变成可能」。
修正前的实测量化：入门鼓轮 `drag_max = 2`，逃逸净速度 = `fight×0.04 − 0.20`，
fight 7/8/9/10 分别是 0.08/0.12/0.16/0.20 每秒 ⇒ 12.5/8.3/6.3/5 s 必跑；
而同等条件下收满盘要 13~20 s，**数学上不可能钓上来**。修正后 fight 9/10 的
逃逸净速度 0.052/0.08（19/12.5 s），落在「稍微慢一拍就走」的可操作区间。
`SAFE_HALF_WIDTH` 刻意未动——它是玩家的操作难度刻度，放宽等于降低技术上限。

**抛投预告（D-083）**：`cast_preview(power)` 在蓄力阶段就报出「这一层最猛：
{鱼名} · 拉力 {n}」，线强度不足时追加警告，空层如实报空。纯函数版
`_preview_of(distance, pool_by_id)` 供探针直调，不必开一场 session。

---

## 6. 状态机与接口

```text
IDLE →(start_fishing) SELECT_BAIT →(select_bait) SELECT_SINKER →(select_sinker)
CASTING →(cast_power) WAITING →(update_wait) HOOKED →(hook_fish) REELING
→(update_reel 满进度/断线/跑鱼) RESULT →(end_session) IDLE
```

信号：`fish_caught(fish_id, spot_id, gear)` / `new_species_unlocked(fish_id)` /
`fishing_failed(reason)`（`spot_missing` / 装备问题 / `no_bite` / `line_broke` /
`fish_escaped`）/ `fishing_state_changed(state)` / `journal_changed`。

`SELECT_GEAR` 枚举在位但流程不经它（钓具在选择界面选好，`start_fishing`
一次性带入）；任务书 `start_fishing() -> void` 实为 `-> bool`（校验失败发
`fishing_failed` 并返回 false）。探针/UI 常用接口：`weighted_pool()`（适配度
预览 + 抽取）、`best_match()`、`reel_state()`（收线全部可视状态，UI 每帧读
这一份）、`session_info()`、`set_drag()` / `add_drag()`。

---

## 7. 日志 / 图鉴 / 教学 / 任务

### 7.1 钓鱼日志（user://fishing_journal.json）

```text
{ version, records, gear(已拥有钓具 id), lessons_seen, replay, stats }
records[fish_id] = {
  first_caught_at / first_caught_spot / first_caught_gear(五件套) /
  last_caught_at / catch_count / max_weight_kg(历史最大) / released }
replay[] = { tick(ms), action, spot, fish_id, player:"小方块" }   # 最近 300 条
action ∈ cast / catch / release / break / escape
stats: casts / catches / escapes / releases
```

任务书的 CSV 回放（`tick, action, position, fish_id, player`，含坐标列）
**未按此实现**：改为 JSON 对象数组、无 position 列、上限 300 条。
放生只加 `released` 计数与任务计数，**不删图鉴记录**（钓到过就是钓到过）。

### 7.2 与生物图鉴的关系（任务书 §9 未落地）

fish.json 的 id 与图鉴条目 id 一致，但 **bestiary 数据侧没有 `catchable`
字段、图鉴 UI 也没有钓鱼图标**——「新鱼种解锁卡片」与钓获时间/钓点/钓具记录
都存在**钓鱼日志**里（FishingUI 消费），未接入 BestiaryData。fish.json 注释里
「图鉴侧标 catchable:true」的表述与 data/bestiary 实际内容不符，以代码为准。

### 7.3 教学（teaching.json，5 课）

`lesson_bait` / `lesson_sinker` / `lesson_drag` / `lesson_cast` / `lesson_reel`，
各自 `trigger`（first_time_*）首次触发；看过的课记入 `lessons_seen`，钓具界面
提供「重看教学」（`reset_lessons()` 清空已看记录）。任务书 §7 的五课文案
与实现**完全一致**。

### 7.4 任务（quest_data.gd）

| 任务 | 目标 | 奖励钩子 |
|---|---|---|
| q_fish_first | fish_caught ×1 | 解锁碳氟线 |
| q_fish_five | fish_caught ×5 | 解锁重型鼓轮 |
| q_fish_deep | fish_deep ×1 | 解锁深海船竿 + 软虫 |
| q_fish_oceans | fished_region_* ×4（四大洋各钓 1 次） | — |
| q_fish_lure | fish_lure_predator ×1（假饵钓掠食性） | — |
| q_fish_release | fish_released ×3（放生 3 条） | — |

另有成就 `a_hunt_fish`。任务书 §11.1 的五条任务全部落地，「钓到 1 条稀有鱼」
一项以 `fish_rare` 计数形式存在于 Progress 通知键（未单列任务）。

---

## 8. 持久化与踩过的坑

- **原子写**：`_save_journal()` 先写 `fishing_journal.json.tmp` 再 rename 覆盖。
  背景：`FileAccess.WRITE` 会先把原文件截断为 0 字节，若此刻进程被信号打断
  （本工程 headless 退出期偶发段错误），存档即被清空——改为临时文件 + 改名，
  任何时刻盘上都有一份完整存档（decisions.md 竞速章节记载了这次实测数据丢失）。
- **读档失败拒写**：解析失败时 `journal_ok=false`，本次会话不回写（§2.3）。
- **退出落盘**：`_exit_tree()` 时保存一次；每次钓获/放生/领奖即时保存。

---

## 9. 界面入口

| 入口 | 路径 |
|---|---|
| 地图选择器 | 四大洋球面 3D 小鱼标记（D-044）/ 图例 🎣 / 介绍页「去钓鱼」按钮，三者判据同源（FishingSystem 钓点表）→ `hud.open_fishing_gear(atlas_region)` |
| 出海 | 船上「去钓鱼」→ `hud.open_fishing_gear_boat(atlas_region, 距港距离)`：按距离定位唯一可下竿点，其余置灰标注「需航行 X m」 |
| 教学重看 | 钓具选择界面「重看教学」 |

渔猎界面（FishingUI）四阶段：选饵（显示目标鱼与适配度）→ 配坠（预告抛投
距离/可达水层）→ 抛投（力量条蓄力）→ 收线（鱼位置/安全区/张力/进度 +
卸力调节）。3D 浮漂（FishingBobber）随钓具抛出，咬钩时抖动并牵鱼线。

---

## 10. 验证（探针）

| 探针 | 覆盖 |
|---|---|
| `tests/fishing_probe.gd` | **102 断言**：四份数据加载自检（16 钓点 / 20 鱼 / 岸边钓点过滤 / 默认钓具）、纯计算（抛投距离公式与水层边界、饵适配度、铅坠惩罚、装配校验、咬钩门槛）、等咬钩超时（`NO_BITE_FACTOR` 单帧大步长分支）、完整钓获（单鱼种池确定性：等咬钩 → 收线 → 结算，验重量区间、日志 records/replay/stats、Progress 计数折算）、收线三败局（饵不对没鱼 / 卸力最大断线 / 卸力全松跑鱼）、放生与教学、状态机边界（坏钓点 / 缺渔轮 / 非等待态 / 非收线态）、**K 段可钓性（D-083）**：4 个岸钓点最猛鱼 fight ≤ 8 / 入门套装能上 fight 8、上不了 fight 9（正反一对）/ `cast_preview` 报鱼名与 fight 一致 / 空层如实报空 / `line_short` 与线强度严格一致 |
| `tests/boat_probe.gd` | 出海钓点鱼池非空、距港距离分带（D-042 接线） |
| `tests/life_probe.gd` / `globe_marker_probe.gd` | 球面小鱼标记（D-044）存在性与计数 |

> D-010 合规：`fishing_probe` 开局 `SaveGuard.snapshot()`（progress/settings/
> 竞速三件套 + Progress 内存态），钓鱼日志单独快照原文本；收尾还原文本 +
> 把 `journal_ok` 置否（`_save_journal` 的拒写闸——否则退出期
> `FishingSystem._exit_tree` 会把探针改乱的日志再写一遍盘），`_exit_tree`
> 安全网 + 120 s 看门狗兜底；断言全部走「基线差分」，真实存档里已有什么
> 都不影响结论。
> 回归基线：日常无头 **54 探针** / 验收全量 **66 探针**
> （`tmp/run_regression.sh` / `tmp/run_regression.sh full`）。

---

## 11. 差距与已知问题（以代码为准）

1. ~~独立钓鱼探针缺失~~ —— **已修复**（2026-10-23）：新增
   `tests/fishing_probe.gd`（87 断言），钉死抛投距离公式、水层分界、
   `BITE_MIN_MATCH` 门槛、等咬钩超时、收线三败局（断线 / 跑鱼 / 没鱼）、
   完整钓获链路与日志 round-trip（records / replay / stats）+ Progress
   计数折算；已登记进 `tmp/run_regression.sh` 日常档（42 → 43 探针）。
   断线用例借任务锁装备 `heavy_reel`（drag_max=5 时逃逸速率归零，保证
   断线先于跑鱼的确定性）——发放走 `grant_gear()` 公有接口，不验解锁流。
2. **图鉴集成未落地**：任务书 §9 的 `catchable` 字段 / 图鉴钓鱼图标 / 解锁
   卡片入图鉴均未实现，钓获记录只在钓鱼日志（§7.2）。
3. **`wind_enabled` 式的统一设置面板不覆盖钓鱼**：钓鱼无面板化设置项
   （教学重看入口在钓具界面内）。
4. **UI 细节以试玩为准**：力量条手感、安全区宽度（0.18）、张力可视化等
   数值虽被代码钉死，但未经过系统可玩性评估。
