extends CharacterBody3D
class_name Player
## 第一人称玩家控制器。
## 同时支持桌面（键盘 + 鼠标）与移动端（虚拟摇杆 + 触屏视角）。
## 键盘动作由 InputActions 运行时注册到 InputMap（见 scripts/core/input_actions.gd）。

## 体素 0.5m 化（D-030）：一格 = 0.5 米。玩家 1.8m ≈ 3.6 格，方块相对玩家
## 缩小一倍。所有米制常量（速度/重力/距离）×2，格数体系（地形/SEA_LEVEL）不变。
const GRAVITY := 48.0
const JUMP_VELOCITY := 16.0
const WALK_SPEED := 11.0
const SPRINT_SPEED := 18.0
const FLY_SPEED := 24.0
const MOUSE_SENSITIVITY := 0.002
const TOUCH_LOOK_SENSITIVITY := 0.004
const PITCH_LIMIT := 1.55
const REACH_DISTANCE := 16.0
const MAX_HEALTH := 20
const MAX_HUNGER := 20
## 饥饿消耗：站着不动满饥饿可撑 1000 秒（白天 600 秒，约 1.7 个白天）。
## 早期是 0.08/秒——满饥饿 250 秒就见底，站着发呆 4 分钟就开始掉血，
## 玩家只觉得「血掉得莫名其妙」；放慢到 0.02 后饥饿仍是压力，但给得起反应时间。
const HUNGER_DRAIN_PER_SECOND := 0.02
## 冲刺额外消耗：叠加后 0.08/秒，连续冲刺约 250 秒见底（原 0.12 → 100 秒）。
const SPRINT_HUNGER_DRAIN := 0.06
const STARVATION_DAMAGE_INTERVAL := 5.0
## 受击无敌帧：被生物命中后 0.5 秒内的再次命中全部忽略。
## 没有它时一群怪会在同一帧把 20 点血一次性打空——玩家只看到血条瞬间归零。
const HURT_INVULN_TIME := 0.5
## 死亡停顿：原地立 R.I.P 墓碑的时长，倒计时结束才从出生点复活。
const DEATH_PAUSE := 2.2
# 落地速度阈值：sqrt(2 * GRAVITY * 6) ≈ 24 m/s，对应约 6 格内免伤。
const FALL_DAMAGE_THRESHOLD := 24.0
const FALL_DAMAGE_SCALE := 0.5
## 蓄力射箭：按住右键满蓄 BOW_MAX_CHARGE 秒，伤害与初速随蓄力提升。
const BOW_MIN_CHARGE := 0.15
const BOW_MAX_CHARGE := 1.2
## 垂钓状态机取值：未抛竿 / 等待咬钩 / 咬钩中。
const FISH_IDLE := 0
const FISH_WAITING := 1
const FISH_BITING := 2
## 垂钓：抛竿最远距离、等待咬钩的时间区间与咬钩窗口。
const FISH_CAST_RANGE := 28.0
const FISH_WAIT_MIN := 2.0
const FISH_WAIT_MAX := 5.0
const FISH_BITE_WINDOW := 1.6
## 兼容旧命名的基准伤害（狩猎实际伤害由 HuntRules 按工具结算）。
const ATTACK_DAMAGE := 1
const ATTACK_COOLDOWN_MS := 500
const DOUBLE_TAP_FLY_MS := 300
## 双击 F 收起飞机：从「下机 / 登机」切换为「把停着的飞机收回到背包」。
const DOUBLE_TAP_PICKUP_MS := 350
## 回收飞机的搜索半径（m，按机体重心原点）：比登机判定（碰撞盒 + 1.6 m 容差）
## 更宽松，因为下机后玩家被弹到机身侧旁约 5 m，单按 F 下机后立刻再按 F 仍能找到。
const PICKUP_RANGE := 7.0
const CAM_STEP := 1.8
const CAM_DISTANCE_MAX := 9.0
## 驾驶时的追尾距离上限：机模放大后（翼展 24 m），步行档的 9 m 距离会被机身糊满屏。
const CAM_DISTANCE_MAX_RIDING := 20.0
## 驾驶时的默认追尾俯仰：抬高相机越过垂尾（垂尾顶 4.28 m = 8.55 格，眼位只有
## 2.75 m），否则追尾视角正对着自己的尾翼。
const CHASE_PITCH_RIDING := -0.22
const FIRST_PERSON_MAX_DISTANCE := 0.1
const SWING_INTERVAL := 0.3
# 防卡死：脚部与头部格均为实心且持续超过宽限帧数，判定嵌入地形并瞬间重生脱困。
# 宽限 3 帧过滤传送/高速掠过的单帧误判，体感仍接近瞬间。
const STUCK_GRACE_FRAMES := 3
# 鱼群陪伴回血：身边 8 格内有鱼时每 5 秒回 1 点血（生命值不满才生效）。
const FISH_HEAL_RADIUS := 8.0
const FISH_HEAL_INTERVAL := 5.0
# 饮用水恢复：解渴（饥饿）+ 少量生命。
const DRINK_HUNGER := 4.0
const DRINK_HEALTH := 1

@export var flying := false

# 由移动端 HUD 写入的虚拟输入。
var virtual_move := Vector2.ZERO
var virtual_jump := false
var virtual_descend := false
var virtual_look := Vector2.ZERO
var break_held := false
var virtual_place := false
## 弓的蓄力秒数（>0 表示正在拉弓）。
var _bow_charge := 0.0
## 当前垂钓状态（FISH_IDLE / FISH_WAITING / FISH_BITING）。
var _fishing := FISH_IDLE
var _fish_timer := 0.0
var _bobber: FishingBobber
var selected_slot := 0

signal selected_slot_changed(slot: int)
signal health_changed(value: int)
signal hunger_changed(value: int)
signal died
## 每次扣血都广播来源（"饥饿" / "摔落" / 生物名 / "箭"），HUD 据此提示玩家
## 血是怎么掉的——看不见原因的掉血只会让人以为是 bug。
signal damage_taken(amount: int, reason: String, remaining: int)

## 伤害来源常量：HUD 提示与探针断言共用同一套措辞。
const REASON_STARVE := "饥饿"
const REASON_FALL := "摔落"
const REASON_ARROW := "箭矢"
const REASON_STUCK := "卡住"
const REASON_CRASH := "坠机"

var health := MAX_HEALTH
var hunger := float(MAX_HUNGER)
var inventory := Inventory.new(Inventory.SLOT_COUNT, Inventory.COMMON_COUNT)
var spawn_position := Vector3(8.5, 32.0, 8.5)

var _world: World
var _fall_speed := 0.0
var _starvation_timer := 0.0
var _break_target := Vector3i(0, 0, 0)
var _has_break_target := false
var _break_progress := 0.0
var _break_total := 0.0
var _swing_cooldown := 0.0
var camera_distance := 0.0
var _last_attack_ms := 0
var _last_jump_ms := 0
## 上次按 F 的时间戳（ms）：用于双击 F 收起飞机。
var _last_aircraft_f_ms := 0
## 上次飞行中左键单击的时间戳（ms）：双击 = 自动改平（D-034）。
var _last_flight_click_ms := 0
## 飞行中 Esc 解锁了鼠标（D-034）：点游戏画面重新捕获继续驾驶。
var _esc_released := false
var _last_hunger_int := MAX_HUNGER
var _stuck_frames := 0
var _hurt_invuln := 0.0
## 死亡停顿中：原地立墓碑，倒计时结束后才从出生点复活。
var _dead := false
## 模态界面（工坊台建造等）打开：冻结玩家输入与物理，界面关闭时解除。
var input_locked := false
## 鱼群陪伴回血的计时器。
var _fish_heal_timer := 0.0
## 昼夜循环引用：睡觉跳过夜晚用（由 main 装配时注入）。
var day_night_ref: DayNightCycle = null
## 防卡死累计脱困次数（探针/调试用）。
var stuck_rescues := 0
## 正在驾驶的飞行器（null 表示徒步）。驾驶期间玩家物理冻结，位置每帧贴到座舱位。
var _aircraft: Aircraft = null
## 正在驾驶的船（D-042，null 表示不在船上）。与飞机互斥；驾驶期间玩家
## 物理冻结，位置每帧贴到驾驶座。
var _boat: Boat = null
## 飞行视角 rig（D-033，由 main 装配时注入）：驾驶中的视角切换 / 自由观察 / 缩放
## 都经它；null 时（无头探针未装配）飞行输入退化为旧行为，不影响探针。
var flight_camera: AircraftCamera = null

@onready var _camera: Camera3D = $Camera3D
@onready var _held_item: HeldItem = $Camera3D/HeldItem
@onready var _spring_arm: SpringArm3D = $SpringArm3D
@onready var _third_camera: Camera3D = $SpringArm3D/Camera3D
@onready var _model: PlayerModel = $PlayerModel


func _ready() -> void:
	InputActions.register()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_held_item.setup(self)
	# 第三人称弹簧臂不与玩家自身胶囊碰撞。
	_spring_arm.add_excluded_object(get_rid())
	_apply_camera_mode()
	GameState.mode_changed.connect(_on_game_mode_changed)


func _unhandled_input(event: InputEvent) -> void:
	# 模态界面（工坊台建造等）打开期间玩家不响应任何输入。
	if input_locked:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if _aircraft != null:
			# 驾驶中鼠标是操纵杆：左右滚转、上下俯仰（仅第一人称座舱生效，
			# D-034——追尾/后视/地图模式用键盘方向键，避免视线外鼠标一晃、
			# 飞机就跟着歪）。自由观察（V / 按住右键）激活时让位给视角环顾（D-033）。
			if flight_camera != null \
					and flight_camera.current_mode() == AircraftCamera.ViewMode.FREE_LOOK:
				flight_camera.apply_look_delta(event.relative)
			elif flight_camera != null \
					and flight_camera.current_mode() == AircraftCamera.ViewMode.FIRST_PERSON:
				_aircraft.add_mouse_motion(event.relative)
		else:
			_rotate_view(Vector2(event.relative.x, event.relative.y) * MOUSE_SENSITIVITY)

	# 滚轮缩放视角：拉近回第一人称（驾驶中即座舱视角），拉远切第三人称追尾。
	# 驾驶中上限放宽到 CAM_DISTANCE_MAX_RIDING——机身大，9 格距离会糊满屏。
	# 装配了飞行相机后滚轮改喂它（追尾距离 / 地图高度，D-033）；
	# 第一人称座舱内滚轮改作油门微调 ±5%（D-034 PC 鼠标操控）。
	if event is InputEventMouseButton and event.pressed:
		if _aircraft != null and flight_camera != null:
			if flight_camera.current_mode() == AircraftCamera.ViewMode.FIRST_PERSON:
				if event.button_index == MOUSE_BUTTON_WHEEL_UP:
					_aircraft.adjust_throttle(0.05)
					return
				if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
					_aircraft.adjust_throttle(-0.05)
					return
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				flight_camera.zoom(-1.0)
				return
			if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				flight_camera.zoom(1.0)
				return
		var max_distance := CAM_DISTANCE_MAX_RIDING if _aircraft != null else CAM_DISTANCE_MAX
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_distance = maxf(0.0, camera_distance - CAM_STEP)
			_apply_camera_mode()
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_distance = minf(max_distance, camera_distance + CAM_STEP)
			_apply_camera_mode()
			return

	# 驾驶中按住右键 = 自由观察（D-033）；松开自动回正。
	if event is InputEventMouseButton and _aircraft != null and flight_camera != null:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			flight_camera.set_free_look(event.pressed)
			return
		# 鼠标中键 = 视角回正（D-034）：环顾偏移与追尾距离一键归位。
		if event.button_index == MOUSE_BUTTON_MIDDLE and event.pressed:
			flight_camera.recenter()
			return
		# 双击左键 = 自动改平（D-034）：约 2 秒内增强增益把坡度摆回水平；
		# 期间重新移动鼠标即刻接管。
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			# Esc 解锁后首次点击先恢复捕获（D-034）：不当改平输入，也避免
			# 与下面的双击判定抢同一个点击。
			if _esc_released:
				_esc_released = false
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				return
			var now := Time.get_ticks_msec()
			if now - _last_flight_click_ms <= DOUBLE_TAP_FLY_MS:
				# 受「自动改平」设置门控（设置面板可关）：关掉后双击不再触发摆平。
				if FlightSettings.current().auto_level:
					_aircraft.request_level()
				_last_flight_click_ms = 0
			else:
				_last_flight_click_ms = now
			return

	# Esc 解锁鼠标后（D-034）：点游戏画面重新捕获、继续驾驶。HUD 按钮自身
	# 会消费点击，不会走到这里——只有点空白处才重捕。
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and _esc_released and _aircraft != null:
		_esc_released = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	if event is InputEventMouseButton and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and _aircraft == null:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				start_break_or_attack()
			else:
				break_held = false
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_begin_use()
			else:
				_end_use()

	if event is InputEventKey and event.pressed and not event.echo:
		for i in range(Inventory.HOTBAR_SIZE):
			if event.is_action_pressed("slot_%d" % (i + 1)):
				select_slot(i)
		if event.is_action_pressed("jump") and _aircraft == null and _boat == null:
			_handle_jump_tap()
		# 回放中（D-033）：F/X 让位给 Esc 跳过，防止运镜中被下机打断。
		var replaying := flight_camera != null \
			and flight_camera.current_mode() == AircraftCamera.ViewMode.REPLAY
		# F（D-033/D-042）：开船中 = 发动机启停；开飞机中 = 发动机启停；
		# 徒步时 = 就近登船（优先）或登机（双击收回）。
		if event.is_action_pressed("aircraft_engine") and not _dead and not replaying:
			if _boat != null:
				_boat.toggle_engine()
			elif _aircraft != null:
				_aircraft.toggle_engine()
			else:
				var boat_target := boat_board_target()
				if boat_target != null:
					ride_boat(boat_target)
				else:
					_handle_aircraft_key()
		# X（D-033/D-042）：开船中 = 下船；开飞机中 = 下机（双击收回）；
		# 徒步时 = 就近收回停着的飞机。
		if event.is_action_pressed("aircraft_exit") and not _dead and not replaying:
			if _boat != null:
				exit_boat()
			elif _aircraft != null:
				_handle_aircraft_key()
			else:
				var near: Aircraft = _pickup_target()
				if near != null:
					_pick_up_aircraft(near)
				else:
					Events.notice.emit("附近没有停着的飞机——按 F 登机要走到机身跟前。")
		# Z（D-034）：襟翼单键循环 0→1→2→0（儿童友好：不必记两个键；
		# Toast 播报档位，VFE 30 m/s 软门限在机体侧提示）。
		if event.is_action_pressed("aircraft_flaps") and not _dead and not replaying:
			if _aircraft != null:
				_aircraft.cycle_flaps()
		# H（D-034）：HUD 简单/详细模式切换（默认简单，随 settings.json 落盘）。
		if event.is_action_pressed("hud_detail") and not _dead and not replaying:
			if _aircraft != null:
				var s := FlightSettings.current()
				s.hud_detail = not s.hud_detail
				s.save()
				Events.notice.emit("📋 HUD %s模式" % ("详细" if s.hud_detail else "简单"))

	if event.is_action_pressed("ui_cancel"):
		var was_captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		Input.mouse_mode = (
			Input.MOUSE_MODE_VISIBLE
			if was_captured
			else Input.MOUSE_MODE_CAPTURED
		)
		# 飞行中 Esc 解锁（D-034）：释放指针后可点 HUD 按钮（简单/详细模式、
		# 发动机、视角等），点游戏画面重新捕获继续驾驶。
		_esc_released = _aircraft != null and was_captured


## 双击跳跃键在允许飞行的模式（创造 / 探索）下切换飞行。
func _handle_jump_tap() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_jump_ms <= DOUBLE_TAP_FLY_MS:
		_last_jump_ms = 0
		if GameState.can_fly():
			set_flying(not flying)
	else:
		_last_jump_ms = now


func _process(delta: float) -> void:
	if _dead:
		return
	# 驾驶飞行器 / 船只期间不破坏方块、不拉弓、不垂钓（垂钓走航海界面）。
	if _aircraft != null or _boat != null:
		return
	_update_breaking(delta)
	_update_bow(delta)
	_update_fishing(delta)
	if virtual_place:
		virtual_place = false
		_begin_use()


## 右键按下：手持弓开始蓄力，手持鱼竿抛竿/收竿，其余走 _use_selected。
func _begin_use() -> void:
	if _dead:
		return
	var item := get_selected_item()
	if ItemTypes.is_bow(item):
		_bow_charge = BOW_MIN_CHARGE
		return
	if ItemTypes.is_rod(item):
		_toggle_fishing()
		return
	_use_selected()


## 右键松开：松开弓即射箭。
func _end_use() -> void:
	if _bow_charge > 0.0:
		_release_bow()


## 使用选中物品：手持食物且饥饿未满时优先食用，
## 其次与村民/酿灶台交互（打开交易面板），最后放置方块。
func _use_selected() -> void:
	if _use_aircraft_kit():
		return
	if _use_bucket():
		return
	if _eat_selected():
		return
	if _interact_village():
		return
	_place_target()


## 手持飞机：在身前平地上放下一架可驾驶的飞行器（生存模式消耗 1 个）。
func _use_aircraft_kit() -> bool:
	if get_selected_item() != ItemTypes.AIRCRAFT or _world == null:
		return false
	var forward := -global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3(1.0, 0.0, 0.0)
	var at := global_position + forward.normalized() * 5.0
	var cell := Vector3i(at.floor())
	var surface := _world.get_surface_height(cell.x, cell.z)
	# 机轮要落在实心面上：脚下那格不是实心（水面/空中）就拒绝，避免放出一架掉下去的飞机。
	if not BlockTypes.is_solid(_world.get_block(Vector3i(cell.x, surface - 1, cell.z))):
		Events.notice.emit("前方不是平地，飞机放不稳。")
		return true
	Aircraft.spawn(
		get_parent(),
		Vector3(float(cell.x) + 0.5, float(surface), float(cell.z) + 0.5),
		rotation.y,
	)
	if GameState.is_survival():
		inventory.remove_item(active_inventory_slot(), 1)
	Events.notice.emit("✈️ 飞机放好了，走到跟前按 F 登机。")
	_held_item.swing()
	return true


## 木桶/水桶逻辑：空桶对准水面装水；水桶右键饮水（解渴 + 少量回血）。
## 装水不消耗水源方块（儿童向：河水取之不尽）。
func _use_bucket() -> bool:
	var id := get_selected_item()
	if id == ItemTypes.BUCKET:
		var hit := _raycast_water()
		if hit.is_empty():
			return false
		if not GameState.is_creative():
			inventory.remove_item(active_inventory_slot(), 1)
			inventory.add_item(ItemTypes.WATER_BUCKET, 1)
		Events.notice.emit("🪣 装满了一桶水。")
		_held_item.swing()
		return true
	if id == ItemTypes.WATER_BUCKET:
		if GameState.is_creative():
			return false
		if hunger >= float(MAX_HUNGER) and health >= MAX_HEALTH:
			Events.notice.emit("💧 现在不渴也不饿。")
			return true
		hunger = minf(float(MAX_HUNGER), hunger + DRINK_HUNGER)
		hunger_changed.emit(int(hunger))
		if health < MAX_HEALTH:
			health = mini(MAX_HEALTH, health + DRINK_HEALTH)
			health_changed.emit(health)
		inventory.remove_item(active_inventory_slot(), 1)
		inventory.add_item(ItemTypes.BUCKET, 1)
		Events.notice.emit("💧 咕嘟咕嘟~ 精神多了！")
		_held_item.swing()
		return true
	return false


## 只找水的射线：体素步进查找准星路径上的 WATER 方块（水无碰撞体，
## 物理射线打不中）。命中返回 {position, cell}，未命中空字典。
func _raycast_water() -> Dictionary:
	if _world == null:
		return {}
	var from := _camera.global_position
	var to := from + (-_camera.global_transform.basis.z) * REACH_DISTANCE
	var dir := to - from
	var length := dir.length()
	if length < 0.001:
		return {}
	var step := dir / length * 0.05
	var p := from
	for i in range(int(length / 0.05) + 1):
		p += step
		var cell := Vector3i(p.floor())
		if _world.get_block(cell) == BlockTypes.Block.WATER:
			return {"position": p, "cell": cell}
	return {}


## 右键指向村民/酿灶台时请求交易，指向储物箱时请求打开储物面板。
func _interact_village() -> bool:
	var hit := _raycast_target()
	if hit.is_empty():
		return false
	var collider: Object = hit.get("collider")
	if collider is Mob and (collider as Mob).type == Mob.MobType.VILLAGER:
		Events.request_trade.emit()
		return true
	var pos: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	var cell := Vector3i((pos - normal * 0.5).floor())
	if _world != null and _world.get_block(cell) == BlockTypes.Block.BREWING:
		Events.request_trade.emit()
		return true
	if _world != null and _world.get_block(cell) == BlockTypes.Block.CHEST:
		Events.request_box_open.emit(cell)
		return true
	if _world != null and _world.get_block(cell) == BlockTypes.Block.SMELTER:
		Events.request_smelt.emit()
		return true
	# 床：夜晚右键睡觉直接跳到清晨。
	if _world != null and _world.get_block(cell) == BlockTypes.Block.BED:
		if day_night_ref != null and day_night_ref.sleep_to_morning():
			Events.notice.emit("🛏️ 睡了个好觉，天亮了！")
		else:
			Events.notice.emit("🛏️ 现在还不困，天亮了再睡吧。")
		return true
	return false


## 食用选中槽位的食物：恢复饥饿并消耗 1 个。
## 饥饿已满或非食物返回 false（回退到放置流程）。
func _eat_selected() -> bool:
	if GameState.is_creative():
		return false
	var id := get_selected_item()
	if not ItemTypes.is_food(id):
		return false
	if hunger >= float(MAX_HUNGER):
		return false
	hunger = minf(float(MAX_HUNGER), hunger + float(ItemTypes.food_value(id)))
	inventory.remove_item(active_inventory_slot(), 1)
	hunger_changed.emit(int(hunger))
	_held_item.swing()
	_model.swing_arms()
	return true


func _physics_process(delta: float) -> void:
	# 死亡停顿：冻结一切（不移动、不掉血、不防卡死），等墓碑倒计时结束复活。
	if _dead:
		velocity = Vector3.ZERO
		return

	# 模态界面（工坊台建造等）打开：冻结玩家一切输入与物理，交由界面自理。
	if input_locked:
		velocity = Vector3.ZERO
		return

	# 驾驶飞行器：机体自己跑物理（Aircraft._physics_process），玩家只被贴到座舱位，
	# 相机随弹簧臂跟随机体姿态。生存结算与防卡死在驾驶期间一并跳过。
	if _aircraft != null:
		velocity = Vector3.ZERO
		global_transform = _aircraft.seat_transform()
		return

	# 驾驶船只（D-042）：船体自己跑物理（Boat._physics_process），玩家贴驾驶座。
	if _boat != null:
		velocity = Vector3.ZERO
		global_transform = _boat.seat_transform()
		return

	var jump_pressed := virtual_jump
	virtual_jump = false
	if Input.is_action_pressed("jump"):
		jump_pressed = true

	var move_input := _get_move_input()
	var can_sprint := GameState.is_creative() or hunger > 6.0
	var sprinting := can_sprint and Input.is_action_pressed("sprint")
	var speed := SPRINT_SPEED if sprinting else WALK_SPEED

	if flying:
		velocity = _fly_velocity(move_input, jump_pressed)
		_fall_speed = 0.0
	else:
		_apply_walk(delta, move_input, jump_pressed, speed)

	move_and_slide()

	# 第三人称模型行走摆动数据源。
	_model.set_move_speed(Vector2(velocity.x, velocity.z).length())

	if not flying:
		_update_fall_state()
	_tick_survival(delta, sprinting)
	if _hurt_invuln > 0.0:
		_hurt_invuln = maxf(0.0, _hurt_invuln - delta)

	if virtual_look != Vector2.ZERO:
		_rotate_view(virtual_look * TOUCH_LOOK_SENSITIVITY)
		virtual_look = Vector2.ZERO

	_check_stuck()


## 防卡死检测：脚部与头部所在格均为实心方块视为嵌入地形
## （区块加载延迟走入未生成区域、高速坠落嵌入等），
## 持续超过宽限帧数仍嵌入则瞬间死亡并在出生点重生脱困。
## 不走 _damage：卡死被不死图腾救活后仍卡在原地会形成死循环，
## 且创造模式无敌时同样需要脱困，因此直接重生。
func _check_stuck() -> void:
	if _world == null:
		return
	var feet_solid := BlockTypes.is_solid(_world.get_block(Vector3i(global_position.floor())))
	var head_solid := BlockTypes.is_solid(
		_world.get_block(Vector3i((global_position + Vector3(0.0, 1.4, 0.0)).floor()))
	)
	if feet_solid and head_solid:
		_stuck_frames += 1
		if _stuck_frames >= STUCK_GRACE_FRAMES:
			_stuck_frames = 0
			stuck_rescues += 1
			_force_unstuck()
	else:
		_stuck_frames = 0


## 防卡死脱困：瞬间清空生命走死亡表现，再从出生点安全重生。
func _force_unstuck() -> void:
	damage_taken.emit(health, REASON_STUCK, 0)
	health = 0
	died.emit()
	_respawn()
	if _world != null:
		global_position = _safe_respawn_position()


## 出生点被堵时沿 Y 向上搜索"四格空气 + 实心底"的安全落点，
## 防止重生后立即再次卡死形成循环。（玩家 3.6 格高，需 4 格净空）
func _safe_respawn_position() -> Vector3:
	var cell := Vector3i(spawn_position.floor())
	for _i in range(64):
		var clear := true
		for h in range(4):
			if BlockTypes.is_solid(_world.get_block(cell + Vector3i(0, h, 0))):
				clear = false
				break
		var grounded := BlockTypes.is_solid(_world.get_block(cell + Vector3i(0, -1, 0)))
		if clear and grounded:
			return Vector3(cell) + Vector3(0.5, 0.1, 0.5)
		cell.y += 1
	return spawn_position


func setup_world(world: World) -> void:
	_world = world


## 世界引用访问器（D-033：HUD 战术地图采样地形用）。
func world_ref() -> World:
	return _world


## 世界访问器：HUD 打开储物箱面板时经此读取箱内背包（避免直接访问私有成员）。
func get_world() -> World:
	return _world


func set_spawn_position(pos: Vector3) -> void:
	spawn_position = pos


## 传送救援（D-039 飞行重置入口之一）：清空全部运动状态并把玩家放到指定点。
## 与 _respawn() 的区别：不动生命/饥饿（重置不是死亡），但速度、坠落累积与
## 卡死帧必须清——坠机时残留的坠落速度会在落点被误判为跌落伤害。
## 落点复用「4 格空气 + 实心底」向上搜索（同 _safe_respawn_position），
## 防跑道被玩家自己拿方块堵住时嵌进地形。注意流式世界：玩家在远方坠机时
## 初始跑道所在区块可能已卸载，get_block 对未加载列逐步失败、搜索一路跑满
## ——此时回退 pos 原值（同 _safe_respawn_position 的兜底），区块随后随玩家
## 位置自动重载，绝不对玩家使用搜索后的位置。
func teleport_to(pos: Vector3, heading: float) -> void:
	velocity = Vector3.ZERO
	_fall_speed = 0.0
	_stuck_frames = 0
	if _world != null:
		var cell := Vector3i(pos.floor())
		var found := false
		for _i in range(64):
			var clear := true
			for h in range(4):
				if BlockTypes.is_solid(_world.get_block(cell + Vector3i(0, h, 0))):
					clear = false
					break
			var grounded := BlockTypes.is_solid(_world.get_block(cell + Vector3i(0, -1, 0)))
			if clear and grounded:
				found = true
				break
			cell.y += 1
		if found:
			pos = Vector3(cell) + Vector3(0.5, 0.1, 0.5)
	global_position = pos
	rotation.y = heading


## 选择快捷栏槽位并广播变化。
## 生存模式快捷栏 9 位；创造模式虚拟快捷栏更长（建材 + 工具）。
func select_slot(slot: int) -> void:
	var max_slot := Inventory.HOTBAR_SIZE - 1
	if GameState.is_creative():
		max_slot = ItemTypes.CREATIVE_HOTBAR.size() - 1
	selected_slot = clampi(slot, 0, max_slot)
	selected_slot_changed.emit(selected_slot)


## 当前快捷栏位所引用的背包槽索引（-1 表示无有效映射）。
## 快捷栏是背包槽的视图：手持/消耗/耐久都以该索引操作背包本体。
func active_inventory_slot() -> int:
	if inventory == null:
		return -1
	return inventory.hotbar_slot(selected_slot)


## 切换飞行状态；创造与探索模式允许飞行，切换时经事件总线广播。
func set_flying(value: bool) -> void:
	if value and not GameState.can_fly():
		return
	if flying == value:
		return
	flying = value
	if not flying:
		velocity = Vector3.ZERO
	Events.player_mode_changed.emit(flying)


func _on_game_mode_changed(_mode: int) -> void:
	if not GameState.can_fly():
		set_flying(false)
	# 创造→生存时选中位可能落在工具区（超出 9 格快捷栏），收回有效范围。
	if selected_slot >= Inventory.HOTBAR_SIZE:
		select_slot(0)


## ── 驾驶飞行器 ──────────────────────────────────────────
## 上机：驾驶期间玩家物理冻结、位置每帧贴到座舱位，相机随弹簧臂跟随机体姿态。
## 徒步飞行（创造/探索）与驾驶互斥：驾驶时不再走 _fly_velocity。
func ride_aircraft(craft: Aircraft) -> void:
	if craft == null or craft.is_wrecked() or _dead:
		return
	if _aircraft == craft:
		return
	if _aircraft != null:
		exit_aircraft()
	_aircraft = craft
	craft.set_piloted(true, self)
	velocity = Vector3.ZERO
	_fall_speed = 0.0
	_clear_fishing()
	# 骑乘者与机身互不碰撞：座舱位落在机体碰撞盒内部，否则两个 CharacterBody3D
	# 互相深穿透，物理分离会在一帧内把飞机弹飞并触发撞击解体（登机即坠机）。
	add_collision_exception_with(craft)
	# 弹簧臂排除机体自身，否则追尾相机会被机身顶到座舱里。
	_spring_arm.add_excluded_object(craft.get_rid())
	camera_distance = CAM_DISTANCE_MAX_RIDING
	# 驾驶中鼠标让位给操纵杆，弹簧臂俯仰不再由视角驱动——设一个越过垂尾的默认值。
	_spring_arm.rotation.x = CHASE_PITCH_RIDING
	# 登机即回到捕获态（D-034）：Esc 解锁过鼠标再登机也不能带着自由指针开飞机。
	_esc_released = false
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_apply_camera_mode()
	_model.visible = false
	_held_item.visible = false
	Events.aircraft_ride_changed.emit(true)
	# 登机提示只留「教练卡片不说」的通用键位（D-046）：起飞四步（点火→油门→
	# 滑跑→抬轮）已由飞行面板卡片里的起飞教练区分步带，这里再重复一遍只会把
	# 三行长字压在卡片读数上。X 下机与视角切换是教练不提的，留在这里。
	Events.notice.emit("✈️ 登机：W/S 油门 · ↑/↓ 拉杆推杆 · A/D 方向舵 · C 切视角 · X 下机"
		+ "（起飞步骤看面板里的教练区）")


## 下机：落到机身侧面。damage > 0 表示坠机抛出（照常扣血）。
func exit_aircraft(damage: int = 0) -> void:
	if _aircraft == null:
		return
	var craft := _aircraft
	_aircraft = null
	if is_instance_valid(craft):
		remove_collision_exception_with(craft)
		craft.set_piloted(false)
		_spring_arm.remove_excluded_object(craft.get_rid())
		# 从机身左侧跳下（机体坐标 +X 为右翼）：跨出碰撞盒半宽 3.3 再留余量，
		# 否则出生在机体碰撞盒内会被挤出去。
		global_position = craft.global_position \
			- craft.global_transform.basis.x * 5.0 + Vector3(0.0, 1.0, 0.0)
	velocity = Vector3.ZERO
	_fall_speed = 0.0
	camera_distance = 0.0
	# 下机恢复徒步的鼠标捕获（飞行中 Esc 解锁过的话，见 D-034）。
	if _esc_released:
		_esc_released = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# 弹簧臂俯仰恢复与第一人称相机一致（登机时曾设成越尾仰角）。
	_spring_arm.rotation.x = _camera.rotation.x
	# 第一人称下 PlayerModel 由 set_third_person(false) 自行隐藏，勿再强行置可见。
	_apply_camera_mode()
	if damage > 0:
		_damage(damage, REASON_CRASH)
	Events.aircraft_ride_changed.emit(false)


## 当前驾驶的飞行器（null 表示徒步）；HUD 飞行仪表据此显隐。
func aircraft() -> Aircraft:
	return _aircraft


func is_riding() -> bool:
	return _aircraft != null


# ── 驾驶船只（D-042 航海玩法）────────────────────────────────
## 与飞机同构：驾驶期间玩家物理冻结、位置每帧贴到驾驶座。
## 与飞机互斥（同按 F 登机，谁近谁先；在机上时机车分支不生效）。
func ride_boat(boat: Boat) -> void:
	if boat == null or _dead or _aircraft != null:
		return
	if _boat == boat:
		return
	_boat = boat
	boat.set_piloted(true, self)
	velocity = Vector3.ZERO
	_fall_speed = 0.0
	_clear_fishing()
	# 骑乘者与船体互不碰撞（驾驶位落在船体碰撞盒内，否则两个
	# CharacterBody3D 互相深穿透会被物理弹飞——登机同款教训）。
	add_collision_exception_with(boat)
	camera_distance = CAM_DISTANCE_MAX_RIDING
	_spring_arm.rotation.x = CHASE_PITCH_RIDING
	_esc_released = false
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_apply_camera_mode()
	_model.visible = false
	_held_item.visible = false
	Events.boat_ride_changed.emit(true)
	Events.notice.emit("⛵ 登船：W/S 油门（S 倒船），A/D 转舵；F 发动机，X 下船；"
		+ "开得越远鱼种越多，按 M 打开地图就能下竿。")


## 下船：落到船侧码头上（船体坐标 +X 为右舷，跨出碰撞盒半宽再留余量）。
func exit_boat() -> void:
	if _boat == null:
		return
	var boat := _boat
	_boat = null
	if is_instance_valid(boat):
		remove_collision_exception_with(boat)
		boat.set_piloted(false)
		# 船可能正在航行：落点取船侧 + 略高（掉下水也能游上岸，不掉血）。
		global_position = boat.global_position \
			+ boat.global_transform.basis.x * 4.0 + Vector3(0.0, 1.0, 0.0)
	velocity = Vector3.ZERO
	_fall_speed = 0.0
	camera_distance = 0.0
	if _esc_released:
		_esc_released = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_spring_arm.rotation.x = _camera.rotation.x
	_apply_camera_mode()
	Events.boat_ride_changed.emit(false)


## 当前驾驶的船（null 表示不在船上）；HUD 航海界面据此显隐。
func boat() -> Boat:
	return _boat


func is_riding_boat() -> bool:
	return _boat != null


## 就近找一艘能登的船（与 _pickup_target 飞机同思路：横向距离判定）。
func boat_board_target() -> Boat:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var best: Boat = null
	var best_d := Boat.BOARD_RANGE
	for child in scene.get_children():
		var boat := child as Boat
		if boat == null or not is_instance_valid(boat):
			continue
		var d := Vector2(boat.global_position.x - global_position.x,
			boat.global_position.z - global_position.z).length()
		if d <= best_d:
			best_d = d
			best = boat
	return best


## 死亡停顿中（墓碑倒计时）为真：外部输入守卫用（D-039 飞行重置与之对齐）。
func is_dead() -> bool:
	return _dead


## 登机判定容差（m）：距机身碰撞盒最近点再放宽的距离。
## 机模放大后（MODEL_SCALE=3）机身碰撞盒达 6.6 × 4.8 × 15.6 m，右键放机又固定
## 落在身前 5 m 处——若只按「到重心原点 ≤ 4 m」判定，刚放好按 F、或站在机头/
## 机尾旁按 F 都会误报「附近没有飞行器」。改为按碰撞盒最近点 + 容差判定
## （D-032 玩家反馈）。
const BOARD_MARGIN := 1.6

## 登机 / 下机 / 收回分发（D-033 后由两键触发）：
## 徒步按 F = 登机；驾驶中按 X = 下机；双击 X（驾驶中）= 把停着的飞机收回背包。
## 双击判据：距上次按 X ≤ DOUBLE_TAP_PICKUP_MS。下机后玩家被弹到机身侧旁约 5 m，
## 故回收搜索用更宽松的 PICKUP_RANGE（按机体重心原点）。
func _handle_aircraft_key() -> void:
	var now := Time.get_ticks_msec()
	var double := now - _last_aircraft_f_ms <= DOUBLE_TAP_PICKUP_MS
	_last_aircraft_f_ms = now

	if _aircraft != null:
		if double:
			_pick_up_aircraft(_aircraft)
		else:
			exit_aircraft()
		return

	# 徒步：就近停车场机。
	var craft := _pickup_target() if double else nearest_aircraft()
	if craft == null:
		if not double:
			Events.notice.emit("附近没有飞行器——走到机身跟前按 F 登机。")
		return
	if double:
		_pick_up_aircraft(craft)
	else:
		ride_aircraft(craft)


## 收回停着的飞机：从世界移除；生存模式退回 1 个飞行器道具（与放置时的消耗对应），
## 创造 / 探索不增不减（放置本就不消耗）。已解体或正在驾驶的不处理。
## 试飞机（蓝图拼装、未消耗物品）例外：一律不退回，否则「工坊台试飞 → 双击 F
## 收回」可无限刷 AIRCRAFT（P2-3；蓝图本身持久化在 user://，试飞不花道具）。
func _pick_up_aircraft(craft: Aircraft) -> void:
	if craft == null or not is_instance_valid(craft) or craft.is_wrecked():
		return
	if _aircraft == craft:
		exit_aircraft()
	if craft.blueprint_built:
		Events.notice.emit("✈️ 试飞机已收回（蓝图还在工坊台，不退回物品）。")
	elif GameState.is_survival():
		inventory.add_item(ItemTypes.AIRCRAFT, 1)
		Events.notice.emit("✈️ 飞机已收回（背包 +1）。")
	else:
		Events.notice.emit("✈️ 飞机已收回。")
	craft.queue_free()


## 回收目标：未解体、无人驾驶，且在 PICKUP_RANGE（到机体重心原点）内的就近一架。
## 比登机判定更宽松——下机后被弹到机身侧旁约 5 m，双击 F 仍能命中。
func _pickup_target() -> Aircraft:
	var best: Aircraft = null
	var best_distance := PICKUP_RANGE
	for node in get_tree().get_nodes_in_group("aircraft"):
		var craft := node as Aircraft
		if craft == null or craft.is_wrecked() or craft.piloted:
			continue
		var distance := global_position.distance_to(craft.global_position)
		if distance < best_distance:
			best_distance = distance
			best = craft
	return best


## 最近的可用飞行器：未解体、无人驾驶，且玩家贴近机身碰撞盒。
## 距离按「玩家到机身碰撞盒最近点」计算（而非到重心原点的直线距离），
## 否则机身两端各约 4 m 内按 F 都会失败——机模越大越离谱。
func nearest_aircraft() -> Aircraft:
	var best: Aircraft = null
	var best_distance := BOARD_MARGIN
	for node in get_tree().get_nodes_in_group("aircraft"):
		var craft := node as Aircraft
		if craft == null or craft.is_wrecked() or craft.piloted:
			continue
		var distance := _board_distance(craft)
		if distance < best_distance:
			best_distance = distance
			best = craft
	return best


## 玩家到机身碰撞盒最近点的距离（m）：把玩家位置变换到机体局部坐标，
## 夹到碰撞盒（含碰撞盒中心偏移）范围内后取距离。碰撞盒只包机身不含机翼。
func _board_distance(craft: Aircraft) -> float:
	var local := craft.to_local(global_position) - Aircraft.COLLIDER_CENTER
	var half: Vector3 = Aircraft.COLLIDER_SIZE * 0.5
	var closest := local.clamp(-half, half)
	return local.distance_to(closest)


func get_selected_item() -> int:
	if GameState.is_creative():
		var items := ItemTypes.CREATIVE_HOTBAR
		return items[clampi(selected_slot, 0, items.size() - 1)]
	return inventory.get_item(active_inventory_slot())


func get_selected_tool() -> int:
	var item := get_selected_item()
	return item if ItemTypes.is_tool_item(item) else -1


func get_selected_placeable() -> int:
	var item := get_selected_item()
	return item if ItemTypes.is_placeable(item) else BlockTypes.Block.AIR


func start_break_or_attack() -> void:
	if _dead:
		return
	_held_item.swing()
	_model.swing_arms()
	if _try_attack_mob():
		return
	break_held = true


## 是否正在破坏目标（供 HUD 进度条与手持模型轮询）。
func is_breaking() -> bool:
	return break_held and _has_break_target


## 当前破坏进度 0..1；未在破坏时返回 0。
func break_ratio() -> float:
	if _break_total <= 0.0:
		return 0.0
	return clampf(_break_progress / _break_total, 0.0, 1.0)


func _try_attack_mob() -> bool:
	if _world == null:
		return false
	var hit := _raycast_target()
	if hit.is_empty():
		return false
	var collider: Object = hit.get("collider")
	if not (collider and collider is Mob):
		return false
	if Time.get_ticks_msec() - _last_attack_ms < ATTACK_COOLDOWN_MS:
		return true
	_attack_mob(collider as Mob)
	_last_attack_ms = Time.get_ticks_msec()
	return true


## 近战命中生物：伤害与提示由 HuntRules 结算（保护动物与幼体免伤）。
func _attack_mob(mob: Mob) -> void:
	var tool := get_selected_tool()
	var outcome := HuntRules.evaluate(mob, tool)
	var toast := String(outcome["toast"])
	if not toast.is_empty():
		Events.notice.emit(toast)
	if not bool(outcome["ok"]):
		# 保护动物与幼体免伤：记一笔「了解保护动物」，用于对应成就。
		if bool(outcome["protection"]):
			Progress.notify("protected_blocked")
		return
	mob.take_damage(int(outcome["damage"]))
	if GameState.is_survival() and HuntRules.wears_tool(mob, tool):
		inventory.damage_tool(active_inventory_slot(), 1)


func _update_breaking(delta: float) -> void:
	if not break_held:
		_reset_break()
		return

	var hit := _raycast_target()
	if hit.is_empty():
		_reset_break()
		return

	var collider: Object = hit.get("collider")
	if collider and collider is Mob:
		# 按住左键持续攻击：冷却结束后自动再次命中。
		# 修复原先仅按下瞬间攻击一次的问题；冷却中调用无副作用。
		_try_attack_mob()
		_reset_break()
		return

	var pos: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	# 体素命中（作物等）带精确 cell；物理命中从面位置反推方块格。
	var cell: Vector3i = hit["cell"] if hit.has("cell") \
		else Vector3i((pos - normal * 0.5).floor())
	var id := _world.get_block(cell)
	if id == BlockTypes.Block.AIR or not BlockTypes.HARDNESS.has(id):
		_reset_break()
		return

	if not _has_break_target or cell != _break_target:
		_break_target = cell
		_has_break_target = true
		_break_progress = 0.0
		_break_total = _break_time_for(id)

	_break_progress += delta
	_swing_cooldown -= delta
	if _swing_cooldown <= 0.0:
		_swing_cooldown = SWING_INTERVAL
		_held_item.swing()
		_model.swing_arms()
		# 挥动命中反馈：在命中面喷少量碎屑。
		BreakFx.spawn_hit(_world, pos, normal, id)
	if _break_progress >= _break_total:
		_finish_break(cell, id)
		_reset_break()


func _reset_break() -> void:
	_has_break_target = false
	_break_progress = 0.0
	_break_total = 0.0


func _break_time_for(id: int) -> float:
	if GameState.is_creative():
		return 0.0
	var hardness: float = BlockTypes.HARDNESS.get(id, 0.5)
	var tool := get_selected_tool()
	if tool != -1:
		var effective: String = BlockTypes.EFFECTIVE_TOOL.get(id, "")
		if effective != "" and effective == ItemTypes.tool_type(tool):
			return hardness / ItemTypes.tool_speed(tool)
	return hardness


func _finish_break(cell: Vector3i, id: int) -> void:
	var tool := get_selected_tool()
	var tool_type := ItemTypes.tool_type(tool) if tool != -1 else ""
	var drop := BlockTypes.drop_for(id, tool_type)

	# 矿石有最低工具等级要求：等级不够时采下却不给掉落，并提示该用什么。
	var required := BlockTypes.required_tier(id)
	if required > 0:
		var have_tier := ItemTypes.tool_tier(tool) if tool != -1 else 0
		if have_tier < required:
			drop = BlockTypes.Block.AIR
			Events.notice.emit("%s 太硬了，需要 %s 才能采下。" % [
				BlockTypes.display_name(id), BlockTypes.tier_hint(id)
			])

	# 储物箱被破坏前散落箱内全部物品，避免物资凭空消失。
	if id == BlockTypes.Block.CHEST:
		_world.spill_box(cell, self)

	_world.set_block(cell, BlockTypes.Block.AIR)
	# 砍的是木头：上方还立着树干就让它倒下来（_on_log_broken 内部判断是否成树）。
	if id == BlockTypes.Block.WOOD:
		_on_log_broken(cell)
	if GameState.is_survival():
		if drop != BlockTypes.Block.AIR:
			inventory.add_item(drop, BlockTypes.drop_count_for(id, tool_type))
			# 挖矿幸运掉落：额外矿石与宝藏（Toast 播报，让幸运看得见）。
			# 等级不够的矿连基础掉落都没有，自然也不参与幸运结算。
			var luck := 0
			if required > 0 and tool != -1:
				luck = ItemTypes.tool_tier(tool) - required
			for bonus: Array in BlockTypes.ore_lucky_drops(id, luck):
				inventory.add_item(int(bonus[0]), int(bonus[1]))
				Events.notice.emit("✨ 幸运掉落：%s ×%d！" % [
					ItemTypes.item_name(int(bonus[0])), int(bonus[1])
				])
		if tool != -1:
			inventory.damage_tool(active_inventory_slot(), 1)
	Events.block_broken.emit(id, cell)


## 砍断木头后的处置：上方还立着一截树干且顶着树冠 → 整截倒下来；
## 否则退回「整棵树砍光后树冠落叶」的老逻辑。
func _on_log_broken(cell: Vector3i) -> void:
	var height := _world.trunk_height_above(cell)
	# 手搭的木柱上方没有树冠，不该被当成树推倒——只按落叶处理。
	if height <= 0 or not _world.has_canopy_above(cell, height):
		_world.decay_tree_leaves(cell)
		return
	var logs := _world.fell_trunk_above(cell)
	# 树冠属于正在倒下的那截：无论下方是否还剩树桩，都随树一起走。
	_world.decay_tree_leaves(cell, true)
	# 倒向先取主轴：演出与落地铺木头必须用同一个方向，否则木头会躺在树倒向的斜对角。
	var dir := _axis_of(_tree_fall_direction(cell))
	FallingTree.spawn(
		_world,
		Vector3(cell) + Vector3(0.5, 0.5, 0.5),
		logs,
		dir,
		_on_tree_landed.bind(cell, logs, dir),
	)


## 倒向：背离玩家（从玩家指向树），玩家正贴着树时退化为面朝方向。
func _tree_fall_direction(cell: Vector3i) -> Vector3:
	var away := Vector3(cell.x + 0.5, 0.0, cell.z + 0.5) \
		- Vector3(global_position.x, 0.0, global_position.z)
	if away.length_squared() < 0.25:
		away = -Vector3(global_basis.z.x, 0.0, global_basis.z.z)
	if away.length_squared() < 0.01:
		away = Vector3(1.0, 0.0, 0.0)
	return away


## 把倒向吸附到水平主轴：斜着倒会让木头压在方块缝里，落点也不好预测。
func _axis_of(dir: Vector3) -> Vector3:
	if absf(dir.x) >= absf(dir.z):
		return Vector3(signf(dir.x) if dir.x != 0.0 else 1.0, 0.0, 0.0)
	return Vector3(0.0, 0.0, signf(dir.z) if dir.z != 0.0 else 1.0)


## 树落地：把倒下的树干铺在地面上（放不下的格子就丢弃，不悬空）。
func _on_tree_landed(cell: Vector3i, logs: int, dir: Vector3) -> void:
	var dir_cell := Vector3i(roundi(dir.x), 0, roundi(dir.z))
	if dir_cell == Vector3i.ZERO:
		dir_cell = Vector3i(1, 0, 0)
	_world.place_fallen_logs(cell, logs, dir_cell)


func _place_target() -> void:
	if _world == null:
		return
	var hit := _raycast_target()
	if hit.is_empty():
		return

	# 种植：手持蔬菜/小麦对准耕地右键，作物落在耕地上方一格。
	var held := get_selected_item()
	var crop := ItemTypes.crop_of(held)
	if crop != BlockTypes.Block.AIR:
		_plant_crop(crop, hit)
		return

	var pos: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	var cell := Vector3i((pos + normal * 0.5).floor())
	var target_id := _world.get_block(cell)
	if target_id != BlockTypes.Block.AIR and target_id != BlockTypes.Block.WATER:
		return
	if _overlaps_player(cell) or _overlaps_mob(cell):
		return

	var id := get_selected_placeable()
	if id == BlockTypes.Block.AIR:
		return
	_world.set_block(cell, id)
	if GameState.is_survival():
		inventory.remove_item(active_inventory_slot(), 1)
	Events.block_placed.emit(id, cell)
	_held_item.swing()
	_model.swing_arms()


## 在耕地（或任意泥土顶面）上种下作物：目标格必须为空气且下方是耕地。
func _plant_crop(crop: int, hit: Dictionary) -> void:
	var pos: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	var cell := Vector3i((pos + normal * 0.5).floor())
	if _world.get_block(cell) != BlockTypes.Block.AIR:
		return
	if _world.get_block(cell + Vector3i(0, -1, 0)) != BlockTypes.Block.FARMLAND:
		Events.notice.emit("🌱 作物只能种在耕地上。")
		return
	_world.set_block(cell, crop)
	if GameState.is_survival():
		inventory.remove_item(active_inventory_slot(), 1)
	Events.block_placed.emit(crop, cell)
	_held_item.swing()
	_model.swing_arms()


func _raycast_target() -> Dictionary:
	var space := get_world_3d().direct_space_state
	var from := _camera.global_position
	var to := from + (-_camera.global_transform.basis.z) * REACH_DISTANCE
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := space.intersect_ray(query)
	# 体素兜底：作物/水草等非固体方块没有碰撞面，物理射线会穿过去。
	# 体素命中带精确进入距离（distance）：不晚于物理命中（共用面算同时命中）
	# 就取体素——否则瞄准作物时会被其脚下耕地顶面的物理命中抢走，割到的永远是耕地。
	if _world != null:
		var vhit := _world.raycast_blocks(from, to)
		if not vhit.is_empty():
			if hit.is_empty() \
					or (vhit["distance"] as float) \
						<= (hit["position"] as Vector3).distance_to(from) + 0.001:
				return vhit
	return hit


func _overlaps_player(cell: Vector3i) -> bool:
	var cell_aabb := AABB(Vector3(cell), Vector3.ONE)
	var player_aabb := AABB(global_position - Vector3(0.8, 0.0, 0.8), Vector3(1.6, 3.6, 1.6))
	return cell_aabb.intersects(player_aabb)


func _overlaps_mob(cell: Vector3i) -> bool:
	var cell_aabb := AABB(Vector3(cell), Vector3.ONE)
	for node in get_tree().get_nodes_in_group("mobs"):
		var mob := node as Mob
		if mob == null:
			continue
		var mob_aabb := AABB(mob.global_position - Vector3(0.35, 0.0, 0.35), Vector3(0.7, 1.25, 0.7))
		if cell_aabb.intersects(mob_aabb):
			return true
	return false


func _update_fall_state() -> void:
	if is_on_floor():
		if _fall_speed > FALL_DAMAGE_THRESHOLD:
			_apply_fall_damage(_fall_speed)
		_fall_speed = 0.0
	else:
		_fall_speed = maxf(_fall_speed, -velocity.y)


func _tick_survival(delta: float, sprinting: bool) -> void:
	if GameState.is_creative():
		return

	var drain := HUNGER_DRAIN_PER_SECOND * delta
	if sprinting:
		drain += SPRINT_HUNGER_DRAIN * delta

	hunger = maxf(0.0, hunger - drain)
	var hunger_int := int(hunger)
	if hunger_int != _last_hunger_int:
		_last_hunger_int = hunger_int
		hunger_changed.emit(hunger_int)

	if hunger <= 0.0:
		_starvation_timer += delta
		if _starvation_timer >= STARVATION_DAMAGE_INTERVAL:
			_starvation_timer = 0.0
			_damage(1, REASON_STARVE)
	else:
		_starvation_timer = 0.0

	_tick_fish_companionship(delta)


## 鱼群陪伴：身边有鱼在游时缓慢回血——「看到鱼心情就好」的轻量正向反馈。
func _tick_fish_companionship(delta: float) -> void:
	if health >= MAX_HEALTH:
		return
	var near_fish := false
	for node in get_tree().get_nodes_in_group("mobs"):
		var mob := node as Mob
		if mob == null or mob.is_queued_for_deletion() or mob.type != Mob.MobType.FISH:
			continue
		if global_position.distance_to(mob.global_position) <= FISH_HEAL_RADIUS:
			near_fish = true
			break
	if not near_fish:
		_fish_heal_timer = 0.0
		return
	_fish_heal_timer += delta
	if _fish_heal_timer >= FISH_HEAL_INTERVAL:
		_fish_heal_timer = 0.0
		health = mini(MAX_HEALTH, health + 1)
		health_changed.emit(health)


func _apply_fall_damage(fall_speed: float) -> void:
	var excess := fall_speed - FALL_DAMAGE_THRESHOLD
	if excess <= 0.0:
		return
	_damage(int(ceil(excess * FALL_DAMAGE_SCALE)), REASON_FALL)


## 真正的扣血入口：集中处理无敌、死亡、重生与来源广播。
func _damage(amount: int, reason: String = "") -> void:
	if _dead or GameState.is_creative():
		return
	health -= amount
	damage_taken.emit(amount, reason, maxi(0, health))
	if health <= 0:
		# 不死图腾：致命一击时自动消耗，恢复半血并免于死亡。
		if inventory.consume_item(ItemTypes.TOTEM, 1):
			health = MAX_HEALTH / 2
			health_changed.emit(health)
			return
		health = 0
		died.emit()
		_begin_death()
		return
	health_changed.emit(health)


## 死亡表现：原地立起 R.I.P 墓碑，短暂停顿后再从出生点复活。
## 停顿期间玩家冻结（不移动、不受击、不交互）；防卡死脱困不走这里（保持瞬间重生）。
func _begin_death() -> void:
	if _dead:
		return
	_dead = true
	velocity = Vector3.ZERO
	# 驾驶中死亡：先把飞机交还（否则复活后会立刻被贴回座舱）。
	if _aircraft != null:
		exit_aircraft()
	var tomb_parent := get_parent()
	if tomb_parent != null:
		# 墓碑立在身前 1.6 米（与尸体错开，路人一眼可见；朝向取水平面投影）。
		var facing := -global_transform.basis.z
		facing.y = 0.0
		var front := facing.normalized() if facing.length_squared() > 0.0001 \
			else Vector3(0.0, 0.0, -1.0)
		Tombstone.spawn(tomb_parent, global_position + front * 1.6, global_position)
	get_tree().create_timer(DEATH_PAUSE).timeout.connect(_finish_death)


func _finish_death() -> void:
	if not _dead:
		return
	_dead = false
	_respawn()


## 外部（生物近战、箭矢）打玩家走这里：带来源 + 受击无敌帧。
## 无敌帧只拦这条路，不走 _damage，因此卡死脱困与探针直接扣血不受影响。
func take_damage(amount: int, source: String = "") -> void:
	if _dead or _hurt_invuln > 0.0:
		return
	_hurt_invuln = HURT_INVULN_TIME
	_damage(amount, source)


func _respawn() -> void:
	health = MAX_HEALTH
	hunger = float(MAX_HUNGER)
	_starvation_timer = 0.0
	_hurt_invuln = 0.0
	velocity = Vector3.ZERO
	# 清空坠落速度：重生前残留的坠落速度会在落地瞬间被误判为跌落伤害。
	_fall_speed = 0.0
	_stuck_frames = 0
	global_position = spawn_position
	_last_hunger_int = MAX_HUNGER
	health_changed.emit(health)
	hunger_changed.emit(int(hunger))


func _get_move_input() -> Vector2:
	var input := virtual_move
	input.x += Input.get_axis("move_left", "move_right")
	input.y += Input.get_axis("move_back", "move_forward")
	return input.limit_length(1.0)


func _apply_walk(delta: float, input: Vector2, jump_pressed: bool, speed: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = -0.5
		if jump_pressed:
			velocity.y = JUMP_VELOCITY

	var dir := _camera_relative_dir(input)
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed


func _fly_velocity(input: Vector2, jump_pressed: bool) -> Vector3:
	var forward := -_camera.global_transform.basis.z
	var right := _camera.global_transform.basis.x
	var dir := forward * input.y + right * input.x

	var vertical := 0.0
	if jump_pressed:
		vertical += 1.0
	if virtual_descend or Input.is_action_pressed("fly_down"):
		vertical -= 1.0
	dir += Vector3.UP * vertical

	if dir.length_squared() > 0.0:
		dir = dir.normalized()
	return dir * FLY_SPEED


func _camera_relative_dir(input: Vector2) -> Vector3:
	if input.length_squared() < 0.0001:
		return Vector3.ZERO

	var forward := -_camera.global_transform.basis.z
	var right := _camera.global_transform.basis.x
	forward.y = 0.0
	right.y = 0.0
	return (forward * input.y + right * input.x).normalized()


func _rotate_view(delta: Vector2) -> void:
	rotate_y(-delta.x)
	var pitch := _camera.rotation.x - delta.y
	_camera.rotation.x = clampf(pitch, -PITCH_LIMIT, PITCH_LIMIT)
	# 第三人称弹簧臂俯仰与第一人称相机保持一致（yaw 由父节点旋转自动跟随）。
	_spring_arm.rotation.x = _camera.rotation.x


## 依相机距离切换第一/第三人称：距离为 0 时相机在眼位并隐藏模型。
func _apply_camera_mode() -> void:
	var first_person := camera_distance < FIRST_PERSON_MAX_DISTANCE
	_camera.current = first_person
	_third_camera.current = not first_person
	_held_item.visible = first_person
	_model.set_third_person(not first_person)
	# 驾驶中飞行员坐在舱内不显示：set_third_person(true) 会把模型重新置可见，
	# 而驾驶期间（滚轮切视角）仍可能走到这里，必须保持隐藏，否则人物会「站」在机身上。
	if _aircraft != null:
		_model.visible = false
		_held_item.visible = false
	_spring_arm.spring_length = camera_distance


## ── 蓄力射箭（M8.4） ──────────────────────────────────
## 推进蓄力：满蓄后不再增加；手中换成非弓时取消拉弓。
func _update_bow(delta: float) -> void:
	if _bow_charge <= 0.0:
		return
	if not ItemTypes.is_bow(get_selected_item()):
		_bow_charge = 0.0
		return
	_bow_charge = minf(BOW_MAX_CHARGE, _bow_charge + delta)


## 蓄力进度 0..1（供 HUD 画蓄力条）。
func bow_charge_ratio() -> float:
	if _bow_charge <= 0.0:
		return 0.0
	return clampf((_bow_charge - BOW_MIN_CHARGE) / (BOW_MAX_CHARGE - BOW_MIN_CHARGE), 0.0, 1.0)


func is_charging_bow() -> bool:
	return _bow_charge > 0.0


## 松手射箭：生存与探索模式消耗一支箭，伤害与初速随蓄力提升。
func _release_bow() -> void:
	var charge := bow_charge_ratio()
	_bow_charge = 0.0
	if get_parent() == null:
		return
	if GameState.is_survival():
		if inventory.count_item(ItemTypes.ARROW) <= 0:
			Events.notice.emit("没有箭了——用木头、圆石和羽毛做几支吧。")
			return
		inventory.consume_item(ItemTypes.ARROW, 1)
	var arrow := ArrowProjectile.new()
	arrow.setup_player_shot(self, _ray_forward(), charge, HuntRules.bow_damage(charge))
	get_parent().add_child(arrow)
	arrow.global_position = camera_position() + _ray_forward() * 0.6
	_held_item.swing()
	_model.swing_arms()


## ── 垂钓（M8.4） ──────────────────────────────────────
## 右键手持鱼竿：未抛竿则抛竿，已抛竿则收竿。
func _toggle_fishing() -> void:
	if _fishing == FISH_IDLE:
		_cast_fishing()
	else:
		_reel_fishing()


## 抛竿：沿准星找最近的一格水，把浮标放在水面并开始等待咬钩。
func _cast_fishing() -> bool:
	if _world == null:
		return false
	var from := camera_position()
	var dir := _ray_forward()
	var found := Vector3.INF
	var travelled := 0.0
	while travelled <= FISH_CAST_RANGE:
		travelled += 0.5
		var cell := Vector3i((from + dir * travelled).floor())
		var id := _world.get_block(cell)
		if id == BlockTypes.Block.WATER:
			found = Vector3(float(cell.x) + 0.5, float(World.SEA_LEVEL) + 1.05, float(cell.z) + 0.5)
			break
		# 撞到实心方块说明水在障碍后面，不再继续找。
		if id != BlockTypes.Block.AIR and not BlockTypes.is_water_plant(id):
			break
			break
	if found == Vector3.INF:
		Events.notice.emit("把浮标甩到水面上才能钓鱼。")
		return false
	if get_parent() == null:
		return false
	_bobber = FishingBobber.new()
	_bobber.setup(self)
	get_parent().add_child(_bobber)
	_bobber.global_position = found
	_fishing = FISH_WAITING
	_fish_timer = randf_range(FISH_WAIT_MIN, FISH_WAIT_MAX)
	Events.notice.emit("抛竿啦，等浮标下沉时再按右键。")
	_held_item.swing()
	return true


## 收竿：咬钩窗口内收竿则有收获，否则空手而归。
func _reel_fishing() -> void:
	if _fishing == FISH_BITING:
		var loot := ItemTypes.roll_fishing_loot()
		var item := int(loot["item"])
		var count := int(loot["count"])
		var leftover := inventory.add_item(item, count)
		var gained := count - leftover
		if gained > 0:
			Events.notice.emit("钓到了 %s ×%d！" % [ItemTypes.item_name(item), gained])
		else:
			Events.notice.emit("背包满了，%s 溜走了。" % ItemTypes.item_name(item))
	else:
		Events.notice.emit("还没有鱼上钩，再耐心等等。")
	_clear_fishing()


func _clear_fishing() -> void:
	_fishing = FISH_IDLE
	_fish_timer = 0.0
	if _bobber != null and is_instance_valid(_bobber):
		_bobber.queue_free()
	_bobber = null


## 垂钓状态推进：等待 → 咬钩 → 超时回到等待。
func _update_fishing(delta: float) -> void:
	if _fishing == FISH_IDLE:
		return
	if _bobber == null or not is_instance_valid(_bobber):
		_clear_fishing()
		return
	_fish_timer -= delta
	if _fish_timer > 0.0:
		return
	if _fishing == FISH_WAITING:
		_fishing = FISH_BITING
		_fish_timer = FISH_BITE_WINDOW
		_bobber.set_biting(true)
		Events.notice.emit("咬钩了！快按右键收竿。")
	else:
		# 咬钩窗口错过：鱼儿脱钩，回到等待状态。
		_fishing = FISH_WAITING
		_fish_timer = randf_range(FISH_WAIT_MIN, FISH_WAIT_MAX)
		_bobber.set_biting(false)
		Events.notice.emit("鱼跑掉了……继续等吧。")


## 垂钓状态：0 未抛竿，1 等待咬钩，2 咬钩中（供 HUD 与探针读取）。
func fishing_state() -> int:
	return _fishing


## 相机世界坐标（浮标牵引钓线时读取）。
func camera_position() -> Vector3:
	return _camera.global_position


## 相机朝向（射箭与抛竿的基准方向）。
func _ray_forward() -> Vector3:
	return -_camera.global_transform.basis.z
