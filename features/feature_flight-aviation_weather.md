# Block Planet 飞行气象与特情处置开发任务书

项目：Block Planet ｜ 引擎：Godot 4.6 / GDScript
目标：在**已有气动模型**（D-030~D-035 `aircraft_flight.gd`）与**已有天气外观**（`day_night.gd`）之上，补齐航空气象的**物理耦合与决策玩法**，让风、积冰、能见度对飞行有真实影响，并配套儿童科普。

> **本文档性质：开发任务书（要做什么）。** 现状与数值事实以 `features/feature_flight.md` 为准；
> 代码是唯一事实来源，两者冲突时以代码为准并回头修订本文。

---

## 0. 开工前必读：与代码现状的三处冲突

本任务书初稿（AI 生成）假设若干系统不存在，**照抄会重复建设或破坏既有实现**。开工前必须知道：

| 初稿假设 | 代码现状（实测） | 本任务的正确做法 |
|---|---|---|
| 「结合已有的 AutoPilot」 | **不存在 AutoPilot**。只有 D-034「自动改平」（双击左键增强摆平增益，`aircraft.gd:93 LEVEL_ASSIST_TIME`） | 不要假设有自动驾驶。气象不引入自动驾驶；返航/备降若需自动飞，见 §6 用「目标点 + 现有 FlightDirector」实现 |
| 「创建 weather.json + WeatherSystem Autoload 管理气象」 | `day_night.gd` **已有 `enum Weather { CLEAR, CLOUDY, RAIN }`、`set_weather()`、`clear_weather_override()`、雨粒子 `_build_rain()`、`WEATHER_AMBIENT_MUL`** | **扩展 `day_night.gd` 的 Weather 枚举**，不新建平行的 WeatherSystem。气象的外观层（光/雨/云）已存在，本任务做的是**物理层耦合** |
| 「HUD 上绘制十字指引线做 ILS 盲降」 | **D-054 飞行指引十字已实现**（`flight_director.gd`，模式 `OFF/ROLL/TAKEOFF/APPROACH(≤400m)/CRUISE`，含 11 px/度导引律与三档配色） | 不重画十字。扩展它：在 `APPROACH` 模式叠加 RVR 判据——低能见度时把「指令十字」接管为盲降引导 |

另注：`day_night.Weather` 只有 3 档且**只影响环境光与雨粒子**，不涉及飞行物理。本任务的核心是把气象**接到气动上**。
**〔D-093 补注：三档天气的外观层（Sky 四色 / 程序化云纹 / 雨幕位置）已由 D-093 补齐；本任务书「只影响环境光与雨粒子 / 只有三档天气外观」为当时快照，物理层耦合的结论不变〕**

另注 2：本任务书 §1 的尺度前提已按 D-063 订正（1 格 = 1 m）。初版曾写过一版 0.5 m 旧尺度，**那一版的数值（含 `icing_alt_band [90,150]`、风切变「约 90 格」）全部作废**，以 §1 现行值为准。

---

## 1. 尺度前提（决定所有数值，先读）

初稿大量使用 km / 数百米高度，**与本作尺度不符，照抄会做出飞不到的东西**。且本任务书 §1 初版本身也写过一版旧尺度（1 格 = 0.5 m / 世界高 128 m / `LOAD_RADIUS=2`），**那一版已随 D-063 作废**，现行值如下：

- **1 格 = 1 m**（D-063 起，格与米数值直接相等，不要再乘 0.5）；世界总高 **256 格 = 256 m**（D-055）。
- 分层地形最高 **188 m**（青藏高原 / 喜马拉雅-昆仑雪脊，见 `features/feature_flight.md`）——**不是 94 m**，旧值差一倍，所有避让/云带高度按旧值算会直接埋进山体。
- 巡航高度典型 **50~90 m AGL**，不是「300 m」「1000 m」。
- **风切变触发高度**：初稿写「低于 300 m」在本作意味着全程都在切变层内。改为 **AGL < 45 m（即 45 格）**。
- 流式加载：高模 `LOAD_RADIUS = 4` 区块（64 m）+ 低模环 `LOW_RADIUS = 16` 区块（256 m）。世界是无限流式生成的，没有「地图边界」；但**超过低模环 256 m 就只有高度图粗网格**，气象可视距离（雾）的设计上限就在此。
- 战术地图视野 `RANGE_M = 180`，缩放 0.5~2× → 最远可视 **360 m**。
- **积冰云带必须按 188 m 地形重定**：旧稿 `icing_alt_band: [90, 150] 格` 在 0.5 m 尺度下是 45~75 m；按现行 1 m 尺度该区间会埋进青藏高原山体，云带应抬高到约 **[120, 200] 格**（地形最高 188 m 之上留出可结冰空间，又低于世界顶 256 m）。

---

## 2. 气象要素 → 气动耦合（核心机制）

每条都标注**接到 `aircraft_flight.gd` 的哪个量**。这是本任务的技术核心：不是加特效，是让气象真的改变受力。

### 2.1 风：地面风 + 高空风梯度

- **地面风（≥10 m AGL）**：**不改 `velocity`**。风作为独立矢量 `State.wind` 由 `WindModel` 每帧填入（D-067），气动唯一速度入口是 `air_velocity(state) = velocity − wind`（`aircraft_flight.gd:229`）。`velocity` 保持**地速**语义（质心对地），位置积分用 `velocity` 本身；升力/阻力/失速/操纵权限全部由相对气流的**空速**决定，故风只改变空速、不改任何气动公式——这正是 §2.2 的核心要求（直接改 `velocity` 会破坏气动自洽，定为红线，`wind_flight_probe` C3 钉死）。表现为：对地速度 = 空速 + 风；顺风地速 > 空速。
- **顺/逆风影响**：起飞滑跑距离、爬升率随之变化。**不要另写「滑跑距离公式」**——气动积分天然会产生这个现象，重复实现反而两套数打架。
- **侧风**：以偏流角体现——地速矢量与机头不一致。落地时机头对不齐会带着侧向速度接地，`_check_failure(impact)` 自然判解体。**蟹形进近因此是真实有效的技巧，不是脚本判定**。
- **风梯度**：风速随 AGL 从 0 线性增到高空值（约 3 倍）。这让「低空风弱、高空风强」自然成立。

### 2.2 风切变（最危险，也是最该做对的）

初稿说「瞬间改变 linear_velocity，空速骤降 20 节」——**这是错的**，直接改速度会破坏气动模型的自洽（升力由空速算，改速度等于作弊）。

正确做法：**只改变风矢量，制造空速与地速的突变**。
- 下降气流（downdraft）分量 `w` 突然加大 → 迎角增大 → 升力骤降 → 掉高度。
- 玩家应对：**推油门 + 改平姿态**。若已是低空，则复飞。
- 判定交给现有 `impact >= CRASH_DV` 与 `stall_changed` 信号，**不另写坠毁判定**。

### 2.3 积冰（icing）

- 暴露变量：`ice_level: float`（0..1）。
- **接到气动**：`CL_MAX` 乘以 `(1 - 0.35 * ice_level)`（冰污染翼型，降低最大升力系数）；`CD0_BASE` 加上 `0.05 * ice_level`（粗糙度增加阻力）。**同时改这两个量**，才是真实的积冰后果（升力降 + 阻力增 → 失速速度上升）。
  - ⚠️ 实施注意：`CL_MAX`（`aircraft_flight.gd:35`）与 `CD0_BASE`（`:42`）目前都是 **`const`**，且 `CL_MAX` 有 3 个直接调用点（`:240` 失速速度 / `:250` 与 `:298` 升力计算）、`CD0_BASE` 有 2 个（`:142` 聚合初值 / `:299` 阻力结算）。要么把二者改为可注入的气动参数，要么在各调用点统一乘冰系数——**只改定义不改调用点不会生效**。好消息：`lift_coefficient(alpha, cl_max)`（`:250`）本就支持传入 cl_max，接口是现成的。
- 质量增加：可选，小幅（燃油占比很小，不做也能玩）。
- 防冰（anti-ice）：`ice_level` 以 0.02/s 消退；开启防冰本身有耗电/燃油代价，避免「无脑开着」。
- **进入结冰条件的判据**：云层高度带 + 气温低于冰点 + 有降水。三者缺一不可，否则大晴天结冰会显得莫名其妙。注意 `day_night.gd` **没有云层高度概念**（只有三档天气外观），云带参数要随 `weather_profile.icing_alt_band` 新建。
**〔D-093 补注：三档天气的外观层（Sky 四色 / 程序化云纹 / 雨幕位置）已由 D-093 补齐；本任务书「只影响环境光与雨粒子 / 只有三档天气外观」为当时快照，物理层耦合的结论不变〕**

### 2.4 能见度与 RVR

- **白屏/雾**：本任务要做的仍是**物理层耦合**——让 `Environment.fog_density` 随能见度 / RVR 动态变化（当前为静态值）。路径走 `day_night.setup_environment(env)`。**现状已非初稿假设的空钩子**（旧文写「只存 `_env` 引用、全库 `fog_` 零命中、`scenes/main.tscn:11` 从未设置任何雾参数」，双重过时，订正如下）：D-090 已在 `scenes/main.tscn:17-20` 落 `fog_enabled=true` / `fog_mode=1`(DEPTH) / `fog_density=0.004` / `fog_aerial_perspective=0.35`；D-093 已把 `setup_environment()` 填成运行时构造 Sky（`BG_SKY` + `ProceduralSkyMaterial` + 云纹 + `fog_sky_affect=0.0`）。源码行号已漂移、不再写死。本任务在既有雾参数之上**追加按能见度调制**（`fog_density` / `fog_light_color` 每帧回读 `_env.background_color`，与 D-065 拍摄口径同源），不是从零新建雾配置。**绝不开 `volumetric_fog_enabled`**——Mobile 渲染器直接拒绝（已实测）。雾密度参考值 **0.004~0.005**（256 m 低模环边界约 100 px 过渡带；判雾看地平线外缘，不看近处景物）。
- **盲降**：RVR < 决断高度时，扩展 D-054 指引十字——命令十字接管为盲降引导（**不新增 UI**）。
- 偏离过大触地 → 现有 `CRASH_IMPACT_DV = 7.0`（`aircraft.gd:41`）判解体。**不另写「偏离则坠毁」脚本判定**。

### 2.5 密度高度

**这条初稿低估了**：`aircraft_flight.gd` 已有完整的密度模型（`SEA_LEVEL_DENSITY`、`DENSITY_SCALE_HEIGHT`、`THRUST_DENSITY_EXPONENT`）。密度高度**已经是仿真的一部分**，气象只需把气温/气压喂进去，不要另写一套公式。

### 2.6 雷暴与颠簸

- **雷暴 = 空中禁区**：进入即弹决策面板（§4），不做「飞进去打雷」的真实模拟——儿童向且安全。
- **颠簸**：给机体施加随机的力扰动（±X m/s² 级），**只扰动速度，不直接改位置**（保持物理自洽）。相机抖动是表现层。

---

## 3. 气象数据（挂在已有天气系统上，不新建 json）

初稿的 `weather.json` 与 `day_night.gd` 的 Weather 枚举职责重叠。改为**扩展枚举 + profile 配置**：

```gdscript
# day_night.gd 的枚举扩展为：
enum Weather { CLEAR, CLOUDY, RAIN, FOG, SNOW, THUNDERSTORM, WIND_SHEAR, ICING }
```

气象的**物理参数**挂在区域 profile（`region_atlas.gd`，与 `flat_zones` 同级），而不是独立 json：

```
"weather_profile": {
    "fog_density_clear": 0.0,
    "fog_density_fog": 0.08,
    "surface_wind_mps": 3.0,
    "shear_probability": 0.0,     # 非洲/大洋高，山地低
    "icing_alt_band": [120, 200]  # 格（D-063 尺度，详见 §1）
}
```

理由：气象要**按区域**不同（青藏高原易积冰、大洋易雷暴），这正是 region_atlas 已有职责（现有字段只有 `climate` 文案与 `sky` 色调，物理参数是**新建**）；新建 json 会与它脱钩。

> ⚠️ **与现状轮换机制的关系**：`day_night.gd` 现有一套 150 s 固定序列自动轮换（`WEATHER_CYCLE` 6 槽 + `WEATHER_SLOT`）+ `set_weather()` / `clear_weather_override()` 手动覆盖。本任务的「按区域 profile 概率触发」是**替换**自动轮换，不是平行新增。实施时必须：
> 1. **保留 override 机制**——`cockpit3d_shot` 等多处取证探针依赖 `set_weather(CLEAR)` 钉住天气（防 150 s 槽边界换档让整屏像素漂移），删了会打穿窗口档。
> 2. `set_weather()` 内的 `clampi(w, Weather.CLEAR, Weather.RAIN)` 上限**写死了 RAIN**：枚举扩到 8 档后不改这行，FOG/SNOW/THUNDERSTORM 会被静默夹成 RAIN（D-066 在 `landmarks_of` 踩过同类 `clampi` 伪装 bug）。
> 3. 扩展后 `WEATHER_NAMES` / `WEATHER_AMBIENT_MUL` / `WEATHER_SUN_MUL` 三张字典要为每个新档补条目（字典缺键会直接崩）。
> 4. 现有 `tests/weather_probe.gd`（22 PASS，D-093 后）覆盖三档枚举与 override，扩展后需同步补断言，不要打穿。

---

## 4. 特情决策（保留初稿设计，这部分立意好）

初稿的「遇恶劣天气 → 暂停 → 四选一（强飞/返航/备降/迫降）」是**儿童向教学的核心，保留**。

- **触发**：`is_illegal_to_fly = true`（进入雷暴 / 严重积冰 / RVR 超标）。
- **四选项结算**（初稿表格可用，补充本作落点）：
  - **返航 / 备降**：设 `set_navigation(机场坐标)`，玩家用 D-054 指引十字自己飞回去。**不做自动飞行**（无 AutoPilot）。
  - **迫降**：玩家手动找平地，接地速度过大则解体（现有判定）。
  - **强飞**：不改变任何力，只维持恶劣气象 → 大概率解体。
- **面板是 `pause` + Control 覆盖层**，复用现有 HUD 弹层模式。

---

## 5. METAR 简报（保留初稿设计）

初稿的「真实报文 + 大白话翻译」双栏是**最佳教育设计，完整保留**。仅调整：

- 报文数值必须**由当前实际气象生成**（风速/能见度/云底高取自当天气象状态），不能写死示例值。
- 海拔/气压字段按本作尺度给。

---

## 6. 开发 Checklist

- [ ] 扩展 `day_night.Weather` 枚举到 8 档，各档配 `_apply_lighting` 与雨/雪粒子表现。
- [ ] 同步三张字典 `WEATHER_NAMES` / `WEATHER_AMBIENT_MUL` / `WEATHER_SUN_MUL` 补全 8 档条目（缺键直接崩）；**`set_weather()` 的 `clampi` 上限从 `Weather.RAIN` 改为枚举末档**（否则新档被静默夹成 RAIN）。
- [ ] 保留 `set_weather()` / `clear_weather_override()` 覆盖机制（`cockpit3d_shot` 等取证探针依赖）；按区域概率的状态机**替换** 150 s 固定轮换，不平行新增。
- [ ] 气象状态机：随机剧本触发（按区域 profile 概率），对外暴露 `current_weather()` / `wind_at(agl)` / `visibility_m()`。
- [x] 风接入 `aircraft_flight.gd`：地面风 + 风梯度，只改速度不改升力；叠加时机在积分前。**（D-067 已实施：`State.velocity` 保持地速度语义，新增 `State.wind`，`air_velocity() = velocity − wind` 为气动唯一速度入口——动压/攻角/侧滑/升力/阻力/失速判定全部改读空速；位置积分仍用 `velocity`。风模型 `scripts/flight/wind_model.gd`，区域数据在 `RegionAtlas.weather_profile`。）**
- [x] 风切变：只改风矢量（含 downdraft 分量），靠现有失速/impact 判解体。**（D-067 已实施：8 s 瞬态剧本 = 风向急转 ±60~120° + 强度 ×2.5 + 下沉 ≤6 m/s；AGL < 45 m 低空门控 + 60 s 冷却 + 登机 20 s 静默；种子可复现。**不改 `velocity`** 是红线——`wind_flight_probe` C3 钉死。）**
- [ ] 积冰：先把 `CL_MAX` / `CD0_BASE` 从 const 参数化（3+2 个调用点），再接 `ice_level`；结冰判据 = 云带 ∩ 低温 ∩ 降水（云带高度参数新建）。
- [ ] 雾/能见度 → 在既有雾参数之上做物理层耦合（D-090 已在 `scenes/main.tscn:17-20` 落 `fog_enabled=true` / `fog_mode=1`(DEPTH) / `fog_density=0.004` / `fog_aerial_perspective=0.35`，D-093 已把 `setup_environment()` 填成构造 Sky + `fog_sky_affect=0.0`，**不再是空钩子 / 全库无 `fog_` 设置**）；按能见度调制 `fog_density`（禁 `volumetric_fog`，密度 0.004~0.005）；低 RVR 接管 D-054 指引十字为盲降。
- [ ] 密度高度：把气温/气压喂进现有密度模型（`air_density()` `:234`），不另写公式。
- [ ] 雷暴禁区 + 颠簸扰动（只扰速度）。
- [ ] 决策面板（强飞/返航/备降/迫降），返航备降走 `set_navigation` + 指引十字。
- [ ] METAR 简报 UI：报文数值取自实际气象状态。
- [ ] 科普卡片：每次特情后展示对应知识点（复用现有成就/教学弹层模式）。
- [x] **探针（第一批：风两层）**：新增 `wind_flight_probe`，40 条覆盖风梯度/侧风偏流/空速地速分流/切变掉高度与推油门改出/区域数据与接线/设置开关，`SaveGuard.snapshot()/restore()` 全路径（D-010）。**（后续批次：积冰改气动/低 RVR 接管十字/决策面板四态并入同一探针或扩展，命名以代码为准。）**
- [ ] **回归保护**：不得打穿现有 `weather_probe`（22 PASS，D-093 后）、`night_shot`（昼夜取证）与所有钉 `set_weather(CLEAR)` 的窗口截图探针。

## 7. 验收标准

- [x] 起降能感到逆风/顺风的差别（滑跑距离肉眼可见不同）。**（模型级已验证：同空速下顺风地速大、逆风地速小，1 s 位移差可测——`wind_flight_probe` B1/B2。窗口级目检随 full 档取证。）**
- [x] 风切变触发时飞机掉高度，**推油门能改出**，不推则解体。**（模型级已验证：`wind_flight_probe` C1/C2——同剧本同 15 s 窗口唯一变量为油门，怠速侧掉高 68.9 m 且空速崩，满油门侧空速改出、切变后下沉收敛、同窗口少掉 12.9 m。「不推则解体」= 低空掉高度坠地触发现有 impact 判定，随窗口取证确认。）**
- [ ] 积冰后仪表能看出速度异常/失速告警，防冰开启后恢复。
- [ ] 恶劣天气弹决策面板，选「返航」后指引十字指向机场且能飞回去。
- [ ] 低能见度下靠指引十字完成盲降。
- [ ] 全量回归 0 FAIL 0 SCRIPT ERROR，`user://` 零 DIFF（D-010）。
- [ ] 既有 `weather_probe`（22 PASS，D-093 后）/ `night_shot` / 所有钉 `set_weather(CLEAR)` 的窗口截图探针不打穿；气象扩展后 `weather_probe` 断言数只增不减。