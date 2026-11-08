# Block Planet 航海长期目标实现文档

> 项目：Block Planet
> 引擎：Godot 4.6.3 / GDScript（Mobile 渲染器）
> 文档性质：**已实现现状说明书**（不是开发任务书）
> 事实来源：**代码**。本文与代码冲突时以代码为准，并应回头修订本文。
> 相关决策：`docs/decisions.md` D-089（出海里程 / 里程碑徽章 / 我的航海记录）、D-010（存档原子写与回归零 DIFF）、D-086（按槽存档八份之一）、D-087（无 `class_name` 的 preload UI 范式）、D-077（同批三条收口）、D-063（1 格 = 1 m）。

---

## 0. 文档定位与改版说明

本文记录 D-089「航海长期目标」的**实现现状**，不是任务书。它与钓鱼 / 竞速
两个玩法的差别在于：不引入新场景、不引入新存档文件、不引入新的小游戏，
只在既有开船循环里加一层「累计里程 → 徽章 → 回看面板」的长期回报。设计
取向上刻意收敛——6-12 岁儿童向、单机离线、失败温和，**无 QTE、无联网、
无付费压力、无失败 / 惩罚**。

现状一句话：**开船（`piloted`）时每 0.1 s 采一次船体 XZ 位移，累加进
`user://boats.json` 的 `sail.total_m`；累计达 100 / 500 / 1000 m 可点亮三档
里程碑徽章；触屏步行控制层「⛵ 航海记录」按钮打开可回看的专属面板
（⛵ 我的航海记录），展示累计里程 / 最远离港距离 / 三档海面到访 / 徽章。**

定名「我的航海记录」而非「航海日志」：J 键 Journal 已占用「我的冒险记录」
语义（`decisions.md:158`），避免混淆。

---

## 1. 玩法定位与入口

| 维度 | 现状 |
|---|---|
| 受众 | 6-12 岁儿童向；文案「每划一小段都会记下来，慢慢来，海很大」「还差 N m，慢慢来」 |
| 形态 | 单机离线；无需账号、无排行榜、无云端同步 |
| 失败 | 无失败态、无惩罚、无 QTE、无倒计时；里程只增不减，停船不倒扣 |
| 付费 | 无内购、无广告、无解锁墙；徽章是纯荣誉标记，不改数值、不发道具 |
| 长期目标 | 累计出海里程 → 三档里程碑徽章（100 / 500 / 1000 m）→ 可回看专属面板 |
| 入口 | 触屏步行控制层 `_touch_walk` 右下角「⛵ 航海记录」按钮（`hud.gd:3401-3414`，`_anchor_bottom_right`）；桌面态 `_touch_walk == null`，**不建按钮、不新增键盘快捷键**（D-089 裁决，桌面入口另开票） |

徽章不是自动发放：`total_m` 达标只是把「点亮徽章」按钮变可点，玩家点一下
`claim_badge()` 才落标记（一次性事件，立即写盘）。未达标显示「还差 N m，
慢慢来」，已点亮显示「已点亮 ✓」。

---

## 2. 架构与数据流

```text
data/boating/boats.json            静态船型表，只读（BoatSystem.DATA_PATH）

BoatSystem（Autoload，scripts/systems/boat_system.gd）
  ├── DATA_PATH    = "res://data/boating/boats.json"   静态表（:24）
  ├── JOURNAL_PATH = "user://boats.json"               运行时日志（:27）
  │                 （有槽时 = Profile.slot_file("boats.json")，:265）
  └── journal = { version: 2, owned, current, fuel, sail {...} }

scripts/vehicles/boat.gd
  └── _emit_readings(delta) 每 READINGS_INTERVAL = 0.1 s
        → _sample_sail()  → BoatSystem.record_sail(step_m, dist, band)
        → readings_changed.emit(snapshot())（死信号，无订阅者）

scripts/ui/sailing_journal_ui.gd   extends Control，无 class_name
  └── HUD preload + new() → open()/refresh()
        → BoatSystem.sail_state() / badge_of() / claim_badge()
```

```text
每 0.1 s 采样 XZ 位移 → record_sail() 只改 journal["sail"] 内存态 + 标脏
  → _process() 防抖（至多每 1.5 s 一次）→ _save_journal() .tmp + rename 原子写
面板 open() → 每次现取 sail_state()（拷贝）/ badge_of()（标量）渲染
点亮徽章 → claim_badge() 幂等闸门 → 立即写盘（不等防抖窗口）
```

采样与展示完全解耦：`boat.gd` 不认识 UI，UI 不认识采样节拍；两者只通过
`BoatSystem` 的 `sail` 子字典通信。

---

## 3. 数据层：扩展既有 boats.json（version 1 → 2）

本次**不新增第 9 份按槽文件**。D-086 已定八份 `user://` 存档，D-089 只是给
`user://boats.json` 这一个文件加一个 `sail` 子字典并把 `version` 升到 2：

```text
{
  "version": 2,
  "owned": [...], "current": "", "fuel": {},
  "sail": {
    "total_m": 0.0,
    "farthest_m": 0.0,
    "bands": {"near": 0, "mid": 0, "far": 0},
    "badges": {}
  }
}
```

| 字段 | 类型 | 语义 |
|---|---|---|
| `total_m` | float | 累计出海里程（m），只增不减；相邻两拍 XZ 位移长度之和 |
| `farthest_m` | float | 历史最远离港距离（m），只在有效采样（`dist >= 0`）更新 |
| `bands` | Dictionary | 三档海面「有位移的采样拍数」（见 §6，**不是到访次数**） |
| `badges` | Dictionary | 已点亮徽章标记 `{key: 1}`，由 `claim_badge()` 写入 |

**旧档兼容（无需迁移脚本）**：`BoatSystem._load_journal()`（:283）读到
`version 1` / 缺 `sail` 的旧档时，内存里由 `_parse_sail()`（:330）逐字段兜底
——整块缺 `sail` 用 `_default_sail()`，坏子键由 `_num_or_zero()` /
`_int_or_zero()` 单独夹回（只认结构、不信任类型），随后 `journal_ok = true`。
磁盘上的旧档**不被改写**，「读到旧档」不等于「玩家改过存档」（§8）。

| 读档情形 | 行为 |
|---|---|
| 缺 `sail` 键 / 类型错 | 内存宽容升级为 v2，磁盘逐字节不变 |
| JSON 解析失败 | `push_error` + return，`journal_ok = false`（保护原档，本次不回写） |
| 文件不存在 | `_load_journal()` 只置 `journal_ok = true` 后 return，**不新建文件** |

**同名不同物，务必分清**（本次最易踩的坑）：

| 路径 | 常量 | 内容 | 本次 |
|---|---|---|---|
| `data/boating/boats.json` | `BoatSystem.DATA_PATH`（:24） | 静态船型表（raft / 各船 `max_speed_mps` 等），`res://` 只读 | **一字未改** |
| `user://boats.json` | `BoatSystem.JOURNAL_PATH`（:27） | 运行时拥有船只 / 油料 / `sail` 日志，按槽 | 增 `sail` 子字典、version → 2 |

`load_data()` 读的是前者，`_load_journal()` 读的是后者；两者**同名不同物**。
另注意别误引 `FishingSystem` 的同名 `_load_journal()`（:270 注释）——数据源
与字典形状都不同。

换槽时 `JOURNAL_PATH = Profile.slot_file("boats.json")`（:265）并整体替换
`journal` 对象，故 `sail_state()`（:376）返回**拷贝**（`bands` / `badges`
子字典也是新建），绝不返回 `journal["sail"]` 内部引用——D-086 §2 的整体替换
陷阱：换槽后缓存的旧引用会静默指向旧槽对象。

---

## 4. 里程口径：相邻 XZ 位移之和（唯一采样落点）

**累计里程 = 相邻两次采样的船体 XZ 位移长度之和**，绝不是「离港距离累加」。
反例（探针 B 段钉死）：停在离港 200 m 不动，若每拍加一次离港距离，30 拍
会得 30 × 200 = **6000 m**；正确实现 `Δtotal_m ≈ 0`。同理，绕一圈回到
出发点累计的是路径长度（8 m），不是 0。

**唯一采样落点** `scripts/vehicles/boat.gd:_sample_sail()`（:236），由
`_emit_readings()` 每 `READINGS_INTERVAL = 0.1 s` 触发一次（:227-231）。

- **绝不放进 `snapshot()`**：实测 3 个调用方 `boat.gd:232`（`readings_changed.emit(snapshot())`）、
  `boat_hud.gd:48`、`hud.gd:3301`；其中 `BoatHUD._draw()` 每渲染帧调用，把采样塞进去会让里程
  随帧率翻倍。`snapshot()` 保持纯读（只组一份 `{boat_id, pos, physics,
  wave_m, harbor_distance_m, band, at_harbor}` 字典）。
- **`readings_changed` 全仓零 `.connect`，是死信号**：不挂它做采样，采样
  与广播并列发生在 `_emit_readings()` 里。

`_sample_sail()` 九条硬性约束（代码注释 ①—⑨）：

| # | 约束 | 原因 |
|---|---|---|
| ① | `piloted` 硬闸，无人船不记里程 | `_emit_readings()` 不判 `use_player_input`，港湾里 ≥2 艘景观船仍每 0.1 s 广播；`WIND_PUSH × WIND_MAX_MPS` 还会让停泊船缓慢漂流 |
| ② | 用节点 `global_position`，不用 `physics.pos` | `physics.pos` 是纯逻辑积分；搁浅时 `move_and_slide` 挡住节点而 `pos` 仍前进 ⇒ 虚增 |
| ③ | 取 XZ 平面差 | 波浪 bob 让 Y 摆 ±0.2 m，用 3D `distance_to` 会给停泊船凭空造 0.5~1 m/s 垂直里程 |
| ④ | 首次采样（含登船）只播种 `_sail_prev`，不累加 | 否则登船瞬间会把出生点到 `_sail_prev` 初值（原点）的巨量距离记进去 |
| ⑤ | 传送护栏 `max_step = maxf(physics.max_speed() * READINGS_INTERVAL * 4.0, 5.0)` | `step > max_step` 时只更新 prev，不累加、`farthest_m` 也不更新；≥4096 m 浮动原点搬迁另见 ⑦ |
| ⑥ | `step < 0.05` 记 `step_m = 0` 但仍上报 | 属「通过护栏的有效采样」，让 `farthest_m` 记录到过的最远处；`record_sail()` 只在 `step_m > 0` 时累加 `bands` |
| ⑦ | `rebase_anchors_after_shift(delta)` 同步 `_sail_prev += Vector2(delta.x, delta.z)` | 浮动原点搬迁后 prev 仍指向旧坐标系，不修会造出一次巨量假位移 |
| ⑧ | `farthest_m` 只在有效采样更新 | `record_sail()` 内按 `harbor_distance_m < 0`（无港口）判负距离，不更新 |
| ⑨ | 无港口时 `band` 取 `near`、`dist = -1` | `distance_to_harbor()` 在 `harbor_pos == Vector3.ZERO` 时返回 -1 |

`record_sail()`（:404）只做 `total_m += maxf(0.0, step_m)`，`farthest_m =
maxf(..., harbor_distance_m)`，`bands[band_key] += 1`（仅 `step_m > 0`），
然后标脏；落盘不在这里。

---

## 5. 常量与理由

| 常量 | 值 | 理由 |
|---|---|---|
| `READINGS_INTERVAL` | `0.1` s | 采样节拍；与航海 HUD 读数节流同源 |
| `SAIL_MIN_STEP_M` | `0.05` | 小于 0.05 m 的抖动不累加里程 |
| `SAIL_MIN_SPEED_MPS` | `0.5` | 最慢木筏 `max_speed_mps 5.0` 的 10%，速度语义下限 |

**如实标注（勿当成两道独立判据）**：
`SAIL_MIN_SPEED_MPS * READINGS_INTERVAL = 0.5 × 0.1 = 0.05`，与
`SAIL_MIN_STEP_M` **恒等**，因此 `_sample_sail()` 里的
`min_step = maxf(SAIL_MIN_STEP_M, SAIL_MIN_SPEED_MPS * READINGS_INTERVAL)`
恒返回 0.05。`SAIL_MIN_SPEED_MPS` 当前只是**速度语义锚点**（把 0.05 m
翻译成「0.5 m/s × 0.1 s」），不构成独立速度判据；`boat.gd:40-48` 注释已
写明这一点。

**刻意不引入 `physics.speed()` 判据**：探针手动写 `global_position` 打节拍，
物理未 `step()`，`speed()` 恒 0，会把所有有效位移判掉；且 `physics.pos`
与节点位置在搁浅时本就不同步（§4 ②）。位移门槛只看节点 XZ 差。

---

## 6. `bands` 两层语义（如实写清，别混）

| 层 | 语义 | 值域 | 落点 |
|---|---|---|---|
| 数据层 `sail.bands` | **有位移的采样拍数** | `step_m > 0.0` 才 `+1`；长航程可达几千 | `BoatSystem.record_sail()`（:412-417） |
| UI 层 | **布尔式到访**：「已去过 ✓ / 还没去过」 | `int(bands.get(key, 0)) > 0` | `sailing_journal_ui.gd:229` |

数据层**不是到访次数**，也不做独立收集册。停泊时 `boat.gd` 仍以
`step_m = 0` 每 0.1 s 上报一次以刷新 `farthest_m`，若照常 `+1`，一次长航程
会把 `bands` 刷成「0.1 s 采样次数」（几千拍）。`bands` 的三档由
`BoatSystem.band_of(dist)`（:515）按距港距离切：`<= 100 m` 为 `near`、
`<= 250 m` 为 `mid`、其余 `far`（探针 A2 / A3 钉 100 / 250 边界）。

UI 侧刻意把它压成布尔，避免儿童把「几千拍」误读成「去过几千次」。两层
各管一处常量：数据侧 `SAIL_BANDS`，UI 侧 `BAND_KEYS` / `BAND_TITLES`
（近海 / 中海 / 远海）。

---

## 7. 里程碑徽章

| key | 目标里程 | UI 标题 |
|---|---|---|
| `sail_100` | 100 m | 初次远航 |
| `sail_500` | 500 m | 近海熟客 |
| `sail_1000` | 1000 m | 远洋探险家 |

`SAIL_BADGES` / `SAIL_BADGE_TARGETS`（`boat_system.gd:71-73`）与 UI 侧
`BADGE_KEYS` / `BADGE_TITLES` / `BADGE_TARGETS` 各管一处展示，数值对齐。

`claim_badge(key)`（:430）是**幂等闸门**（对齐 `FishingSystem.bundle_claimed()`）：
非法 key / 已领过 / `total_m < target` 一律 `false`；通过后写
`badges[key] = 1` 并**立即 `_save_journal()`**（不等 1.5 s 防抖窗口，不丢
关键进度），再 `journal_changed.emit()`。`badge_of(key)`（:422）返回标量。
面板顶部「徽章 N / 3」由 `badge_of()` 现场数，不缓存。

---

## 8. 持久化与 D-010（本批踩过的坑）

| 机制 | 现状 |
|---|---|
| 防抖 | `SAVE_INTERVAL_MS := 1500`（同 `Progress.SAVE_INTERVAL_MS`）：`record_sail()` 每 0.1 s 一拍只改内存 + `_dirty = true`，`_process()`（:104）合并到至多每 1.5 s 一次落盘 |
| 原子写 | `_save_journal()`（:356）先写 `JOURNAL_PATH + ".tmp"` 再 `DirAccess.rename_absolute`；`FileAccess.WRITE` 会先截断原文件，进程被信号打断就丢档 |
| 关键事件立即写 | `claim_badge()` 绕过防抖立即写 |
| 拒写闸 | `journal_ok = false`（损坏档保护 / 探针收尾）时 `_save_journal()` 直接 return，`_process()` 也跳过 |
| 退出补写 | `_exit_tree()`（:91）**仅 `_dirty` 时** `_save_journal()`——本批关键修复 |

### 8.1 D-010 新形态：v1 旧档被「退出期无条件覆写」

本批回归实测发现一种新的回归判定假阳性形态，与 D-088 §2 的四步不同
（首次实测 v1 旧档形如 `{"current":"raft","fuel":{},"owned":["raft"],"version":1}`）：

```text
v1 旧档 → _load_journal() 在内存里宽容升级为 v2（磁盘未动）
        → 探针 SaveGuard.restore() 逐字节还原文件
        → 引擎关停期 Autoload 的 _exit_tree() 又「无条件」_save_journal()
          把内存态 v2 覆写回磁盘
        → 回归 diff -r 报 DIFF
```

> 主理人口径称「假 DIFF」：字节确实被从 v1 覆写成 v2，DIFF 是**真实字节差异**，
> 只是根因是退出期探针污染、非玩家改档，属回归判定假阳性；ADR D-089 §5
> 直接写「回归 `diff -r` 报 DIFF」。

根因是「读到旧档」被误当成「玩家改过存档」。**生产侧 / 助手侧修复两处**
（与 ADR D-089 §5 的 ①② 一一对应），**另加探针侧三层闭合**（ADR 单列，
属探针善后范式，不与前两处并列）：

1. **生产侧**：`BoatSystem._exit_tree()` 改为 `if _dirty: _save_journal()`。
   未标脏时磁盘文件就是权威；标脏时仍立即 flush，保证 1.5 s 防抖窗口
   没到就退出也不丢里程。
2. **`SaveGuard.restore()`**（`tests/save_guard.gd:84-90`）统一置
   `FishingSystem.journal_ok = false` 与 `BoatSystem.journal_ok = false`，
   凡走本助手的探针退出期一律不写盘（两个 Autoload 都做，缺一不可）。

探针侧三层闭合（`tests/sailing_journal_probe.gd:_restore()`，顺序固定）：
① 拒写闸最前（两个 `journal_ok=false`，挡住 `_process()` 防抖与两个
`_exit_tree()`）→ ② 按开局记录的 `JOURNAL_PATH` **逐字节回写 / 删除两份
`JOURNAL_PATH` 文本**（`fishing_journal.json` 与 `boats.json`）→ ③ 最后
`SaveGuard.restore()`。

`tests/save_guard.gd` 的 `EXTRA_FILES` 由 5 项**增至 6 项**（新增
`user://boats.json`）：无槽态下 `_exit_tree()` 会落 legacy 根文件，不登记
则退出期凭空留文件 → 下次 `diff -r` 报 DIFF（同属测试污染型回归判定假阳性）。
`fishing_journal.json` 始终不在 `EXTRA_FILES` 内、有槽态 `boats.json` 由
`snapshot_profiles()` 覆盖整树，两者都靠探针自己按开局路径回写；快照必须先于
任何早退分支，看门狗 /
`_exit_tree` 安全网 / 正常路径三条路共用一个幂等 `_restore()`。
竞速侧「无 `_exit_tree` 不调即不写」的不对称别套错。

---

## 9. 界面与探针查询 API

`scripts/ui/sailing_journal_ui.gd` 为 `extends Control`、**无 `class_name`**
（项目铁律，坑 #24）：HUD 用 `const SailingJournalUIScript := preload(...)`
（`hud.gd:9`）+ `var _sailing_journal_ui = null` **无类型实例**（D-087 范式，
同 `profile_picker.gd` / `fishing_collection_ui.gd`），全代码现场搭节点、不配
`.tscn`。`_build_sailing_journal(root)`（:3403）`new()` + `closed.connect` +
`add_child`；按钮挂 `_touch_walk`（驾驶飞机时该容器整体隐藏，改由
`_flight_touch` 接管），桌面态为 null 则不建按钮。

**现取约束**：`_load_journal()` 会整体替换 `journal`，任何缓存的 `journal` /
`sail` 子字典 / `sail_state()` 返回引用都会在换槽瞬间静默失效。故 UI 成员
只持控件引用与静态常量，唯一刷新入口 `open()` / `refresh()`，每次当场调
`BoatSystem` 的 API 读标量 / 拷贝，**不连 `slot_changed` 自刷新**。

7 个只读查询 API 供探针断言（读的是**已渲染控件值**，不是数据层直读）：

| API | 返回 |
|---|---|
| `title_text()` | 「⛵ 我的航海记录」 |
| `total_text()` | 「累计出海：%.1f m」 |
| `farthest_text()` | 「最远离港：%.1f m」 |
| `badge_text()` | 「徽章 N / 3」 |
| `band_text(key)` | 「近海：已去过 ✓」/「近海：还没去过」 |
| `claim_state(key)` | `{disabled: bool, text: String}` |
| `row_count()` | 徽章行数（3） |

布局：`CenterContainer` + 相对锚点 + **单个 `ScrollContainer`**（禁止嵌套，
触屏抢手势，与探索课堂 / 收集册同红线）；`canvas_items` + `aspect=expand`
下逻辑视口高恒 720、20:9 宽 1600，物理 PNG 仍等于窗口尺寸。关闭按钮
`UiKit.make_close(24)` 默认热区约 38×26，本面板显式
`custom_minimum_size = Vector2(44, 44)`；**`UiKit.make_close()` 本身刻意不改**
（7 个面板共用，只造字形，热区由各调用方按需设）。

**截图探针** `tests/sailing_journal_shot.gd`：16:9（1280×720）/ 20:9
（1280×576）两档 PNG，两档复用同一 UI 实例（构造式闸：16:9 若滚过底，
20:9 默认态证据图会带滚动残留）。含 `_passed > 0` **哨兵**（`_passed == 0`
即整段 `_run()` 被跳过时不许打印 `_OK`，防恒 PASS 假绿，坑 #15）与
R4 / R5 / R6 **反向对照**：

| 断言 | 内容 |
|---|---|
| R4 | 改 `sail` 内存态但**未刷新**前 `total_text()` 不变（证明不是每帧轮询） |
| R5 | `refresh()` 后文本**必须变化**（缓存实现必 FAIL） |
| R6 | 刷新后文本等于当前 `sail_state()["total_m"]` |

反向对照把 `total_m` 从 680.0 推到 930.0，随后 `_seed_sail()` + `refresh()`
还原基线，避免污染 `_check_common()` 与两张 PNG；全程只改内存、不写盘，
`journal_ok` 保持 false。

`tests/quest_shot.gd` 同批覆盖任务面板窗口取证（触屏「任务」入口 + 三页签
44 px 热区 + 任务 / 成就 / 探索课堂三张 PNG，第三页签「探索课堂」截图正常）：
窗口探针已覆盖 44 px 热区与三页签断言，**真机可点性仍待目检**；同样遵守
D-010 三层收尾。

---

## 10. 同批 D-077 三条收口（简述，详见 ADR D-089）

| 收口 | 现状 |
|---|---|
| 触屏「任务」按钮 + 面板 44 px 热区 | 新按钮显式设 `custom_minimum_size = Vector2(44, 44)`；`UiKit.make_close()` **刻意不改**（7 个面板共用），热区由调用方按需设 |
| `cards_read` 埋点 + `cls_cards3` | `map_selector.gd:1001` 每次打开详情 `Progress.notify("cards_read")`；`quest_data.gd:283-285` 任务目标 `{type: count, key: cards_read, count: 3}`。**按打开详情次数计、未去重**，去重另开票 |
| 环保课诚实订正 | **只改文案 / 注释**，不改 `protected_blocked` 判据（`player.gd:1108` / `quest_data.gd:446`）；图鉴 `protected_viewed` 另开票 |

三条均随 ADR D-089 收口，不在本说明书展开实现细节。

---

## 11. 验证（探针）

| 探针 | 覆盖 | 标记 |
|---|---|---|
| `tests/sailing_journal_probe.gd` | 无头：A 段纯数据（`sail_state()` 返回拷贝 / `band_of` 100·250 边界 / 非法徽章 / 未达标拒领）、B 段里程语义反例（停泊 30 拍 Δ≈0 / 往返 40 m / 绕圈 8 m / 首次播种 / 传送护栏 / 无港口）、C 段按槽持久化（序列化往返 / v1 旧档兜底后原档逐字节不变 / 损坏 JSON 拒写 / 缺文件不新建）、D 段 1.5 s 防抖与 `claim_badge` 幂等、E 段 D-010 三层闭合 | `SAILING_JOURNAL_PROBE_OK` |
| `tests/sailing_journal_shot.gd` | 窗口：16:9 / 20:9 两档 PNG + `_passed>0` 哨兵 + R4/R5/R6 反向对照 + 只读查询 API | `SAILING_JOURNAL_SHOT_OK` |
| `tests/quest_shot.gd` | 窗口：任务面板三张 PNG + 触屏「任务」入口 / 三页签 44 px 热区（窗口态才成立的 `get_global_rect()` 断言，不伪造 headless 验证） | — |
| `tests/save_guard.gd` | D-010：`EXTRA_FILES` 6 项 + `restore()` 双 `journal_ok=false` | — |

无头探针用确定性构造：不实例化 `main.tscn`（物理不确定），而是
`Boat.new()` + raft（无发动机，`_emit_readings()` 不额外写盘）+
`set_physics_process(false)`，手动打 `_emit_readings(0.1)` 节拍。
窗口探针**不加 `--headless`**（无头下 `frame_post_draw` 永不触发会挂起）。

---

## 12. 未做 / 另开票（以代码为准）

1. **真机目检**：触屏 44 px 热区实际可点性、字形回退、多指、倒计时遮挡——
   截图探针只覆盖 16:9 / 20:9 两档逻辑比例，不替代真机。已知一例：
   `sailing_journal_ui.gd:111` 标题字符串为「⛵ 我的航海记录」，
   但 `tmp/sailing_journal_16x9.png` / `tmp/sailing_journal_20x9.png` 里
   ⛵ 在桌面字体下渲染成「黄色三角 + 字母 A」缺字回退方块（其余文字 /
   布局 / 20:9 不裁切均正常）。因 `fishing_gear_ui.gd:281`、
   `race_result_ui.gd:166` 等同样使用 emoji，本批刻意不改、不扩大字体方案，
   归真机目检统一裁决（见 ADR D-089「未做 / 另开票（真机目检统一裁决）」）。
2. **`chunk_mesh_baseline` full 档重录**：本批未触碰区块网格基线。
3. **`cards_read` 去重**：当前按打开详情次数计（§10），任务 `cls_cards3`
   可被反复开同一张卡刷满，去重另开票。
4. **`inventory` 不落盘，归 #44**：绿宝石只是本局内存态；本功能可回看的
   持久回报是 `sail` 里程与三档徽章，不发道具、不改背包。
5. **区块 / 地形改动落盘回避**：本批只写 `user://boats.json`，未触碰世界
   存档；相关落盘策略不在本次范围。
6. **`tmp/run_regression.sh` 参数化后移 `tools/`**：当前日常档仍需按
   ~10 个一组分段串行（本环境单次 600 s 跑不完 57 个探针）。
7. **桌面端入口 / 键盘快捷键**：D-089 裁决不新增，另开票。
8. **图鉴 `protected_viewed`**：与环保课 `protected_blocked` 判据分离的
   独立埋点，另开票。

---

> 回归基线（D-089 后）：日常无头 **57 探针** / 验收全量 **73 探针**
> （57 无头 + 16 窗口，`tmp/run_regression.sh` / `tmp/run_regression.sh full`）。
> 本批 full 档实测 **73 探针 / 2876 PASS / 0 FAIL**（无头 57 / 2511 PASS、
> 窗口 16 / 365 PASS）。8 段全部 `RESTORED_OK` 零 DIFF、最终 `diff -r` rc=0、
> `user://boats.json` 逐字节仍是 version 1、无残留移出目录与 Godot 进程。
> 与 D-088 对账：70 / 2778 → 73 / 2876，增量 = `sailing_journal_probe` 37 +
> `life_probe` 11 + `quest_shot` 16 + `sailing_journal_shot` 34 = **+98**。
