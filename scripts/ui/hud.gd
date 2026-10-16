extends CanvasLayer
class_name HUD
## 移动端触屏 HUD：左侧摇杆、右侧视角滑动、右下角动作按钮。
## 桌面环境显示键位提示。

## 生命爱心条：5 颗心换算 20 点生命，每颗 4 点。
const HEART_COUNT := 5
const HEARTS_PER_POINT := 4
## 右上角信息列：小地图距屏幕顶部/右缘的留白，模式徽章与时间行与它对齐同宽。
const MINIMAP_MARGIN := 20.0
## 模式徽章：贴在小地图外框正下方，只显示两个字（生存/创造/探索）。
## 字号比正文大、加深色描边——它是玩家一眼确认「当前在哪种模式」的锚点。
const MODE_BADGE_FONT_SIZE := 22
const MODE_BADGE_OUTLINE_SIZE := 5
const MODE_BADGE_OUTLINE := Color(0.06, 0.08, 0.12, 0.96)
const MODE_BADGE_HEIGHT := 32.0
const MODE_BADGE_GAP := 4.0
## 饥饿低于该值时提示一次「该吃东西了」（满值 20，即剩 1/5 时提醒）。
const HUNGER_WARN_LEVEL := 4

var _player: Player
var _root: Control
var _slot_group: ButtonGroup
var _recipe_group: ButtonGroup
var _slot_buttons: Array[Button] = []
## 快捷栏整条容器：创造/生存模式格数不同，刷新时按可见格数重新居中。
var _hotbar_bar: Control
## 左上角状态块容器（姓名 + 爱心 + 饥饿）：驾驶飞行器时整块隐藏，
## 按容器而非逐个节点控制——三个读数都随容器走，日后新增状态行自动跟随。
var _stats_box: Control
var _hunger_label: Label
var _name_label: Label
var _hearts: Control
var _minimap: MiniMap
var _time_label: Label
var _mode_label: Label
var _map_name_label: Label
var _map_selector: MapSelector
var _manual: ManualPanel
var _bestiary: BestiaryUI
var _quest_panel: QuestPanel
var _mission_panel: MissionPanel
var _settings_panel: SettingsPanel
## 钓鱼三件套（feature_fishing）：钓具界面 → 渔猎界面 → 教学浮层。
## 层级依次升高，教学盖在最上面（z_index 40）。
var _fishing_gear: FishingGearUI
var _fishing_ui: FishingUI
var _fishing_teaching: FishingTeachingUI
## 工坊台建造界面（main 持有、挂在 $UI 下）：模态互斥与冻结态广播用。
var _build_screen: BuildScreen
var _inventory_panel: InventoryPanel
var _toast_label: Label
var _toast_tween: Tween
var _death_overlay: Control
var _death_tween: Tween
var _day_night: DayNightCycle
var _craft_overlay: Control
var _craft_result_grid: GridContainer
var _craft_result_slot: ItemSlot
var _craft_tree: Control
var _craft_material_row: HBoxContainer
var _craft_craft_button: Button
var _selected_recipe := 0
## 合成台分类页：当前页号 + 页签按钮 + 页签分组（与成品格分组分开）。
var _craft_cat := 0
var _craft_cat_buttons: Array[Button] = []
var _craft_cat_group: ButtonGroup

## 合成台分页：名称 + 说明。配方按产物经 ItemTypes.recipe_page 自动归页。
const CRAFT_PAGES := [
	["工具", "镐 · 斧 · 铲 · 镰"],
	["武器钓具", "弓 · 箭 · 鱼竿"],
	["方块", "玻璃 · 储物箱 · 冶炼炉"],
	["食物", "面包等可食用成品"],
]
var _log_label: Label
var _log_lines := PackedStringArray()
var _trade_overlay: Control
var _trade_list: VBoxContainer
## 交易面板页签：0 买入（绿宝石换物资）/ 1 卖出（物资换绿宝石）。
var _trade_tab := 0
var _trade_tab_buttons: Array[Button] = []
var _box_overlay: Control
var _box_grid: GridContainer
var _box_player_grid: GridContainer
var _open_box_cell := Vector3i.ZERO
var _box_inventory: Inventory
var _tip_panel: PanelContainer
var _tip_name: Label
var _tip_desc: Label
var _tip_viewport: SubViewport
var _tip_mesh: MeshInstance3D
var _smelt_overlay: Control
var _smelt_list: VBoxContainer
var _fly_button: Button
var _descend_button: Button
var _break_bar: ProgressBar
var _charge_bar: ProgressBar
var _look_touch := -1
## 飞行仪表：仅驾驶飞行器时显示（见 Aircraft.snapshot 的读数来源）。
var _flight_panel: PanelContainer
var _flight_speed: Label
var _flight_altitude: Label
var _flight_throttle: Label
var _flight_stall: Label
## 触屏飞行控制层：仅触屏设备、驾驶飞行器时出现；隐藏步行触控（_touch_walk）。
var _flight_touch: Control
var _touch_walk: Control
var _ft_throttle_slider: VSlider
var _ft_pitch := 0.0
var _ft_roll := 0.0
var _ft_yaw := 0.0
var _ft_throttle := 0.0
## 当前驾驶的飞机（P2-5 坠机原因播报用）：驾驶中连接 crashed 信号，
## 下机断开——wreck 先广播原因再弹射玩家，连接在广播时仍有效。
var _ridden_craft: Aircraft = null
var _ft_brake := false
## 飞行视角三件套（D-033，main 装配时经 setup_flight 注入）：相机 rig /
## 轨迹录制器 / 回放。驾驶中的 C/V/M/R、任务成功自动回放、P 手动回放都经它们。
var _flight_camera: AircraftCamera = null
var _recorder: FlightRecorder = null
var _replay: FlightReplay = null
## 飞行仪表的两行新读数（D-033）：当前视角模式 + 发动机状态。
var _flight_view: Label
var _flight_engine: Label
## 回放提示条（回放期间居中显示，Esc 跳过）。
var _replay_hint: Label
## 触屏飞行层新增按钮（D-033）：视角切换 / 发动机启停。
var _ft_view: Button
var _ft_engine: Button
## 飞行战术地图（D-033，M 键）：_build 时创建，默认隐藏。
var _tactical_map: FlightTacticalMap
## 飞行屏幕仪表 HUD（D-034）：座舱玻璃 HUD / 追尾四角 / 小地图 / 警告 / 详细清单。
var _instrument_hud: FlightInstrumentHUD
## 警告蜂鸣码播放器（D-034）：程序生成音，落地儿童友好「语音提示」。
var _alert_beeper: AlertBeeper


func setup(player: Player) -> void:
	InputActions.register()
	_player = player
	_player.selected_slot_changed.connect(_on_player_slot_changed)
	_player.health_changed.connect(_on_health_changed)
	_player.hunger_changed.connect(_on_hunger_changed)
	# 掉血提示：把「血怎么没的」显示出来（饥饿 / 摔落 / 被谁打了）。
	_player.damage_taken.connect(_on_damage_taken)
	_player.inventory.changed.connect(_refresh_hotbar)
	# 背包变化时若合成台开着，同步刷新按钮可用态，避免「攒够材料按钮却还灰着」。
	_player.inventory.changed.connect(_on_inventory_changed_for_craft)
	GameState.mode_changed.connect(_on_mode_changed)
	Events.player_mode_changed.connect(_on_player_flying_changed)
	Events.request_trade.connect(set_trade_open.bind(true))
	# 通用提示通道：狩猎拦截、矿石等级不足、垂钓结果等都以 Toast 呈现。
	Events.notice.connect(_on_notice)
	# 死亡 RIP 覆盖层：与玩家的墓碑停顿同步浮现与消隐。
	Events.player_died.connect(_on_player_died)
	# 登机 / 下机：飞行仪表随驾驶状态显隐（读数本身每帧轮询）。
	Events.aircraft_ride_changed.connect(_on_aircraft_ride_changed)
	_build()
	_on_mode_changed(GameState.mode)


func set_day_night(day_night: DayNightCycle) -> void:
	_day_night = day_night
	if day_night:
		day_night.time_changed.connect(_on_time_changed)
		day_night.day_changed.connect(_on_day_changed)
		_refresh_time()


## 飞行视角三件套注入（D-033，main._ready 调用）：相机 / 录制 / 回放。
func setup_flight(camera: AircraftCamera, recorder: FlightRecorder,
		replay: FlightReplay) -> void:
	_flight_camera = camera
	_recorder = recorder
	_replay = replay
	if _replay != null:
		_replay.replay_finished.connect(_on_replay_finished)
	if _flight_camera != null:
		_flight_camera.view_mode_changed.connect(_on_view_mode_changed)


func _build() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_root = root

	_build_stats(root)
	_build_crosshair(root)
	_build_log(root)

	if DisplayServer.is_touchscreen_available():
		# 步行触控（摇杆/视角/动作按钮）收进一个容器，驾驶飞机时整体隐藏，
		# 改由 _flight_touch 飞行触控层接管。
		_touch_walk = Control.new()
		_touch_walk.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_touch_walk.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(_touch_walk)
		_build_joystick(_touch_walk)
		_build_look_area(_touch_walk)
		_build_action_buttons(_touch_walk)
		_build_flight_touch(root)

	_build_hotbar(root)
	_build_craft_panel(root)
	_build_trade_panel(root)
	_build_box_panel(root)
	_build_smelt_panel(root)
	_build_minimap(root)
	_build_manual(root)
	_build_bestiary(root)
	_build_inventory_panel(root)
	_build_quest_panel(root)
	_build_mission_panel(root)
	_build_settings_panel(root)
	_build_fishing(root)
	_build_toast(root)
	_build_death_overlay(root)
	_build_flight_panel(root)
	_build_replay_hint(root)
	# 飞行战术地图（D-033，M 键）：默认隐藏，驾驶中按 M 打开。
	_tactical_map = FlightTacticalMap.new()
	add_child(_tactical_map)
	# 飞行屏幕仪表 HUD（D-034）：全屏覆盖层，登机后才显形。
	_instrument_hud = FlightInstrumentHUD.new()
	add_child(_instrument_hud)
	# 警告蜂鸣码播放器（D-034）：程序生成音，无 TTS / 无语音资产依赖。
	_alert_beeper = AlertBeeper.new()
	add_child(_alert_beeper)
	_instrument_hud.set_beeper(_alert_beeper)
	_connect_progress()
	_build_map_name(root)
	_build_map_selector(root)


func _unhandled_input(event: InputEvent) -> void:
	# 工坊台建造界面（V）同为模态窗口：打开时其余热键一律让位。否则
	# E/B/J/K/O/M 会在建造界上叠面板，关闭顺序错乱会扯乱鼠标捕获与
	# input_locked（P2-1）。建造界面自己的按键由它自身的 _unhandled_input 处理。
	if _build_screen != null and _build_screen.visible:
		return
	# 回放中（D-033）：Esc / P 跳过，其余热键一律让位（电影运镜不被面板打断）。
	if _replay != null and _replay.is_playing():
		if event is InputEventKey and event.pressed and not event.echo \
				and (event.is_action_pressed("ui_cancel") or event.is_action_pressed("replay_play")):
			_replay.skip()
			get_viewport().set_input_as_handled()
		return
	# 地图选择器为模态界面：仅响应 ESC 关闭，其余热键一律让位。
	if _map_selector != null and _map_selector.is_open():
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			close_map_selector()
			get_viewport().set_input_as_handled()
		return
	# 钓鱼三件套同为模态窗口：教学 → 渔猎 → 钓具，ESC 逐层关闭最上面那层。
	if _fishing_teaching != null and _fishing_teaching.is_open():
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			_fishing_teaching.close()
			_on_fishing_teaching_closed()
			get_viewport().set_input_as_handled()
		return
	if _fishing_ui != null and _fishing_ui.is_open():
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			_fishing_ui.close()
			_on_fishing_closed()
			get_viewport().set_input_as_handled()
		return
	if _fishing_gear != null and _fishing_gear.is_open():
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			_fishing_gear.close()
			_on_fishing_gear_closed()
			get_viewport().set_input_as_handled()
		return
	# 说明书同为模态窗口：ESC / F1 关闭，其余热键让位。
	if _manual != null and _manual.is_open():
		if event is InputEventKey and event.pressed and not event.echo \
				and (event.keycode == KEY_ESCAPE or event.keycode == KEY_F1):
			close_manual()
			get_viewport().set_input_as_handled()
		return
	# 生物图鉴同为模态窗口：ESC / F2 关闭，其余热键让位。
	if _bestiary != null and _bestiary.is_open():
		if event is InputEventKey and event.pressed and not event.echo \
				and (event.keycode == KEY_ESCAPE or event.keycode == KEY_F2):
			close_bestiary()
			get_viewport().set_input_as_handled()
		return
	# 任务面板为模态窗口：ESC / J 关闭，其余热键让位。
	if _quest_panel != null and _quest_panel.is_open():
		if event is InputEventKey and event.pressed and not event.echo \
				and (event.keycode == KEY_ESCAPE or event.keycode == KEY_J):
			close_quest_panel()
			get_viewport().set_input_as_handled()
		return
	# 飞行任务面板同为模态窗口：ESC / K 关闭。
	if _mission_panel != null and _mission_panel.is_open():
		if event is InputEventKey and event.pressed and not event.echo \
				and (event.keycode == KEY_ESCAPE or event.keycode == KEY_K):
			close_mission_panel()
			get_viewport().set_input_as_handled()
		return
	# 飞行设置面板同为模态窗口：ESC / O 关闭。
	if _settings_panel != null and _settings_panel.is_open():
		if event is InputEventKey and event.pressed and not event.echo \
				and (event.keycode == KEY_ESCAPE or event.keycode == KEY_O):
			close_settings_panel()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		# ── 飞行视角键（D-033，仅驾驶中）────────────────────────
		# C 切第一/三人称、V 自由观察（消费事件以阻止建造界面打开）、
		# R 后视、M 战术俯视地图；P 在停机状态手动回放最近一段飞行。
		var flying := _player != null and _player.is_riding()
		if flying and event.is_action_pressed("aircraft_view"):
			if _flight_camera != null:
				_flight_camera.toggle_first_third()
			get_viewport().set_input_as_handled()
		elif flying and event.is_action_pressed("aircraft_freelook"):
			if _flight_camera != null:
				_flight_camera.set_free_look(
					_flight_camera.current_mode() != AircraftCamera.ViewMode.FREE_LOOK)
			get_viewport().set_input_as_handled()
		elif flying and event.is_action_pressed("aircraft_rear"):
			if _flight_camera != null:
				_flight_camera.toggle_rear()
			get_viewport().set_input_as_handled()
		elif flying and event.is_action_pressed("toggle_map"):
			_toggle_tactical_map()
			get_viewport().set_input_as_handled()
		elif not flying and event.is_action_pressed("replay_play") \
				and _recorder != null and _recorder.sample_count() > 1 \
				and not (_replay != null and _replay.is_playing()):
			_start_replay()
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("toggle_craft"):
			_toggle_craft_panel()
		elif event.is_action_pressed("toggle_mode"):
			_toggle_game_mode()
		elif event.is_action_pressed("toggle_inventory"):
			open_inventory()
		elif event.is_action_pressed("toggle_trade"):
			_toggle_trade_panel()
		elif event.is_action_pressed("toggle_map"):
			Progress.notify("map_opened")
			open_map_selector()
		elif event.is_action_pressed("toggle_manual"):
			open_manual()
		elif event.is_action_pressed("toggle_bestiary"):
			open_bestiary()
		elif event.is_action_pressed("toggle_quests"):
			open_quest_panel()
		elif event.is_action_pressed("toggle_missions"):
			open_mission_panel()
		elif event.is_action_pressed("toggle_settings"):
			open_settings_panel()
		elif event.keycode == KEY_ESCAPE and _box_overlay != null and _box_overlay.visible:
			set_box_open(false)
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and _craft_overlay != null and _craft_overlay.visible:
			set_craft_open(false)
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and _inventory_panel != null and _inventory_panel.is_open():
			close_inventory()
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	# 回放推进（D-033）：电影运镜 + 机体重演。
	if _replay != null and _replay.is_playing():
		_replay.process_replay(delta)
	# 战术地图跟随（D-033）：打开期间每帧刷新本机与信息条。
	if _tactical_map != null and _tactical_map.is_open():
		_tactical_map.process_map(delta)
	if _tip_panel != null and _tip_panel.visible and _tip_mesh != null:
		_tip_mesh.rotation.y += delta * 1.5
	_refresh_flight_panel()
	# 飞行屏幕仪表 HUD（D-034）：驾驶中每帧驱动（读快照→加工→分发）。
	if _instrument_hud != null and _player != null and _player.is_riding():
		_instrument_hud.tick(delta)
	if _player == null or _break_bar == null:
		return
	var breaking := _player.is_breaking()
	_break_bar.visible = breaking
	if breaking:
		_break_bar.value = _player.break_ratio()
	# 弓蓄力条：仅在拉弓时出现，与破坏进度条错开一行。
	if _charge_bar != null:
		var charging := _player.is_charging_bow()
		_charge_bar.visible = charging
		if charging:
			_charge_bar.value = _player.bow_charge_ratio()


## 屏幕中心准星 + 破坏进度条：破坏需按住左键，准星与进度提供必要反馈。
func _build_crosshair(root: Control) -> void:
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(overlay)

	var h := ColorRect.new()
	h.color = Color(1.0, 1.0, 1.0, 0.7)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	h.offset_left = -9.0
	h.offset_right = 9.0
	h.offset_top = -1.0
	h.offset_bottom = 1.0
	overlay.add_child(h)

	var v := ColorRect.new()
	v.color = Color(1.0, 1.0, 1.0, 0.7)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	v.offset_left = -1.0
	v.offset_right = 1.0
	v.offset_top = -9.0
	v.offset_bottom = 9.0
	overlay.add_child(v)

	_break_bar = ProgressBar.new()
	_break_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_break_bar.show_percentage = false
	_break_bar.max_value = 1.0
	_break_bar.custom_minimum_size = Vector2(64.0, 7.0)
	_break_bar.visible = false
	_break_bar.modulate = Color(1.0, 0.9, 0.5)
	_break_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_break_bar.offset_left = -32.0
	_break_bar.offset_right = 32.0
	_break_bar.offset_top = 18.0
	_break_bar.offset_bottom = 25.0
	overlay.add_child(_break_bar)

	_charge_bar = ProgressBar.new()
	_charge_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_charge_bar.show_percentage = false
	_charge_bar.max_value = 1.0
	_charge_bar.custom_minimum_size = Vector2(64.0, 7.0)
	_charge_bar.visible = false
	_charge_bar.modulate = Color(0.65, 0.92, 0.60)
	_charge_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_charge_bar.offset_left = -32.0
	_charge_bar.offset_right = 32.0
	_charge_bar.offset_top = -32.0
	_charge_bar.offset_bottom = -25.0
	overlay.add_child(_charge_bar)


func _toggle_game_mode() -> void:
	if GameState.is_explore():
		# 探索模式不允许一键跳进创造：要换模式请走地图选择器，
		# 那里能明确选到三种模式之一，而不是靠反复按键撞出来。
		_show_toast("探索模式请按 M 打开地图选择器切换模式")
		return
	if GameState.is_survival():
		GameState.set_mode(GameState.Mode.CREATIVE)
	else:
		GameState.set_mode(GameState.Mode.SURVIVAL)


func _build_joystick(root: Control) -> void:
	var stick := VirtualJoystick.new()
	root.add_child(stick)

	stick.anchor_left = 0.0
	stick.anchor_top = 1.0
	stick.anchor_right = 0.0
	stick.anchor_bottom = 1.0
	var s := stick.custom_minimum_size
	stick.offset_left = 32.0
	stick.offset_top = -(s.y + 32.0)
	stick.offset_right = 32.0 + s.x
	stick.offset_bottom = -32.0

	stick.value_changed.connect(_on_joystick_changed)


func _build_look_area(root: Control) -> void:
	var look := Control.new()
	look.anchor_left = 0.35
	look.anchor_top = 0.0
	look.anchor_right = 1.0
	look.anchor_bottom = 1.0
	look.mouse_filter = Control.MOUSE_FILTER_STOP
	look.gui_input.connect(_on_look_input)
	root.add_child(look)


func _build_action_buttons(root: Control) -> void:
	var jump := Button.new()
	jump.text = "跳"
	jump.custom_minimum_size = Vector2(92, 92)
	jump.focus_mode = Control.FOCUS_NONE
	jump.button_down.connect(_on_jump_down)
	_anchor_bottom_right(root, jump, 28.0, 28.0)

	_fly_button = Button.new()
	_fly_button.text = "飞"
	_fly_button.custom_minimum_size = Vector2(76, 76)
	_fly_button.focus_mode = Control.FOCUS_NONE
	_fly_button.button_down.connect(_on_fly_down)
	_fly_button.visible = GameState.can_fly()
	_anchor_bottom_right(root, _fly_button, 34.0, 138.0)

	var descend := Button.new()
	descend.text = "降"
	descend.custom_minimum_size = Vector2(76, 76)
	descend.focus_mode = Control.FOCUS_NONE
	descend.button_down.connect(_on_descend_down)
	descend.button_up.connect(_on_descend_up)
	descend.visible = GameState.can_fly()
	_anchor_bottom_right(root, descend, 120.0, 138.0)
	_descend_button = descend

	var break_button := Button.new()
	break_button.text = "挖"
	break_button.custom_minimum_size = Vector2(92, 92)
	break_button.focus_mode = Control.FOCUS_NONE
	break_button.button_down.connect(_on_break_down)
	break_button.button_up.connect(_on_break_up)
	_anchor_bottom_right(root, break_button, 136.0, 28.0)

	var place_button := Button.new()
	place_button.text = "放"
	place_button.custom_minimum_size = Vector2(92, 92)
	place_button.focus_mode = Control.FOCUS_NONE
	place_button.button_down.connect(_on_place_down)
	_anchor_bottom_right(root, place_button, 244.0, 28.0)

	var craft_button := Button.new()
	craft_button.text = "合成"
	craft_button.custom_minimum_size = Vector2(76, 76)
	craft_button.focus_mode = Control.FOCUS_NONE
	craft_button.pressed.connect(_toggle_craft_panel)
	_anchor_bottom_right(root, craft_button, 142.0, 138.0)

	var mode_button := Button.new()
	mode_button.text = "模式"
	mode_button.custom_minimum_size = Vector2(76, 76)
	mode_button.focus_mode = Control.FOCUS_NONE
	mode_button.pressed.connect(_toggle_game_mode)
	_anchor_bottom_right(root, mode_button, 228.0, 138.0)

	var trade_button := Button.new()
	trade_button.text = "交易"
	trade_button.custom_minimum_size = Vector2(76, 76)
	trade_button.focus_mode = Control.FOCUS_NONE
	trade_button.pressed.connect(_toggle_trade_panel)
	_anchor_bottom_right(root, trade_button, 314.0, 138.0)

	var smelt_button := Button.new()
	smelt_button.text = "冶炼"
	smelt_button.custom_minimum_size = Vector2(76, 76)
	smelt_button.focus_mode = Control.FOCUS_NONE
	smelt_button.pressed.connect(_toggle_smelt_panel)
	_anchor_bottom_right(root, smelt_button, 400.0, 138.0)

	var bestiary_button := Button.new()
	bestiary_button.text = "图鉴"
	bestiary_button.custom_minimum_size = Vector2(76, 76)
	bestiary_button.focus_mode = Control.FOCUS_NONE
	bestiary_button.pressed.connect(func(): open_bestiary())
	_anchor_bottom_right(root, bestiary_button, 486.0, 138.0)


func _build_hotbar(root: Control) -> void:
	# 快捷栏按「创造模式清单」建满（建材 + 工具）；生存模式只显示前 9 格。
	var items := ItemTypes.CREATIVE_HOTBAR
	var slot_size := 52.0
	var gap := 6.0
	var total := items.size() * slot_size + (items.size() - 1) * gap

	var bar := Control.new()
	bar.anchor_left = 0.5
	bar.anchor_top = 1.0
	bar.anchor_right = 0.5
	bar.anchor_bottom = 1.0
	bar.offset_left = -total / 2.0
	bar.offset_right = total / 2.0
	bar.offset_top = -(slot_size + 16.0)
	bar.offset_bottom = -16.0
	bar.mouse_filter = Control.MOUSE_FILTER_PASS
	root.add_child(bar)
	_hotbar_bar = bar

	_slot_group = ButtonGroup.new()
	for i in range(items.size()):
		var b := ItemSlot.new()
		b.set_dark_style()
		b.toggle_mode = true
		b.button_group = _slot_group
		b.custom_minimum_size = Vector2(slot_size, slot_size)
		b.position = Vector2(i * (slot_size + gap), 0)
		b.pressed.connect(_on_slot_pressed.bind(i))
		_slot_buttons.append(b)
		bar.add_child(b)

	if not _slot_buttons.is_empty():
		_slot_buttons[0].button_pressed = true
	_refresh_hotbar()


## 左上角状态面板：姓名 + 红色爱心生命（5 颗心，每颗 4 点）+ 饥饿文本。
## 右上角小地图外框正下方依次是模式徽章与时间行，同宽居中成一条竖列。
## 飞行仪表：屏幕顶部居中的一块小面板，只在驾驶飞行器时出现。
## 读数全部来自 Aircraft.snapshot()——HUD 与探针共用同一份来源，不会各算一套。
func _build_flight_panel(root: Control) -> void:
	var panel := PanelContainer.new()
	panel.visible = false
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.offset_left = -118.0
	panel.offset_right = 118.0
	panel.offset_top = 16.0
	root.add_child(panel)
	_flight_panel = panel

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.07, 0.10, 0.60)
	style.border_color = Color(0.86, 0.91, 0.97, 0.25)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	panel.add_child(box)

	var title := Label.new()
	title.text = "✈️ 轻型飞机"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(0.80, 0.90, 1.0))
	box.add_child(title)

	_flight_speed = _flight_line(box, Color(1.0, 1.0, 1.0, 0.95))
	_flight_altitude = _flight_line(box, Color(1.0, 1.0, 1.0, 0.95))
	_flight_throttle = _flight_line(box, Color(1.0, 0.84, 0.45))
	_flight_stall = _flight_line(box, Color(1.0, 0.42, 0.36))
	_flight_stall.visible = false
	# D-033：视角模式 + 发动机状态两行新读数。
	_flight_view = _flight_line(box, Color(0.80, 0.90, 1.0))
	_flight_engine = _flight_line(box, Color(0.55, 0.95, 0.65))


func _flight_line(box: VBoxContainer, color: Color) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", color)
	box.add_child(label)
	return label


## 回放提示条（D-033）：回放期间居中顶部显示，Esc / P 跳过。
func _build_replay_hint(root: Control) -> void:
	var label := Label.new()
	label.text = "🎬 飞行回放中 — Esc 跳过"
	label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	label.offset_top = 64.0
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.visible = false
	root.add_child(label)
	_replay_hint = label


## 当前视角模式的中文名（飞行仪表「视角」行）。
func _view_mode_name() -> String:
	if _flight_camera == null:
		return "追尾"
	match _flight_camera.current_mode():
		AircraftCamera.ViewMode.FIRST_PERSON:
			return "座舱"
		AircraftCamera.ViewMode.CHASE:
			return "追尾"
		AircraftCamera.ViewMode.REAR:
			return "后视"
		AircraftCamera.ViewMode.FREE_LOOK:
			return "环顾"
		AircraftCamera.ViewMode.MAP:
			return "地图"
		AircraftCamera.ViewMode.REPLAY:
			return "回放"
	return "追尾"


## ── 回放控制（D-033）────────────────────────────────────────

## 开始一段回放（任务成功自动 / P 手动）：相机交给回放系统，显示提示条。
func _start_replay() -> void:
	if _replay == null or _recorder == null or _recorder.sample_count() < 2:
		return
	var craft: Aircraft = _player.aircraft() if _player != null else null
	if craft == null or craft.is_wrecked():
		return
	if _flight_camera != null:
		_flight_camera.set_mode(AircraftCamera.ViewMode.REPLAY)
	_replay.begin(_recorder, craft, _flight_camera)
	if _replay_hint != null:
		_replay_hint.visible = true
	# 回放期间鼠标不抓取（运镜不需要操纵杆）。
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## 回放结束 / 跳过：相机退回到飞行视角，恢复鼠标捕获。
func _on_replay_finished() -> void:
	if _flight_camera != null:
		_flight_camera.exit_replay()
	if _replay_hint != null:
		_replay_hint.visible = false
	if _player != null and _player.is_riding():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_refresh_flight_panel()


## 视角模式变化：即时刷新飞行仪表（其余每帧刷新，这里只是让切换「零延迟」）。
func _on_view_mode_changed(_mode: AircraftCamera.ViewMode) -> void:
	_refresh_flight_panel()


## M 键（驾驶中）：飞行战术俯视地图开 / 关（D-033）。
## 战术地图自行从世界识别机场 / 降落场（COBBLESTONE 聚类），无需传锚点。
func _toggle_tactical_map() -> void:
	if _tactical_map == null:
		return
	if _tactical_map.is_open():
		_tactical_map.close_map()
		return
	var craft: Aircraft = _player.aircraft() if _player != null else null
	if craft == null or craft.is_wrecked():
		return
	var world: World = _player.world_ref() if _player != null else null
	# 传任务面板（Control）：战术地图内部经 mission_manager() / _mm 取真正的
	# MissionManager（其 open_map 的 mission_mgr 形参收型 Node）。
	var panel: Node = _mission_panel
	_tactical_map.open_map(craft, panel, world)


## 触屏飞行控制层（P1-3 最小飞行 UI）：单杆俯仰/滚转 + 油门竖滑 + 方向舵 + 刹车 + 下机。
## 仅触屏设备构建；驾驶飞机时由 _on_aircraft_ride_changed 显隐，并隐藏步行触控。
func _build_flight_touch(root: Control) -> void:
	var pad := Control.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.visible = false
	root.add_child(pad)
	_flight_touch = pad

	# 左下：俯仰/滚转单杆（复用 VirtualJoystick；上推=抬头，右推=右滚）。
	var stick := VirtualJoystick.new()
	stick.anchor_left = 0.0
	stick.anchor_top = 1.0
	stick.anchor_right = 0.0
	stick.anchor_bottom = 1.0
	var s := stick.custom_minimum_size
	stick.offset_left = 32.0
	stick.offset_top = -(s.y + 32.0)
	stick.offset_right = 32.0 + s.x
	stick.offset_bottom = -32.0
	pad.add_child(stick)
	stick.value_changed.connect(_on_ft_joystick)

	# 右下：油门竖滑杆（上推=加油门）。
	var thr := VSlider.new()
	thr.min_value = 0.0
	thr.max_value = 1.0
	thr.step = 0.01
	thr.anchor_left = 1.0
	thr.anchor_top = 1.0
	thr.anchor_right = 1.0
	thr.anchor_bottom = 1.0
	thr.offset_right = -32.0
	thr.offset_bottom = -32.0
	thr.offset_left = -80.0
	thr.offset_top = -232.0
	thr.mouse_filter = Control.MOUSE_FILTER_STOP
	pad.add_child(thr)
	thr.value_changed.connect(_on_ft_throttle)
	_ft_throttle_slider = thr

	# 油门旁：方向舵左右 + 刹车（竖直排布）。
	var col := VBoxContainer.new()
	col.anchor_left = 1.0
	col.anchor_top = 1.0
	col.anchor_right = 1.0
	col.anchor_bottom = 1.0
	col.offset_right = -96.0
	col.offset_bottom = -32.0
	col.offset_left = -226.0
	col.offset_top = -154.0
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	pad.add_child(col)

	var yaw_row := HBoxContainer.new()
	col.add_child(yaw_row)
	var yaw_l := Button.new()
	yaw_l.text = "◀"
	yaw_l.custom_minimum_size = Vector2(60, 54)
	yaw_l.focus_mode = Control.FOCUS_NONE
	var yaw_r := Button.new()
	yaw_r.text = "▶"
	yaw_r.custom_minimum_size = Vector2(60, 54)
	yaw_r.focus_mode = Control.FOCUS_NONE
	yaw_row.add_child(yaw_l)
	yaw_row.add_child(yaw_r)
	yaw_l.button_down.connect(func(): _ft_yaw = -1.0; _push_touch_flight())
	yaw_l.button_up.connect(func(): if _ft_yaw < 0.0: _ft_yaw = 0.0; _push_touch_flight())
	yaw_r.button_down.connect(func(): _ft_yaw = 1.0; _push_touch_flight())
	yaw_r.button_up.connect(func(): if _ft_yaw > 0.0: _ft_yaw = 0.0; _push_touch_flight())
	var brake := Button.new()
	brake.text = "刹车"
	brake.custom_minimum_size = Vector2(120, 54)
	brake.focus_mode = Control.FOCUS_NONE
	brake.button_down.connect(func(): _ft_brake = true; _push_touch_flight())
	brake.button_up.connect(func(): _ft_brake = false; _push_touch_flight())
	col.add_child(brake)

	# 右上：视角切换 + 发动机 + 下机（横排，D-033；分别等价于键盘 C / F / X）。
	var row := HBoxContainer.new()
	row.anchor_left = 1.0
	row.anchor_top = 0.0
	row.anchor_right = 1.0
	row.anchor_bottom = 0.0
	row.offset_right = -16.0
	row.offset_top = 16.0
	row.add_theme_constant_override("separation", 8)
	pad.add_child(row)
	var view_btn := Button.new()
	view_btn.text = "视角"
	view_btn.custom_minimum_size = Vector2(72, 56)
	view_btn.focus_mode = Control.FOCUS_NONE
	view_btn.pressed.connect(_on_ft_view)
	row.add_child(view_btn)
	_ft_view = view_btn
	var engine_btn := Button.new()
	engine_btn.text = "发动机"
	engine_btn.custom_minimum_size = Vector2(88, 56)
	engine_btn.focus_mode = Control.FOCUS_NONE
	engine_btn.pressed.connect(_on_ft_engine)
	row.add_child(engine_btn)
	_ft_engine = engine_btn
	var exit := Button.new()
	exit.text = "下机"
	exit.custom_minimum_size = Vector2(72, 56)
	exit.focus_mode = Control.FOCUS_NONE
	exit.pressed.connect(_on_ft_exit)
	row.add_child(exit)


func _on_ft_joystick(value: Vector2) -> void:
	_ft_pitch = -value.y   # 摇杆上推 = 抬头（屏幕 y 向下，故取负）
	_ft_roll = value.x     # 右推 = 右滚
	_push_touch_flight()


func _on_ft_throttle(value: float) -> void:
	_ft_throttle = value
	_push_touch_flight()


## 把当前触屏操纵量推给正在驾驶的飞机。
func _push_touch_flight() -> void:
	var craft: Aircraft = _player.aircraft() if _player != null else null
	if craft == null or craft.is_wrecked():
		return
	craft.set_touch_flight_input(_ft_pitch, _ft_roll, _ft_yaw, _ft_throttle, _ft_brake)


## 坠机记录（P2-5）：存下结构失效的具体原因（超速解体/硬着陆），供随后
## 的掉血播报带上「为什么」——Toast 是覆盖式的，两条各自弹出会互相顶掉，
## 合并成一条「飞机坠毁了（原因）」玩家才看得全。
var _last_crash_reason := ""


## 坠机播报（P2-5）：记录原因并即时提示；玩家正驾驶时紧随的掉血播报会
## 把原因合并进去（见 _on_damage_taken 的 REASON_CRASH 分支）。
func _on_aircraft_crashed(reason: String) -> void:
	_last_crash_reason = reason
	_show_toast("💥 %s" % reason)


func _on_ft_exit() -> void:
	if _player != null and _player.is_riding():
		_player.exit_aircraft()


## 触屏「视角」按钮（D-033）：等价于键盘 C。
func _on_ft_view() -> void:
	if _flight_camera != null:
		_flight_camera.toggle_first_third()


## 触屏「发动机」按钮（D-033）：等价于键盘 F。
func _on_ft_engine() -> void:
	var craft: Aircraft = _player.aircraft() if _player != null else null
	if craft != null:
		craft.toggle_engine()


func _on_aircraft_ride_changed(_riding: bool) -> void:
	# P2-5：坠机原因播报的监听按驾驶状态摘挂（下机即断开）。
	if _ridden_craft != null and is_instance_valid(_ridden_craft) \
			and _ridden_craft.crashed.is_connected(_on_aircraft_crashed):
		_ridden_craft.crashed.disconnect(_on_aircraft_crashed)
	_ridden_craft = _player.aircraft() if _riding and _player != null else null
	if _ridden_craft != null:
		_ridden_craft.crashed.connect(_on_aircraft_crashed)
	# P1-2：下机且任务仍在进行 → 主动放弃当前任务，避免永久卡 RUNNING。
	if not _riding and _mission_panel != null and _mission_panel.is_running():
		_mission_panel.abandon_mission()
	# 底部物品栏（快捷栏）：驾驶飞行器时整条隐藏——飞行中不放置也不取用
	# 方块，留着它既挡视野又与飞行触控/仪表重叠；下机经同一信号恢复显示
	#（坠机弹射与死亡退机都走 exit_aircraft，状态不会漏恢复）。
	# _refresh_hotbar 只动子格 visible、不动本容器：模式切换、背包变化
	#（含飞行任务奖励入包）都不会把驾驶中的它放出来。
	if _hotbar_bar != null:
		_hotbar_bar.visible = not _riding
	# 左上角状态块（姓名 + 爱心 + 饥饿）：驾驶飞行器时整块隐藏——飞行中玩家
	# 就是飞机本身（3D 角色模型在 ride_aircraft 里已隐藏），身份与生存读数
	# 都让位给飞行信息；坠机弹射与死亡退机都走 exit_aircraft，下机经同一信号
	# 恢复，状态不会漏恢复。饥饿读数虽然藏了，但「快见底」提醒走顶部 Toast，
	# 不会因隐藏读数而丢失警告。
	# 按容器而非逐节点控制：三个读数随容器一起走，日后新增状态行自动跟随，
	# 不会出现「藏了姓名忘了饥饿」。_refresh_stats 只重画爱心/改饥饿文本、
	# 不动本容器显隐：掉血、饥饿变化都不会把驾驶中的它放出来。
	if _stats_box != null:
		_stats_box.visible = not _riding
	# 右上角竖列：驾驶时隐藏圆形小地图（黄铜指南针框）与模式徽章（生存/创造/
	# 探索），保留下方天数·时钟·天气行——飞行中仍要看得见昼夜与天气。
	# 方位信息不会丢：M 键战术地图（北上东右）与飞行仪表 HUD 自带的右下角
	# 160×160 小地图（仅追尾视角）都在，主小地图只是徒步视角的地形俯瞰。
	# 时钟行按固定 offset 挂在原处，其上方留白是刻意保留——飞行时右上角
	# 只剩一行信息，比再挪一次位置更不容易误读。
	# _refresh_mode_badge 只改文字与颜色、_refresh_time 只改文本，都不动
	# 显隐：模式切换、昼夜更替都不会把驾驶中的它们放出来。
	if _minimap != null:
		_minimap.visible = not _riding
		# 隐藏 ≠ 停算：小地图的 _process 每帧累加、每 0.6 s 扫一次地形圆域
		#（23×23 圆域 ≈ 529 列，每列还要自地表往下扫首个实块）。飞行中玩家
		# 高速掠过地形、这却是纯白工——一并停掉 _process；下机恢复时把采样
		# 计时器顶到阈值，下一帧立刻重采样，避免显示出来的是上机前的旧图。
		_minimap.set_process(not _riding)
		if not _riding:
			_minimap.request_resample()
	if _mode_label != null:
		_mode_label.visible = not _riding
	# P1-3：触屏设备上，驾驶时隐藏步行触控、显示飞行触控层。
	if DisplayServer.is_touchscreen_available() and _flight_touch != null:
		if _riding:
			_touch_walk.visible = false
			_flight_touch.visible = true
			_ft_pitch = 0.0
			_ft_roll = 0.0
			_ft_yaw = 0.0
			_ft_brake = false
			_ft_throttle = 0.0
			if _ft_throttle_slider != null:
				_ft_throttle_slider.value = 0.0
			_push_touch_flight()
		else:
			_touch_walk.visible = true
			_flight_touch.visible = false
	# 飞行屏幕仪表 HUD（D-034）：登机时绑定飞机与相机、清空语音去重状态。
	if _riding and _instrument_hud != null and _flight_camera != null:
		var cr := _player.aircraft()
		if cr != null and is_instance_valid(cr):
			_instrument_hud.setup(cr, _flight_camera)
	_refresh_flight_panel()


func _refresh_flight_panel() -> void:
	if _flight_panel == null:
		return
	var craft: Aircraft = _player.aircraft() if _player != null else null
	if craft == null or craft.is_wrecked():
		_flight_panel.visible = false
		return
	_flight_panel.visible = true
	var reading := craft.snapshot()
	var warning := bool(reading["stall_warning"])
	_flight_speed.text = "空速  %d km/h   失速 %d" % [
		int(reading["kmh"]), int(float(reading["stall_speed"]) * AircraftFlight.MPS_TO_KMH)
	]
	_flight_speed.add_theme_color_override(
		"font_color", Color(1.0, 0.42, 0.36) if warning else Color(1.0, 1.0, 1.0, 0.95))
	# 离地高度（AGL）而非世界坐标 y：停放时读 0，越过山头时读数随地形起伏，
	# 这才是「会不会撞地」的直接依据；绝对高度留待气动与探针使用。
	_flight_altitude.text = "离地  %d m" % int(reading["altitude_agl"])
	_flight_throttle.text = "油门  %s %d%%" % [
		_throttle_bar(float(reading["throttle"])), int(float(reading["throttle"]) * 100.0)
	]
	_flight_stall.visible = warning
	_flight_stall.text = "⚠️ 失速！推杆加速" if bool(reading["stalled"]) else "⚠️ 接近失速"
	# 视角模式 + 发动机状态（D-033）：视角随 C/V/R/M 实时切换，熄火时油门条置灰提示。
	if _flight_view != null:
		_flight_view.text = "视角  %s" % _view_mode_name()
	if _flight_engine != null:
		var engine_on := bool(reading.get("engine", false))
		_flight_engine.text = "发动机  %s" % ("运转" if engine_on else "熄火（按 F）")
		_flight_engine.add_theme_color_override(
			"font_color", Color(0.55, 0.95, 0.65) if engine_on else Color(1.0, 0.55, 0.45))


## 油门条：10 格实心/空心，比纯数字更快读出推杆位置。
func _throttle_bar(value: float) -> String:
	var filled := clampi(int(round(clampf(value, 0.0, 1.0) * 10.0)), 0, 10)
	return "█".repeat(filled) + "░".repeat(10 - filled)


func _build_stats(root: Control) -> void:
	var box := VBoxContainer.new()
	box.position = Vector2(16, 16)
	box.add_theme_constant_override("separation", 6)
	root.add_child(box)
	_stats_box = box

	_name_label = Label.new()
	_name_label.text = "小方块"
	_name_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.98))
	_name_label.add_theme_font_size_override("font_size", 20)
	box.add_child(_name_label)

	_hearts = Control.new()
	_hearts.custom_minimum_size = Vector2(HEART_COUNT * 20.0 + (HEART_COUNT - 1) * 2.0, 20.0)
	_hearts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hearts.draw.connect(_draw_hearts.bind(_hearts))
	box.add_child(_hearts)

	_hunger_label = Label.new()
	_hunger_label.add_theme_color_override("font_color", Color(1.0, 0.78, 0.35))
	_hunger_label.add_theme_font_size_override("font_size", 18)
	box.add_child(_hunger_label)

	_time_label = Label.new()
	_time_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.95))
	_time_label.add_theme_font_size_override("font_size", 18)
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_time_label)
	_time_label.anchor_left = 1.0
	_time_label.anchor_right = 1.0
	_time_label.offset_left = -(MiniMap.SIZE + MINIMAP_MARGIN)
	_time_label.offset_right = -MINIMAP_MARGIN
	_time_label.offset_top = MINIMAP_MARGIN + MiniMap.SIZE + MODE_BADGE_GAP + MODE_BADGE_HEIGHT + 8.0

	# 模式徽章：紧贴小地图指南针框下缘，只放两个字。描边而非加底板——
	# 压在任何画面上都读得清，又不必额外糊住一块视野。
	_mode_label = Label.new()
	_mode_label.add_theme_font_size_override("font_size", MODE_BADGE_FONT_SIZE)
	_mode_label.add_theme_color_override("font_outline_color", MODE_BADGE_OUTLINE)
	_mode_label.add_theme_constant_override("outline_size", MODE_BADGE_OUTLINE_SIZE)
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mode_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_mode_label)
	_mode_label.anchor_left = 1.0
	_mode_label.anchor_right = 1.0
	_mode_label.offset_left = -(MiniMap.SIZE + MINIMAP_MARGIN)
	_mode_label.offset_right = -MINIMAP_MARGIN
	_mode_label.offset_top = MINIMAP_MARGIN + MiniMap.SIZE + MODE_BADGE_GAP
	_mode_label.offset_bottom = _mode_label.offset_top + MODE_BADGE_HEIGHT

	_refresh_stats()
	_refresh_mode_badge()


## 生命爱心条：共 5 颗心，每颗代表 4 点生命（满 20），余量 2 点时绘制半心。
func _draw_hearts(hearts: Control) -> void:
	var health := _player.health if _player else 0
	var s := 20.0
	var gap := 2.0
	for i in range(HEART_COUNT):
		var pos := Vector2(i * (s + gap), 0.0)
		_draw_heart(hearts, pos, s, Color(0.30, 0.10, 0.10, 0.85))
		var here: int = health - i * HEARTS_PER_POINT
		if here >= HEARTS_PER_POINT:
			_draw_heart(hearts, pos, s, Color(0.88, 0.20, 0.22))
		elif here >= HEARTS_PER_POINT / 2:
			_draw_half_heart(hearts, pos, s, Color(0.88, 0.20, 0.22))


## 心形：两个圆瓣 + 底部三角。
func _draw_heart(canvas: Control, pos: Vector2, s: float, fill: Color) -> void:
	canvas.draw_circle(pos + Vector2(s * 0.27, s * 0.28), s * 0.27, fill)
	canvas.draw_circle(pos + Vector2(s * 0.73, s * 0.28), s * 0.27, fill)
	var tri := PackedVector2Array([
		pos + Vector2(s * 0.02, s * 0.36),
		pos + Vector2(s * 0.98, s * 0.36),
		pos + Vector2(s * 0.5, s * 0.96),
	])
	canvas.draw_colored_polygon(tri, fill)


## 半心：在底色心上叠左瓣与左半三角。
func _draw_half_heart(canvas: Control, pos: Vector2, s: float, fill: Color) -> void:
	canvas.draw_circle(pos + Vector2(s * 0.27, s * 0.28), s * 0.27, fill)
	var tri := PackedVector2Array([
		pos + Vector2(s * 0.02, s * 0.36),
		pos + Vector2(s * 0.5, s * 0.36),
		pos + Vector2(s * 0.5, s * 0.96),
	])
	canvas.draw_colored_polygon(tri, fill)


func _anchor_bottom_right(root: Control, control: Control, right_margin: float, bottom_margin: float) -> void:
	root.add_child(control)
	control.anchor_left = 1.0
	control.anchor_top = 1.0
	control.anchor_right = 1.0
	control.anchor_bottom = 1.0
	var s := control.custom_minimum_size
	control.offset_left = -(right_margin + s.x)
	control.offset_top = -(bottom_margin + s.y)
	control.offset_right = -right_margin
	control.offset_bottom = -bottom_margin


func _on_joystick_changed(value: Vector2) -> void:
	if _player:
		_player.virtual_move = Vector2(value.x, -value.y)


func _on_look_input(event: InputEvent) -> void:
	if _player == null:
		return
	if event is InputEventScreenTouch:
		if event.pressed and _look_touch == -1:
			_look_touch = event.index
		elif not event.pressed and event.index == _look_touch:
			_look_touch = -1
	elif event is InputEventScreenDrag and event.index == _look_touch:
		_player.virtual_look += event.relative


func _on_jump_down() -> void:
	if _player:
		_player.virtual_jump = true


func _on_break_down() -> void:
	if _player:
		_player.start_break_or_attack()


func _on_break_up() -> void:
	if _player:
		_player.break_held = false


func _on_place_down() -> void:
	if _player:
		_player.virtual_place = true


func _on_fly_down() -> void:
	if _player:
		_player.set_flying(not _player.flying)


func _on_descend_down() -> void:
	if _player:
		_player.virtual_descend = true


func _on_descend_up() -> void:
	if _player:
		_player.virtual_descend = false


func _on_player_flying_changed(flying: bool) -> void:
	if _fly_button:
		_fly_button.text = "走" if flying else "飞"


func _on_slot_pressed(slot: int) -> void:
	if _player:
		_player.selected_slot = slot


func _on_player_slot_changed(slot: int) -> void:
	if slot >= 0 and slot < _slot_buttons.size():
		_slot_buttons[slot].button_pressed = true


func _refresh_hotbar() -> void:
	if _player == null:
		return
	var items := ItemTypes.CREATIVE_HOTBAR
	var slot_size := 52.0
	var gap := 6.0
	if GameState.is_creative():
		# 创造模式：全部格子可见，整条重新居中；建材按堆叠上限满格显示。
		for i in range(_slot_buttons.size()):
			var b := _slot_buttons[i] as ItemSlot
			b.visible = true
			if i < items.size():
				var id: int = items[i]
				var count := BlockTypes.STACK_SIZE if not ItemTypes.is_tool_item(id) else 1
				b.set_slot({"item": id, "count": count})
			else:
				b.set_slot({"item": 0, "count": 0})
		_center_hotbar(items.size(), slot_size, gap)
	else:
		# 生存模式：只保留前 9 格（映射背包），其余隐藏并把整条居中。
		for i in range(_slot_buttons.size()):
			var b := _slot_buttons[i] as ItemSlot
			if i >= Inventory.HOTBAR_SIZE:
				b.visible = false
				continue
			b.visible = true
			# 快捷栏是背包槽的视图：读取 hotbar_map 指向的背包格。
			var slot := _player.inventory.hotbar_slot(i)
			var item := _player.inventory.get_item(slot)
			if item == BlockTypes.Block.AIR:
				b.set_slot({"item": 0, "count": 0})
			elif ItemTypes.is_tool_item(item):
				b.set_slot({"item": item, "count": 1, "durability": _player.inventory.get_durability(slot)})
			else:
				b.set_slot({"item": item, "count": _player.inventory.get_count(slot)})
		_center_hotbar(Inventory.HOTBAR_SIZE, slot_size, gap)


## 按可见格数把快捷栏整条水平居中（创造 16 格 / 生存 9 格宽度不同）。
func _center_hotbar(visible_count: int, slot_size: float, gap: float) -> void:
	if _hotbar_bar == null:
		return
	var total := visible_count * slot_size + (visible_count - 1) * gap
	_hotbar_bar.offset_left = -total / 2.0
	_hotbar_bar.offset_right = total / 2.0


## 合成台面板：储物箱同款淡色设计。左栏成品栏（6 格一行），右栏自上而下
## 合成路径图：顶端成品、下层材料格（不足红框），悬停弹出预览简介，
## 「合成」按钮固定在窗口右下角，右上角的 ✕ 走 UiKit.make_close()（透明底）。


## 点「合成」执行，成品飞入背包动画 + 系统日志播报。
func _build_craft_panel(root: Control) -> void:
	_craft_overlay = Control.new()
	_craft_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_craft_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_craft_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	_craft_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_craft_overlay.add_child(center)

	var wrapper := Control.new()
	# 6 列成品栏（6×64 + 5×6 间距 ≈ 414，再加滚动条）+ 右栏路径图 320。
	wrapper.custom_minimum_size = Vector2(820, 460)
	center.add_child(wrapper)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.95, 0.92, 0.84)
	panel_style.border_color = Color(0.62, 0.47, 0.27)
	panel_style.set_border_width_all(3)
	panel_style.set_corner_radius_all(12)
	panel_style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", panel_style)
	wrapper.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "合成台"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(0.36, 0.26, 0.13))
	vbox.add_child(title)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 24)
	vbox.add_child(columns)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	columns.add_child(left)

	# 分类页签：配方按产物自动归页（工具/武器钓具/方块/食物），
	# 格子仍是一次建齐、按页切换显隐——与图鉴卡片同一套「建一次」策略。
	var cat_row := HBoxContainer.new()
	cat_row.add_theme_constant_override("separation", 6)
	left.add_child(cat_row)
	_craft_cat_group = ButtonGroup.new()
	for c in CRAFT_PAGES.size():
		var chip := Button.new()
		chip.text = String(CRAFT_PAGES[c][0])
		chip.tooltip_text = String(CRAFT_PAGES[c][1])
		chip.toggle_mode = true
		chip.button_group = _craft_cat_group
		chip.button_pressed = c == _craft_cat
		chip.focus_mode = Control.FOCUS_NONE
		chip.custom_minimum_size = Vector2(0, 32)
		chip.add_theme_font_size_override("font_size", 15)
		chip.add_theme_color_override("font_color", Color(0.36, 0.26, 0.13))
		chip.add_theme_color_override("font_pressed_color", Color(0.30, 0.20, 0.08))
		chip.add_theme_stylebox_override("normal", _craft_chip_style(false))
		chip.add_theme_stylebox_override("hover", _craft_chip_style(false))
		chip.add_theme_stylebox_override("pressed", _craft_chip_style(true))
		chip.pressed.connect(_on_craft_cat.bind(c))
		cat_row.add_child(chip)
		_craft_cat_buttons.append(chip)

	var left_title := Label.new()
	left_title.text = "成品（点击选择）"
	left_title.add_theme_font_size_override("font_size", 16)
	left_title.add_theme_color_override("font_color", Color(0.42, 0.32, 0.18))
	left.add_child(left_title)

	# 成品栏用滚动容器：M8 起配方增至 30 条，矮面板放不下全部格子。
	var recipe_scroll := ScrollContainer.new()
	recipe_scroll.custom_minimum_size = Vector2(432.0, 336.0)
	recipe_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(recipe_scroll)

	_craft_result_grid = GridContainer.new()
	_craft_result_grid.columns = 6
	_craft_result_grid.add_theme_constant_override("h_separation", 6)
	_craft_result_grid.add_theme_constant_override("v_separation", 6)
	recipe_scroll.add_child(_craft_result_grid)

	_recipe_group = ButtonGroup.new()
	for i in range(ItemTypes.RECIPES.size()):
		var b := ItemSlot.new()
		b.toggle_mode = true
		b.button_group = _recipe_group
		b.custom_minimum_size = Vector2(64, 64)
		b.pressed.connect(_on_recipe_selected.bind(i))
		b.mouse_entered.connect(_on_slot_hover.bind(b))
		b.mouse_exited.connect(_hide_item_tip)
		b.visible = ItemTypes.recipe_page(ItemTypes.RECIPES[i]) == _craft_cat
		_craft_result_grid.add_child(b)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 6)
	columns.add_child(right)

	var right_title := Label.new()
	right_title.text = "合成路径"
	right_title.add_theme_font_size_override("font_size", 16)
	right_title.add_theme_color_override("font_color", Color(0.42, 0.32, 0.18))
	right.add_child(right_title)

	var top_row := HBoxContainer.new()
	top_row.alignment = BoxContainer.ALIGNMENT_CENTER
	right.add_child(top_row)
	_craft_result_slot = ItemSlot.new()
	_craft_result_slot.custom_minimum_size = Vector2(64, 64)
	_craft_result_slot.mouse_entered.connect(_on_slot_hover.bind(_craft_result_slot))
	_craft_result_slot.mouse_exited.connect(_hide_item_tip)
	top_row.add_child(_craft_result_slot)

	_craft_tree = Control.new()
	_craft_tree.custom_minimum_size = Vector2(320, 36)
	_craft_tree.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_craft_tree.draw.connect(_draw_craft_links)
	right.add_child(_craft_tree)

	_craft_material_row = HBoxContainer.new()
	_craft_material_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_craft_material_row.add_theme_constant_override("separation", 8)
	right.add_child(_craft_material_row)

	_craft_craft_button = Button.new()
	_craft_craft_button.text = "合成"
	_craft_craft_button.custom_minimum_size = Vector2(128, 46)
	_craft_craft_button.focus_mode = Control.FOCUS_NONE
	_craft_craft_button.pressed.connect(_on_craft_pressed)
	var btn_style := StyleBoxFlat.new()
	btn_style.bg_color = Color(0.87, 0.72, 0.42)
	btn_style.set_corner_radius_all(8)
	var btn_hover := btn_style.duplicate()
	btn_hover.bg_color = Color(0.93, 0.80, 0.52)
	var btn_disabled := btn_style.duplicate()
	btn_disabled.bg_color = Color(0.78, 0.74, 0.66)
	_craft_craft_button.add_theme_stylebox_override("normal", btn_style)
	_craft_craft_button.add_theme_stylebox_override("hover", btn_hover)
	_craft_craft_button.add_theme_stylebox_override("pressed", btn_hover)
	_craft_craft_button.add_theme_stylebox_override("disabled", btn_disabled)
	_craft_craft_button.add_theme_color_override("font_color", Color(0.30, 0.20, 0.08))
	_craft_craft_button.add_theme_color_override("font_disabled_color", Color(0.52, 0.48, 0.42))
	# 按钮锚定窗口右下角（不随右栏内容排布）。
	wrapper.add_child(_craft_craft_button)
	_craft_craft_button.anchor_left = 1.0
	_craft_craft_button.anchor_right = 1.0
	_craft_craft_button.anchor_top = 1.0
	_craft_craft_button.anchor_bottom = 1.0
	_craft_craft_button.offset_left = -148.0
	_craft_craft_button.offset_right = -20.0
	_craft_craft_button.offset_top = -62.0
	_craft_craft_button.offset_bottom = -16.0

	# 面板 ✕：UiKit 统一透明底，只剩红字形，看着像直接画在窗面上。
	var close := UiKit.make_close()
	close.pressed.connect(func(): set_craft_open(false))
	wrapper.add_child(close)
	close.anchor_left = 1.0
	close.anchor_right = 1.0
	close.offset_left = -44.0
	close.offset_right = -10.0
	close.offset_top = 10.0
	close.offset_bottom = 44.0

	_craft_overlay.visible = false
	_refresh_craft_panel()


func _toggle_craft_panel() -> void:
	if _craft_overlay:
		set_craft_open(not _craft_overlay.visible)


func set_craft_open(open: bool) -> void:
	if _craft_overlay == null:
		return
	_craft_overlay.visible = open
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	if open:
		_refresh_craft_panel()
	else:
		_hide_item_tip()


func _refresh_craft_panel() -> void:
	if _craft_result_grid == null:
		return
	_hide_item_tip()
	# 成品卡角标 = 按当前持有材料实时推算的可合成成品数（不足为 ×0）。
	# 背包任何变化都会经 changed 信号走到这里，数量始终跟着材料走。
	for i in range(ItemTypes.RECIPES.size()):
		var b := _craft_result_grid.get_child(i) as ItemSlot
		var craftable := 0
		if _player != null:
			craftable = _player.inventory.craftable_count(ItemTypes.RECIPES[i])
		b.set_craftable(ItemTypes.RECIPES[i]["result"], craftable)
	_apply_craft_cat()


## 当前分类页生效：格子显隐 + 选中项不在本页时改选本页第一个。
func _apply_craft_cat() -> void:
	var page_slots: Array[int] = []
	for i in range(ItemTypes.RECIPES.size()):
		var in_page := ItemTypes.recipe_page(ItemTypes.RECIPES[i]) == _craft_cat
		(_craft_result_grid.get_child(i) as ItemSlot).visible = in_page
		if in_page:
			page_slots.append(i)
	if page_slots.is_empty():
		return
	if not page_slots.has(_selected_recipe):
		_selected_recipe = page_slots[0]
	for i in range(ItemTypes.RECIPES.size()):
		(_craft_result_grid.get_child(i) as ItemSlot).button_pressed = i == _selected_recipe
	_refresh_craft_path()


## 切换分类页：只动显隐与选中，不重建任何格子。
func _on_craft_cat(page: int) -> void:
	_craft_cat = clampi(page, 0, CRAFT_PAGES.size() - 1)
	_apply_craft_cat()


## 分类页签底色：选中态金、未选中米灰。
func _craft_chip_style(active: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.80, 0.72, 0.55) if active else Color(0.89, 0.85, 0.74)
	style.set_corner_radius_all(7)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 4.0
	style.content_margin_bottom = 4.0
	return style


## 右侧路径图刷新：顶端成品格 + 下层材料格（拥有量不足描红框）。
func _refresh_craft_path() -> void:
	if _craft_result_slot == null or _craft_material_row == null:
		return
	var recipe: Dictionary = ItemTypes.RECIPES[_selected_recipe]
	var owned := _player.inventory.count_item(recipe["result"]) if _player != null else 0
	_craft_result_slot.set_slot({"item": recipe["result"], "count": maxi(1, owned)})
	for child in _craft_material_row.get_children():
		_craft_material_row.remove_child(child)
		child.queue_free()
	for ingredient in recipe["ingredients"]:
		var need := int(recipe["ingredients"][ingredient])
		var b := ItemSlot.new()
		b.custom_minimum_size = Vector2(64, 64)
		b.set_slot({"item": ingredient, "count": need})
		b.set_deficit(_player == null or _player.inventory.count_item(ingredient) < need)
		b.mouse_entered.connect(_on_slot_hover.bind(b))
		b.mouse_exited.connect(_hide_item_tip)
		_craft_material_row.add_child(b)
	if _craft_craft_button:
		_craft_craft_button.disabled = not _can_craft(recipe)
	if _craft_tree:
		_craft_tree.queue_redraw()


## 连线自上而下：顶端成品中心扇出到各材料格中心。
func _draw_craft_links() -> void:
	if _craft_tree == null or _craft_tree.size.x <= 0.0:
		return
	var recipe: Dictionary = ItemTypes.RECIPES[_selected_recipe]
	var n: int = recipe["ingredients"].size()
	var w := _craft_tree.size.x
	var top := Vector2(w * 0.5, 0.0)
	var col := Color(0.55, 0.42, 0.25)
	_craft_tree.draw_circle(top, 4.0, col)
	for i in range(n):
		var x := w * 0.5 + (float(i) - float(n - 1) * 0.5) * 72.0
		var end := Vector2(x, _craft_tree.size.y)
		_craft_tree.draw_line(top, end, col, 3.0)
		_craft_tree.draw_circle(end, 4.0, col)


func _on_recipe_selected(index: int) -> void:
	_selected_recipe = index
	_refresh_craft_path()


## 悬停预览：直接读取格子当前物品，供成品/材料格共用。
func _on_slot_hover(slot: ItemSlot) -> void:
	_show_item_tip(slot, slot.item_id())


func _recipe_text(recipe: Dictionary) -> String:
	var parts: Array[String] = []
	for ingredient in recipe["ingredients"]:
		parts.append("%s×%d" % [ItemTypes.item_short_name(ingredient), int(recipe["ingredients"][ingredient])])
	return "%s  →  %s" % [" + ".join(parts), ItemTypes.item_name(recipe["result"])]


func _can_craft(recipe: Dictionary) -> bool:
	if _player == null:
		return false
	return _player.inventory.can_craft(recipe)


func _on_craft_pressed() -> void:
	if _player == null:
		return
	var recipe: Dictionary = ItemTypes.RECIPES[_selected_recipe]
	if not _player.inventory.craft(recipe):
		# 理论上按钮禁用时点不到；走到这里说明状态过期或边界异常，给出提示而非静默。
		Events.notice.emit("暂时无法合成：请确认材料充足且背包常用区有空位。")
		return
	Events.craft_done.emit(int(recipe["result"]))
	_refresh_craft_path()
	_refresh_hotbar()
	_play_craft_fly(int(recipe["result"]))


## 背包变化且合成台可见时，实时刷新成品持有量与按钮可用态。
func _on_inventory_changed_for_craft() -> void:
	if _craft_overlay != null and _craft_overlay.visible:
		_refresh_craft_panel()


## 成品飞入背包动画：从成品格飞向底部快捷栏中心，落地后播报获得。
func _play_craft_fly(item_id: int) -> void:
	if _root == null or _craft_result_slot == null:
		_push_log("获得 %s×1" % ItemTypes.item_name(item_id))
		return
	var icon := ItemSlot.new()
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.custom_minimum_size = Vector2(56, 56)
	icon.size = Vector2(56, 56)
	icon.pivot_offset = Vector2(28, 28)
	icon.z_index = 60
	icon.set_slot({"item": item_id, "count": 1})
	_root.add_child(icon)
	var start := _craft_result_slot.get_global_rect().position + Vector2(4.0, 4.0)
	var vp := _root.get_viewport_rect().size
	icon.position = start
	var end := Vector2(vp.x * 0.5 - 28.0, vp.y - 78.0)
	var tw := create_tween()
	tw.tween_property(icon, "position", end, 0.7) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	tw.parallel().tween_property(icon, "rotation_degrees", 360.0, 0.7)
	tw.tween_callback(func():
		icon.queue_free()
		_push_log("获得 %s×1" % ItemTypes.item_name(item_id))
	)


## 交易面板（T 键）：样式对齐储物箱——米色窗体 + 棕色描边 + ItemSlot 微缩图。
## 两列网格，每格「绿宝石×N → 成品×M」+ 交换按钮；悬停物品格出 3D 提示。
func _build_trade_panel(root: Control) -> void:
	_trade_overlay = Control.new()
	_trade_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_trade_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_trade_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	_trade_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_trade_overlay.add_child(center)

	var wrapper := Control.new()
	# 13 条交易排两列（7 行 × 54px）+ 标题提示行，500 高度放得下且不出屏。
	wrapper.custom_minimum_size = Vector2(640, 500)
	center.add_child(wrapper)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.95, 0.92, 0.84)
	panel_style.border_color = Color(0.62, 0.47, 0.27)
	panel_style.set_border_width_all(3)
	panel_style.set_corner_radius_all(12)
	panel_style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", panel_style)
	wrapper.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "村庄交易"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(0.36, 0.26, 0.13))
	vbox.add_child(title)

	# 页签：买入（绿宝石换物资）/ 卖出（物资换绿宝石），样式与合成台页签同源。
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 6)
	vbox.add_child(tab_row)
	var tab_group := ButtonGroup.new()
	var tab_defs := [
		["买入（绿宝石换物资）", "花绿宝石换食物、工具和材料"],
		["卖出（物资换绿宝石）", "前期易得的物资打包卖，比一键售卖划算 50%"],
	]
	for t in tab_defs.size():
		var chip := Button.new()
		chip.text = String(tab_defs[t][0])
		chip.tooltip_text = String(tab_defs[t][1])
		chip.toggle_mode = true
		chip.button_group = tab_group
		chip.button_pressed = t == _trade_tab
		chip.focus_mode = Control.FOCUS_NONE
		chip.custom_minimum_size = Vector2(0, 32)
		chip.add_theme_font_size_override("font_size", 14)
		chip.add_theme_color_override("font_color", Color(0.36, 0.26, 0.13))
		chip.add_theme_color_override("font_pressed_color", Color(0.30, 0.20, 0.08))
		chip.add_theme_stylebox_override("normal", _craft_chip_style(false))
		chip.add_theme_stylebox_override("hover", _craft_chip_style(false))
		chip.add_theme_stylebox_override("pressed", _craft_chip_style(true))
		chip.pressed.connect(_on_trade_tab.bind(t))
		tab_row.add_child(chip)
		_trade_tab_buttons.append(chip)

	var hint := Label.new()
	hint.name = "TradeHint"
	hint.text = "用绿宝石交换物资（悬停物品格查看详情）"
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_color", Color(0.42, 0.32, 0.18))
	vbox.add_child(hint)

	_trade_list = VBoxContainer.new()
	_trade_list.add_theme_constant_override("separation", 6)
	vbox.add_child(_trade_list)

	# 面板 ✕：UiKit 统一透明底（与储物箱一致），红字形直接压在窗面上。
	var close := UiKit.make_close()
	close.pressed.connect(func(): set_trade_open(false))
	wrapper.add_child(close)
	close.anchor_left = 1.0
	close.anchor_right = 1.0
	close.offset_left = -44.0
	close.offset_right = -10.0
	close.offset_top = 10.0
	close.offset_bottom = 44.0

	_trade_overlay.visible = false
	_build_item_tip()
	_refresh_trade_panel()


func _toggle_trade_panel() -> void:
	if _trade_overlay:
		set_trade_open(not _trade_overlay.visible)


func set_trade_open(open: bool) -> void:
	if _trade_overlay == null:
		return
	_trade_overlay.visible = open
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	if open:
		_refresh_trade_panel()
	else:
		_hide_item_tip()


func _refresh_trade_panel() -> void:
	if _trade_list == null:
		return
	_hide_item_tip()
	for child in _trade_list.get_children():
		_trade_list.remove_child(child)
		child.queue_free()
	var hint := _trade_overlay.find_child("TradeHint", true, false) as Label
	if hint != null:
		hint.text = ("用绿宝石交换物资（悬停物品格查看详情）" if _trade_tab == 0
			else "打包卖出手头的物资，比待售区一键售卖划算 50%（悬停查看详情）")

	# 两列网格：买入 13 条 / 卖出 8 条各排 7 行与 4 行，整面板同高可容纳。
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	_trade_list.add_child(grid)

	if _trade_tab == 0:
		for trade in ItemTypes.TRADES:
			_add_buy_row(grid, trade)
	else:
		for trade in ItemTypes.SELL_TRADES:
			_add_sell_row(grid, trade)


func _on_trade_tab(tab: int) -> void:
	_trade_tab = clampi(tab, 0, 1)
	_refresh_trade_panel()


## 买入行：绿宝石×cost → 成品×count + 「交换」按钮。
func _add_buy_row(grid: GridContainer, trade: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	grid.add_child(row)

	row.add_child(_make_trade_slot(ItemTypes.EMERALD, int(trade["cost"])))
	row.add_child(_make_arrow_label())
	row.add_child(_make_trade_slot(int(trade["result"]), int(trade["count"])))

	var name_label := _make_trade_name(ItemTypes.item_name(int(trade["result"])))
	row.add_child(name_label)

	var button := Button.new()
	button.text = "交换"
	button.custom_minimum_size = Vector2(56, 40)
	button.focus_mode = Control.FOCUS_NONE
	# 暖金色系与米色窗体同调（合成台「合成」同款），禁用变灰一目了然。
	UiKit.apply_warm_style(button)
	button.disabled = not _can_trade(trade)
	button.pressed.connect(_on_trade_pressed.bind(trade))
	row.add_child(button)


## 卖出行：物资×count → 绿宝石×bundle + 「出售」按钮（物资不足置灰）。
func _add_sell_row(grid: GridContainer, trade: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	grid.add_child(row)

	var item := int(trade["item"])
	var count := int(trade["count"])
	var bundle := ItemTypes.sell_bundle_price(item, count)
	row.add_child(_make_trade_slot(item, count))
	row.add_child(_make_arrow_label())
	row.add_child(_make_trade_slot(ItemTypes.EMERALD, bundle))

	var name_label := _make_trade_name("%s ×%d" % [ItemTypes.item_name(item), count])
	row.add_child(name_label)

	var button := Button.new()
	button.text = "出售"
	button.custom_minimum_size = Vector2(56, 40)
	button.focus_mode = Control.FOCUS_NONE
	UiKit.apply_warm_style(button)
	if _player != null:
		button.disabled = _player.inventory.count_item(item) < count
	button.pressed.connect(_on_sell_pressed.bind(trade))
	row.add_child(button)


func _make_arrow_label() -> Label:
	var arrow := Label.new()
	arrow.text = "→"
	arrow.add_theme_font_size_override("font_size", 16)
	arrow.add_theme_color_override("font_color", Color(0.42, 0.32, 0.18))
	return arrow


func _make_trade_name(text: String) -> Label:
	var name_label := Label.new()
	name_label.text = text
	name_label.add_theme_font_size_override("font_size", 15)
	name_label.add_theme_color_override("font_color", Color(0.28, 0.20, 0.10))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return name_label


## 点「出售」：扣物资、发绿宝石，播报与刷新同买入一致。
func _on_sell_pressed(trade: Dictionary) -> void:
	if _player == null:
		return
	var item := int(trade["item"])
	var count := int(trade["count"])
	if _player.inventory.count_item(item) < count:
		return
	_player.inventory.consume_item(item, count)
	var bundle := ItemTypes.sell_bundle_price(item, count)
	_player.inventory.add_item(ItemTypes.EMERALD, bundle)
	Progress.notify("traded")
	_refresh_trade_panel()
	_refresh_hotbar()
	Events.notice.emit("卖出了 %s×%d，获得绿宝石×%d" % [ItemTypes.item_name(item), count, bundle])


## 交易行的微缩物品格（储物箱同款 ItemSlot）：角标 ×N，悬停出 3D 物品提示。
func _make_trade_slot(item: int, count: int) -> ItemSlot:
	var slot := ItemSlot.new()
	slot.custom_minimum_size = Vector2(48, 48)
	slot.set_slot({"item": item, "count": count})
	slot.mouse_entered.connect(_show_item_tip.bind(slot, item))
	slot.mouse_exited.connect(_hide_item_tip)
	return slot


func _can_trade(trade: Dictionary) -> bool:
	if _player == null:
		return false
	var inv: Inventory = _player.inventory
	return inv.count_item(ItemTypes.EMERALD) >= int(trade["cost"]) \
		and inv.has_space_for(trade["result"])


func _on_trade_pressed(trade: Dictionary) -> void:
	if _player == null:
		return
	if _player.inventory.consume_item(ItemTypes.EMERALD, int(trade["cost"])):
		_player.inventory.add_item(trade["result"], int(trade["count"]))
		Progress.notify("traded")
		_refresh_trade_panel()
		_refresh_hotbar()


## 储物箱面板：上 36 格为箱内格子、下方为玩家背包（36 格，含待售区）。
## 点击任一格把该格整叠转移到另一侧（工具不可堆叠按容量截断）。
func _build_box_panel(root: Control) -> void:
	_box_overlay = Control.new()
	_box_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_box_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_box_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	_box_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box_overlay.add_child(center)

	var wrapper := Control.new()
	# 玩家背包扩至 36 格后，下方背包网格由 3 行变 4 行，面板需相应加高。
	wrapper.custom_minimum_size = Vector2(664, 664)
	center.add_child(wrapper)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.95, 0.92, 0.84)
	panel_style.border_color = Color(0.62, 0.47, 0.27)
	panel_style.set_border_width_all(3)
	panel_style.set_corner_radius_all(12)
	panel_style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", panel_style)
	wrapper.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "储物箱"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(0.36, 0.26, 0.13))
	vbox.add_child(title)

	var box_label := Label.new()
	box_label.text = "箱子（点击整叠取出，悬停查看物品）"
	box_label.add_theme_font_size_override("font_size", 16)
	box_label.add_theme_color_override("font_color", Color(0.42, 0.32, 0.18))
	vbox.add_child(box_label)

	_box_grid = GridContainer.new()
	_box_grid.columns = 9
	_box_grid.add_theme_constant_override("h_separation", 6)
	_box_grid.add_theme_constant_override("v_separation", 6)
	vbox.add_child(_box_grid)

	var player_label := Label.new()
	player_label.text = "背包（点击整叠存入）"
	player_label.add_theme_font_size_override("font_size", 16)
	player_label.add_theme_color_override("font_color", Color(0.42, 0.32, 0.18))
	vbox.add_child(player_label)

	_box_player_grid = GridContainer.new()
	_box_player_grid.columns = 9
	_box_player_grid.add_theme_constant_override("h_separation", 6)
	_box_player_grid.add_theme_constant_override("v_separation", 6)
	vbox.add_child(_box_player_grid)

	# 面板 ✕：UiKit 统一透明底（与合成台一致），红字形直接压在窗面上。
	var close := UiKit.make_close()
	close.pressed.connect(func(): set_box_open(false))
	wrapper.add_child(close)
	close.anchor_left = 1.0
	close.anchor_right = 1.0
	close.offset_left = -44.0
	close.offset_right = -10.0
	close.offset_top = 10.0
	close.offset_bottom = 44.0

	for i in range(36):
		var b := ItemSlot.new()
		b.custom_minimum_size = Vector2(56, 56)
		b.pressed.connect(_on_box_slot_pressed.bind(i))
		b.mouse_entered.connect(_on_box_slot_hover.bind(i, true, b))
		b.mouse_exited.connect(_hide_item_tip)
		_box_grid.add_child(b)
	for i in range(Inventory.SLOT_COUNT):
		var b := ItemSlot.new()
		b.custom_minimum_size = Vector2(56, 56)
		b.pressed.connect(_on_box_player_slot_pressed.bind(i))
		b.mouse_entered.connect(_on_box_slot_hover.bind(i, false, b))
		b.mouse_exited.connect(_hide_item_tip)
		_box_player_grid.add_child(b)

	_box_overlay.visible = false
	_build_item_tip()
	Events.request_box_open.connect(_on_request_box_open)
	Events.block_broken.connect(_on_box_block_broken)


func _on_request_box_open(cell: Vector3i) -> void:
	if _player == null or _player.get_world() == null:
		return
	_open_box_cell = cell
	_box_inventory = _player.get_world().get_box(cell)
	set_box_open(true)


## 箱子被破坏时若面板正开着这只箱子，立即关闭（内容已散落）。
func _on_box_block_broken(block_id: int, cell: Vector3i) -> void:
	if block_id == BlockTypes.Block.CHEST and cell == _open_box_cell:
		set_box_open(false)


func set_box_open(open: bool) -> void:
	if _box_overlay == null:
		return
	_box_overlay.visible = open
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	if open:
		_refresh_box_panel()
	else:
		_hide_item_tip()


func _refresh_box_panel() -> void:
	if _box_grid == null or _box_player_grid == null:
		return
	if _box_inventory == null or _player == null:
		return
	_hide_item_tip()
	# 箱体是 36 格背包：全部刷新（此前只刷 27 格，落入 27~35 的物品
	# 既看不见也取不出来，看起来就像「存进去数量没变化」）。
	var box_slots := mini(_box_inventory.slots.size(), _box_grid.get_child_count())
	for i in range(box_slots):
		var b := _box_grid.get_child(i) as ItemSlot
		b.set_slot(_box_inventory.slots[i])
	for i in range(Inventory.SLOT_COUNT):
		var b := _box_player_grid.get_child(i) as ItemSlot
		b.set_slot(_player.inventory.slots[i])


## 系统日志区：透明背景文本，悬浮主界面左下角，鼠标事件穿透不可选中。
func _build_log(root: Control) -> void:
	_log_label = Label.new()
	_log_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_log_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.95))
	_log_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.8))
	_log_label.add_theme_constant_override("outline_size", 8)
	_log_label.add_theme_font_size_override("font_size", 18)
	_log_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	root.add_child(_log_label)
	_log_label.anchor_top = 1.0
	_log_label.anchor_bottom = 1.0
	_log_label.offset_left = 16.0
	_log_label.offset_right = 460.0
	_log_label.offset_top = -190.0
	_log_label.offset_bottom = -48.0


## 追加一条系统播报，最多保留最近 5 条。
func _push_log(message: String) -> void:
	_log_lines.append(message)
	while _log_lines.size() > 5:
		_log_lines.remove_at(0)
	if _log_label:
		_log_label.text = "\n".join(_log_lines)


## 悬停预览卡：3D 旋转模型 + 名称 + 简介，弹在触发格子右侧并钳制在屏内。
func _build_item_tip() -> void:
	if _tip_panel != null:
		return
	_tip_panel = PanelContainer.new()
	_tip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_panel.z_index = 20
	var tip_style := StyleBoxFlat.new()
	tip_style.bg_color = Color(0.97, 0.94, 0.86, 0.98)
	tip_style.border_color = Color(0.62, 0.47, 0.27)
	tip_style.set_border_width_all(2)
	tip_style.set_corner_radius_all(10)
	tip_style.set_content_margin_all(10)
	_tip_panel.add_theme_stylebox_override("panel", tip_style)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_tip_panel.add_child(v)

	var vpc := SubViewportContainer.new()
	vpc.stretch = true
	vpc.custom_minimum_size = Vector2(120, 120)
	vpc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(vpc)

	_tip_viewport = SubViewport.new()
	_tip_viewport.own_world_3d = true
	_tip_viewport.transparent_bg = true
	_tip_viewport.size = Vector2i(120, 120)
	_tip_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vpc.add_child(_tip_viewport)

	var cam := Camera3D.new()
	cam.position = Vector3(1.27, 1.26, 1.27)
	cam.rotation_degrees = Vector3(-35.0, 45.0, 0.0)
	_tip_viewport.add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45.0, 30.0, 0.0)
	_tip_viewport.add_child(light)

	_tip_mesh = MeshInstance3D.new()
	_tip_viewport.add_child(_tip_mesh)

	_tip_name = Label.new()
	_tip_name.add_theme_font_size_override("font_size", 18)
	_tip_name.add_theme_color_override("font_color", Color(0.30, 0.20, 0.08))
	v.add_child(_tip_name)

	_tip_desc = Label.new()
	_tip_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip_desc.custom_minimum_size = Vector2(170, 0)
	_tip_desc.add_theme_font_size_override("font_size", 14)
	_tip_desc.add_theme_color_override("font_color", Color(0.35, 0.27, 0.16))
	v.add_child(_tip_desc)

	_tip_panel.visible = false
	_root.add_child(_tip_panel)


func _on_box_slot_hover(index: int, from_box: bool, slot: ItemSlot) -> void:
	if _player == null or (from_box and _box_inventory == null):
		return
	var inv := _box_inventory if from_box else _player.inventory
	_show_item_tip(slot, int(inv.slots[index]["item"]))


func _show_item_tip(slot: ItemSlot, item_id: int) -> void:
	if _tip_panel == null:
		return
	if item_id == 0:
		_tip_panel.visible = false
		return
	_tip_name.text = ItemTypes.item_name(item_id)
	_tip_desc.text = ItemTypes.item_description(item_id)
	_apply_tip_mesh(item_id)
	_tip_panel.reset_size()
	var pos := slot.get_global_rect().position + Vector2(slot.size.x + 8.0, 0.0)
	pos = pos.clamp(Vector2.ZERO, slot.get_viewport_rect().size - _tip_panel.size)
	_tip_panel.position = pos
	_tip_panel.visible = true


## 预览模型与实物匹配：方块=立方体（储物箱带木纹栅格面与锁扣）、
## 工具=木柄+头部组合、金属锭=棱柱条、其余物品=扁盒，颜色与格子微缩图同源。
func _apply_tip_mesh(item_id: int) -> void:
	for child in _tip_mesh.get_children():
		_tip_mesh.remove_child(child)
		child.queue_free()
	_tip_mesh.mesh = null
	var base: Color = ItemTypes.item_color(item_id)
	if ItemTypes.category(item_id) == 0:
		if item_id == BlockTypes.Block.CHEST:
			_build_tip_chest(base)
		else:
			_add_tip_part(Vector3.ONE, base, Vector3.ZERO)
	elif ItemTypes.is_tool_item(item_id):
		_build_tip_tool(item_id, base)
	elif item_id in [ItemTypes.COPPER_INGOT, ItemTypes.TIN_INGOT, ItemTypes.BRONZE_INGOT,
			ItemTypes.IRON_INGOT, ItemTypes.SILVER_INGOT, ItemTypes.GOLD_INGOT,
			ItemTypes.ALLOY_INGOT, ItemTypes.CARBON_ROD, ItemTypes.CRYSTAL]:
		var prism := PrismMesh.new()
		prism.size = Vector3(1.0, 0.45, 0.55)
		prism.material = _tip_material(base)
		var ingot := MeshInstance3D.new()
		ingot.mesh = prism
		ingot.rotation_degrees = Vector3(0.0, 90.0, 0.0)
		_tip_mesh.add_child(ingot)
	else:
		_add_tip_part(Vector3(0.85, 0.35, 0.6), base, Vector3.ZERO)
	_tip_mesh.rotation = Vector3(0.35, 0.6, 0.0)


func _tip_material(base: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = base
	return mat


## 往预览场景追加一个盒体部件，返回节点便于调用方追加旋转/位置调整。
func _add_tip_part(box_size: Vector3, base: Color, pos: Vector3, mat: StandardMaterial3D = null) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = box_size
	mesh.material = mat if mat != null else _tip_material(base)
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.position = pos
	_tip_mesh.add_child(part)
	return part


## 储物箱预览：木纹栅格贴面 + 中部深色捆带 + 前侧金色锁扣。
func _build_tip_chest(base: Color) -> void:
	var grid := _make_grid_texture(base)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = grid
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_add_tip_part(Vector3.ONE, base, Vector3.ZERO, mat)
	_add_tip_part(Vector3(1.04, 0.16, 1.04), base.darkened(0.35), Vector3(0.0, 0.12, 0.0))
	_add_tip_part(Vector3(0.16, 0.24, 0.08), Color(0.85, 0.72, 0.30), Vector3(0.0, 0.12, 0.52))


## 工具预览：斜握木柄 + 按类型组合头部（镐横梁/斧侧刃/锹铲头）。
func _build_tip_tool(item_id: int, base: Color) -> void:
	var wood := Color(0.45, 0.30, 0.15)
	var handle := _add_tip_part(Vector3(0.12, 1.1, 0.12), wood, Vector3.ZERO)
	handle.rotation_degrees = Vector3(0.0, 0.0, -35.0)
	match ItemTypes.tool_type(item_id):
		"pickaxe":
			_add_tip_part(Vector3(0.9, 0.14, 0.14), base, Vector3(0.18, 0.48, 0.0))
		"axe":
			_add_tip_part(Vector3(0.42, 0.34, 0.14), base, Vector3(0.3, 0.42, 0.0))
		"shovel":
			_add_tip_part(Vector3(0.3, 0.4, 0.1), base, Vector3(0.18, 0.52, 0.0))
		"sickle":
			# 镰刀：横向弯月刀身 + 短柄。
			var blade := _add_tip_part(Vector3(0.62, 0.09, 0.09), base, Vector3(0.34, 0.42, 0.0))
			blade.rotation_degrees = Vector3(0.0, 0.0, -28.0)
			var tip := _add_tip_part(Vector3(0.26, 0.08, 0.08), base.darkened(0.15), Vector3(0.62, 0.28, 0.0))
			tip.rotation_degrees = Vector3(0.0, 0.0, -62.0)
		"rod":
			# 鱼竿：细长竿身 + 绕线轮 + 垂下的钓线。
			_add_tip_part(Vector3(0.06, 1.25, 0.06), wood, Vector3(0.02, 0.12, 0.0)).rotation_degrees = Vector3(0.0, 0.0, -14.0)
			_add_tip_part(Vector3(0.16, 0.16, 0.10), base, Vector3(-0.1, 0.0, 0.0))
			_add_tip_part(Vector3(0.02, 0.34, 0.02), Color(0.92, 0.92, 0.88), Vector3(0.16, -0.5, 0.0))
		"bow":
			# 弓：竖起的弓臂 + 弓弦。
			var limb := _add_tip_part(Vector3(0.09, 1.15, 0.09), base, Vector3(0.06, 0.06, 0.0))
			limb.rotation_degrees = Vector3(0.0, 0.0, 6.0)
			_add_tip_part(Vector3(0.02, 1.12, 0.02), Color(0.92, 0.92, 0.88), Vector3(0.18, 0.06, 0.0))


## 程序化栅格纹理：底色 + 每隔 16 像素的深色格线（64×64，最近邻采样）。
func _make_grid_texture(base: Color) -> ImageTexture:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(base)
	var line := base.darkened(0.4)
	for i in range(0, 64, 16):
		for p in range(64):
			img.set_pixel(i, p, line)
			img.set_pixel(p, i, line)
	return ImageTexture.create_from_image(img)


func _hide_item_tip() -> void:
	if _tip_panel:
		_tip_panel.visible = false


func _on_box_slot_pressed(index: int) -> void:
	if _box_inventory == null or _player == null:
		return
	var slot: Dictionary = _box_inventory.slots[index]
	var item: int = slot["item"]
	var count: int = slot["count"]
	if item == BlockTypes.Block.AIR or count <= 0:
		return
	# 传源格耐久：磨旧的工具搬进背包不能凭空修满。
	var remaining := _player.inventory.add_item(item, count, int(slot["durability"]))
	var moved := count - remaining
	if moved <= 0:
		return
	_box_inventory.remove_item(index, moved)
	_refresh_box_panel()
	_refresh_hotbar()


func _on_box_player_slot_pressed(index: int) -> void:
	if _box_inventory == null or _player == null:
		return
	var slot: Dictionary = _player.inventory.slots[index]
	var item: int = slot["item"]
	var count: int = slot["count"]
	if item == BlockTypes.Block.AIR or count <= 0:
		return
	var remaining := _box_inventory.add_item(item, count, int(slot["durability"]))
	var moved := count - remaining
	if moved <= 0:
		return
	_player.inventory.remove_item(index, moved)
	_refresh_box_panel()
	_refresh_hotbar()


## 冶炼炉面板：矿石炼锭、铜锡合青铜，材料齐备时按钮可用。
func _build_smelt_panel(root: Control) -> void:
	_smelt_overlay = Control.new()
	_smelt_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_smelt_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(_smelt_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	_smelt_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_smelt_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(500, 320)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "冶炼炉"
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	_smelt_list = VBoxContainer.new()
	_smelt_list.add_theme_constant_override("separation", 8)
	vbox.add_child(_smelt_list)

	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, 44)
	close.pressed.connect(func(): set_smelt_open(false))
	vbox.add_child(close)

	_smelt_overlay.visible = false
	Events.request_smelt.connect(func(): set_smelt_open(true))


func _toggle_smelt_panel() -> void:
	if _smelt_overlay:
		set_smelt_open(not _smelt_overlay.visible)


func set_smelt_open(open: bool) -> void:
	if _smelt_overlay == null:
		return
	_smelt_overlay.visible = open
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	if open:
		_refresh_smelt_panel()


func _refresh_smelt_panel() -> void:
	if _smelt_list == null:
		return
	for child in _smelt_list.get_children():
		_smelt_list.remove_child(child)
		child.queue_free()

	for recipe in ItemTypes.SMELT_RECIPES:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		_smelt_list.add_child(row)

		var label := Label.new()
		label.text = _recipe_text(recipe)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		var button := Button.new()
		button.text = "冶炼"
		button.custom_minimum_size = Vector2(84, 40)
		button.focus_mode = Control.FOCUS_NONE
		button.disabled = not _can_smelt(recipe)
		button.pressed.connect(_on_smelt_pressed.bind(recipe))
		row.add_child(button)


func _can_smelt(recipe: Dictionary) -> bool:
	if _player == null:
		return false
	return _player.inventory.can_craft(recipe)


func _on_smelt_pressed(recipe: Dictionary) -> void:
	if _player == null:
		return
	if _player.inventory.craft(recipe):
		Events.smelt_done.emit(int(recipe["result"]))
		_refresh_smelt_panel()
		_refresh_hotbar()


## 右上角圆形小地图：以玩家为中心定时采样顶面着色，玩家所在格即圆心。
func _build_minimap(root: Control) -> void:
	_minimap = MiniMap.new()
	root.add_child(_minimap)
	_minimap.anchor_left = 1.0
	_minimap.anchor_top = 0.0
	_minimap.anchor_right = 1.0
	_minimap.anchor_bottom = 0.0
	_minimap.offset_left = -(MiniMap.SIZE + MINIMAP_MARGIN)
	_minimap.offset_top = MINIMAP_MARGIN
	_minimap.offset_right = -MINIMAP_MARGIN
	_minimap.offset_bottom = MINIMAP_MARGIN + MiniMap.SIZE
	_minimap.setup(_player, _player.get_world())


## 屏幕顶部居中的地图名：进入区域后显示当前地图名称（带描边保证在天空下可读）。
func _build_map_name(root: Control) -> void:
	_map_name_label = Label.new()
	_map_name_label.text = GameState.region_title()
	_map_name_label.add_theme_font_size_override("font_size", 24)
	_map_name_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.96))
	_map_name_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.75))
	_map_name_label.add_theme_constant_override("outline_size", 6)
	_map_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_map_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_map_name_label)
	_map_name_label.anchor_left = 0.0
	_map_name_label.anchor_right = 1.0
	_map_name_label.offset_left = 0.0
	_map_name_label.offset_right = 0.0
	_map_name_label.offset_top = 14.0
	_map_name_label.offset_bottom = 46.0


func set_map_name(title: String) -> void:
	if _map_name_label != null:
		_map_name_label.text = title


## 地图选择器：M 键呼出；首次进入游戏由 Main 在 _ready 中自动打开。
func _build_map_selector(root: Control) -> void:
	_map_selector = MapSelector.new()
	_map_selector.region_entered.connect(_on_region_entered)
	_map_selector.closed.connect(_on_region_closed)
	_map_selector.bestiary_requested.connect(_on_map_bestiary_requested)
	_map_selector.fishing_requested.connect(_on_fishing_requested)
	root.add_child(_map_selector)


func open_map_selector() -> void:
	if _map_selector == null:
		return
	_map_selector.open()
	_set_player_frozen(true)
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close_map_selector() -> void:
	if _map_selector == null:
		return
	_map_selector.close()


func _on_region_closed() -> void:
	_set_player_frozen(false)
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## 选定区域：本层只解除锁定，区域生效由 Main 监听 Events.region_entered 处理
## （记录到 GameState 并重载主场景，保证区块、村庄、生物一并重建）。
func _on_region_entered(region_id: int) -> void:
	_set_player_frozen(false)
	Events.region_entered.emit(region_id)


## 游戏说明书：阅读型窗口，不冻结玩家（与储物箱面板同模式）。
func _build_manual(root: Control) -> void:
	_manual = ManualPanel.new()
	_manual.closed.connect(_on_manual_closed)
	root.add_child(_manual)


func _build_inventory_panel(root: Control) -> void:
	_inventory_panel = InventoryPanel.new()
	_inventory_panel.closed.connect(_on_inventory_closed)
	_inventory_panel.sold.connect(_on_inventory_sold)
	# 悬停预览：与储物箱/合成台共用同一张预览卡。
	_inventory_panel.slot_hovered.connect(_show_item_tip)
	_inventory_panel.slot_hover_ended.connect(_hide_item_tip)
	root.add_child(_inventory_panel)
	if _player != null:
		_inventory_panel.setup(_player.inventory)


func open_inventory() -> void:
	if _inventory_panel == null:
		return
	_inventory_panel.setup(_player.inventory)
	_inventory_panel.open()
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close_inventory() -> void:
	if _inventory_panel == null:
		return
	_hide_item_tip()
	_inventory_panel.close()


## 背包窗口关闭：没有其他面板仍打开时收回鼠标捕获。
func _on_inventory_closed() -> void:
	if _any_overlay_open() or DisplayServer.is_touchscreen_available():
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## 售卖完成：写系统日志，并把入包后的背包变化暴露给任务系统计数。
func _on_inventory_sold(result: Dictionary) -> void:
	var sold := int(result.get("sold", 0))
	if sold <= 0:
		return
	_push_log("售出 %d 件物品，获得绿宝石 ×%d" % [sold, int(result.get("emeralds", 0))])
	Progress.notify("trade_done", sold)


## 是否有任一覆盖层处于打开状态（决定关闭后是否收回鼠标捕获）。
func _any_overlay_open() -> bool:
	return (_box_overlay != null and _box_overlay.visible) \
		or (_craft_overlay != null and _craft_overlay.visible) \
		or (_trade_overlay != null and _trade_overlay.visible) \
		or (_smelt_overlay != null and _smelt_overlay.visible) \
		or (_manual != null and _manual.is_open()) \
		or (_bestiary != null and _bestiary.is_open()) \
		or (_quest_panel != null and _quest_panel.is_open()) \
		or (_mission_panel != null and _mission_panel.is_open()) \
		or (_settings_panel != null and _settings_panel.is_open()) \
		or (_fishing_gear != null and _fishing_gear.is_open()) \
		or (_fishing_ui != null and _fishing_ui.is_open()) \
		or (_fishing_teaching != null and _fishing_teaching.is_open())


## 是否有任一窗口/面板打开（对外的模态互斥查询）：覆盖层 + 地图选择器 + 背包。
## 工坊台建造界面据此决定 V 键是否响应——模态栈只允许一层（P2-1）。
func is_any_panel_open() -> bool:
	return _any_overlay_open() \
		or (_map_selector != null and _map_selector.is_open()) \
		or (_inventory_panel != null and _inventory_panel.is_open())


## 注入工坊台建造界面（main 在 _ready 里接线）：模态互斥 + 冻结态传播用。
func set_build_screen(screen: BuildScreen) -> void:
	_build_screen = screen


func open_manual() -> void:
	if _manual == null:
		return
	_manual.open()
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close_manual() -> void:
	if _manual == null:
		return
	_manual.close()


func _on_manual_closed() -> void:
	# 仅当没有其他面板仍处于打开状态时，才把鼠标收回捕获模式。
	var overlay_open: bool = (_box_overlay != null and _box_overlay.visible) \
		or (_craft_overlay != null and _craft_overlay.visible) \
		or (_trade_overlay != null and _trade_overlay.visible) \
		or (_smelt_overlay != null and _smelt_overlay.visible)
	if not overlay_open and not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## 生物图鉴：阅读 + 问答型窗口，行为与说明书一致（不冻结玩家物理）。
##   atlas_id 给定时预置该世界区域的地区筛选——地图页的「看看这里的生物」走这条。
func _build_bestiary(root: Control) -> void:
	_bestiary = BestiaryUI.new()
	_bestiary.closed.connect(_on_manual_closed)
	root.add_child(_bestiary)


func open_bestiary(atlas_id: int = -1) -> void:
	if _bestiary == null:
		return
	if atlas_id >= 0:
		_bestiary.open_for_atlas_region(atlas_id)
	else:
		_bestiary.open()
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close_bestiary() -> void:
	if _bestiary == null:
		return
	_bestiary.close()


## 地图介绍页 → 图鉴：先关掉地图选择器（它会解除玩家冻结），再打开图鉴。
func _on_map_bestiary_requested(region_id: int) -> void:
	close_map_selector()
	open_bestiary(region_id)


## 任务与成就面板：模态窗口，冻结玩家（同地图选择器）。
func _build_quest_panel(root: Control) -> void:
	_quest_panel = QuestPanel.new()
	_quest_panel.closed.connect(_on_quest_panel_closed)
	root.add_child(_quest_panel)


func open_quest_panel() -> void:
	if _quest_panel == null:
		return
	_quest_panel.open()
	_set_player_frozen(true)
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close_quest_panel() -> void:
	if _quest_panel == null:
		return
	_quest_panel.close()


func _on_quest_panel_closed() -> void:
	_set_player_frozen(false)
	_on_manual_closed()


## 飞行任务面板：模态窗口，冻结玩家（同任务与成就面板）。
func _build_mission_panel(root: Control) -> void:
	_mission_panel = MissionPanel.new()
	_mission_panel.closed.connect(_on_mission_panel_closed)
	_mission_panel.mission_reward.connect(_on_mission_panel_reward)
	root.add_child(_mission_panel)


## 注入飞行任务锚点（机场中心或出生点 xz）到任务面板：任务航路/降落区随之贴合实际机场。
func set_mission_anchor(center: Vector3) -> void:
	if _mission_panel != null:
		_mission_panel.set_mission_anchor(center)


## 飞行屏幕仪表 HUD 实例（main 装配座舱 3D 面板 / 世界标注时注册 3D 视图用）。
func instrument_hud() -> FlightInstrumentHUD:
	return _instrument_hud


## 设置飞行 HSI/CDI 直飞导航目标（main 在登机时注入机场/任务锚点）。
func set_flight_navigation(target: Vector3, name: String = "") -> void:
	if _instrument_hud != null:
		_instrument_hud.set_navigation(target, name)


func open_mission_panel() -> void:
	if _mission_panel == null:
		return
	_mission_panel.open()
	_set_player_frozen(true)
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close_mission_panel() -> void:
	if _mission_panel == null:
		return
	_mission_panel.close()


func _on_mission_panel_closed() -> void:
	_set_player_frozen(false)
	_on_manual_closed()


func _build_settings_panel(root: Control) -> void:
	_settings_panel = SettingsPanel.new()
	_settings_panel.closed.connect(_on_settings_panel_closed)
	_settings_panel.settings_changed.connect(_on_settings_changed)
	root.add_child(_settings_panel)


func open_settings_panel() -> void:
	if _settings_panel == null:
		return
	_settings_panel.open()
	_set_player_frozen(true)
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close_settings_panel() -> void:
	if _settings_panel == null:
		return
	_settings_panel.close()


func _on_settings_panel_closed() -> void:
	_set_player_frozen(false)
	_on_manual_closed()


## 设置改动即时生效（飞机每帧读 FlightSettings.current()）；此处只 Toast 确认。
func _on_settings_changed(_difficulty: int, _assist_level: int, _livery_index: int) -> void:
	var s := FlightSettings.current()
	Events.notice.emit("飞行设置：难度 %s · 辅助 %s · 涂装 %s" % [
		s.difficulty_name(), s.assist_name(), s.livery_name()])


# ────────────────────────── 钓鱼（feature_fishing） ──────────────────────────
## 三个界面按「整备 → 操作 → 教学」的顺序挂在同一层里，教学 z 最高。
## .modal 互斥沿用既有规则：任一钓鱼窗口打开时，其余热键与建造界面让位。
func _build_fishing(root: Control) -> void:
	_fishing_gear = FishingGearUI.new()
	_fishing_gear.closed.connect(_on_fishing_gear_closed)
	_fishing_gear.start_requested.connect(_open_fishing_ui)
	root.add_child(_fishing_gear)

	_fishing_ui = FishingUI.new()
	_fishing_ui.closed.connect(_on_fishing_closed)
	_fishing_ui.teaching_requested.connect(_on_fishing_teaching_requested)
	root.add_child(_fishing_ui)

	_fishing_teaching = FishingTeachingUI.new()
	_fishing_teaching.closed.connect(_on_fishing_teaching_closed)
	root.add_child(_fishing_teaching)

	FishingSystem.fish_caught.connect(_on_fish_caught)
	FishingSystem.new_species_unlocked.connect(_on_new_species)


## 从地图选择器点「🎣 去钓鱼」进来：先关地图选择器（它会解冻玩家），再冻结。
func _on_fishing_requested(atlas_region: int) -> void:
	if _map_selector != null and _map_selector.is_open():
		_map_selector.close()
	open_fishing_gear(atlas_region)


func open_fishing_gear(atlas_region: int) -> void:
	if _fishing_gear == null:
		return
	_fishing_gear.open_for_atlas(atlas_region)
	if not _fishing_gear.is_open():
		Events.notice.emit("这片海域还没有开放的钓点")
		return
	_set_player_frozen(true)
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_fishing_gear_closed() -> void:
	_set_player_frozen(false)
	_on_manual_closed()


## 装备整备完成 → 打开渔猎界面（FishingSystem 里已经 start_fishing 过）。
func _open_fishing_ui() -> void:
	if _fishing_ui == null:
		return
	_fishing_ui.open_session()
	_set_player_frozen(true)


func _on_fishing_closed() -> void:
	_set_player_frozen(false)
	_on_manual_closed()


## 教学弹窗：弹出期间冻结渔猎界面的计时（不然读教学时鱼早跑了）。
func _on_fishing_teaching_requested(lesson: Dictionary) -> void:
	if _fishing_teaching == null or _fishing_teaching.is_open():
		return
	if _fishing_teaching.show_lesson(lesson):
		_fishing_ui.set_paused(true)


func _on_fishing_teaching_closed() -> void:
	if _fishing_ui != null:
		_fishing_ui.set_paused(false)


## 钓到鱼：生鱼入包（复用既有 RAW_FISH），图鉴记录由 FishingSystem 自己写。
func _on_fish_caught(fish_id: String, _spot_id: String, _gear: Dictionary) -> void:
	var entry := FishingSystem.get_fish(fish_id)
	if _player != null:
		_player.inventory.add_item(ItemTypes.RAW_FISH, 1)
	_push_log("钓到 %s（%s）" % [
		String(entry.get("name_zh", fish_id)), String(FishingSystem.record_of(fish_id).get(
			"first_caught_spot", ""))])


func _on_new_species(fish_id: String) -> void:
	var entry := FishingSystem.get_fish(fish_id)
	Events.notice.emit("新鱼种：%s 已收入生物图鉴" % String(entry.get("name_zh", fish_id)))


## main 每物理帧调用：把飞行遥测透传给任务面板（仅 RUNNING 时生效）。
func feed_mission(dt: float, telemetry: Dictionary) -> void:
	if _mission_panel != null:
		_mission_panel.feed(dt, telemetry)


## 任务成功奖励：绿宝石直接入库存（货币复用 ItemTypes.EMERALD），并 Toast。
## 防刷（P2-9）：同一任务每进程仅发一次——repeat 结果（MissionManager 裁决）
## 只提示「本次不再发放」，不再入包。
func _on_mission_panel_reward(emeralds: int, success: bool, result: Dictionary) -> void:
	if not success:
		return
	# D-033：任务成功 → 1.2 s 后自动回放本段飞行（先让奖励 Toast 读完）。
	# repeat（重复挑战）同样回放——演出与奖励脱钩；仅要求仍在驾驶（未下机）。
	if _replay != null and _recorder != null and _recorder.sample_count() > 1 \
			and _player != null and _player.is_riding():
		get_tree().create_timer(1.2).timeout.connect(_start_replay)
	if bool(result.get("repeat", false)):
		_show_toast("任务完成！奖励已在本进程内领取，本次不再发放")
		return
	if emeralds <= 0:
		return
	if _player != null:
		_player.inventory.add_item(ItemTypes.EMERALD, emeralds)
		_refresh_hotbar()
	_show_toast("任务奖励：绿宝石 ×%d" % emeralds)


## 进度信号 → 面板刷新 / 奖励入包 / 顶部 Toast 提示。
func _connect_progress() -> void:
	Progress.quest_completed.connect(_on_quest_completed)
	Progress.quest_claimed.connect(_on_quest_claimed)
	Progress.achievement_unlocked.connect(_on_achievement_unlocked)
	Progress.quiz_reward_earned.connect(_on_quiz_reward)


func _on_quest_completed(id: String) -> void:
	var entry := QuestData.entry_by_id(id)
	_show_toast("任务达成：%s（打开任务面板领取奖励）" % String(entry.get("title", id)))


func _on_quest_claimed(_id: String, reward: Dictionary) -> void:
	if _player != null:
		_player.inventory.add_item(int(reward["item"]), int(reward["count"]))
		_refresh_hotbar()
	_show_toast("已领取：%s ×%d" % [
		ItemTypes.item_name(int(reward["item"])), int(reward["count"]),
	])
	if _quest_panel != null:
		_quest_panel.refresh()


func _on_achievement_unlocked(id: String) -> void:
	var entry := QuestData.entry_by_id(id)
	_show_toast("成就达成：◆ %s" % String(entry.get("title", id)))


func _on_quiz_reward(item: int, count: int) -> void:
	if _player != null:
		_player.inventory.add_item(item, count)
		_refresh_hotbar()
	_show_toast("问答连对奖励：%s ×%d" % [ItemTypes.item_name(item), count])


## 顶部居中 Toast：短暂浮现后淡出，不阻塞操作。
func _build_toast(root: Control) -> void:
	_toast_label = Label.new()
	_toast_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_toast_label.offset_left = -320.0
	_toast_label.offset_right = 320.0
	_toast_label.offset_top = 64.0
	_toast_label.offset_bottom = 96.0
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.add_theme_font_size_override("font_size", 20)
	_toast_label.add_theme_color_override("font_color", Color(1.0, 0.96, 0.85))
	_toast_label.add_theme_color_override("font_outline_color", Color(0.16, 0.11, 0.05))
	_toast_label.add_theme_constant_override("outline_size", 6)
	_toast_label.modulate.a = 0.0
	root.add_child(_toast_label)


func _show_toast(text: String) -> void:
	if _toast_label == null:
		return
	_toast_label.text = text
	if _toast_tween != null:
		_toast_tween.kill()
	_toast_label.modulate.a = 1.0
	_toast_tween = create_tween()
	_toast_tween.tween_interval(2.2)
	_toast_tween.tween_property(_toast_label, "modulate:a", 0.0, 0.6)


## 死亡 RIP 覆盖层：暗幕 + 墓碑图案 + 文案，与玩家的死亡停顿时长同步。
## mouse_filter 全程 IGNORE：不挡触摸/点击，停顿结束随复活淡出。
func _build_death_overlay(root: Control) -> void:
	_death_overlay = Control.new()
	_death_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_death_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_overlay.visible = false
	root.add_child(_death_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.08, 0.05, 0.06, 0.62)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_overlay.add_child(dim)

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_overlay.add_child(box)

	var tomb := Label.new()
	tomb.text = "🕯\nR.I.P"
	tomb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tomb.add_theme_font_size_override("font_size", 56)
	tomb.add_theme_color_override("font_color", Color(0.92, 0.90, 0.86))
	tomb.add_theme_color_override("font_outline_color", Color(0.10, 0.07, 0.06))
	tomb.add_theme_constant_override("outline_size", 8)
	box.add_child(tomb)

	var tip := Label.new()
	tip.text = "睡了一觉……即将回到出生点"
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.add_theme_font_size_override("font_size", 18)
	tip.add_theme_color_override("font_color", Color(0.85, 0.80, 0.74))
	tip.add_theme_color_override("font_outline_color", Color(0.10, 0.07, 0.06))
	tip.add_theme_constant_override("outline_size", 5)
	box.add_child(tip)


## 玩家死亡：浮现 RIP 覆盖层，停顿结束（约 2.2 秒）后淡出，与复活同步。
func _on_player_died() -> void:
	if _death_overlay == null:
		return
	if _death_tween != null:
		_death_tween.kill()
	_death_overlay.modulate.a = 0.0
	_death_overlay.visible = true
	_death_tween = create_tween()
	_death_tween.tween_property(_death_overlay, "modulate:a", 1.0, 0.25)
	_death_tween.tween_interval(1.6)
	_death_tween.tween_property(_death_overlay, "modulate:a", 0.0, 0.45)
	_death_tween.tween_callback(func() -> void: _death_overlay.visible = false)


## 全屏模态期间冻结玩家：关闭物理与输入处理，避免镜头与移动在背后漂移。
func _set_player_frozen(frozen: bool) -> void:
	if _player == null:
		return
	_player.set_physics_process(not frozen)
	_player.set_process_unhandled_input(not frozen)
	# 冻结态同时落到 input_locked：飞行器每帧读它门控驾驶输入——
	# 否则骑着飞机开 K/O 面板时，W/S 油门、A/D 方向舵、空格刹车仍实时
	# 操控飞机（P2-2）。语义即「模态界面打开中」，与工坊台用法一致。
	_player.input_locked = frozen


func _refresh_stats() -> void:
	if _player == null:
		return
	if _hearts:
		_hearts.queue_redraw()
	if _hunger_label:
		_hunger_label.text = "饥饿 %d / %d" % [int(_player.hunger), _player.MAX_HUNGER]
	_refresh_time()


## 通用提示：直接转成顶部 Toast。
func _on_notice(text: String) -> void:
	_show_toast(text)


func _on_day_changed(_day: int) -> void:
	_refresh_time()


func _refresh_time() -> void:
	if _time_label == null:
		return
	if _day_night == null:
		_time_label.text = "白天 06:00"
	else:
		_time_label.text = "第 %d 天 %s%s · %s" % [
			_day_night.day_count(),
			"白天 " if _day_night.is_day() else "夜晚 ",
			_day_night.get_clock(),
			_day_night.weather_name(),
		]


func _on_health_changed(_value: int) -> void:
	_refresh_stats()


func _on_hunger_changed(_value: int) -> void:
	_refresh_stats()
	# 快见底时提醒一次（只在跨过阈值那一次提示，不每点都刷屏）。
	if _player != null and int(_player.hunger) == HUNGER_WARN_LEVEL:
		_show_toast("🍖 饿得发慌了，找点东西吃吧")


## 掉血播报：把来源和数值一起说清楚，站着不动莫名掉血时玩家能立刻看懂原因。
func _on_damage_taken(amount: int, reason: String, remaining: int) -> void:
	if amount <= 0:
		return
	var label := "被%s打中了" % reason if not reason.is_empty() else "受伤"
	if reason == Player.REASON_STARVE:
		label = "饿坏了"
	elif reason == Player.REASON_FALL:
		label = "摔了一跤"
	elif reason == Player.REASON_STUCK:
		label = "卡进方块里了"
	elif reason == Player.REASON_CRASH:
		# 带上 wreck 广播的具体原因（P2-5）：「飞机坠毁了（摔得太狠，机身解体）」
		# 而不是修复前的病句「被坠机打中了」。
		label = "飞机坠毁了" if _last_crash_reason.is_empty() \
			else "飞机坠毁了（%s）" % _last_crash_reason
	_show_toast("💔 %s −%d（剩 %d）" % [label, amount, remaining])


func _on_time_changed(_percent: float, _is_day: bool) -> void:
	_refresh_time()


func _on_mode_changed(_mode: int) -> void:
	_refresh_mode_badge()
	if _fly_button:
		_fly_button.visible = GameState.can_fly()
	if _descend_button:
		_descend_button.visible = GameState.can_fly()
	# 中途切进探索模式：补发开局赠送的那架飞机（一次性标记防重复）。
	if GameState.is_explore() and GameState.claim_explore_aircraft() \
			and _player != null and _player.inventory != null:
		_player.inventory.add_item(ItemTypes.AIRCRAFT, 1)
		_show_toast("🎁 探索模式礼物：一架轻型飞机，找块平地右键放下它")
	_refresh_hotbar()
	_refresh_stats()


## 刷新模式徽章：只取两个字（生存/创造/探索），颜色按模式区分——
## 草绿=生存、金黄=创造、天青=探索。文字与判据都取自 GameState，
## HUD 只负责呈现，免得这里再长出第二套说法。
func _refresh_mode_badge() -> void:
	if _mode_label == null:
		return
	var color := Color(0.72, 0.94, 0.60)
	if GameState.is_creative():
		color = Color(1.0, 0.86, 0.42)
	elif GameState.is_explore():
		color = Color(0.62, 0.92, 1.0)
	_mode_label.text = GameState.mode_name()
	_mode_label.add_theme_color_override("font_color", color)
