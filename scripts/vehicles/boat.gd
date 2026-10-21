class_name Boat
extends CharacterBody3D
## 可乘坐的船（D-042 航海玩法）——四大洋的默认载具。
##
## 分工（与 Aircraft 同构的两段式）：数值积分在 BoatPhysics（纯逻辑），
## 本节点只做「把状态搬进场景」——浮水/地形碰撞/骑乘座位/读数广播。
## 船模是 BoatModel（程序化盒子拼装）。
##
## 世界尺度（D-030）：1 格 = 0.5 m。水线 = SEA_LEVEL + 1（水填到 y≤22，
## 可浮面在 23）。船体碰撞盒半高 1.1，底落在水线略下方——深水不搁浅，
## 滩涂地形高出水线时自然被碰撞盒挡住（搁浅）。
##
## 驾驶输入（piloted 且 use_player_input 且 BoatSystem.input_suspended 为假）：
##   W/S → 油门加/减（S 是倒车，油门取负）   A/D → 左/右舵
##   F → 发动机启停（有油料的船；木筏恒「有动力」）   X → 下船
## 探针把 use_player_input 置否、直接写 physics.throttle/steer 走同一路径。
##
## 航线数据（HUD 与钓鱼分带共用）：harbor_pos 由 Main 摆船时注入
## （港口泊位），距港距离 = 横向距离 × 0.5 m。

## 读数广播节流（秒）：与 Aircraft 一致。
const READINGS_INTERVAL := 0.1
## 驾驶座相对船体的偏移（局部坐标，+Z 船头）：站在驾驶位。
const SEAT_OFFSET := Vector3(0.0, 2.3, -0.5)
## 油门变化速率（每秒）与舵角速率（每秒）。
const THROTTLE_RATE := 0.8
const STEER_RATE := 2.2
## 垂直弹簧（1/s）：把船拢在水线/滩涂支撑面上，move_and_slide 负责碰撞滑开。
const FLOAT_SPRING := 6.0
## 地形扫描范围（格）：自 SEA_LEVEL+8 向下找首个实心块。
const TERRAIN_SCAN_TOP := World.SEA_LEVEL + 8
const TERRAIN_SCAN_BOTTOM := 4
## 登船判定：玩家与船体原点的横向距离（格）。
const BOARD_RANGE := 6.5
## 加油：距港此距离内且近乎静止时自动补油（升/秒）。
const REFUEL_RADIUS := 14.0
const REFUEL_RATE := 2.0
## 油料落盘节流（秒）：骑行中定期存，避免每次抖动都写盘。
const FUEL_SAVE_INTERVAL := 2.0

## 每帧读数变化时广播（节流到 READINGS_INTERVAL），航海 HUD 监听。
signal readings_changed(snapshot: Dictionary)
## 登船 / 下船广播（HUD 显隐航海界面）。
signal boarded(rider: Node)
signal exited

@export var use_player_input := true
## 船型 id（数据表 boat_by_id 的键）；_ready 时据此生成船模与物理参数。
@export var boat_id := "raft"

var physics := BoatPhysics.new()
var model: BoatModel
## 是否有人驾驶（决定输入来源与座位跟随）。
var piloted := false
## 当前骑乘者（Player），未骑乘为 null。
var rider: Player = null
## 港口泊位（世界坐标）：Main 摆船时注入；零向量 = 无港口（距港 -1）。
var harbor_pos := Vector3.ZERO

var _world: World = null
var _day_night: DayNightCycle = null
var _model_root: Node3D
var _readings_timer := 0.0
var _fuel_timer := 0.0
var _refuel_noticed := false
var _bob_phase := 0.0
## 最近一次算出的海况（HUD 风向显示用；不重算，保证与物理同一份）。
var _last_sea: Dictionary = {}


func _ready() -> void:
	var spec := BoatSystem.boat_by_id(boat_id)
	if spec.is_empty():
		push_error("boat: 未知船型 %s，退回木筏" % boat_id)
		spec = BoatSystem.boat_by_id("raft")
		boat_id = "raft"
	# 物理参数 + 持久化油量（新档满油；老档读 user://boats.json）。
	var at := Vector2(global_position.x, global_position.z)
	var facing := rotation.y
	physics.setup(spec, at, facing)
	physics.fuel = BoatSystem.fuel_of(boat_id)

	_model_root = Node3D.new()
	add_child(_model_root)
	model = BoatModel.new()
	model.spec = spec
	_model_root.add_child(model)

	# 碰撞盒：横向略宽于船身、半高 1.1（底落在水线略下方）。
	var shape := BoxShape3D.new()
	var width := float(spec.get("width_blocks", 4.2))
	var length := float(spec.get("length_blocks", 11.0))
	shape.size = Vector3(width + 0.8, 2.2, length + 0.8)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = Vector3(0.0, 1.1, 0.0)
	add_child(collider)
	# 船只与玩家互不碰撞（登船时贴 seat，避免两个 CharacterBody3D 互挤）。
	collision_layer = 1 << 3
	collision_mask = 1  # 只与世界（地形）碰撞


func _physics_process(delta: float) -> void:
	_read_input(delta)
	var sea := _sea_state()
	_last_sea = sea
	physics.step(delta, sea)
	_apply_motion(delta, sea)
	_update_refuel(delta)
	_emit_readings(delta)
	_bob_phase += delta


## 输入：只读「有人驾驶 + 允许输入 + 模态面板没开」三条件全满足时。
func _read_input(delta: float) -> void:
	if not (piloted and use_player_input and not BoatSystem.input_suspended):
		# 没人在开：舵回中、油门收掉（漂流）。
		physics.throttle = move_toward(physics.throttle, 0.0, THROTTLE_RATE * delta)
		physics.steer = move_toward(physics.steer, 0.0, STEER_RATE * delta)
		return
	var target_throttle := 0.0
	if Input.is_action_pressed("move_forward"):
		target_throttle = 1.0
	elif Input.is_action_pressed("move_back"):
		target_throttle = -0.4  # 倒车慢
	physics.throttle = move_toward(physics.throttle, target_throttle, THROTTLE_RATE * delta)
	var target_steer := 0.0
	if Input.is_action_pressed("move_left"):
		target_steer = -1.0
	elif Input.is_action_pressed("move_right"):
		target_steer = 1.0
	physics.steer = move_toward(physics.steer, target_steer, STEER_RATE * delta)


## 海况：区域 × 天气 × 时刻（进港避风）。day_night 未注入时按晴 + 正午。
func _sea_state() -> Dictionary:
	var region := GameState.current_region
	var weather := DayNightCycle.Weather.CLEAR
	var day_t := 43200.0
	if _day_night != null and is_instance_valid(_day_night):
		weather = _day_night.get_weather()
		day_t = _day_night.elapsed_seconds()
	var sea := BoatSystem.sea_state(region, weather, day_t, is_at_harbor())
	# 风沿航向分量（顺风正、逆风负）：BoatPhysics.step 用于顺推/逆阻。
	# 投影到当前船首方向，世界风向见 BoatSystem.sea_state 返回的 wind_deg/wind_mps。
	var wind_mps := float(sea.get("wind_mps", 0.0))
	var wind_dir := Vector2(sin(deg_to_rad(float(sea.get("wind_deg", 0.0)))),
		cos(deg_to_rad(float(sea.get("wind_deg", 0.0)))))
	var fwd := Vector2(sin(physics.heading), cos(physics.heading))
	sea["wind_along_mps"] = wind_mps * wind_dir.dot(fwd)
	return sea


## 运动：横向速度来自纯逻辑；纵向用弹簧拢到「水线/滩涂支撑面」，
## move_and_slide 负责与海岛地形的碰撞（搁浅时被坡面挡住滑停）。
func _apply_motion(delta: float, sea: Dictionary) -> void:
	var support := _support_height()
	var wave := float(sea.get("wave_m", 0.0))
	var bob := sin(_bob_phase * 1.6) * wave * 0.10
	var target_y := support + bob
	# 横向（X/Z）速度来自纯逻辑积分；纵向用弹簧拢到支撑面。
	# physics.vel 是 Vector2（x→世界 X、y→世界 Z），与世界 XZ 平面对应。
	velocity = Vector3(physics.vel.x,
		clampf((target_y - global_position.y) * FLOAT_SPRING, -30.0, 30.0),
		physics.vel.y)
	move_and_slide()
	rotation.y = physics.heading
	# 船体摇晃（只摇模型，不摇碰撞盒）。
	var t := _bob_phase
	model.rotation.z = sin(t * 1.1) * wave * 0.03
	model.rotation.x = sin(t * 0.8 + 1.3) * wave * 0.02


## 支撑面高度（格）：该列最高实心块顶面；深水列（无水底实块）回退水线。
func _support_height() -> float:
	if _world == null:
		return float(World.SEA_LEVEL) + 1.0
	var cell := Vector3i(global_position.floor())
	for y in range(TERRAIN_SCAN_TOP, TERRAIN_SCAN_BOTTOM - 1, -1):
		var b := _world.get_block(Vector3i(cell.x, y, cell.z))
		if b != BlockTypes.Block.AIR and b != BlockTypes.Block.WATER:
			return float(y) + 1.0
	return float(World.SEA_LEVEL) + 1.0


## 靠港自动加油：泊位附近且近乎静止时补油，满油提示一次并落盘。
func _update_refuel(delta: float) -> void:
	if not physics.has_engine() or harbor_pos == Vector3.ZERO:
		return
	if not is_at_harbor() or physics.speed() > 3.0:
		return
	var cap := float(BoatSystem.boat_by_id(boat_id).get("fuel_l", 0.0))
	if physics.fuel >= cap:
		if not _refuel_noticed:
			_refuel_noticed = true
			Events.notice.emit("⛽ 油已加满，可以出海了。")
		return
	physics.fuel = minf(cap, physics.fuel + REFUEL_RATE * delta)
	BoatSystem.set_fuel_of(boat_id, physics.fuel)


func _emit_readings(delta: float) -> void:
	_readings_timer -= delta
	# 油料定期落盘（骑行中）。
	if piloted:
		_fuel_timer -= delta
		if _fuel_timer <= 0.0:
			_fuel_timer = FUEL_SAVE_INTERVAL
			if physics.has_engine():
				BoatSystem.set_fuel_of(boat_id, physics.fuel)
	if _readings_timer > 0.0:
		return
	_readings_timer = READINGS_INTERVAL
	readings_changed.emit(snapshot())


## 最近一次物理帧算出的海况（HUD 显示用，不重算）。
func current_sea_state() -> Dictionary:
	return _last_sea


## 当前读数快照（航海 HUD 与钓鱼分带共用一份，勿各算一套）。
func snapshot() -> Dictionary:
	var dist_blocks := distance_to_harbor()
	return {
		"boat_id": boat_id,
		"pos": global_position,
		"physics": physics.snapshot(),
		"wave_m": float(_last_sea.get("wave_m", 0.0)),
		# D-062 P1：1 格 = 1 m，格距离即米，不再 ×0.5。
		"harbor_distance_m": dist_blocks if dist_blocks >= 0.0 else -1.0,
		"band": BoatSystem.band_of(dist_blocks) if dist_blocks >= 0.0 else "near",
		"at_harbor": is_at_harbor(),
	}


## 距港横向距离（格）；无港口返回 -1。
func distance_to_harbor() -> float:
	if harbor_pos == Vector3.ZERO:
		return -1.0
	return Vector2(global_position.x - harbor_pos.x, global_position.z - harbor_pos.z).length()


func is_at_harbor() -> bool:
	if harbor_pos == Vector3.ZERO:
		return false
	return distance_to_harbor() <= REFUEL_RADIUS


## 驾驶座世界变换（玩家每帧贴这，同 Aircraft.seat_transform）。
func seat_transform() -> Transform3D:
	return global_transform * Transform3D(Basis(), SEAT_OFFSET)


func set_piloted(value: bool, who: Player = null) -> void:
	piloted = value
	rider = who if value else null
	if value:
		boarded.emit(who)
	else:
		exited.emit()


## F 键：发动机启停（木筏无发动机，提示即可）。
func toggle_engine() -> void:
	if not physics.has_engine():
		Events.notice.emit("🪵 木筏没有发动机，靠划桨和风——W 推桨、S 倒划。")
		return
	if physics.fuel <= 0.0:
		Events.notice.emit("⛽ 没油了：回港靠岸会自动加油，或先随波漂回去。")
		return
	physics.engine_on = not physics.engine_on
	Events.notice.emit("🚤 发动机%s" % ("已启动" if physics.engine_on else "已熄火"))


## 玩家是否在登船判定范围内（横向距离，格）。
func within_board_range(world_pos: Vector3) -> bool:
	var d := Vector2(world_pos.x - global_position.x, world_pos.z - global_position.z).length()
	return d <= BOARD_RANGE


## 注入世界与昼夜（Main 摆船后调用）：地形扫描与海况读数都需要。
func setup_world(world: World, day_night: DayNightCycle) -> void:
	_world = world
	_day_night = day_night


## 浮动原点搬迁（D-062）：节点位置由 main 的组遍历整体 +delta，这里补内部
## 渲染锚点 harbor_pos——「距港距离 / 鱼种带」判据拿它与 global_position 做差，
## 不随节点一起平移会让停靠中的船永远算出「已离港」。
func rebase_anchors_after_shift(delta: Vector3) -> void:
	if harbor_pos != Vector3.ZERO:
		harbor_pos += delta


## 摆一艘船：parent 下的新节点，落位 at、船头朝向 facing（rotation.y）。
## use_player_input=false 的实例是港口里泊着的装饰船（不读输入、不广播）。
static func spawn(parent: Node, at: Vector3, facing: float, which_boat_id: String,
		use_input: bool = true) -> Boat:
	var boat := Boat.new()
	boat.boat_id = which_boat_id
	boat.use_player_input = use_input
	boat.position = at
	boat.rotation.y = facing
	parent.add_child(boat)
	WorldAnchor.register(boat)  # D-062：Main 级实体，随 origin 搬迁
	return boat
