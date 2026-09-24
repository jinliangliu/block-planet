# assets —— 数字资产管理与新增流程

> **一句话**：本工程**没有任何外部美术文件**——没有 PNG、没有 glTF、没有字体。
> 方块贴图、生物模型、物品图标、区域插画全部由 GDScript 在运行时程序化生成。
> 所以「数字资产」在这里就等于**代码里的那些表**，
> 「资产管理」就等于**保证表与实现始终对得上**。这份文档讲的就是这套规矩与流程。

---

## 一、资产总账：什么是资产、存在哪、谁是唯一来源

| 类别 | 内容 | 唯一事实来源 | 文件 |
|------|------|-------------|------|
| 方块外观 | 16×16 程序化瓦片拼成的图集纹理 | `BlockTypes.TILES`（方块→瓦片号）→ `TextureAtlas._tile_color`（瓦片号→配色与花纹） | `scripts/world/block_types.gd`、`texture_atlas.gd` |
| 方块数据 | 名称、实心、透明、硬度、有效工具、采集等级门槛、掉落 | `BlockTypes.NAMES / SOLID / TRANSPARENT / HARDNESS / EFFECTIVE_TOOL / MIN_TIER / SHORT_NAMES` | `block_types.gd` |
| 物品数据 | 工具（类别/等级/耐久/名字）、材料（名字/简称/颜色/简介）、配方、冶炼、食物、交易、售价、垂钓产出 | `ItemTypes.*`（见 `item_types.gd` 内的表） | `scripts/systems/item_types.gd` |
| 物品图标（2D） | 背包与快捷栏里的小图 | `ItemSlot._draw_mini_cube / _draw_tool_icon / _draw_item_icon` | `scripts/ui/item_slot.gd` |
| 物品预览（3D） | 悬停说明里的立体模型 | `HUD._apply_tip_mesh / _build_tip_tool / _build_tip_chest` | `scripts/ui/hud.gd` |
| 手持物 | 第一人称手里的方块/工具 | `HeldItem` | `scripts/player/held_item.gd` |
| 生物名录 | 物种枚举、中文名、阶段链、保护/反击/敌对名单 | `Mob.MobType / MOB_NAMES / MOB_STAGES / PROTECTED_MOBS / PROTECTED_NOTES / COUNTER_MOBS / HOSTILE_MOBS` | `scripts/mobs/mob.gd` |
| 生物造型 | 程序化积木式 3D 模型 + 幼体小模型 | `Mob.ART_BUILDERS`（物种→方法名）→ `_build_*()`；阶段模型 `_build_stage_art()` | `mob.gd` |
| 掉落物模型 | 地面上的掉落物外观 | `DroppedItem` | `scripts/player/dropped_item.gd` |
| 狩猎规则 | 物种 → 所需工具类别/最低等级/伤害/提示 | `HuntRules.HUNT_RULES` | `scripts/systems/hunt_rules.gd` |
| 区域生成 | 地形参数、天空、昼夜生态表、四段介绍 | `RegionAtlas.REGIONS` | `scripts/world/region_atlas.gd` |
| 区域图鉴卡片 | 每个区域 3 张知识卡片（标题/正文/插画/主色） | `RegionAtlas.REGION_CARDS` | `region_atlas.gd` |
| 卡片插画 | 程序化插画 | `MapSelector._draw_art()` + 种类清单 `ART_KINDS` | `scripts/ui/map_selector.gd` |
| 任务/问答/成就 | 新手任务链 8 环、题库、成就 | `QuestData._build()` | `scripts/core/quest_data.gd` |
| 手册文案 | 说明书分页与每页状态栏提示 | `ManualPanel.PAGES` | `scripts/ui/manual_panel.gd` |
| 地球外观 | 大洲掩码、配色、区域锚点 | `RegionAtlas.LAND_MASK / REGION_COLORS / REGION_ANCHORS` | `region_atlas.gd` |
| **外部美术文件** | **（无）** | —— | —— |

> 仓库里唯一的二进制文件是 `tmp/` 下的探针截图，已被 `.gitignore` 忽略，不进版本库。

---

## 二、四条管理原则

1. **零外部美术文件。**
   好处：一切可 diff、可 review、无素材授权问题、包体极小、改一个数字就能改观感。
   代价：观感上限受代码描述力限制——但方块风格正好吃这一套。

2. **一个事实来源，其余派生。**
   同一个信息不写第二遍：模式说明只有 `GameState.mode_hint()` 一处，地图页与说明书都引用它；
   「谁被动」由 `Mob.HOSTILE_MOBS` 派生，不再是散落的长串 `or`。

3. **新东西默认落在安全的一边，并且要显眼。**
   新增物种**默认被动**（想让它有害必须显式登记 `HOSTILE_MOBS`）；
   新增物种**未登记造型**时画出**品红占位方块**并打警告——宁可丑得刺眼，也不要静默地长成别的东西。

4. **凡是「新增时必须同步 N 张表」的地方，都要有机器校验。**
   人工清单会漏，探针不会。对应实现：`tests/life_probe.gd` 的 **阶段 R：资产完整性守门**（12 条断言，见第五节）。

---

## 三、新增一个物种：九步

> 顺序即依赖顺序；每一步后面括号里是**漏掉会怎样**与**哪条探针断言会拦你**。

| # | 动作 | 位置 | 漏掉会怎样 | 守门 |
|---|------|------|-----------|------|
| 1 | 枚举尾巴追加一项 | `mob.gd` → `enum MobType` | 无法引用该物种 | — |
| 2 | 加中文名 | `mob.gd` → `MOB_NAMES` | 名牌显示「生物」 | R-1 |
| 3 | 若有害：登记敌对；无害则**什么都不用做** | `mob.gd` → `HOSTILE_MOBS` | 漏登：白天不会被清、夜里按敌对生成却算被动，生态错乱 | R-2 |
| 4 | 定栖息地；走水轨的还要进 `is_aquatic` | `mob.gd` → `habitat_of()`、`is_aquatic()` | 陆生生物掉进水里、或水生生物走上岸 | R-3 |
| 5 | 生命/速度/攻击/掉落 | `mob.gd` → `_apply_type_stats()` | 落到默认分支：5 血、掉木头 | 阶段 P/R 抽查 |
| 6 | 生长链（可选） | `mob.gd` → `MOB_STAGES` | 不出幼体；或末段不是成体导致属性换算错 | R-4 |
| 7 | 写造型 + **登记到 `ART_BUILDERS`** | `mob.gd` → `_build_xxx()` / `ART_BUILDERS` | 画成品红占位方块 + 警告（不会静默出错） | R-6 |
| 8 | 登区域生成表 | `region_atlas.gd` → `REGIONS[i]["passive"/"hostile"]` | 满世界找不到它 | R-5 |
| 9 | 内容补全：保护名录 / 狩猎规则 / 题目成就 / 手册文案 | `PROTECTED_MOBS`+`PROTECTED_NOTES`、`HUNT_RULES`、`quest_data.gd`、`manual_panel.gd` | 打不动、或打得到却没有规则、或图鉴里查不到 | R-7，其余靠阶段 P 断句 |

**两个高频错误**：

- **区域表的键是「枚举名」字符串**（`"PANDA"`），不是中文名也不是数字。拼错不会崩，只是永远刷不出来——R-5 会点名报错。
- **枚举只能往后追加，不能插入、不能删除、不能复用**。枚举值会被区域表（按名字）、存档与探针当作稳定标识；插一个进去会让所有后序语义整体错位。

---

## 四、新增图鉴资料：按内容类型落位

| 想加的东西 | 写到哪 | 注意 |
|-----------|--------|------|
| 区域知识卡片（地球页点区域后弹出的三张卡） | `RegionAtlas.REGION_CARDS[区域]` 追加 `{title, text, art, tint}` | `art` 必须是 `MapSelector.ART_KINDS` 里已有的种类；要新画法就去 `_draw_art()` 写分支并补进清单（R-10 会拦） |
| 区域加载页四段介绍 | `RegionAtlas.REGIONS[i]` 的 `vegetation / creature / climate / scenery` | 加载页逐条揭示，每条一句话为宜 |
| 区域地理简介 | `REGIONS[i]` 的 `title / subtitle / intro` | `intro` 是介绍页正文 |
| 问答题目 | `QuestData.quiz_bank()` | 题目答案要能在说明书或卡片里找到线索（设计红线） |
| 成就 | `QuestData.achievements()` | 键用 `ItemTypes.*` / `Mob.MobType.*` 符号，不写字面量 |
| 任务链 | `QuestData.quests()` | 目前 8 环新手链，追加时注意与进度管理器事件对齐 |
| 物品简介 | `ItemTypes.ITEM_DESCRIPTIONS` | 工具与主要材料各一句；纯食材可缺省 |
| 保护动物说明 | `Mob.PROTECTED_NOTES` | 与 `PROTECTED_MOBS` 必须成对（R-7） |
| 说明书页 / 行 / 状态栏提示 | `ManualPanel.PAGES` | 每页的 `tip` 会显示在窗口底部状态栏 |

---

## 五、新增方块与物品

**方块**（`block_types.gd`）
1. `enum Block` 追加；
2. `NAMES`（全名）、`SOLID`、`TRANSPARENT`（必须给）；
3. 非空气还要 `TILES`（瓦片号）与 `SHORT_NAMES`（简称）；
4. 非空气且非水还要 `HARDNESS`（挖掘时长）；
5. 顺手：`EFFECTIVE_TOOL`（用哪类工具挖更快）、`MIN_TIER`（采集等级门槛）；
6. 纹理：`texture_atlas.gd` 新增瓦片号并在 `_tile_color` 里给配色与花纹。
   → 一次最多 64 个瓦片（`ATLAS_TILES=8`，8×8）。

**物品**（`item_types.gd`）
- 工具：`TOOL_TYPE`、`TOOL_TIER`、`TOOL_DURABILITY`、`TOOL_NAMES` **四张表都要给**；
- 材料：`ITEM_NAMES`、`ITEM_SHORT_NAMES`、`ITEM_COLORS` **三张都要给**，简介可选；
- 图标：`item_slot.gd` 的 `_draw_item_icon` / `_draw_tool_icon` 加分支（否则图标会是空的）；
- 3D 预览：`hud.gd` 的 `_apply_tip_mesh` / `_build_tip_tool` 加分支；
- 出货途径：`RECIPES`（合成台）或 `SMELT_RECIPES`（冶炼炉），两者都在 `item_types.gd`。

---

## 六、校验：跑什么、看什么

```bash
# 资产完整性守门（阶段 R，12 条）+ 全量功能回归
"C:/Program Files/Godot/Godot_v4.6.3-stable_win64_console.exe" \
  --headless --path . res://tests/life_probe.tscn

# 只想知道有没有解析错误（比跑探针快）
"C:/Program Files/Godot/Godot_v4.6.3-stable_win64_console.exe" --headless --path . --import

# UI/外观改动：开窗截图目检（输出落 tmp/，勿加 --headless）
"C:/Program Files/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://tests/hud_mode_shot.tscn
```

阶段 R 覆盖的 12 条（新增内容时最该关注）：

| 断言 | 拦什么 |
|------|--------|
| MOB_NAMES 覆盖全部物种 | 加了枚举忘了起名 |
| 敌对名单与保护名录无交集、区域敌对表无越界 | 保护动物被当敌对清掉 / 区域表登错分类 |
| 在水里的物种都归水生物轨道 | 水生生物不在水轨、或陆地生物误入水轨 |
| 阶段链自洽（末段成体、多段首段幼体） | 生长链写反或漏末段 |
| 区域生成表物种名与分类自洽 | 键拼错、被动表混进敌对 |
| 区域表收录无遗漏（除水轨/村庄角色） | 新增陆地物种忘了登表，满世界找不到 |
| 造型登记表覆盖全枚举且方法存在 | 造型写好了却忘了登记（或方法名拼错） |
| 保护动物都有中文名录 | 名录与说明表不同步 |
| 方块名称/实心/透明/瓦片/硬度完整 | 新方块缺表项导致渲染或挖掘异常 |
| 工具四表齐、材料三表齐 | 新物品在背包里没名字/没颜色 |
| 每个区域都有卡片组 | 新区域忘配图鉴 |
| 卡片插画种类都有画法 | 卡片写了 `art` 却没有画法，静默空白 |

---

## 七、踩坑备忘

- **Godot 文件里含中文 + tab 缩进**：改动成片文本时用脚本按行替换并断言替换次数，别指望手改的行尾匹配。
- **`match` 多模式不能跨行**：`A, B,` 换行接 `C:` 会报 `Expected expression for match pattern`，必须写一行。踩过两次（`mob.gd`、`item_slot.gd`）。
- **`--check-only --script <单文件>` 会假报 Autoload 未注册**（`GameState` 等），那是模式限制，不是真错误——用 `--import` 复核。
- **探针 `--headless` 与渲染**：`render_probe` 之类要 `frame_post_draw` 的探针**不能**加 `--headless`，会卡住。
- **新增截图探针**：一律写 `res://tmp/`，用 `_shot_path()` 取路径，不写绝对路径。
