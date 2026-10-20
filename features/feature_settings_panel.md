# Block Planet 游戏设置面板实现文档

> 项目：Block Planet
> 引擎：Godot 4.6.3 / GDScript（Mobile 渲染器）
> 文档性质：**已实现现状说明书**（不是开发任务书）
> 事实来源：**代码**。本文与代码冲突时以代码为准，并应回头修订本文。
> 相关决策：`docs/decisions.md` D-032（Phase 5-a / 5-b / 5-c）、D-033、D-034；飞行玩法基准见 `features/feature_flight.md`

---

## 0. 文档定位与改版说明

本文件初稿是一份 **AI 生成的通用设置菜单设计任务书**：6 页签（画面 / 音频 / 控制 /
玩法与辅助 / 无障碍与儿童 / 系统与数据）+ `SettingsManager` Autoload +
`GameSettings` Resource（`.tres` 持久化）。**该设计基本未落地**——`project.godot`
的 Autoload 列表里没有 `SettingsManager`，工程里没有 `.tres` 设置存档，也没有
任何画面 / 音频类设置项。

已实现的只是**飞行设置**一个模态面板（3 行分段按钮）。本文按代码现状重写为
**现状说明书**；初稿中有价值的设计取向移入 §8「设计蓝图（未实现）」，供后续做
通用设置系统时参考。**不要按初稿直接施工**——会假设不存在的基础设施，并重复
建设已经跑通的 `FlightSettings` 持久化链路。

现状一句话：**设置面板 = 「飞行设置」模态窗（难度 / 辅助稳定 / 涂装 3 行分段
按钮），数据层是 `FlightSettings` 类级单例，持久化 `user://settings.json` 共
8 键，其中 5 键在面板里没有入口（§7）。**

---

## 1. 概述

玩家按 **O 键**打开「飞行设置」模态面板，用三行分段按钮调整飞行难度、辅助稳定
等级与机身涂装；改动**即时生效并落盘**，关闭面板后继续游戏。面板本身只做展示
与改写，不直接碰飞行动力学——飞机每个物理帧读 `FlightSettings.current()` 的
增益表与涂装索引。

| 设计取向 | 落地方式 |
|---|---|
| 儿童友好 | 难度预设只决定辅助出发点（休闲=全开辅助），玩家可单独覆盖；辅助只在松杆时接管，一压杆立刻让位 |
| 即时反馈 | 改动即写 `user://settings.json` + Toast 确认；不做「应用/取消」两段式 |
| UI 与逻辑分离 | `FlightSettings`（纯逻辑、可无头探针验证）/ `SettingsPanel`（纯 UI）/ 消费方各自每帧读单例 |
| 单一持久化文件 | 全部设置（含 HUD 模式、自动改平等飞行相关开关）共用 `user://settings.json`，不用 `.tres`、不用 Autoload |
| 模态互斥 | 面板打开即冻结玩家 + 纳入 `_any_overlay_open`，ESC / O 关闭 |

---

## 2. 架构与数据流

```text
输入（O 开 / ESC·O 关，hud.gd:341-344、392-393）
   │
   ▼
SettingsPanel（scripts/ui/settings_panel.gd，纯 UI）
   │  点击分段按钮 → FlightSettings.set_*(…)
   │  每次改动：save() 落盘 + refresh() 同步选中态 + settings_changed 信号
   ▼
FlightSettings（scripts/core/flight_settings.gd，纯逻辑，类级单例 current()）
   │  to_dict() → JSON → user://settings.json（save，失败返回 false）
   │  load_or_new() ← JSON（缺失 / 损坏 → 默认值）
   ▼
消费方（各自每帧 / 事件驱动读单例，改动即时生效）
   ├─ Aircraft（aircraft.gd:545）   每物理帧读 gains() → 气动辅助
   ├─ Aircraft（aircraft.gd:308/600）涂装索引 → 材质（整数比对，变了才刷）
   ├─ AircraftCamera（…:266-267）   auto_recenter / camera_shake
   ├─ FlightInstrumentHUD（…:141/175）beeper_enabled / hud_detail
   └─ Player（player.gd:236/308）   auto_level（双击左键）/ hud_detail（H 键）
```

三个关键约定：

1. **没有 Autoload**：`FlightSettings.current()` 是类级静态单例，首次访问时懒加载
   读档；`main` 可在启动早期 `set_current()` 统一注入（探针即用此隔离，见 §9）。
2. **不做「应用」按钮**：每次点击立即 `save()` 落盘。写入失败（只读 / 磁盘满）
   时 `push_warning` 进控制台（P2-14：设置对本进程仍生效，玩家下次启动回到旧值，
   比无声丢失好排查）。
3. **面板不理解设置语义**：难度切换会把辅助重置为该难度预设（`set_difficulty`
   的副作用），但辅助可再被单独覆盖——逻辑全部封装在 `FlightSettings`。

---

## 3. 已实现设置项清单（8 键，全部随 `user://settings.json` 持久化）

| # | 键 | 取值 | 默认 | 面板入口 | 其他入口 | 主要消费方 |
|---|---|---|---|---|---|---|
| 1 | `difficulty` | 休闲 / 标准 / 硬核 | 标准 | ✅ 第一行分段按钮 | — | 决定辅助出发点（`DIFFICULTY_ASSIST`） |
| 2 | `assist_level` | 关闭 / 半开 / 全开 | 半开 | ✅ 第二行分段按钮 | — | `Aircraft.gd:545` → 气动增益 |
| 3 | `livery_index` | 0~3（经典红白 / 深海蓝 / 丛林绿 / 落日橙） | 0 | ✅ 第三行分段按钮 | — | `Aircraft.gd:308/600` → 材质 |
| 4 | `camera_shake` | bool | true | ❌ 无 | ❌ 无 | `AircraftCamera.gd:79/409`（坠机 / 湍流镜头抖动） |
| 5 | `auto_recenter` | bool | true | ❌ 无 | ❌ 无 | `AircraftCamera.gd:80/210/271`（自由观察松手回正） |
| 6 | `hud_detail` | bool | false | ❌ 无 | **H 键**（`player.gd:305-311`） | `FlightInstrumentHUD.gd:175`（简单 / 详细模式） |
| 7 | `auto_level` | bool | true | ❌ 无 | **双击左键**（`player.gd:236`） | 约 2 秒增强增益摆平坡度 |
| 8 | `beeper_enabled` | bool | true | ❌ 无 | ❌ 无 | `FlightInstrumentHUD.gd:141`（警告蜂鸣码） |

> ⚠️ `camera_shake` / `auto_recenter` / `beeper_enabled` **三个键目前没有任何
> UI 入口**，只能靠手改 `user://settings.json`；`hud_detail` / `auto_level` 有
> 键位但面板里看不到也改不了。详见 §7。

---

## 4. 面板 UI 与交互（`SettingsPanel`）

### 4.1 节点结构（全部代码构建，无 .tscn）

```text
SettingsPanel（Control，全屏矩形，初始 visible=false）
├── ColorRect        模态暗幕（黑 55% alpha，吃鼠标事件）
├── CenterContainer  居中容器（鼠标 IGNORE）
└── PanelContainer   面板（560 px 最小宽）
    ├── StyleBoxFlat 米色底 (0.95,0.92,0.84) / 棕边 (0.62,0.47,0.27) / 3 px 边 / 12 圆角 / 16 px 内边距
    └── VBoxContainer
        ├── HBoxContainer  标题行：「飞行设置」(24 px) + UiKit.make_close()
        ├── Label「难度」+ 分段按钮行：休闲 / 标准 / 硬核
        ├── Label「辅助稳定」+ 分段按钮行：关闭 / 半开 / 全开
        ├── Label「涂装」+ 分段按钮行：经典红白 / 深海蓝 / 丛林绿 / 落日橙
        ├── Label 提示语：「辅助稳定只在松杆时接管：放手后自动摆平机翼、压住摆头；一压杆立刻让位。」
        └── Label 状态行：「当前：难度 标准 · 辅助 半开 · 涂装 经典红白」
```

### 4.2 交互约定

| 行为 | 实现 |
|---|---|
| 分段按钮选中态 | `ButtonGroup` + `toggle_mode`，`_sync()` 按当前值同步 `button_pressed`（`settings_panel.gd:103-122/152-154`） |
| 打开 | O 键（`toggle_settings`，`input_actions.gd:25`）；冻结玩家 + 非触屏时鼠标改 VISIBLE（`hud.gd:2859-2865`） |
| 关闭 | 关闭按钮 / ESC / 再按 O；`closed` 信号 → 解冻 + 还原鼠标（`hud.gd:341-344/2874-2876`） |
| 改动生效 | `set_*` → `save()` 落盘 → `refresh()` 同步 UI → `settings_changed` 信号 → HUD Toast 确认（`settings_panel.gd:172-179`、`hud.gd:2880-2883`） |
| 模态互斥 | 纳入 `_any_overlay_open`（`hud.gd:2705`）：面板开着时其余热键与建造界面让位 |
| 落盘失败 | `push_warning("SettingsPanel: 设置保存失败（磁盘写入被拒？）")`，不静默（P2-14） |

### 4.3 难度与辅助的联动规则

- `set_difficulty(d)`：夹紧到三档，**同时把 `assist_level` 重置为该难度预设**
  （休闲→全开 / 标准→半开 / 硬核→关闭）。
- `set_assist_level(a)`：单独覆盖，不动难度；读档时若 JSON 显式带
  `assist_level` 以它为准（`flight_settings.gd:138-139`）——玩家「标准难度 +
  关闭辅助」的 custom 配置跨会话保留。
- 增益表 `ASSIST_GAINS`（`flight_settings.gd:23-27`）：

| 辅助档 | `roll_level`（坡度摆平，1/s·rad） | `yaw_damp`（偏航阻尼，1/s） |
|---|---|---|
| 关闭 | 0.0 | 0.0 |
| 半开 | 0.9 | 0.8 |
| 全开 | 1.8 | 1.5 |

  辅助**只在松杆（三轴杆量≈0）且未失速时接管**，玩家一压杆立刻完全让位；
  刻意不含俯仰自动配平（会与爬升 / 失速机动对抗，D-032 Phase 5-a 实测结论）。

---

## 5. 持久化机制（`FlightSettings`）

- **路径**：`user://settings.json`（`SAVE_PATH`，`flight_settings.gd:17`）。
- **写入**：`save()` → `JSON.stringify(to_dict())`；`FileAccess.open` 失败返回
  `false`，不抛异常。
- **读取**：`load_or_new()`；文件不存在 / 打不开 / JSON 损坏（非 Dictionary）
  一律安全退回默认（难度标准 + 辅助半开 + 涂装 0 + 四个 bool 默认值）。
- **8 键 round-trip**：`to_dict()` / `from_dict()` 成对；未知 / 缺失键走
  `d.get(key, default)`，旧版本存档向前兼容。
- **类级单例**：`current()` 懒加载；`set_current()` 供 main 启动早期注入与探针
  隔离（探针用完 `set_current(null)` 复位）。
- **不持久化**：窗口模式 / 分辨率 / 音量等通用设置（初稿设计，未实现——见 §8）。

---

## 6. 键位入口

| 键 | 作用 | 代码位置 |
|---|---|---|
| **O** | 打开 / 关闭「飞行设置」面板 | `hud.gd:392-393`、`input_actions.gd:25` |
| **ESC** | 面板打开时关闭面板（否则开建造界面） | `hud.gd:341-344` |
| **H** | HUD 简单 / 详细模式切换（`hud_detail`，Toast 确认） | `player.gd:305-311`、`input_actions.gd:46` |
| **双击左键** | 自动改平（受 `auto_level` 门控，约 2 秒增强增益） | `player.gd:236` |

> 📌 `features/feature_flight.md` §5.1 键位表现缺 O 键行（2026-10-20 已补）。

---

## 7. 差距与已知问题（以代码为准）

1. **5 个持久化键没有面板入口**（§3 表红字项）：`camera_shake` /
   `auto_recenter` / `beeper_enabled` 连键位都没有，玩家只能手改
   `user://settings.json`；`hud_detail` / `auto_level` 有键位但面板不可见。
2. **代码注释与实现不符**：`flight_settings.gd:52-53` 注释称
   「（抖动 / 松手自动回正）两者都可在飞行设置面板里关掉（防晕动症）」——
   面板只有 3 行，没有这两个开关。修面板或修注释，二选一（建议补面板入口，
   防晕动症是儿童向刚需）。
3. **无「恢复默认」按钮**：改乱了只能手删 `user://settings.json`。
4. **初稿 6 页签设计全部未实现**：画面 / 音频 / 控制 / 玩法 / 无障碍 / 系统
   六组设置、`SettingsManager` Autoload、`.tres` 存档均不存在（§8 保留为蓝图）。
5. **触屏无专属设置**：虚拟摇杆的 `radius` / `knob_radius` / `deadzone` 是
   编辑器 `@export`（`virtual_joystick.gd:7-9`），非运行时设置项。

---

## 8. 设计蓝图（未实现，保留初稿精华）

后续若做通用设置系统，初稿以下取向仍然成立，但须与现状对接：

- **分级呈现**：基础设置（音量、画质）一眼可见，进阶收折二级菜单。
- **跨端自适应**：`OS.has_feature("mobile")` 动态显示摇杆 / 触控布局项。
- **儿童防晕**：镜头平滑、自动回正、抖动幅度可调（对应现 `camera_shake` /
  `auto_recenter`，应优先补面板入口而非新造轮子）。
- **持久化选型**：初稿的 `SettingsManager` Autoload + `GameSettings` Resource
  (.tres) 与现状 `FlightSettings` 类级单例 + JSON **二选一**；若换 Resource 方案，
  必须迁移现有 `settings.json` 的 8 键（玩家已有存档），或保留 JSON 双读过渡。
- **建议施工顺序**：先补 §7.1 的 5 键面板入口（小步、可探针验证），再评估是否
  值得引入通用设置框架。

---

## 9. 验证（探针）

| 探针 | 断言数 | 覆盖 | 标记 |
|---|---|---|---|
| `tests/flight_settings_probe.gd` | 31 | 默认值 / 难度预设 / 增益表 / `to_dict`·`from_dict` / save 往返 / 损坏文件退回 / 坡度配平 / 辅助不干预俯仰 / 4 套涂装改色 | `FLIGHT_SETTINGS_OK` |
| `tests/settings_panel_probe.gd` | 26 | 面板初始隐藏 / 三行按钮与文案 / 默认选中态 / 难度→辅助预设重置 / 辅助单独覆盖 / 落盘读回 / 涂装选中态与越界夹回 / 模态开关与 `closed` 信号 | `SETTINGS_PANEL_OK` |

D-010 合规：`settings_panel_probe` 先快照真实 `user://settings.json`，用
`FlightSettings.set_current(default_settings())` 隔离单例，结束原样还原
（探针内 25-31 / 99-106 行）；按钮点击走 `pressed.emit()`，与真实点击同路。
回归基线：2026-10-20 全量 41 探针 1583 PASS / 0 FAIL / 存档逐字节还原。

---

## 10. 移动端 / PC 差异

| 维度 | PC（现状） | 移动端（现状） |
|---|---|---|
| 打开方式 | O 键 | 触屏无打开面板的入口按钮（O 键无触屏映射）——**缺口** |
| 面板操作 | 鼠标点击分段按钮（160 px 宽，键鼠舒适） | 按钮可点但无触屏优化；打开时**不**改鼠标模式（`hud.gd:2864` 触屏分支跳过） |
| 设置内容 | 飞行三行 | 同 PC；无摇杆大小 / 透明度 / 按钮布局等触屏专属项（初稿设计） |
| 冻结行为 | 冻结玩家 + ESC/O 关闭 | 冻结玩家；关闭依赖面板自带的关闭按钮 |

---

## 11. 相关决策索引

| 决策 | 内容 |
|---|---|
| D-032 Phase 5-a | `FlightSettings`：难度三档 + 辅助三档；增益只在松杆时接管；不做俯仰自动配平 |
| D-032 Phase 5-b | `SettingsPanel`：O 键模态、两行分段按钮（后增涂装行）、即时生效 + 落盘、HUD 接线 |
| D-032 Phase 5-c | 4 套涂装 `AircraftLivery`；索引随设置落盘；`_sync_livery` 整数比对 |
| D-033 | 飞行视角：自动回正、镜头抖动可关（开关即 `auto_recenter` / `camera_shake`） |
| D-034 | HUD 简单 / 详细（H 键）、双击左键自动改平、蜂鸣码——三项均随 `settings.json` 落盘 |
