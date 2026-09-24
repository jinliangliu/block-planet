extends CharacterBody3D
class_name Player
## 第一人称玩家控制器。
## 同时支持桌面（键盘 + 鼠标）与移动端（虚拟摇杆 + 触屏视角）。
## 键盘动作由 InputActions 运行时注册到 InputMap（见 scripts/core/input_actions.gd）。

const GRAVITY := 24.0
const JUMP_VELOCITY := 8.0
const WALK_SPEED := 5.5
const SPRINT_SPEED := 9.0
const FLY_SPEED := 12.0
const MOUSE_SENSITIVITY := 0.002
const TOUCH_LOOK_SENSITIVITY := 0.004
const PITCH_LIMIT := 1.55
const REACH_DISTANCE := 8.0
const MAX_HEALTH := 20
const MAX_HUNGER := 20
const HUNGER_DRAIN_PER_SECOND := 0.08
const SPRINT_HUNGER_DRAIN := 0.12
const STARVATION_DAMAGE_INTERVAL := 4.0
# 落地速度阈值：sqrt(2 * GRAVITY * 3) ≈ 12 m/s，对应约 3 格内免伤。
const FALL_DAMAGE_THRESHOLD := 12.0
const FALL_DAMAGE_SCALE := 0.5
## 蓄力射箭：按住右键满蓄 BOW_MAX_CHARGE 秒，伤害与初速随蓄力提升。
const BOW_MIN_CHARGE := 0.15
const BOW_MAX_CHARGE := 1.2
## 垂钓状态机取值：未抛竿 / 等待咬钩 / 咬钩中。
const FISH_IDLE := 0
const FISH_WAITING := 1
const FISH_BITING := 2
## 垂钓：抛竿最远距离、等待咬钩的时间区间与咬钩窗口。
const FISH_CAST_RANGE := 14.0
const FISH_WAIT_MIN := 2.0
const FISH_WAIT_MAX := 5.0
const FISH_BITE_WINDOW := 1.6
## 兼容旧命名的基准伤害（狩猎实际伤害由 HuntRules 按工具结算）。
const ATTACK_DAMAGE := 1
const ATTACK_COOLDOWN_MS := 500
const DOUBLE_TAP_FLY_MS := 300
const CAM_STEP := 0.9
const CAM_DISTANCE_MAX := 4.5
const FIRST_PERSON_MAX_DISTANCE := 0.05
const SWING_INTERVAL := 0.3
# 防卡死：脚部与头部格均为实心且持续超过宽限帧数，判定嵌入地形并瞬间重生脱困。
# 宽限 3 帧过滤传送/高速掠过的单帧误判，体感仍接近瞬间。
const STUCK_GRACE_FRAMES := 3

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
var _last_hunger_int := MAX_HUNGER
var _stuck_frames := 0
## 防卡死累计脱困次数（探针/调试用）。
var stuck_rescues := 0

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
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_rotate_view(Vector2(event.relative.x, event.relative.y) * MOUSE_SENSITIVITY)

	# 滚轮缩放视角：拉近回第一人称，拉远经弹簧臂切第三人称（可看到角色形体）。
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_distance = maxf(0.0, camera_distance - CAM_STEP)
			_apply_camera_mode()
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_distance = minf(CAM_DISTANCE_MAX, camera_distance + CAM_STEP)
			_apply_camera_mode()
			return

	if event is InputEventMouseButton and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
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
		if event.is_action_pressed("jump"):
			_handle_jump_tap()

	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = (
			Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED
		)


## 双击跳跃键在创造模式下切换飞行。
func _handle_jump_tap() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_jump_ms <= DOUBLE_TAP_FLY_MS:
		_last_jump_ms = 0
		if GameState.is_creative():
			set_flying(not flying)
	else:
		_last_jump_ms = now


func _process(delta: float) -> void:
	_update_breaking(delta)
	_update_bow(delta)
	_update_fishing(delta)
	if virtual_place:
		virtual_place = false
		_begin_use()


## 右键按下：手持弓开始蓄力，手持鱼竿抛竿/收竿，其余走 _use_selected。
func _begin_use() -> void:
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
	if _eat_selected():
		return
	if _interact_village():
		return
	_place_target()


## 右键指向村民/酿灶台时请求交易，指向储物箱时请求打开储物面板。
func _interact_village() -> bool:
	var hit := _raycast_target()
	if hit.is_empty():
		return false
	var collider: Object = hit["collider"]
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
	health = 0
	died.emit()
	_respawn()
	if _world != null:
		global_position = _safe_respawn_position()


## 出生点被堵时沿 Y 向上搜索"两格空气 + 实心底"的安全落点，
## 防止重生后立即再次卡死形成循环。
func _safe_respawn_position() -> Vector3:
	var cell := Vector3i(spawn_position.floor())
	for _i in range(64):
		var feet_free := not BlockTypes.is_solid(_world.get_block(cell))
		var head_free := not BlockTypes.is_solid(_world.get_block(cell + Vector3i(0, 1, 0)))
		var grounded := BlockTypes.is_solid(_world.get_block(cell + Vector3i(0, -1, 0)))
		if feet_free and head_free and grounded:
			return Vector3(cell) + Vector3(0.5, 0.1, 0.5)
		cell.y += 1
	return spawn_position


func setup_world(world: World) -> void:
	_world = world


## 世界访问器：HUD 打开储物箱面板时经此读取箱内背包（避免直接访问私有成员）。
func get_world() -> World:
	return _world


func set_spawn_position(pos: Vector3) -> void:
	spawn_position = pos


## 选择快捷栏槽位并广播变化。
func select_slot(slot: int) -> void:
	selected_slot = clampi(slot, 0, Inventory.HOTBAR_SIZE - 1)
	selected_slot_changed.emit(selected_slot)


## 当前快捷栏位所引用的背包槽索引（-1 表示无有效映射）。
## 快捷栏是背包槽的视图：手持/消耗/耐久都以该索引操作背包本体。
func active_inventory_slot() -> int:
	if inventory == null:
		return -1
	return inventory.hotbar_slot(selected_slot)


## 切换飞行状态；仅创造模式允许飞行，切换时经事件总线广播。
func set_flying(value: bool) -> void:
	if value and not GameState.is_creative():
		return
	if flying == value:
		return
	flying = value
	if not flying:
		velocity = Vector3.ZERO
	Events.player_mode_changed.emit(flying)


func _on_game_mode_changed(_mode: int) -> void:
	if not GameState.is_creative():
		set_flying(false)


func get_selected_item() -> int:
	if GameState.is_creative():
		var blocks := BlockTypes.HOTBAR_BLOCKS
		return blocks[clampi(selected_slot, 0, blocks.size() - 1)]
	return inventory.get_item(active_inventory_slot())


func get_selected_tool() -> int:
	var item := get_selected_item()
	return item if ItemTypes.is_tool_item(item) else -1


func get_selected_placeable() -> int:
	var item := get_selected_item()
	return item if ItemTypes.is_placeable(item) else BlockTypes.Block.AIR


func start_break_or_attack() -> void:
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
	var collider: Object = hit["collider"]
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

	var collider: Object = hit["collider"]
	if collider and collider is Mob:
		# 按住左键持续攻击：冷却结束后自动再次命中。
		# 修复原先仅按下瞬间攻击一次的问题；冷却中调用无副作用。
		_try_attack_mob()
		_reset_break()
		return

	var pos: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	var cell := Vector3i((pos - normal * 0.5).floor())
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
	if GameState.is_survival():
		if drop != BlockTypes.Block.AIR:
			inventory.add_item(drop, BlockTypes.drop_count_for(id, tool_type))
		if tool != -1:
			inventory.damage_tool(active_inventory_slot(), 1)
	Events.block_broken.emit(id, cell)


func _place_target() -> void:
	if _world == null:
		return
	var hit := _raycast_target()
	if hit.is_empty():
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


func _raycast_target() -> Dictionary:
	var space := get_world_3d().direct_space_state
	var from := _camera.global_position
	var to := from + (-_camera.global_transform.basis.z) * REACH_DISTANCE
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return space.intersect_ray(query)


func _overlaps_player(cell: Vector3i) -> bool:
	var cell_aabb := AABB(Vector3(cell), Vector3.ONE)
	var player_aabb := AABB(global_position - Vector3(0.4, 0.0, 0.4), Vector3(0.8, 1.8, 0.8))
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
			_damage(1)
	else:
		_starvation_timer = 0.0


func _apply_fall_damage(fall_speed: float) -> void:
	var excess := fall_speed - FALL_DAMAGE_THRESHOLD
	if excess <= 0.0:
		return
	_damage(int(ceil(excess * FALL_DAMAGE_SCALE)))


func _damage(amount: int) -> void:
	if GameState.is_creative():
		return
	health -= amount
	if health <= 0:
		# 不死图腾：致命一击时自动消耗，恢复半血并免于死亡。
		if inventory.consume_item(ItemTypes.TOTEM, 1):
			health = MAX_HEALTH / 2
			health_changed.emit(health)
			return
		health = 0
		died.emit()
		_respawn()
		return
	health_changed.emit(health)


func take_damage(amount: int) -> void:
	_damage(amount)


func _respawn() -> void:
	health = MAX_HEALTH
	hunger = float(MAX_HUNGER)
	_starvation_timer = 0.0
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


## 松手射箭：生存模式消耗一支箭，伤害与初速随蓄力提升。
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
