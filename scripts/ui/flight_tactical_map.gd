class_name FlightTacticalMap
extends CanvasLayer
## 飞行战术地图：飞行中按 M 唤出的全屏俯视 overlay（儿童友好）。
##
## 分工（与 HUD 飞行仪表互补）：仪表回答「现在飞得怎么样」，本地图回答
## 「我在哪、目标在哪、机场在哪」。打开不影响飞行——只读世界与飞机状态，
## 不写任何东西；本机图标每帧跟随 XZ，地形在打开时一次性采样并缓存。
##
## 集成契约（主理人按此接线，签名一字不差）：
##   signal map_closed
##   func open_map(craft: Aircraft, mission_mgr: Node, world: Node) -> void
##   func close_map() -> void
##   func is_open() -> bool
##   func process_map(delta: float) -> void
## mission_mgr 允许为 null（无任务时不画目标）；传 MissionPanel 这类节点时会
## 自动取其内部 MissionManager（见 _mission_manager），也可传任何暴露
## mission / status 的对象。
##
## 性能约定：
##   - 打开时一次性采样：33×33 粗网格（±180 m，近处读真实方块、远处用与
##     World 同源的噪声估算，不依赖区块加载）+ 25×25 细扫（±48 m，只用于
##     识别 COBBLESTONE 跑道簇）。之后 _draw() 只画缓存数据，零世界查询。
##   - 每帧零分配：draw_* 全部用值类型；多边形点阵预先分配、按下标回填；
##     文字仅在整数读数变化时才重新格式化。
##   - 本机飞出缓存范围（>130 m）才以本机为中心重新采样一次。
##
## 鼠标处理：打开时切 MOUSE_MODE_VISIBLE（触屏设备跳过），关闭时恢复原状；
## 地图画布吞掉滚轮与点击，避免缩放地图时连带转动飞行视角。

## 渲染层：压在 HUD（默认层 1）与各类面板之上。
const MAP_LAYER := 20
## 采样网格：33×33 覆盖 ±180 m（格距 11.25 m）。
const GRID_CELLS := 33
const RANGE_M := 180.0
const STEP_M := RANGE_M * 2.0 / float(GRID_CELLS - 1)
## 近处真实方块扫描半径（m）：此范围内读已加载区块的真实顶面方块，
## 之外用噪声估算（与 World._block_at 同源判据，不依赖区块是否加载）。
const DETAIL_M := 45.0
## 跑道细扫：±48 m、步长 4 m（覆盖 World.LOAD_RADIUS 的已加载范围），
## 只挑 COBBLESTONE 顶面簇，用来定位机场 / 降落场标记。
const RUNWAY_SCAN_M := 48.0
const RUNWAY_STEP_M := 4.0
## 本机偏离缓存中心超过该距离即重新采样（m）：留约 50 m 图内余量。
const RECENTER_M := 130.0
## 缩放范围与步长（滚轮按比例、按钮按步长）。
const ZOOM_MIN := 0.5
const ZOOM_MAX := 2.0
const ZOOM_STEP := 0.25
const ZOOM_WHEEL_RATIO := 1.15
## 遥测刷新间隔（秒）：与 Aircraft.READINGS_INTERVAL 同频，避免每帧 new。
const READINGS_INTERVAL := 0.1
## 高度着色归一化区间（格）：地形基准 27±13、海平面 22。
const HEIGHT_LO := 14.0
const HEIGHT_HI := 40.0
## 地形色块不透明度。
const TERRAIN_ALPHA := 0.94
## 底部信息条高度与外边距（屏幕坐标，供比例尺避让）。
const BOTTOM_PANEL_H := 122.0
const BOTTOM_MARGIN := 12.0
## 比例尺候选米数：挑一个让像素长度落在 50~150 的整数刻度。
const SCALE_CANDIDATES := [50.0, 100.0, 200.0, 500.0, 1000.0]
## 聚类四邻域（跑道细扫用）。
const NEIGHBORS4 := [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]

## 底色与面板：半透明深色 + 高对比，压在任何画面上都读得清。
const BG_COLOR := Color(0.04, 0.06, 0.10, 0.86)
const PANEL_BG := Color(0.07, 0.10, 0.15, 0.84)
const PANEL_BORDER := Color(1.0, 1.0, 1.0, 0.30)
const TEXT_HI := Color(1.0, 1.0, 1.0, 0.98)
const TEXT_DIM := Color(1.0, 1.0, 1.0, 0.80)
## 信息条四项读数各配一个颜色，扫一眼就能分区。
const COLOR_ALT := Color(1.0, 1.0, 1.0, 0.96)
const COLOR_SPD := Color(0.62, 0.86, 1.0)
const COLOR_THR := Color(1.0, 0.83, 0.42)
const COLOR_DST := Color(0.58, 0.90, 0.55)
const TARGET_COLOR := Color(1.0, 0.80, 0.30)
const OWN_INK := Color(0.04, 0.06, 0.10, 0.95)
const RUNWAY_INK := Color(0.16, 0.17, 0.20, 0.88)
const BLOCK_FALLBACK := Color(0.52, 0.52, 0.55)


## 机场 / 降落场标记（采样期一次性算出，绘制期只读）。
class RunwayMark extends RefCounted:
	var center := Vector2.ZERO
	var len_m := 0.0
	var wid_m := 0.0
	## 长轴方向（世界 XZ 平面：x 为东西、y 为南北；绘制期经
	## _draw_runways 转屏幕轴向，z 取负使北在上）。
	var axis := Vector2(1.0, 0.0)
	var is_airport := false
	## 预分配的旋转矩形点阵（4 点），绘制期按下标回填，零分配。
	var quad := PackedVector2Array()

	func _init() -> void:
		quad.resize(4)


signal map_closed

var _root: Control
var _map_canvas: Control
var _bottom_panel: PanelContainer
var _stat_alt: Label
var _stat_spd: Label
var _stat_thr: Label
var _stat_dist: Label
var _legend_label: Label
var _zoom_label: Label
var _close_button: Button

var _open := false
var _craft: Aircraft = null
var _mission_mgr: Node = null
var _world: World = null
## 打开前的鼠标模式（关闭时恢复；飞行中通常是捕获模式）。
var _prev_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_VISIBLE

## 缓存中心（世界 XZ）与地形采样结果：平行数组，_draw 只读不写。
var _center := Vector2.ZERO
var _own := Vector2.ZERO
var _heading := 0.0
var _zoom := 1.0
var _cell_pos := PackedVector2Array()
var _cell_color := PackedColorArray()
var _runways: Array[RunwayMark] = []

## 任务目标（_resolve_target 维护；CIRCUIT 取末航点、LANDING 取降落区）。
var _target := Vector3.ZERO
var _has_target := false
var _zone_radius := 0.0
var _waypoints: Array[Vector3] = []
var _target_sig := ""
var _target_dist_shown := -1
var _target_label_text := "目标"

## 帧间状态。
var _readings_timer := 0.0
var _dirty := true
var _last_size := Vector2.ZERO
## 双指捏合：活动触摸索引（≤2）+ 各触摸位置 + 上次指距。
var _pinch_idx: Array[int] = []
var _pinch_pos := {}
var _pinch_dist := 0.0
## 绘制变换（_draw_map 每帧据画布尺寸重算，供各图层共享）。
var _anchor := Vector2.ZERO
var _ppm := 1.0
var _view_size := Vector2.ZERO
var _scale_nice := 0.0
var _scale_label_text := "100 m"
## 预分配多边形点阵（每帧按下标回填，禁止 _draw 里 new）。
var _own_tri_dark := PackedVector2Array()
var _own_tri_light := PackedVector2Array()
var _arrow_tri := PackedVector2Array()
var _north_tri := PackedVector2Array()


func _ready() -> void:
	layer = MAP_LAYER
	visible = false
	# 三角点阵预分配（外深内白 + 复用箭头 + 罗盘北针）。
	_own_tri_dark.resize(3)
	_own_tri_light.resize(3)
	_arrow_tri.resize(3)
	_north_tri.resize(3)
	_build_ui()


## 打开地图：采样并缓存地形，随后由主理人每帧调用 process_map。
func open_map(craft: Aircraft, mission_mgr: Node, world: Node) -> void:
	if craft == null or world == null:
		return
	var w := world as World
	if w == null:
		return
	_craft = craft
	_mission_mgr = mission_mgr
	_world = w
	_prev_mouse_mode = Input.mouse_mode
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_open = true
	visible = true
	_zoom = 1.0
	if _zoom_label != null:
		_zoom_label.text = "1.0×"
	_pinch_idx.clear()
	_pinch_pos.clear()
	_pinch_dist = 0.0
	var pos: Vector3 = craft.global_position
	_center = Vector2(pos.x, pos.z)
	_own = _center
	_heading = _craft_heading(craft)
	_last_size = _map_canvas.size
	_sample_all()
	_target_sig = ""
	_target_dist_shown = -1
	_resolve_target()
	_refresh_readings()
	_dirty = true
	_map_canvas.queue_redraw()


## 关闭地图：恢复鼠标模式并广播 map_closed（飞行不受影响，继续滑行/巡航）。
func close_map() -> void:
	if not _open:
		return
	_open = false
	visible = false
	Input.mouse_mode = _prev_mouse_mode
	_pinch_idx.clear()
	_pinch_pos.clear()
	map_closed.emit()


func is_open() -> bool:
	return _open


## 每帧跟随更新（主理人在 Node._process 里调用）：本机图标 / 航线 / 信息条。
## 打开不影响飞行——本函数只读状态，不写飞机。
func process_map(delta: float) -> void:
	if not _open or _craft == null or not is_instance_valid(_craft) or _world == null:
		return
	var pos: Vector3 = _craft.global_position
	var own := Vector2(pos.x, pos.z)
	var moved := own.distance_to(_own)
	_own = own
	_heading = _craft_heading(_craft)
	var size: Vector2 = _map_canvas.size
	if size != _last_size:
		_last_size = size
		_dirty = true
	# 飞出缓存范围：以本机为中心重新采样（一次性；长飞行中偶发）。
	if _center.distance_to(own) > RECENTER_M:
		_center = own
		_sample_all()
	_readings_timer -= delta
	if _readings_timer <= 0.0:
		_readings_timer = READINGS_INTERVAL
		_refresh_readings()
	if moved > 0.02 or _dirty:
		_dirty = false
		_map_canvas.queue_redraw()


## 设置缩放（钳制 0.5×~2×，围绕本机——本机锚点固定，格子大小变化）。
func set_zoom(value: float) -> void:
	var z := clampf(value, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(z, _zoom):
		return
	_zoom = z
	if _zoom_label != null:
		_zoom_label.text = "%.1f×" % z
	_dirty = true


## 滚轮 / 按钮缩放入口：up=true 放大。
func zoom_step(up: bool) -> void:
	set_zoom(_zoom * (ZOOM_WHEEL_RATIO if up else 1.0 / ZOOM_WHEEL_RATIO))


## 键盘：M / ESC 关闭。飞行键（W/S 油门等）不拦——地图打开期间飞机
## 继续按玩家输入飞行，这正是「打开不影响飞行」的约定。
func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_M or event.keycode == KEY_ESCAPE:
			close_map()
			get_viewport().set_input_as_handled()


## 画布输入（gui_input 信号）：滚轮缩放 + 双指捏合；点击一律吞掉，
## 避免地图打开时误触背后的挖掘 / 视角操作。
func _on_map_gui_input(event: InputEvent) -> void:
	if not _open:
		return
	if event is InputEventMouseButton:
		if event.pressed and (event.button_index == MOUSE_BUTTON_WHEEL_UP \
				or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			zoom_step(event.button_index == MOUSE_BUTTON_WHEEL_UP)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch:
		_on_touch(event)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		_on_drag(event)
		get_viewport().set_input_as_handled()


func _on_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if _pinch_idx.size() < 2 and not _pinch_pos.has(event.index):
			_pinch_idx.append(event.index)
			_pinch_pos[event.index] = event.position
			if _pinch_idx.size() == 2:
				var pa: Vector2 = _pinch_pos[_pinch_idx[0]]
				var pb: Vector2 = _pinch_pos[_pinch_idx[1]]
				_pinch_dist = pa.distance_to(pb)
	else:
		_pinch_idx.erase(event.index)
		_pinch_pos.erase(event.index)
		_pinch_dist = 0.0


func _on_drag(event: InputEventScreenDrag) -> void:
	if not _pinch_pos.has(event.index):
		return
	_pinch_pos[event.index] = event.position
	if _pinch_idx.size() == 2 and _pinch_dist > 8.0:
		var pa: Vector2 = _pinch_pos[_pinch_idx[0]]
		var pb: Vector2 = _pinch_pos[_pinch_idx[1]]
		var d := pa.distance_to(pb)
		if d > 8.0:
			set_zoom(_zoom * (d / _pinch_dist))
			_pinch_dist = d


# ── 采样（打开时一次性，之后只读缓存） ─────────────────────────

func _sample_all() -> void:
	_sample_terrain()
	_scan_runways()
	_dirty = true


## 粗网格地形：33×33 / ±180 m。近处（±45 m）读已加载区块的真实顶面
## 方块（机场跑道、玩家建筑、树冠都算数），远处用噪声估算——同一套
## 生成判据，不加载区块也有一张完整地图。
func _sample_terrain() -> void:
	_cell_pos.clear()
	_cell_color.clear()
	if _world == null:
		return
	var half := float(GRID_CELLS - 1) * 0.5
	var pos := PackedVector2Array()
	pos.resize(GRID_CELLS * GRID_CELLS)
	var col := PackedColorArray()
	col.resize(GRID_CELLS * GRID_CELLS)
	var k := 0
	for j in GRID_CELLS:
		for i in GRID_CELLS:
			var wx := _center.x + (float(i) - half) * STEP_M
			var wz := _center.y + (float(j) - half) * STEP_M
			var ix := int(floor(wx))
			var iz := int(floor(wz))
			var id := BlockTypes.Block.AIR
			var top_y := 0
			if absf(wx - _center.x) <= DETAIL_M and absf(wz - _center.y) <= DETAIL_M:
				var hit := _top_at(ix, iz, 12, 6)
				id = hit.x
				top_y = hit.y
			if id == BlockTypes.Block.AIR:
				id = _estimate_block(ix, iz)
				top_y = _world.get_surface_height(ix, iz)
			pos[k] = Vector2(wx, wz)
			col[k] = _shaded_color(id, top_y)
			k += 1
	_cell_pos = pos
	_cell_color = col


## 跑道识别：±48 m / 4 m 细扫挑 COBBLESTONE 顶面（噪声不生圆石，只有
## 机场跑道与玩家建筑会命中），膨胀一格后聚类，按「长条」形态过滤掉
## 房屋等紧凑建筑。机场（28 m）与降落场（16 m）靠长度 + 区域配置区分。
func _scan_runways() -> void:
	_runways.clear()
	if _world == null:
		return
	var n := int(RUNWAY_SCAN_M / RUNWAY_STEP_M)
	var hits := {}
	for j in range(-n, n + 1):
		for i in range(-n, n + 1):
			var wx := int(floor(_center.x + float(i) * RUNWAY_STEP_M))
			var wz := int(floor(_center.y + float(j) * RUNWAY_STEP_M))
			var hit := _top_at(wx, wz, 10, 6)
			if hit.x == BlockTypes.Block.COBBLESTONE:
				hits[Vector2i(i, j)] = true
	if hits.is_empty():
		return
	# 膨胀一格再聚类：跑道宽 6 m、步长 4 m，单个截面可能只采到一格。
	var dilated := {}
	for key: Vector2i in hits:
		dilated[key] = true
		for off: Vector2i in NEIGHBORS4:
			dilated[key + off] = true
	var seen := {}
	var clusters: Array = []
	for key: Vector2i in dilated:
		if seen.has(key):
			continue
		var queue: Array = [key]
		seen[key] = true
		var cluster: Array = []
		while not queue.is_empty():
			var cur: Vector2i = queue.pop_back()
			cluster.append(cur)
			for off: Vector2i in NEIGHBORS4:
				var nxt: Vector2i = cur + off
				if dilated.has(nxt) and not seen.has(nxt):
					seen[nxt] = true
					queue.append(nxt)
		clusters.append(cluster)
	var is_airport_region := RegionAtlas.has_airport(_world.get_region())
	for cluster: Array in clusters:
		if cluster.size() < 4:
			continue
		var min_i := 1 << 30
		var max_i := -(1 << 30)
		var min_j := 1 << 30
		var max_j := -(1 << 30)
		for cell: Vector2i in cluster:
			min_i = mini(min_i, cell.x)
			max_i = maxi(max_i, cell.x)
			min_j = mini(min_j, cell.y)
			max_j = maxi(max_j, cell.y)
		var span_i := float(max_i - min_i + 1) * RUNWAY_STEP_M
		var span_j := float(max_j - min_j + 1) * RUNWAY_STEP_M
		var len_m := maxf(span_i, span_j)
		var wid_m := minf(span_i, span_j)
		# 长条形态：长度 ≥12 m、宽 ≥2 m、长宽比 ≥2（排除房屋与广场）。
		if len_m < 12.0 or wid_m < 2.0 or len_m < wid_m * 2.0:
			continue
		var mark := RunwayMark.new()
		mark.center = Vector2(
			_center.x + float(min_i + max_i) * 0.5 * RUNWAY_STEP_M,
			_center.y + float(min_j + max_j) * 0.5 * RUNWAY_STEP_M)
		mark.len_m = len_m
		mark.wid_m = wid_m
		mark.axis = Vector2(1.0, 0.0) if span_i >= span_j else Vector2(0.0, 1.0)
		# 机场跑道 28 m、降落场 16 m：区域带机场且够长才记 ✈️。
		mark.is_airport = is_airport_region and len_m >= 22.0
		_runways.append(mark)


## 该列顶面方块：自地表估算上方往下扫首个非空方块。
## 返回 Vector2i(方块 id, 顶面 y)；未命中返回 (AIR, -1)。
func _top_at(wx: int, wz: int, up: int, down: int) -> Vector2i:
	var surface := _world.get_surface_height(wx, wz)
	var y := surface + up
	var limit := surface - down
	while y >= limit:
		var id := _world.get_block(Vector3i(wx, y, wz))
		if id != BlockTypes.Block.AIR:
			return Vector2i(id, y)
		y -= 1
	return Vector2i(BlockTypes.Block.AIR, -1)


## 噪声估算地表方块（未加载区块的格子用）：与 World._block_at 同源判据
## ——水面列按区域水体策略出水 / 冰，陆地按 low_line 分界取 surface/surface_low。
func _estimate_block(wx: int, wz: int) -> int:
	var profile := RegionAtlas.profile(_world.get_region())
	if _world.is_water_column(wx, wz):
		if String(profile.get("water", "normal")) == "iceberg":
			return BlockTypes.Block.ICE
		return BlockTypes.Block.WATER
	var low_line := int(profile.get("low_line", World.SEA_LEVEL))
	if _world.get_surface_height(wx, wz) > low_line:
		return int(profile.get("surface", BlockTypes.Block.GRASS))
	return int(profile.get("surface_low", BlockTypes.Block.SAND))


## 地形配色（儿童友好高对比）：水蓝、沙浅黄、草绿、石灰、雪白、冰浅蓝。
func _block_color(id: int) -> Color:
	match id:
		BlockTypes.Block.WATER:
			return Color(0.20, 0.46, 0.86)
		BlockTypes.Block.ICE:
			return Color(0.66, 0.84, 0.96)
		BlockTypes.Block.SAND:
			return Color(0.93, 0.84, 0.52)
		BlockTypes.Block.GRASS:
			return Color(0.44, 0.74, 0.33)
		BlockTypes.Block.LEAVES:
			return Color(0.27, 0.57, 0.27)
		BlockTypes.Block.SNOW:
			return Color(0.96, 0.98, 1.0)
		BlockTypes.Block.STONE:
			return Color(0.56, 0.58, 0.62)
		BlockTypes.Block.COBBLESTONE:
			return Color(0.40, 0.42, 0.46)
		BlockTypes.Block.DIRT:
			return Color(0.56, 0.41, 0.27)
		BlockTypes.Block.WOOD:
			return Color(0.44, 0.31, 0.18)
		BlockTypes.Block.FARMLAND:
			return Color(0.50, 0.37, 0.22)
		BlockTypes.Block.GLASS:
			return Color(0.75, 0.85, 0.92)
		_:
			return BLOCK_FALLBACK


## 按高度做明暗调制（高地亮、低地暗），让平视色块图有起伏感；
## 水面 / 冰面高度一致，不着色保持纯色可读。
func _shaded_color(id: int, top_y: int) -> Color:
	var base := _block_color(id)
	if id == BlockTypes.Block.WATER or id == BlockTypes.Block.ICE:
		return Color(base.r, base.g, base.b, TERRAIN_ALPHA)
	var t := clampf((float(top_y) - HEIGHT_LO) / (HEIGHT_HI - HEIGHT_LO), 0.0, 1.0)
	var shade := 0.82 + 0.34 * t
	return Color(
		clampf(base.r * shade, 0.0, 1.0),
		clampf(base.g * shade, 0.0, 1.0),
		clampf(base.b * shade, 0.0, 1.0),
		TERRAIN_ALPHA
	)


## 机头水平朝向 → 屏幕角（本工程 +Z 为北；屏幕北上东右，与 _world_to_screen
## 一致）：机头指北 _heading=0、指东 +π/2、指南 ±π、指西 −π/2。
## 消费方 _draw_own：dir = (sin h, −cos h)——指北时 (0,−1) 即屏幕上方。
func _craft_heading(craft: Aircraft) -> float:
	var f: Vector3 = -craft.global_transform.basis.z
	f.y = 0.0
	if f.length_squared() < 0.0001:
		return 0.0
	f = f.normalized()
	return atan2(f.x, f.z)


## 取任务管理器：直接传管理器本体最好；传 MissionPanel 这类包装节点时
## 自动取其内部 MissionManager（优先 mission_manager() getter，回退 _mm）。
## MissionManager 不是 Node 子类（Object 兄弟分支），静态 is/as 会被解析器
## 拒绝，故经 Variant 别名逃逸到运行时判定。
func _mission_manager() -> MissionManager:
	if _mission_mgr == null or not is_instance_valid(_mission_mgr):
		return null
	var src: Variant = _mission_mgr
	if src is MissionManager:
		return src as MissionManager
	if _mission_mgr.has_method("mission_manager"):
		var got: Variant = _mission_mgr.call("mission_manager")
		if got is MissionManager:
			return got as MissionManager
	var inner: Variant = _mission_mgr.get("_mm")
	if inner is MissionManager:
		return inner as MissionManager
	return null


## 解析当前任务目标：status != IDLE 时，CIRCUIT 画全部航点（末个为图钉），
## LANDING 画降落区中心 + 半径圈；TAKEOFF 无空间目标则不画。
func _resolve_target() -> void:
	var mm := _mission_manager()
	if mm == null or mm.status == MissionManager.Status.IDLE or mm.mission == null:
		if _has_target:
			_has_target = false
			_dirty = true
		_target_sig = ""
		return
	var m: MissionData = mm.mission
	var sig := "%d|%d|%d" % [mm.status, m.get_instance_id(), m.waypoints.size()]
	if sig == _target_sig:
		return
	_target_sig = sig
	_waypoints.clear()
	var target := Vector3.ZERO
	if not m.waypoints.is_empty():
		for wp: Vector3 in m.waypoints:
			_waypoints.append(wp)
		target = m.waypoints[m.waypoints.size() - 1]
	elif m.type == MissionData.Type.LANDING:
		target = m.zone_center
	if target == Vector3.ZERO:
		_has_target = false
		_dirty = true
		return
	_target = target
	_has_target = true
	_zone_radius = m.zone_radius() if m.type == MissionData.Type.LANDING else 0.0
	_target_dist_shown = -1
	_dirty = true


## 读数刷新（10 Hz）：高度 AGL / 空速 / 油门 / 距目标。文字仅在整数值
## 变化时重设，避免每帧分配字符串。
func _refresh_readings() -> void:
	if _craft == null or not is_instance_valid(_craft):
		return
	var snap: Dictionary = _craft.snapshot()
	var alt := int(float(snap.get("altitude_agl", 0.0)))
	var spd := int(float(snap.get("kmh", 0.0)))
	var thr := int(round(clampf(float(snap.get("throttle", 0.0)), 0.0, 1.0) * 100.0))
	_set_text(_stat_alt, "高度 %d m" % alt)
	_set_text(_stat_spd, "空速 %d km/h" % spd)
	_set_text(_stat_thr, "油门 %d%%" % thr)
	_resolve_target()
	if _has_target:
		var d := _own.distance_to(Vector2(_target.x, _target.z))
		_set_text(_stat_dist, "距目标 %d m" % int(d))
	else:
		_set_text(_stat_dist, "距目标 —")


func _set_text(label: Label, text: String) -> void:
	if label != null and label.text != text:
		label.text = text


# ── UI 构建（全 Container / 锚点，禁死坐标布局） ─────────────────

func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_root = root

	# 地图画布：全屏、吞输入；绘制与输入都经信号回连到本脚本。
	_map_canvas = Control.new()
	_map_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_map_canvas.draw.connect(_draw_map.bind(_map_canvas))
	_map_canvas.gui_input.connect(_on_map_gui_input)
	root.add_child(_map_canvas)

	# 标题牌（左上）。
	var title_panel := PanelContainer.new()
	title_panel.add_theme_stylebox_override("panel", _panel_style(10.0))
	title_panel.anchor_left = 0.0
	title_panel.anchor_top = 0.0
	title_panel.anchor_right = 0.0
	title_panel.anchor_bottom = 0.0
	title_panel.offset_left = 16.0
	title_panel.offset_top = 16.0
	title_panel.offset_right = 252.0
	title_panel.offset_bottom = 68.0
	root.add_child(title_panel)
	var title := Label.new()
	title.text = "✈️ 战术地图"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", TEXT_HI)
	title_panel.add_child(title)

	# 操作提示（标题牌下方）。
	var hint := Label.new()
	hint.text = "滚轮 / 双指缩放 · ＋－ 微调 · M 关闭"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", TEXT_DIM)
	hint.anchor_left = 0.0
	hint.anchor_top = 0.0
	hint.anchor_right = 0.0
	hint.anchor_bottom = 0.0
	hint.offset_left = 20.0
	hint.offset_top = 76.0
	hint.offset_right = 380.0
	hint.offset_bottom = 96.0
	root.add_child(hint)

	# 关闭按钮（右上，56×56 大触控目标）。
	_close_button = UiKit.make_close(28)
	_close_button.custom_minimum_size = Vector2(56, 56)
	_close_button.anchor_left = 1.0
	_close_button.anchor_top = 0.0
	_close_button.anchor_right = 1.0
	_close_button.anchor_bottom = 0.0
	_close_button.offset_left = -72.0
	_close_button.offset_top = 16.0
	_close_button.offset_right = -16.0
	_close_button.offset_bottom = 72.0
	_close_button.pressed.connect(close_map)
	root.add_child(_close_button)

	# 底部信息条：读数行 + 图例 / 缩放行。
	_bottom_panel = PanelContainer.new()
	_bottom_panel.add_theme_stylebox_override("panel", _panel_style(14.0))
	_bottom_panel.anchor_left = 0.0
	_bottom_panel.anchor_right = 1.0
	_bottom_panel.anchor_top = 1.0
	_bottom_panel.anchor_bottom = 1.0
	_bottom_panel.offset_left = BOTTOM_MARGIN
	_bottom_panel.offset_right = -BOTTOM_MARGIN
	_bottom_panel.offset_top = -(BOTTOM_PANEL_H + BOTTOM_MARGIN)
	_bottom_panel.offset_bottom = -BOTTOM_MARGIN
	root.add_child(_bottom_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	_bottom_panel.add_child(vbox)

	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", 16)
	stats.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(stats)
	_stat_alt = _stat_item(stats, "高度 — m", COLOR_ALT)
	_stat_spd = _stat_item(stats, "空速 — km/h", COLOR_SPD)
	_stat_thr = _stat_item(stats, "油门 — %", COLOR_THR)
	_stat_dist = _stat_item(stats, "距目标 —", COLOR_DST)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	vbox.add_child(row)
	_legend_label = Label.new()
	_legend_label.text = "▲ 本机　📍 目标　▬ 机场跑道　🛬 降落场"
	_legend_label.add_theme_font_size_override("font_size", 12)
	_legend_label.add_theme_color_override("font_color", TEXT_DIM)
	_legend_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_legend_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_legend_label)
	var zoom_out := _zoom_button("－")
	zoom_out.pressed.connect(_on_zoom_out_pressed)
	row.add_child(zoom_out)
	_zoom_label = Label.new()
	_zoom_label.text = "1.0×"
	_zoom_label.add_theme_font_size_override("font_size", 16)
	_zoom_label.add_theme_color_override("font_color", TEXT_HI)
	_zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zoom_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_zoom_label.custom_minimum_size = Vector2(46, 0)
	row.add_child(_zoom_label)
	var zoom_in := _zoom_button("＋")
	zoom_in.pressed.connect(_on_zoom_in_pressed)
	row.add_child(zoom_in)


func _panel_style(radius: float) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(int(radius))
	style.set_content_margin_all(10)
	return style


func _stat_item(box: HBoxContainer, text: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", color)
	box.add_child(label)
	return label


## 缩放按钮：60×60（≥44 触控热区）、圆角深底白框，儿童手指也好按。
func _zoom_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(60, 60)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 26)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.14, 0.20, 0.92)
	style.border_color = Color(1.0, 1.0, 1.0, 0.45)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	b.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.bg_color = Color(0.18, 0.24, 0.32, 0.95)
	b.add_theme_stylebox_override("hover", hover)
	var pressed := style.duplicate()
	pressed.bg_color = Color(0.05, 0.07, 0.10, 0.95)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_color_override("font_color", TEXT_HI)
	return b


func _on_zoom_in_pressed() -> void:
	set_zoom(_zoom + ZOOM_STEP)


func _on_zoom_out_pressed() -> void:
	set_zoom(_zoom - ZOOM_STEP)


# ── 绘制（只读缓存，零分配） ───────────────────────────────────

func _draw_map(canvas: Control) -> void:
	var size: Vector2 = canvas.size
	_view_size = size
	canvas.draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR)
	# 本机锚点：水平居中、垂直 56%（上方留出前瞻空间）。
	_anchor = Vector2(size.x * 0.5, size.y * 0.56)
	_ppm = minf(size.x, size.y) / (2.0 * RANGE_M) * _zoom
	_draw_terrain(canvas)
	_draw_target(canvas)
	_draw_runways(canvas)
	_draw_own(canvas)
	canvas.draw_rect(
		Rect2(Vector2(6.0, 6.0), size - Vector2(12.0, 12.0)),
		Color(1.0, 1.0, 1.0, 0.14), false, 2.0)
	_draw_compass(canvas)
	_draw_scale(canvas)


## 世界 (x, z) → 屏幕：本工程约定 +Z 为北（见 airport_builder 进近方向
## 「+Z、由南向北」与 main.gd「机头朝 +Z 北端」），北在屏幕上为上方，
## 故 z 取负；东（+X）在右。罗盘 / 徽标机头均按此绘制。
func _world_to_screen(wx: float, wz: float) -> Vector2:
	return _anchor + Vector2(wx - _own.x, -(wz - _own.y)) * _ppm


func _on_screen(p: Vector2) -> bool:
	return p.x >= 8.0 and p.y >= 8.0 \
		and p.x <= _view_size.x - 8.0 and p.y <= _view_size.y - 8.0


func _draw_terrain(canvas: Control) -> void:
	var cell_px := STEP_M * _ppm
	if cell_px <= 0.5 or _cell_pos.is_empty():
		return
	var half := cell_px * 0.5
	var over := Vector2(cell_px + 1.0, cell_px + 1.0)
	var w := _view_size.x
	var h := _view_size.y
	for k in _cell_pos.size():
		var p: Vector2 = _world_to_screen(_cell_pos[k].x, _cell_pos[k].y)
		if p.x < -cell_px or p.y < -cell_px or p.x > w + cell_px or p.y > h + cell_px:
			continue
		canvas.draw_rect(Rect2(p.x - half, p.y - half, over.x, over.y), _cell_color[k])


## 任务目标层：航点小圈 → 降落区半径圈 → 虚线航线 → 图钉 + 距离文字；
## 目标出图时在图缘画指向箭头 + 距离，孩子永远知道该往哪飞。
func _draw_target(canvas: Control) -> void:
	if not _has_target:
		return
	var txz := Vector2(_target.x, _target.z)
	var tp := _world_to_screen(txz.x, txz.y)
	if _zone_radius > 0.0:
		var r := _zone_radius * _ppm
		canvas.draw_circle(tp, r, Color(TARGET_COLOR, 0.10))
		canvas.draw_arc(tp, r, 0.0, TAU, 48, Color(TARGET_COLOR, 0.55), 2.0)
	for k in _waypoints.size():
		var wp: Vector3 = _waypoints[k]
		var sp := _world_to_screen(wp.x, wp.z)
		if not _on_screen(sp):
			continue
		canvas.draw_circle(sp, 5.0, Color(1.0, 1.0, 1.0, 0.85))
		canvas.draw_arc(sp, 5.0, 0.0, TAU, 20, OWN_INK, 1.5)
	_draw_dashed(canvas, _anchor, tp, Color(1.0, 1.0, 1.0, 0.55), 2.5, 9.0, 7.0)
	var dist := int(_own.distance_to(txz))
	if dist != _target_dist_shown:
		_target_dist_shown = dist
		_target_label_text = "目标 %d m" % dist
	if _on_screen(tp):
		canvas.draw_circle(tp, 11.0, OWN_INK)
		canvas.draw_circle(tp, 9.0, TARGET_COLOR)
		canvas.draw_circle(tp, 3.2, Color(0.25, 0.17, 0.05, 1.0))
		_draw_text(canvas, tp + Vector2(15.0, -12.0), _target_label_text, 15, TEXT_HI)
	else:
		var at := _draw_edge_arrow(canvas, tp, TARGET_COLOR)
		_draw_text(canvas, at + Vector2(12.0, 24.0), _target_label_text, 14, TARGET_COLOR)


## 机场 / 降落场层：按长轴画跑道条带（俯视长条 + 中线虚线，起降朝向一眼
## 可读），中心压一枚白底小飞机徽标 + 名称；出图时画图缘指向箭头。
func _draw_runways(canvas: Control) -> void:
	for k in _runways.size():
		var mark := _runways[k]
		var sp := _world_to_screen(mark.center.x, mark.center.y)
		var half_len := mark.len_m * 0.5 * _ppm
		var half_wid := maxf(mark.wid_m * 0.5 * _ppm, 3.0)
		# 世界 (x, z) 轴向 → 屏幕轴向（z 取负，同 _world_to_screen）：
		# 本工程跑道沿 +Z（由南向北进近），屏上呈竖直条带、北端在上。
		var axis_s := Vector2(mark.axis.x, -mark.axis.y)
		var perp_s := Vector2(mark.axis.y, mark.axis.x)
		if _on_screen(sp):
			var quad := mark.quad
			quad[0] = sp + axis_s * half_len + perp_s * half_wid
			quad[1] = sp + axis_s * half_len - perp_s * half_wid
			quad[2] = sp - axis_s * half_len - perp_s * half_wid
			quad[3] = sp - axis_s * half_len + perp_s * half_wid
			canvas.draw_colored_polygon(quad, RUNWAY_INK)
			_draw_dashed(canvas,
				sp - axis_s * half_len * 0.86,
				sp + axis_s * half_len * 0.86,
				Color(1.0, 1.0, 1.0, 0.72), 1.5, 4.0, 4.0)
			canvas.draw_circle(sp, 12.0, OWN_INK)
			canvas.draw_circle(sp, 10.0, Color(1.0, 1.0, 1.0, 0.97))
			# 徽标内小飞机：机头朝北（跑道朝向看条带方向）。
			_north_tri[0] = sp + Vector2(0.0, -6.5)
			_north_tri[1] = sp + Vector2(-3.8, 5.0)
			_north_tri[2] = sp + Vector2(3.8, 5.0)
			canvas.draw_colored_polygon(_north_tri, Color(0.10, 0.14, 0.20, 1.0))
			_draw_text(canvas, sp + Vector2(16.0, 5.0),
				"机场" if mark.is_airport else "降落场", 14, TEXT_HI)
		else:
			_draw_edge_arrow(canvas, sp, Color(0.62, 0.86, 1.0, 0.95))


## 本机层：光环 + 航向虚线 + 白底三角箭头（深色描边保对比）。
func _draw_own(canvas: Control) -> void:
	var c := _anchor
	var dir := Vector2(sin(_heading), -cos(_heading))
	canvas.draw_circle(c, 22.0, Color(1.0, 1.0, 1.0, 0.12))
	canvas.draw_arc(c, 22.0, 0.0, TAU, 32, Color(1.0, 1.0, 1.0, 0.38), 2.0)
	_draw_dashed(canvas, c + dir * 13.0, c + dir * 54.0, OWN_INK, 4.5, 9.0, 6.0)
	_draw_dashed(canvas, c + dir * 13.0, c + dir * 54.0, Color(1.0, 1.0, 1.0, 0.9), 2.0, 9.0, 6.0)
	var s := 14.0
	var g := 1.2
	_own_tri_dark[0] = c + dir * (s * g)
	_own_tri_dark[1] = c + dir.rotated(2.55) * (s * 0.62 * g)
	_own_tri_dark[2] = c + dir.rotated(-2.55) * (s * 0.62 * g)
	_own_tri_light[0] = c + dir * s
	_own_tri_light[1] = c + dir.rotated(2.55) * s * 0.62
	_own_tri_light[2] = c + dir.rotated(-2.55) * s * 0.62
	canvas.draw_colored_polygon(_own_tri_dark, OWN_INK)
	canvas.draw_colored_polygon(_own_tri_light, Color(1.0, 1.0, 1.0, 0.98))
	canvas.draw_circle(c, 2.6, OWN_INK)


## 罗盘徽标（右上、关闭按钮下方）：north-up 固定，只作朝向提醒。
func _draw_compass(canvas: Control) -> void:
	var c := Vector2(_view_size.x - 44.0, 118.0)
	canvas.draw_circle(c, 24.0, Color(0.05, 0.08, 0.12, 0.78))
	canvas.draw_arc(c, 24.0, 0.0, TAU, 48, Color(1.0, 1.0, 1.0, 0.55), 2.0)
	_north_tri[0] = c + Vector2(0.0, -16.0)
	_north_tri[1] = c + Vector2(-6.0, -5.0)
	_north_tri[2] = c + Vector2(6.0, -5.0)
	canvas.draw_colored_polygon(_north_tri, Color(1.0, 0.38, 0.34, 0.95))
	_draw_text(canvas, c + Vector2(-7.0, 21.0), "北", 15, TEXT_HI)


## 比例尺（右下、信息条上方）：随缩放选整数米刻度，帮孩子建立距离感。
func _draw_scale(canvas: Control) -> void:
	var meters := 110.0 / _ppm
	var nice: float = SCALE_CANDIDATES[SCALE_CANDIDATES.size() - 1]
	for cand: float in SCALE_CANDIDATES:
		if cand >= meters:
			nice = cand
			break
	if nice != _scale_nice:
		_scale_nice = nice
		_scale_label_text = "%d m" % int(nice)
	var px := nice * _ppm
	var y := _view_size.y - BOTTOM_MARGIN - BOTTOM_PANEL_H - 20.0
	var x0 := _view_size.x - 20.0 - px
	canvas.draw_line(Vector2(x0, y), Vector2(x0 + px, y), Color(1.0, 1.0, 1.0, 0.85), 2.5)
	canvas.draw_line(Vector2(x0, y), Vector2(x0, y + 7.0), Color(1.0, 1.0, 1.0, 0.85), 2.5)
	canvas.draw_line(Vector2(x0 + px, y), Vector2(x0 + px, y + 7.0), Color(1.0, 1.0, 1.0, 0.85), 2.5)
	_draw_text(canvas, Vector2(x0 + px * 0.5 - 18.0, y - 8.0), _scale_label_text, 13, TEXT_DIM)


## 图缘指向箭头：目标 / 机场飞出画面时，在图内边缘画一个朝外的小三角，
## 返回箭头落点（供调用方贴距离文字）。
func _draw_edge_arrow(canvas: Control, tp: Vector2, color: Color) -> Vector2:
	var cx2 := clampf(tp.x, 16.0, maxf(17.0, _view_size.x - 16.0))
	var cy2 := clampf(tp.y, 16.0, maxf(17.0, _view_size.y - 16.0))
	var clamped := Vector2(cx2, cy2)
	var dv := tp - _anchor
	if dv.length_squared() < 1.0:
		return clamped
	dv = dv.normalized()
	_arrow_tri[0] = clamped + dv * 11.0
	_arrow_tri[1] = clamped + dv.rotated(2.5) * 6.5
	_arrow_tri[2] = clamped + dv.rotated(-2.5) * 6.5
	canvas.draw_colored_polygon(_arrow_tri, color)
	return clamped


## 手写虚线（不依赖 draw_dashed_line 的参数细节，段长/间隔可控）。
func _draw_dashed(
	canvas: Control, from: Vector2, to: Vector2,
	color: Color, width: float, dash: float, gap: float) -> void:
	var delta := to - from
	var total := delta.length()
	if total < 1.0:
		return
	var dir := delta / total
	var period := dash + gap
	var pos := 0.0
	while pos < total:
		var seg_end := minf(pos + dash, total)
		canvas.draw_line(from + dir * pos, from + dir * seg_end, color, width)
		pos += period


## 深色描边文字：地图压在任何地形色上都读得清。
func _draw_text(canvas: Control, pos: Vector2, text: String, size: int, color: Color) -> void:
	var font: Font = canvas.get_theme_default_font()
	if font == null:
		return
	var ink := Color(0.03, 0.05, 0.08, 0.92)
	canvas.draw_string(font, pos + Vector2(-1.5, 0.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, ink)
	canvas.draw_string(font, pos + Vector2(1.5, 0.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, ink)
	canvas.draw_string(font, pos + Vector2(0.0, -1.5), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, ink)
	canvas.draw_string(font, pos + Vector2(0.0, 1.5), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, ink)
	canvas.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
