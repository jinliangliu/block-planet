Block Planet 启动流程与模块架构设计文档
项目：Block Planet
模块：启动流程、World Selector、城市选择、无缝加载
目标：明确从打开游戏到角色出生在具体城市的完整链路，划分各模块的职责与层级归属。

> **⚠️ 本文档性质：早期概念稿（已被后续文档取代，勿按本文施工）**
> 本文写于架构定型前，其中的模块命名与数据流**大多未按此实现**：现行事实来源是
> `features/feature_Map System Architecture.md`（D-066 已回订，含「文档术语 ↔
> 代码实体」对照表）与代码本身。主要偏差：① 不存 GameManager / DataManager /
> AudioManager / SaveManager 四个 Autoload（实际 Autoload 只有 Events /
> GameState / Progress / BestiaryData / FishingSystem / RaceSystem /
> BoatSystem）；② 无 regions.json 与「上海」城市坐标——出生区域由
> `GameState.current_region`（区域 id，非坐标）+ `RegionAtlas` 承担，落点由
> `main` 在运行时按机场/降落场/村庄空场计算；③ 无 BriefingUI / METAR /
> 穿云动画——现状是区域介绍页 + 出生加载屏（`SpawnLoading`）；④ 地球是
> `MapGlobe`（顶点色球面网格，只转不缩放），不是写实贴图球。
> 本文保留价值：启动五步流程的**形态描述**与 §5 checklist 的模块划分思路。

一、 核心流程时序图
text
启动游戏
  ↓
[1. 初始化阶段] -> 加载全局单例 (GameManager, DataManager)
  ↓
[2. 星球与地域选择器] -> 展示 3D 地球 (WorldSelectorUI)
  ↓ (玩家操作：拖拽 -> 放大亚洲 -> 点击中国 -> 放大长江三角洲)
[3. 城市简报面板] -> 选中“上海”，展示气象、地形、图鉴 (BriefingUI)
  ↓ (玩家操作：点击“在此着陆”)
[4. 过场与加载] -> 地球急速放大穿云，后台加载体素区块 (LoadingScreen)
  ↓
[5. 游戏内] -> 角色降生在机场，恢复玩家控制 (InGameWorld)
二、 模块划分与层级归属
在 Godot 4.6 工程中，建议将模块按“全局单例（Autoload）”、“UI层（CanvasLayer）”、“3D场景层（Node3D）”和“数据层（Resource/JSON）”进行划分。

1. 全局系统层 (Autoload 单例)
负责跨场景的数据流转和状态管理。

模块名	职责说明	依赖关系
GameManager	游戏总控。负责场景切换、暂停状态、全局变量维护（如当前玩家坐标）。	无
DataManager	数据读取。负责加载 regions.json、weather.json 等静态数据。	无
AudioManager	音频控制。负责 BGM 切换（启动时大气音乐 -> 游戏中环境音）。	无
SaveManager	存档系统。读取玩家的探索进度、已解锁城市。	无
2. UI 与控制层 (CanvasLayer)
负责启动流程中的界面展示和用户交互。

模块名	层级/场景	职责说明
BootScreen	CanvasLayer	启动 Logo、健康游戏忠告、加载进度条。
WorldSelectorUI	CanvasLayer	核心选服界面。包含以下三个子模块：
└ Earth3DView	SubViewport	渲染 3D 地球模型，处理相机的旋转、缩放。
└ RegionLayer	Control	处理 3D 地标 Pin 的 2D 映射、UI 悬浮卡片。
└ BriefingPanel	Control	玩家选中城市后弹出的信息确认面板（含气象、地形图）。
LoadingScreen	CanvasLayer	过场加载遮罩。播放穿云动画，展示科普小提示。
3. 3D 场景层 (Node3D)
负责游戏内的三维世界。

模块名	层级/场景	职责说明
EarthModel	Node3D	启动界面中的 3D 地球球体（高模、带贴图和云层）。
InGameWorld	Node3D	游戏主体场景。包含地形、河流、体素区块加载器。
VoxelTerrain	GridMap / 自研	128km 世界的体素地形系统。
Player	CharacterBody3D	玩家角色（带控制器、相机）。
三、 详细步骤说明
步 1：启动与初始化 (Boot)
动作：玩家双击游戏图标。

表现：显示 Logo，DataManager 开始解析本地 JSON 数据，EarthModel 开始异步预加载。

模块交互：BootScreen 监听加载进度，完成后调用 GameManager.change_to_world_selector()。

步 2：星球与地域选择 (World Selector)
表现：屏幕中央出现缓缓自转的 3D 地球，UI 大字提示“探索星球”。

交互：

玩家滚动滚轮/双指捏合，相机向地球拉近。

Earth3DView 根据相机距离动态调整 LOD（拉近时，平滑地球贴图变为体素浮雕）。

当视图聚焦到中国区时，RegionLayer 通过 camera.unproject_position() 在“上海”的 3D 坐标上绘制一个发光图钉（Pin）。

模块交互：玩家点击 Pin，触发 RegionLayer 发送 city_selected(city_data) 信号给 WorldSelectorUI。

步 3：城市简报 (Briefing)
表现：弹出 BriefingPanel 半透明面板。

内容：

标题：上海 (Shanghai)

地形预览：一张局部的微缩 3D 地图。

气象简报：联动 METAR 系统：“当前气温 22℃，东南风 3 级，适合飞行”。

解锁状态：如果未解锁，提示“需要完成前置任务”。

交互：玩家点击【在此着陆】。WorldSelectorUI 将 city_data.position 存入 GameManager，并触发加载。

步 4：过场与区块加载 (Transition)
表现：3D 地球镜头急速俯冲，穿过云层，屏幕短暂白屏（LoadingScreen 遮罩）。

后台：

卸载 WorldSelectorUI 释放内存。

InGameWorld 场景实例化。

地形生成器读取 GameManager 中的出生点坐标，优先加载该坐标及其周围的 16x16 体素区块（Chunks）。

步 5：进入游戏 (In-Game)
表现：白屏淡出，玩家发现自己站在上海机场的跑道上，周围是方块搭建的城市。

模块交互：Player 节点的 global_position 被设为 GameManager.spawn_point。游戏控制权交还给玩家（WASD 或虚拟摇杆）。

四、 核心数据结构定义
regions.json 示例（供 DataManager 和 RegionLayer 使用）：

json
{
  "cities": [
    {
      "id": "shanghai",
      "name_zh": "上海",
      "name_en": "Shanghai",
      "lat_lon": [31.23, 121.47],
      "world_pos": [15000, 64, 20000], 
      "region": "asia_china",
      "unlocked_by_default": true,
      "terrain_type": "coastal_city",
      "has_airport": true,
      "airport_id": "airport_shanghai"
    }
  ]
}
(注：world_pos 是预先算好的该城市在 128km 体素世界中的绝对坐标，方便 WorldSelectorUI 直接读取)

五、 给 AI 智能体的开发指令 (Checklist)
请按以下顺序实现启动流程：

□ 实现 GameManager (Autoload)：包含 spawn_point 变量，以及 change_scene() 方法。
□ 实现 WorldSelectorUI 场景：
□ 包含一个 Camera3D 和 EarthModel（球体）。
□ 编写 OrbitCamera 脚本，实现拖拽旋转和滚轮缩放。
□ 实现地标映射系统：
□ 创建 RegionLayer，编写 _process 循环，使用 camera.unproject_position() 将城市的 3D 坐标转为屏幕 2D 坐标。
□ 生成对应的图钉 UI 节点，并跟随屏幕坐标移动。
□ 实现 BriefingPanel：
□ 接收点击事件，展示城市信息。
□ 【在此着陆】按钮绑定 GameManager.spawn_point = city_data.world_pos。
□ 实现加载过渡：
□ 使用 SceneTree.change_scene_to_file("res://scenes/main.tscn") 切换场景。
□ 确保 Player 生成时，读取并应用 GameManager.spawn_point。
□ 性能要求：在 WorldSelectorUI 销毁时，必须清理 EarthModel 的材质和贴图，防止内存泄漏。
六、 验收标准
游戏启动后，不能直接进入空荡的 3D 世界，必须停留在地球选择界面。

地球可以流畅旋转和放大，放大到中国区时不会卡顿。

鼠标悬停或点击“上海”的 Pin 时，能弹出正确的城市简报。

点击开始后，加载过程有防穿帮的 UI 遮罩。

进入游戏后，玩家确实出生在上海对应的坐标点，而不是 (0,0,0)。

模块之间通信（如点击 Pin 传数据给 Panel，Panel 传数据给 GameManager）严格使用信号（Signals），避免代码硬耦合。


