class_name InputActions
## 运行时把桌面键位注册到 InputMap，统一以动作名取输入（替代物理键位轮询）。
## register() 幂等，可在 Main 与 Player 的 _ready 中重复调用，保证场景可单独运行。

const ACTIONS := {
	"move_left": [KEY_A],
	"move_right": [KEY_D],
	"move_forward": [KEY_W],
	"move_back": [KEY_S],
	"jump": [KEY_SPACE],
	"sprint": [KEY_SHIFT],
	"fly_down": [KEY_CTRL],
	"toggle_craft": [KEY_E],
	"toggle_mode": [KEY_G],
	"toggle_inventory": [KEY_B],
	"toggle_trade": [KEY_T],
	"toggle_map": [KEY_M],
	"toggle_manual": [KEY_F1],
	"toggle_bestiary": [KEY_F2],
	"toggle_quests": [KEY_J],
	# 工坊台建造界面（V）：蓝图编辑 + 试飞（D-032 Phase 4a）。
	"toggle_build": [KEY_V],
	"toggle_missions": [KEY_K],
	# 飞行设置面板（O）：难度与辅助稳定（D-032 Phase 5-b）。
	"toggle_settings": [KEY_O],
	# 飞行器驾驶：鼠标给操纵杆（俯仰/滚转），方向键为键盘替代；
	# W/S 复用 move_forward/back（油门），A/D 复用 move_left/right（方向舵），
	# 空格复用 jump（地面机轮刹车 / 空中拉升），Shift 复用 sprint（空中加速），
	# Ctrl 复用 fly_down（空中下降），F 发动机启停，X 下机，
	# C 切换第一/第三人称，V 自由观察，R 后视，M 战术地图（复用 toggle_map）。
	"aircraft_pitch_up": [KEY_UP],
	"aircraft_pitch_down": [KEY_DOWN],
	"aircraft_roll_left": [KEY_LEFT],
	"aircraft_roll_right": [KEY_RIGHT],
	"aircraft_engine": [KEY_F],
	"aircraft_exit": [KEY_X],
	"aircraft_view": [KEY_C],
	"aircraft_freelook": [KEY_V],
	"aircraft_rear": [KEY_R],
	# 襟翼单键循环（D-034）：Z 走 0→1→2→0（左手小指区，右手管鼠标时可盲按）。
	"aircraft_flaps": [KEY_Z],
	# HUD 简单/详细模式切换（D-034）：H 从未被占用（D-008 只列为帮助预留）。
	"hud_detail": [KEY_H],
	# 回放（D-033）：P 手动回放最近一段飞行；回放中 P / Esc 跳过。
	"replay_play": [KEY_P],
}

const SLOT_ACTION_COUNT := 9


static func register() -> void:
	for action: String in ACTIONS:
		_register_action(action, ACTIONS[action])
	for i in range(SLOT_ACTION_COUNT):
		_register_action("slot_%d" % (i + 1), [KEY_1 + i])


static func _register_action(action: String, keys: Array) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	for key: Key in keys:
		var event := InputEventKey.new()
		event.physical_keycode = key
		InputMap.action_add_event(action, event)
