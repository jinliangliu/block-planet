extends Node

## 无头验证 BuildScreen（工坊台建造界面，D-032 Phase 4a）的界面逻辑：
## 打开加载默认蓝图 / 光标求交 / 放置冲突 / 删除 / 旋转 / 镜像 / 绿宝石购买 /
## 试飞守卫 / 蓝图存取往返。不渲染验证（headless 无真实画面），只验状态机。

const TEST_PATH := "user://test_bp_probe.json"

var _pass := 0
var _fail := 0
## 真实蓝图存档快照（D-010 铁律 3）：本探针要删掉它从默认可飞套件开局，且运行中
## close() 会把探针态自动落盘——结束时原样还原，绝不毁用户真实蓝图。
var _bp_existed := false
var _bp_text := ""


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("PASS: " + msg)
	else:
		_fail += 1
		print("FAIL: " + msg)


func _key(kc: Key) -> InputEvent:
	var ev := InputEventKey.new()
	ev.keycode = kc
	ev.pressed = true
	ev.echo = false
	return ev


func _send(screen: BuildScreen, ev: InputEvent) -> void:
	screen._unhandled_input(ev)


func _ready() -> void:
	InputActions.register()
	# 快照真实蓝图存档，再清场（保证从默认可飞套件开局）。
	if FileAccess.file_exists(BuildScreen.BLUEPRINT_PATH):
		_bp_existed = true
		var bf := FileAccess.open(BuildScreen.BLUEPRINT_PATH, FileAccess.READ)
		_bp_text = bf.get_as_text()
		bf.close()
	if FileAccess.file_exists(BuildScreen.BLUEPRINT_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(BuildScreen.BLUEPRINT_PATH))
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))

	var player := Player.new()
	player.inventory.add_item(ItemTypes.EMERALD, 30)

	var screen := BuildScreen.new()
	add_child(screen)
	screen.setup(player)
	screen.open()
	_check(screen.visible, "open() 后界面可见")
	_check(screen.editor.blueprint.parts.size() == 7,
		"无存档时从默认可飞套件开局（%d 件）" % screen.editor.blueprint.parts.size())
	_check(screen._selected_id == "fuselage", "默认选中机身")

	# 光标：屏幕中心射线应与建造层平面相交，幽灵盒可见。
	screen._update_cursor(Vector2(576.0, 324.0))
	_check(screen._cursor_valid, "中心射线与建造层平面有效相交")
	_check(screen._ghost != null and screen._ghost.visible, "幽灵盒在光标处显示")

	# 放置：空格落点（镜像开启 → 原件 + 镜像件各一）。
	var spot := Vector3i(5, 2, 5)
	screen._cursor = spot
	screen._cursor_valid = true
	screen._place_cursor()
	_check(screen.editor.blueprint.parts.size() == 9,
		"放置机身成功且轴对称镜像（%d 件）" % screen.editor.blueprint.parts.size())
	# 同格再放：footprint 冲突 → 拒绝。
	screen._place_cursor()
	_check(screen.editor.blueprint.parts.size() == 9, "占用格冲突时拒绝重复放置")
	_check(not screen._status.text.is_empty(), "冲突时给出状态提示")
	# 旋转光标格零件。
	screen._rotate_cursor()
	var rotated := false
	for p in screen.editor.blueprint.parts:
		if p.cell == spot and p.rot == 1:
			rotated = true
	_check(rotated, "R 旋转光标格零件（rot 0→1）")
	# 删除：连同镜像件一并移除。
	screen._delete_cursor()
	_check(screen.editor.blueprint.parts.size() == 7,
		"删除光标格零件（含镜像件）回到 %d 件" % screen.editor.blueprint.parts.size())

	# 键盘：T 切镜像、[ ] 改建造层。
	_send(screen, _key(KEY_T))
	_check(not screen._mirror, "T 键关闭轴对称")
	_send(screen, _key(KEY_BRACKETLEFT))
	_check(screen._build_layer == -1, "[ 键建造层下移")
	_send(screen, _key(KEY_BRACKETRIGHT))
	_send(screen, _key(KEY_BRACKETRIGHT))
	_check(screen._build_layer == 1, "] 键建造层上移")
	_send(screen, _key(KEY_BRACKETLEFT))

	# 绿宝石购买：30 颗买涡轮机（30）成功；长航程机翼（20）余额不足失败。
	screen._on_part_button("turbine")
	_check(screen._selected_id == "turbine", "绿宝石充足时购买并选中涡轮发动机")
	_check(player.inventory.count_item(ItemTypes.EMERALD) == 0,
		"购买扣费正确（剩余 %d）" % player.inventory.count_item(ItemTypes.EMERALD))
	var turbine_btn := screen._palette.get_node("part_turbine") as Button
	_check(turbine_btn != null and not turbine_btn.text.contains("🔒"),
		"解锁后面板不再显示锁标")
	screen._on_part_button("long_wing")
	_check(screen._selected_id == "turbine", "余额不足时保持原选择")
	_check(screen._status.text.contains("不足"), "余额不足时提示（%s）" % screen._status.text)

	# 试飞守卫：清空蓝图 → 拒绝；恢复默认套件 → 放行并关闭界面。
	screen.editor.clear()
	var fly_result: Dictionary = {}
	screen.test_fly_requested.connect(func(bp: Blueprint): fly_result["bp"] = bp)
	screen._on_test_fly()
	_check(fly_result.is_empty(), "蓝图不完整时拒绝试飞")
	_check(screen.visible, "拒绝试飞后界面保持打开")
	screen._selected_id = "fuselage"
	screen._mirror = true
	screen.editor.blueprint.parts = PartRegistry.default_loadout()
	screen._on_test_fly()
	_check(not fly_result.is_empty(), "蓝图合法时发出试飞请求")
	_check(fly_result.get("bp") != null, "试飞请求携带蓝图")
	_check(not screen.visible, "试飞放行后关闭界面")
	_check(not player.input_locked, "关闭界面后解除玩家输入冻结")

	# 存取往返：关闭自动存档 → 重开加载 → 零件集合一致。
	screen.open()
	_check(screen.editor.blueprint.parts.size() == 7,
		"重开自动加载存档蓝图（%d 件）" % screen.editor.blueprint.parts.size())
	screen.editor.save(TEST_PATH)
	var loaded := Blueprint.load(TEST_PATH)
	_check(loaded != null and loaded.parts.size() == 7, "显式保存后可读回（%d 件）"
		% (loaded.parts.size() if loaded else -1))
	screen.close()

	# 还原真实蓝图存档 + 清理探针临时文件（D-010 铁律 3）。
	if _bp_existed:
		var bf := FileAccess.open(BuildScreen.BLUEPRINT_PATH, FileAccess.WRITE)
		bf.store_string(_bp_text)
		bf.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(BuildScreen.BLUEPRINT_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))

	print("BUILD_SCREEN_PROBE_DONE fails=%d" % _fail)
	if _fail > 0:
		print("BUILD_SCREEN_PROBE_FAIL")
	else:
		print("BUILD_SCREEN_PROBE_OK")
	get_tree().quit()
