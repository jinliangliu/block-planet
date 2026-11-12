# 真机 / 窗口目检清单（D-093 后，2026-11-12）

> **用途**：交付项目所有者 dylan 本人执行，用于关闭 ADR D-088~D-093 反复保留的「回归全绿不关闭真机目检」待办。
> **为什么需要人工**：自动化探针只跑 16:9 与 20:9 两档窗口、**无槽态**、**桌面 Godot 4.6.3 / Vulkan**。触屏真实可点性、多指、中低端 Android 帧率与发热、系统字体回退，静态断言与窗口截图都无法替代。
> **事实来源**：本清单所有代码数值均为当前工作树（`HEAD=5999b93`）一手核实；桌面量化基线取自 `tmp/sky_weather_run_report.txt` / `docs/decisions.md` D-093 §5~§6。**推断项一律标注「推断」或「待定性」**，不与实测混写。

---

## 0. 使用前：环境与记录

| 项 | 填写 |
|---|---|
| 设备型号 / SoC / RAM | |
| Android 版本 / 系统字体 | |
| 物理分辨率 / 刷新率 / 屏幕比例 | |
| GPU 驱动 / Vulkan 版本 | |
| 构建方式（导出模板 debug / release、APK / AAB） | |
| 测试时长 / 起始电量 / 机身起始温度 | |
| 存档槽状态（新装空槽 / 已有存档） | ⚠️ 见 F3：空槽态必弹 ProfilePicker |

**判定标记**：`✅ 通过` / `❌ 不通过` / `⚠️ 观察项（不判失败）` / `— 本设备不适用`。
**优先级**：**P0** = 影响可玩性或本批核心收益，必须测；**P1** = 体验打磨；**P2** = 记录基线，供后续对比。

**项目配置（`project.godot:35-43`，先确认与导出包一致）**：
`viewport 1280×720`、`stretch/mode="canvas_items"`、`stretch/aspect="expand"`、`handheld/orientation=4`、`renderer/rendering_method="mobile"`；**未显式设置** `max_fps` / `physics_ticks_per_second` / `low_processor_mode`（均为引擎默认）。
**逻辑视口口径（D-093 已订正，勿再按旧稿判断）**：`expand` ⇒ **高恒 720、宽按窗口宽高比扩展**。16:9 → 逻辑 1280×720；20:9 → 逻辑 **1600×720**；物理 PNG 仍等于窗口尺寸（20:9 为 1280×576）。桌面截图探针只覆盖这两档。

---

## A. D-093 天空与气象可见化（本批新增，P0）

### A1 四档天空可辨识 —— 对照桌面取证图逐档目检

| 档 | 桌面六点 `sky_band_lum` | `distinct_rgba32` | 真机观察点 | 结果 |
|---|---|---|---|---|
| 正午晴 `noon_clear` | **0.7439** | 2595 | 蓝天自上而下渐变、白云团块、云间留出蓝天；**不得**回到均匀分布的一片灰 | |
| 正午阴 `noon_cloudy` | **0.6192** | 2852 | 明显比晴档压暗，仍能看出云层纹理 | |
| 正午雨 `noon_rain` | **0.4400** | 2656 | 乌云压暗 + **多条白色雨滴细竖线可见** | |
| 午夜晴 `night_clear` | **0.1127** | 574 | 近黑夜空 + 月亮/星星；**不得**是灰蓝亮天或亮蓝天 | |

- **判据**：四档彼此肉眼可区分；晴档亮度不得过曝洗白（桌面闸 `0.55 ≤ lum ≤ 0.75`，见 `tests/sky_weather_shot.gd:138`）；夜档不得有「亮度地板」（`lum < 0.25`，`:141`）。真机不要求数值完全相等（渲染器/色调映射差异允许），要求**排序一致**：晴 > 阴 > 雨 > 夜。
- **桌面取证图**（本机 `tmp/`，gitignored）：`tmp/cockpit_noon_clear.png`、`tmp/cockpit_noon_rain.png`、`tmp/sky_weather_noon_clear.png`、`tmp/sky_weather_night_clear.png`。
- **复现注意**：`WEATHER_SLOT=150.0` × 6 槽 = **900 s 周期**，雨只占 1 槽（16.7%），**开局约 7.5 分钟内不会下雨**（`scripts/systems/day_night.gd:49-50`）。真机等雨不现实，须用现有的 `set_weather()` override 或调试入口切档（与 `tests/sky_weather_shot.gd` 相同手法）。
- **失败记录**：截图 + 当时档位 + 是否 `BG_SKY` 生效（若整屏均匀灰，优先怀疑 `fog_sky_affect` 未归零）。

### A2 首帧与昼夜过渡无跳变

- 进主世界第一帧、跨昼夜切换（日落 / 日出）、跨槽位换档各观察 3 秒。
- **判据**：不出现「先亮蓝后突然变暗」或白/灰闪帧；`setup_environment()` 有首帧兜底刷 `_apply_sky()`（`day_night.gd:161`），真机验证其生效。
- **失败记录**：跳变发生时刻与档位、是否伴随日志报错。

### A3 区域 tint 不串色

- 切换不同区域（雪原 / 沙漠 / 森林 / 湿地 / 城市等）观察天空。
- **判据**：色调随区域 `_sky_tint` 变化但不过饱和、不出现品红/荧光色；夜晚 tint 不把夜空提亮。
- **依据**：`_apply_sky()` 白天乘 `_sky_tint`、夜晚不乘（与 `background_color` 原策略一致）。

### A4 夜空月亮 / 星星不被天空球盖住

- 午夜、抬头视角、第一人称与座舱视角各看一次。
- **判据**：卡通月亮（16×16 QuadMesh、仰角刻意压在约 30°，见 `day_night.gd:422` 附近）与三层闪烁星星可见且不被 `ProceduralSkyMaterial` 球壳遮挡；桌面 `tmp/sky_weather_night_clear.png` 为对照。
- **已知观察项（不判失败）**：`night_clear distinct_rgba32=574` 色数偏低；落码午夜 lum `0.1127` 比标定 N1 的 `0.1317` 更暗（方向更安全）。真机若觉得「太黑看不清地形」，记录亮度偏好即可，不作为回归失败。

### A5 雨幕位置无穿帮

- 雨档下：第一人称 / 飞行座舱 / 快速转向 / 爬升下降 / 贴地飞行各一次。
- **判据**：雨滴出现在相机**前方**而非穿过 3D 座舱面板；不出现整片雨幕突然消失、闪现或只在一侧；不出现雨滴穿过地形。
- **依据**：`_update_rain()` 用 `-cam.global_transform.basis.z * RAIN_AHEAD`，`RAIN_AHEAD=9.0` / `RAIN_HEIGHT=6.0` / `RAIN_BOX=(18,0.5,18)` / `RAIN_AMOUNT=240`（`day_night.gd:92-97, 401-409`），粒子为 `CPUParticles3D`。
- **如实写**：桌面雨天取证图 `full_upper diff_pixels=384349/460800 (83.4%)` 的高差异**主要来自天气整体压暗**，不纯归因雨滴；雨滴亮线证据是 `rain_brighter_pixels` 与目检。真机请单独确认雨滴线条本身。

### A6 太阳盘方向（P1）

- 日出 / 日落时段抬头看；**正午看不到太阳盘属正常**（D-090 太阳近天顶 85°，水平视角在画外）。
- **判据**：太阳盘方向与方向光一致，不出现「两个太阳」或光斑与阴影方向矛盾。
- 4.6.3 实测：`ProceduralSkyMaterial` **无** `sun_disk_scale` / `sun_disk_color` / `sun_energy_multiplier`，太阳盘完全由方向光方向决定，不可单独调。

---

## B. 中低端 Android 帧率 / 发热（P0，本批最大未测风险）

> **背景**：D-093 是本批唯一新增渲染负载——`ProceduralSkyMaterial` + 512×256 `NoiseTexture2D` 云纹（`FastNoiseLite` SIMPLEX_SMOOTH / seed 1337 / freq 0.015 / **5 octaves** / seamless，`day_night.gd:174-199`）+ 240 粒 `CPUParticles3D` 雨幕 + 39 个 `MeshInstance3D` 的 3D 座舱内装（`cockpit_interior.gd:172`，探针硬断言 39）+ SubViewport 768×168 仪表面板。**桌面从未测过中低端真机帧率/发热**（ADR D-093 §6 待观察项 4）。

### B1 稳定帧率

- **场景**：飞行座舱第一人称，正午晴 → 阴 → 雨 → 夜各连续 **≥2 分钟**；同时保持区块流式加载（高速飞行穿图），不要停在原地。
- **观测手段**（任选，记录所用方法）：
  - Android 开发者选项「GPU 呈现模式分析 / 帧时间直方图」，或 `adb shell dumpsys gfxinfo <包名> framestats`；
  - Godot 编辑器 Debugger → **Monitors** 面板（精确查询关键词：`Performance.TIME_PROCESS`、`Performance.TIME_PHYSICS_PROCESS`、`Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME`、`Performance.MEMORY_STATIC`，以 Godot 4.6.3 文档为准）。
- **判据（专家团 full 档基线）**：**移动端稳定 ≥ 30 FPS**、PC ≥ 60 FPS；无连续 ≥3 秒掉到 20 FPS 以下的区段；雨档与晴档帧率差不构成可感知卡顿。
- **记录表**：

| 档位 | 稳定 FPS | 最低 FPS | 最长卡顿 (ms) | Draw Call | 静态内存 | 机身温度 | 结果 |
|---|---|---|---|---|---|---|---|
| 正午晴 | | | | | | | |
| 正午阴 | | | | | | | |
| 正午雨 | | | | | | | |
| 午夜晴 | | | | | | | |

### B2 长时发热与降频

- 连续运行 **≥15 分钟**（含飞行 + 雨档 + 3D 座舱），记录起始 / 5 min / 10 min / 15 min 的帧率与机身温度。
- **判据**：不出现明显热降频（15 min 末稳定帧率相对起始下降 >20% 记为不通过）；无烫手、无系统过热弹窗、无崩溃。
- **如实说明**：项目**尚未记录 Draw Call / 内存峰值基线**，本次首测结果即作为后续对比基线，请完整填入上表。

### B3 若不达标：降级顺序（仅记录，不在本次改代码）

按「先减采样、再减粒子、最后关特效」记下哪一项最先恢复帧率，供后续开票：
① 云纹 512×256 → 256×128 / fractal_octaves 5 → 3；② `RAIN_AMOUNT` 240 → 120；③ 雨天关闭 `sky_cover`；④ 3D 座舱内装按设备档降级。

---

## C. 触屏 44 × 44 逻辑像素热区（P0）

> **判据来源**：ADR D-089 §6 已把关键入口统一改 44 px；`docs/decisions.md:4136/4143-4145/4321` 明确「**代码侧已改，真机可点性仍待目检**」。注意 44 px 是**逻辑像素**，请按 `canvas_items` 缩放后的实际尺寸判断，不是物理像素。

### C1 已改 44 的控件 —— 逐项用拇指实测可点性

| 控件 | 代码位置 | 设定值 | 结果 |
|---|---|---|---|
| 鱼类收集册关闭按钮 | `scripts/ui/fishing_collection_ui.gd:114` | `(44, 44)` | |
| 收集册领取按钮 ×2 | `fishing_collection_ui.gd:150, :196` | `(0, 44)` | |
| 渔具面板「收集册」入口 | `fishing_gear_ui.gd:142` | `(0, 44)`（`:140` 注释明确「触摸热区 ≥44px」） | |
| HUD 关闭按钮 | `hud.gd:2743` | `(0, 44)` | |
| 任务面板关闭 / 页签 | `quest_panel.gd:70, :336` | `(44, 44)` / `(0, 44)` | |
| 航海记录关闭按钮 | `sailing_journal_ui.gd:124` | `(44, 44)` | |
| 触屏「任务」按钮 | `hud.gd:761`（D-089 新增） | **76 × 76** | |

- **判据**：儿童拇指（约 8~10 mm）单指一次点中，10 次尝试误触/漏触 ≤1 次；相邻按钮不出现「一次按到两个」。
- **同时验证**：`UiKit.make_close()` **刻意未改**（7 个面板共用），热区由各调用方按需设置；请在共用它的面板上确认没有因此变小到难点。

### C2 仍低于 44 px 的控件 —— 记录是否构成实际障碍（不预判为 bug）

以下为一手核实的 `custom_minimum_size` 高度 <44 的控件（**静态事实，非缺陷结论**）。真机只需记录「是否难点/误触」，不要据此直接改代码：

| 文件:行号 | 尺寸 | 文件:行号 | 尺寸 |
|---|---|---|---|
| `bestiary_ui.gd:201` | 108×36 | `bestiary_ui.gd:228` | 0×34 |
| `bestiary_ui.gd:583` | 150×42 | `bestiary_ui.gd:944` | 0×40 |
| `build_screen.gd:335` | 110×40 | `fishing_gear_ui.gd:127/134/149` | 120×42 / 140×42 / 100×42 |
| `fishing_gear_ui.gd:263/284` | 240×38 | `fishing_gear_ui.gd:310` | 180×36 |
| `fishing_teaching_ui.gd:88/95` | 100×40 / 120×40 | `fishing_ui.gd:117/139/146` | 0×40 / 150×42 / 120×42 |
| `fishing_ui.gd:404/427` | 0×38 | `fishing_ui.gd:532` | 110×38 |
| `hud.gd:1757/2112` | 0×32 | `hud.gd:1818` | 320×36 |
| `hud.gd:2214/2241` | 56×40 | `hud.gd:2785` | 84×40 |
| `inventory_panel.gd:290/304` | 44×32 | `inventory_panel.gd:311` | 64×32 |
| `manual_panel.gd:197` | 150×40 | `map_selector.gd:303` | 150×34 |
| `map_selector.gd:763/771` | 140×42 / 96×42 | `map_selector.gd:917/924/931` | 96×40 |
| `mission_panel.gd:245/291` | 120×34 | `mission_panel.gd:327` | 90×32 |
| `profile_picker.gd:196` | 96×34 | `race_teaching_ui.gd:130` | 120×40 |

- **判据**：只把「实际点不中 / 反复误触 / 孩子放弃操作」的条目标为 ❌ 并写清控件名；其余标 ✅ 或「可点但偏小」。

### C3 竞速 / 飞行触屏层（均 ≥44，验证握持落点）

- `scripts/ui/race_hud.gd:24-30`：`TOUCH_MARGIN=24`、`TOUCH_GAP=12`、`TOUCH_STEER_SIZE=132`、`TOUCH_BRAKE_SIZE=132`、`TOUCH_HANDBRAKE_SIZE=104`、`TOUCH_ACTION_SIZE=(96,56)`；`layer=5`（`:75`）。
- `hud.gd:1034/1038` 偏航键 60×54、`:1048` 刹车 120×54；虚拟摇杆 `virtual_joystick.gd:7,18` `radius=60` → `custom_minimum_size=(144,144)`；视角区 `hud.gd:663` anchor `(0.35,0)-(1,1)`（右侧 65% 全高）。
- **判据**：横屏双手握持时拇指自然够得到左下转向 / 右下刹车+手刹；右上重开/退出不误触；转向与刹车同时按不冲突（见 D 组）。

---

## D. 多指与组合手势（P1）

- **必测组合**：① 左摇杆移动 + 右手划视角；② 飞行时油门/俯仰摇杆 + 偏航键 + 视角拖动；③ 竞速时转向 + 刹车/手刹同时按；④ 三指（误触第三根手指）不导致控制错乱。
- **代码依据**：`hud.gd:1581` 处理 `InputEventScreenTouch`、`:1586` 用 `event.index == _look_touch` 区分视角指；`flight_tactical_map.gd:341/344/349/364` 也消费 ScreenTouch / ScreenDrag；`race_hud.gd` 通过 `touch_input()` 输入快照交 `race_scene` 消费。
- **判据**：无「一根手指抬起导致另一根手指的控制被清零」、无视角突然跳到屏幕边缘、无控制粘连（松手后仍在加速/转向）。
- **如实记录**：静态阅读只能确认上述消费点存在；**多指冲突风险未做静态定性**，以真机结果为准。

---

## E. 字形回退（P1）

- **已知现象**：桌面截图已复现 `⛵` 显示成缺字方块（「黄色三角 + 字母 A」），ADR D-089 §6 与 `features/feature_sailing_journal.md:377` 均如实记录并归真机目检统一裁决。
- **一手核实**：`sailing_journal_ui.gd:111` 标题为 `"⛵ 我的航海记录"`，逐码点为 **U+26F5**（⛵）+ 中文，**不含 U+FE0F 变体选择符**；另一处 `fishing_gear_ui.gd:281` 为 `"⛵ %s"`（里程徽章标题）。
- **字体事实**：仓库内**无任何** `.ttf/.otf/.woff/.theme` 字体资产（D-020 零外部资产）；全库**未配置** `fallbacks` / `font_fallback` / `SystemFont` / `add_font_override`；UI 一律用 `get_theme_default_font()`（`flight_tactical_map.gd:1132`、`item_slot.gd:107/129`、`minimap.gd:146`），即依赖引擎内置默认字体。
- **待定性**：「黄色三角 + 字母 A」的图形来源**未定性**——不能断言是 `.notdef` 特殊变体还是 fallback 错映射。真机请记录实际形状。
- **判据**：① 桌面与 Android 各拍一张标题截图，记录是否都缺字、形状是否相同；② 缺字是否影响可读性（标题其余文字、布局、20:9 不裁切正常）；③ 一并目检其他 emoji 位置。
- **口径**：本批**不改字体方案、不扩大范围**；此项只是采集证据供后续统一裁决。

---

## F. 分辨率 / 倒计时 / 模态遮挡（P0）

### F1 两档比例下 HUD 与倒计时不遮挡

- 16:9（物理 1280×720，逻辑 1280×720）与 20:9（物理 1280×576，逻辑 **1600×720**）各测一遍。
- **重点控件**：`scripts/ui/race_hud.gd:150-155` 倒计时 Label 字号 **120**、`PRESET_FULL_RECT` + 水平/垂直居中、`mouse_filter=IGNORE`；`:159-166` 过线 banner `PRESET_CENTER_TOP` + `offset_top/bottom=86` + `custom_minimum_size=(460,56)`；`race_scene.gd:14` `COUNTDOWN_SECONDS=3.2`；`hud.gd:64` 教学层 `z_index=40`（盖最上）。
- **判据**：3-2-1 大数字不压住圈数 / 排名 / 车速 / 燃油条关键信息；banner 不与倒计时重叠；20:9 下顶部信息不被裁切；倒计时不吃触摸（`MOUSE_FILTER_IGNORE`）。
- **桌面窗口取证图**（本机 `tmp/`，gitignored）：`tmp/fishing_collection_16x9.png` / `_20x9.png`、`tmp/race_result_16x9.png` / `_20x9.png`、`tmp/sailing_journal_16x9.png` / `_20x9.png`。

### F2 安全区 / 刘海 / 挖孔屏

- 挖孔屏、刘海屏、系统手势条三种机型各看一次主 HUD、任务面板、竞速 HUD。
- **判据**：无控件被遮挡或落在手势条内；横屏 `orientation=4` 下左右安全区对称。
- **如实写**：静态配置中**未见**显式安全区处理代码，此项完全依赖真机观察。

### F3 空槽态 ProfilePicker 模态遮挡

- **首次安装 / 清空存档后**启动，观察「选择玩家档案」弹窗。
- **代码依据**：`scripts/main.gd:236` 条件 `(Profile.list_slots().is_empty() or Profile.needs_choice()) and DisplayServer.get_name() != "headless"` → `_hud.open_profile_picker()`；**只豁免 headless**，窗口/真机必弹。弹窗期间 `input_locked` 吞输入，浅色模态会遮挡画面像素（桌面证据 `tmp/flight_e2e_landed.png` 即被遮挡）。
- **判据**：真机上弹窗可正常关闭、关闭后输入立即恢复、无「关不掉」或「关了还吞输入」；弹窗本身不遮挡到无法选择槽位。
- **探针侧规避**（供对照，非真机步骤）：`tests/cockpit3d_shot.gd:88-92` 调用 `close_profile_picker()`，`:231-232` 有「取证时无模态遮挡」守卫断言。

### F4 3D 座舱与 2D 仪表带层级

- 飞行第一人称 / 第三人称 / 视角切换（C 键等价触屏按钮）各看一次。
- **判据**：两侧黑色梯形（2D `cockpit_instruments.gd` 的 `draw_colored_polygon`，**不是** 3D 未上色面）位置正确、不遮住中央天空；3D 内装 39 个盒体不侵入中线视野；2D 仪表带始终在最上层可读。
- **已知正确观感（勿误判为 bug）**：D-065 相机刚性吸附 `target.origin`；**3D 随相机抖而 2D 不抖**是设计如此。

---

## G. 几何基准 full 档正式重录（P1，桌面即可完成）

- **现状**：`tmp/chunk_mesh_baseline` 与 `tmp/chunk_mesh_baseline.new` 各 66 行（61 行有效输出）。D-091 后不覆盖式重录得 **13 行逐字节变化 / 11 个不同区块坐标**，全部归因 D-091；`_clear_approaches()` 不是成因。**旧基准保留未覆盖**，ADR D-091 §4 的「不影响主体地形区块」静态推断已被实测证伪并加订正注记。
- **待办**：full 档**正式重录**仍未做（不覆盖式 `.new` 不等于正式重录）。
- **判据**：正式重录后逐行归因，13 行变化仍可全部解释；出现第 14 行未解释差异即 ❌。
- 本项可在桌面完成，不必等真机；但按 ADR 口径仍列在「真机目检」待办组，故一并记录。

---

## H. 结果汇总

| 组 | 项目数 | ✅ | ❌ | ⚠️ 观察 | — 不适用 |
|---|---|---|---|---|---|
| A 天空与气象 | 6 | | | | |
| B 帧率 / 发热 | 3 | | | | |
| C 触屏热区 | 3 | | | | |
| D 多指 | 1 | | | | |
| E 字形回退 | 1 | | | | |
| F 遮挡 | 4 | | | | |
| G 几何基准 | 1 | | | | |

**总判定**：☐ 全部 P0 通过，可关闭真机目检待办　☐ 存在 P0 不通过，需开票（列出编号）　☐ 仅观察项，记录后关闭

**必须随结果附上的材料**：各档天空截图、雨天雨滴特写、两档比例 HUD 截图、字形标题特写、帧率/温度记录表、设备信息表、失败项复现步骤。

---

## 附：本清单明确不含的内容

- 自动化回归已覆盖项（75 探针 / 2941 PASS / 0 FAIL，D-093 §5），不重复目检。
- 存档隔离 / 背包落盘 / 钓鱼竞速数值等逻辑正确性。
- D-093 已裁决事项：README 不逐条同步视觉 ADR；`chunk_mesh_baseline` full 档正式重录仍列待办；`fog_density` 在 DEPTH 模式下仍参与计算（「惰性值」推论已被引擎实测证伪）；`fog_mode=1` 实为 DEPTH。
- 任何代码修改：本清单是**只读验收单**，产出结论后再决定是否需要开票。
