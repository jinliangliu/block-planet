# Block Planet 地图系统架构与 UI 命名规范设计文档

> 项目：Block Planet  
> 引擎：Godot 4.6 / GDScript  
> 模块：UI/UX 架构、地图系统、全局状态管理  
> 目标：明确“启动地球”与“游戏内地图”的定位差异，规范代码命名，优化玩家从选择出生地到进入无缝大世界的体验流程。

---

## 1. 概念界定与层级对比

在游戏开发中，“地图”一词极易产生歧义。对于《Block Planet》这种无缝体素沙盒游戏，我们需要严格区分以下三种界面：

| 界面 | 玩家视角的称呼 | 严格开发术语 | 核心功能 | 视觉表现 |
| :--- | :--- | :--- | :--- | :--- |
| **启动时的地球** | 世界沙盘 / 选服界面 | **世界选择器 (World Selector)** | 决定出生点、选择剧本、加载对应区块坐标 | 3D 旋转地球，逐级放大洲-国-城市 |
| **游戏内按 M** | 国家地图 / 大地图 | **世界地图 (World Map / In-Game Map)** | 查看当前位置、航点导航、地标打卡、迷雾解锁 | 俯视视角的 2D/3D 局部地图 |
| **驾驶舱内** | 导航雷达 / MFD | **战术地图 (Tactical Map / Minimap)** | 实时导航、偏航距离、气象雷达 | 飞行员仪表盘上的小屏幕或 HUD 角落 |

---

## 2. 设计逻辑解析：为什么启动界面是“世界选择器”？

“地图选择器（Map Selector）”通常用于传统关卡制游戏（如选择独立的地图文件）。但在本项目中，整个世界是无缝的 128km × 128km 大世界。

启动时的地球，是为了让玩家**选择从地球的哪个坐标（经纬度）开始游戏**。选中“亚洲-中国-上海”，系统只是将玩家的 `spawn_position` 设定在这个坐标点，而不是加载一张叫“上海”的独立地图。因此，定义为 **世界选择器（Region Selector）** 最为严谨。

---

## 3. UI/UX 体验流程设计

为了让玩家（尤其是儿童）不感到困惑，地图系统的操作流程设计如下：

### 第一步：启动游戏（地域选择）
- **界面标题**：显示“**探索地球**”。
- **操作**：旋转地球 → 点击“亚洲” → 镜头拉近，显示中国区域 → 点击“中国” → 点击“上海” → 弹出【在此处开始游戏】和【出生地气象简报】（联动 METAR 系统）。

### 第二步：进入游戏（过场动画）
- 点击开始后，地球急速放大，云层穿过屏幕，城市或区域的地标逐渐显现，无缝过渡到第一人称/第三人称视角，玩家发现自己站在了机场或城市的出生点。
- 此过程释放内存中的地球高模，开始加载 3D 体素区块。

### 第三步：游戏中按 M（游戏内地图）
- **动态切换**：如果在国内，按 M 看到的是一张展开的“中国区域导航图”；如果玩家开着飞机跨越了太平洋，按 M 看到的就是整个地球的缩略图。
- **交互**：支持缩放、拖动、标记自定义航点、查看已探索迷雾。

---

## 4. 代码架构与命名规范（给 AI 智能体的指令）

为了避免开发时产生歧义，请严格按照以下规范进行代码架构设计与场景命名：

### 4.1 核心场景与脚本命名
1. **`WorldSelectorUI`（世界世界选择器）**
   - 启动游戏时加载的 3D 地球场景（`scenes/ui/world_selector_ui.tscn`）。
   - 负责经纬度映射、旋转缩放、出生点选择。
   - 核心方法：`lat_lon_to_world()`、`start_game_at(position: Vector3)`。
2. **`InGameWorldMapUI`（游戏内世界地图）**
   - 游戏中按 `M` 唤出的界面（`scenes/ui/in_game_world_map_ui.tscn`）。
   - 负责展示玩家当前坐标、航点、迷雾信息。
   - 核心方法：`set_player_position()`、`add_custom_waypoint()`。
3. **`TacticalRadar`（战术雷达）**
   - 飞行器座舱 MFD 或屏幕右下角的实时导航小地图（`scenes/ui/tactical_radar.tscn`）。
   - 只读，不可拖动，显示实时气象与偏航距离。

### 4.2 数据流转与管理
- 创建全局单例 `MapManager` (Autoload)。
- 当玩家在 `WorldSelectorUI` 确认出生点时，调用 `MapManager.set_spawn_point(coords)`。
- 游戏主场景加载时，读取 `MapManager.get_spawn_point()`，将 `Player` 节点实例化到该坐标。
- 按下 `M` 键时，`InGameWorldMapUI` 从 `MapManager` 获取当前玩家坐标，实时更新自身 UI。

```gdscript
# MapManager.gd (Autoload)
extends Node

var selected_spawn_coords: Vector3 = Vector3.ZERO
var current_player_position: Vector3 = Vector3.ZERO

func set_spawn_point(coords: Vector3) -> void:
    selected_spawn_coords = coords

func get_spawn_point() -> Vector3:
    return selected_spawn_coords
```

---

## 5. 验收标准
 
□ 游戏启动后，必须显示 WorldSelectorUI，且无法直接进入游戏。
□ 玩家在地球上点击后，能正确通过坐标映射算法获取 3D 世界坐标。
□ 点击“开始游戏”后，有平滑的缩放过场动画。
□ 玩家出生点与在地球上选择的坐标一致。
□ 游戏中按 M 唤出的是 InGameWorldMapUI，且显示玩家当前位置。
□ 飞行模式下，HUD 上的 TacticalRadar 能正确指引下一个航点。
