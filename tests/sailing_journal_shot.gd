extends Node
## 我的航海记录（D-089 阶段 2）窗口截图探针：16:9 / 20:9 两档 PNG。
##
## 绕过 main.tscn 与 HUD：直接 preload(".../sailing_journal_ui.gd").new() 挂到
## 探针根节点——这正是阶段 2 不需要改 hud.gd 的原因（阶段 3 才挂 HUD 入口）。
##
## D-010 三层闭合（**两个** Autoload 都做，缺一不可）：BoatSystem 与
## FishingSystem 的 _exit_tree() 都无条件 _save_journal()，唯一闸门是各自的
## journal_ok；两者 _load_journal() 在文件不存在时也会把 journal_ok 置 true。
## fishing_journal.json 始终不在 SaveGuard.EXTRA_FILES 内，SaveGuard.restore()
## 覆盖不到它；BoatSystem._process() 1.5 s 防抖在运行期就有写盘能力。
## 故收尾顺序固定：① 拒写闸最前（两个 journal_ok=false）→ ② 按开局快照的
## JOURNAL_PATH 逐字节回写 / 删除两份文本 → ③ SaveGuard.restore()。
## 本探针只改内存态、不调 claim/record 接口，**但「不调写接口＝零写盘」不成立**
## （D-088 早期规格就栽在这里）；两份快照都必须先于 headless 早退分支。
## 反向对照（坑 #15 防恒 PASS 假绿）：切比例截图之前改内存态并断言
## 「未刷新不变 / refresh() 后变 / 等于当前 sail_state()」，随后 _seed_sail() +
## _ui.refresh() 还原 680.0 基线，避免污染 _check_common() 与两张 PNG；
## 末尾 _passed>0 哨兵 + _finish() 的 _OK 打印门控。
##
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/sailing_journal_shot.tscn
## （勿加 --headless；无头下 frame_post_draw 永不触发会挂起）

const SHOT_DIR := "res://tmp"
const JournalScript := preload("res://scripts/ui/sailing_journal_ui.gd")

var _failed: int = 0
var _passed: int = 0
var _restored: bool = false
## 两份根状态文件按「开局路径 + 原文本 + 是否存在」逐字节快照（D-010）。
var _fish_path_at_start: String = ""
var _fish_text: String = ""
var _fish_existed: bool = false
var _boat_path_at_start: String = ""
var _boat_text: String = ""
var _boat_existed: bool = false

## 航海记录脚本无 class_name，preload 实例是 Variant（坑 #33）：凡接 _ui.xxx()
## 返回值一律显式类型，绝不用 :=（会触发 Parse Error: Cannot infer the type）。
var _ui = null
var _panel_ctrl: Control = null


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		push_warning("sailing_journal_shot: 看门狗超时，强制退出")
		get_tree().quit(1))
	# 快照必须先于任何早退分支：headless 早退同样触发 _exit_tree → _restore()，
	# 若此时 snapshot 未执行，SaveGuard.restore() 会用空静态态删掉真实存档。
	SaveGuard.snapshot()
	# 两份根状态文件按开局路径逐字节快照；必须在 headless 早退之前，
	# 因为早退同样走 _exit_tree() → _restore()（会按这两份快照还原）。
	_fish_path_at_start = FishingSystem.JOURNAL_PATH
	if FileAccess.file_exists(_fish_path_at_start):
		_fish_existed = true
		var ff: FileAccess = FileAccess.open(_fish_path_at_start, FileAccess.READ)
		if ff != null:
			_fish_text = ff.get_as_text()
			ff.close()
	_boat_path_at_start = BoatSystem.JOURNAL_PATH
	if FileAccess.file_exists(_boat_path_at_start):
		_boat_existed = true
		var bf: FileAccess = FileAccess.open(_boat_path_at_start, FileAccess.READ)
		if bf != null:
			_boat_text = bf.get_as_text()
			bf.close()
	if DisplayServer.get_name() == "headless":
		print("SAILING_JOURNAL_SHOT_SKIP: 需窗口渲染")
		get_tree().quit(0)
		return
	await _run()
	_finish()


func _finish() -> void:
	_restore()
	# 哨兵：_passed==0（整段 _run() 被跳过等）不允许打印 _OK；末尾的哨兵断言
	# 会把这种情况记成 FAIL，quit() 沿用 _failed==0 判据即可（0 PASS ⇒ rc=1）。
	if _failed == 0 and _passed > 0:
		print("SAILING_JOURNAL_SHOT_OK passed=%d" % _passed)
	else:
		print("SAILING_JOURNAL_SHOT_FAILED count=%d passed=%d" % [_failed, _passed])
	get_tree().quit(0 if _failed == 0 else 1)


## 幂等收尾（正常路径 / _exit_tree 安全网 / 看门狗三条路共用）。
## 顺序固定：① 拒写闸最前 → ② 按开局路径逐字节还原两份 → ③ SaveGuard.restore()。
func _restore() -> void:
	if _restored:
		return
	_restored = true
	if _ui != null and is_instance_valid(_ui):
		_ui.queue_free()
	# ① 拒写闸优先：挡住 BoatSystem._process() 防抖写盘与两个 _exit_tree()。
	FishingSystem.journal_ok = false
	BoatSystem.journal_ok = false
	# ② 按开局路径复原，并按开局存在性回写 / 删除（删除前 file_exists 守卫）。
	if not _fish_path_at_start.is_empty():
		FishingSystem.JOURNAL_PATH = _fish_path_at_start
		_restore_text(_fish_path_at_start, _fish_existed, _fish_text)
	if not _boat_path_at_start.is_empty():
		BoatSystem.JOURNAL_PATH = _boat_path_at_start
		_restore_text(_boat_path_at_start, _boat_existed, _boat_text)
	# ③ 最后还原 SaveGuard 覆盖的存档树与 Progress 内存态。
	SaveGuard.restore()


func _restore_text(path: String, existed: bool, text: String) -> void:
	if existed:
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(path.get_base_dir()))
		var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(text)
			f.close()
	elif FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _exit_tree() -> void:
	_restore()


# ───────────── 内存态构造（_seed_sail 只改 journal 内存，不调 claim/record）────────────
# 注意：Autoload 退出期仍会无条件写盘，隔离靠上面 _restore() 的三层闭合，
# 不能由「没调写接口」推出「零写盘」。

func _seed_sail() -> void:
	BoatSystem.journal = {
		"version": 2, "owned": ["raft"], "current": "raft", "fuel": {},
		"sail": {
			"total_m": 680.0, "farthest_m": 312.0,
			"bands": {"near": 12, "mid": 7, "far": 3},
			"badges": {"sail_100": 1, "sail_500": 1},
		},
	}
	BoatSystem._dirty = false
	BoatSystem._last_save_msec = Time.get_ticks_msec()


# ────────────────────────── 主流程 ──────────────────────────

func _run() -> void:
	# add_child 前先让 Autoload 完成首帧暖机。
	await get_tree().process_frame
	_ui = JournalScript.new()
	add_child(_ui)
	await get_tree().process_frame
	var panels: Array = _ui.find_children("*", "PanelContainer", true, false)
	if panels.size() >= 1:
		_panel_ctrl = panels[0] as PanelContainer
	_check(_panel_ctrl != null, "① 航海记录 UI 已实例化且 panel 已构建")
	_seed_sail()
	_ui.open()
	await get_tree().process_frame
	await _settle(3)

	# ── 反向对照（坑 #15）：钉死「现取不缓存」，按裁决放在切比例截图之前 ──
	# journal_ok=false 只挡 _process() 防抖写盘与 _exit_tree()，不挡
	# record_sail() 改内存、也不挡 sail_state() 读内存 ⇒ 断言有效。
	BoatSystem.journal_ok = false
	var before: String = _ui.total_text()
	BoatSystem.record_sail(250.0, 300.0, "near")
	var unchanged: String = _ui.total_text()
	_check(unchanged == before, "R4 未刷新前文本保持（证明不是每帧轮询）")
	_ui.refresh()
	var after: String = _ui.total_text()
	var st: Dictionary = BoatSystem.sail_state()
	_check(after != before, "R5 反向对照：改 sail 状态后文本必须变化（缓存实现必 FAIL）")
	_check(after == "累计出海：%.1f m" % float(st["total_m"]),
		"R6 刷新后文本 = 当前 sail_state() 的 total_m")
	# 防污染补步：反向对照把 total_m 从 680.0 推到 930.0，若不还原，后面
	# _check_common() 的 "680.0" 断言与两张 PNG 都会变成 930.0。_seed_sail()
	# 只改内存（不写盘），_ui.refresh() 重新渲染回基线；journal_ok 保持 false，
	# 截图期间 _process() 不会写盘，收尾 _restore() 无需额外复位。
	_seed_sail()
	_ui.refresh()

	# ── 16:9 ──
	await _set_ratio(Vector2i(1280, 720), "16:9", "1280x720")
	_check_common("16:9")
	await _capture("sailing_journal_16x9.png", "① 16:9 默认态", _panel_ctrl)

	# ── 20:9 ──
	await _set_ratio(Vector2i(1280, 576), "20:9", "1280x576")
	# 构造式闸：两档复用同一 UI 实例，16:9 若滚过底，20:9 的默认态证据图
	# 会把顶部标题裁掉（D-088 race_result_20x9 教训）。
	await _scroll_top()
	_check_common("20:9")
	await _capture("sailing_journal_20x9.png", "② 20:9 默认态", _panel_ctrl)
	# 哨兵（坑 #15 / D-088 flight_shot 教训）：PASS=0 是危险信号。放在所有断言
	# 之后，若前面一条 PASS 都没产出，这一条记 FAIL ⇒ _finish() 里 quit() 沿用
	# _failed==0 判据即为 rc=1，且 _OK 的 _passed>0 打印门控也不会放行。
	_check(_passed > 0, "R7 哨兵：本探针至少产出 1 条 PASS（0 PASS 视为假绿）")


# ────────────────────────── 断言组 ──────────────────────────

func _check_common(tag: String) -> void:
	var is_open: bool = bool(_ui.is_open())
	_check(is_open, "%s 航海记录 is_open()==true" % tag)
	var title: String = _ui.title_text()
	_check(title.contains("我的航海记录"),
		"%s 标题为「我的航海记录」（不叫航海日志）" % tag)
	var total: String = _ui.total_text()
	_check(total.contains("680.0"),
		"%s 累计里程现取 680.0 m（实测 %s）" % [tag, total])
	var badge: String = _ui.badge_text()
	_check(badge == "徽章 2 / 3",
		"%s 徽章完成度 2 / 3（实测 %s）" % [tag, badge])
	var scrolls: Array = _ui.find_children("*", "ScrollContainer", true, false)
	_check(scrolls.size() == 1, "%s 恰好 1 个 ScrollContainer（禁止嵌套）" % tag)
	var buttons: Array = _ui.find_children("*", "Button", true, false)
	var hot_ok: bool = true
	for node: Variant in buttons:
		if node is Button:
			if (node as Button).get_global_rect().size.y < 44.0:
				hot_ok = false
	_check(hot_ok, "%s 全部 Button 热区高 ≥44px（共 %d 个）" % [tag, buttons.size()])
	var at_top: bool = false
	if scrolls.size() == 1:
		at_top = (scrolls[0] as ScrollContainer).scroll_vertical <= 1.0
	_check(at_top, "%s 默认态从顶部开始（scroll_vertical ≤1，标题不被裁）" % tag)
	var vp: Rect2 = get_viewport().get_visible_rect()
	var inside: bool = false
	if _panel_ctrl != null:
		inside = _rect_inside(_panel_ctrl.get_global_rect(), vp)
	_check(inside, "%s panel 四边落在视口内" % tag)


# ────────────────────────── 比例 / 滚动 / 截图工具 ──────────────────────────

func _set_ratio(size: Vector2i, tag: String, window_text: String) -> void:
	# --resolution 在 canvas_items + aspect=expand 下无效，必须改窗口尺寸。
	get_window().size = size
	await get_tree().process_frame
	await get_tree().process_frame
	await _settle(6)
	var vp: Vector2 = get_viewport().get_visible_rect().size
	print("SHOT_RATIO %s window=%s viewport=%s" % [tag, window_text, vp])
	_check(get_window().size == size, "%s 窗口尺寸 %s 已生效" % [tag, window_text])
	# expand 语义：逻辑视口高恒 720、宽按窗口宽高比扩展（20:9 → 1600×720）；
	# 物理 PNG 像素仍等于窗口尺寸（1280×576）。
	var aspect: float = float(size.x) / float(size.y)
	var vp_ok: bool = absf(vp.y - 720.0) < 1.0 and absf(vp.x / vp.y - aspect) < 0.01
	_check(vp_ok, "%s 逻辑视口高恒 720 且宽高比 %.4f 与窗口一致（实测 %s）" % [tag, aspect, vp])


func _scroll_top() -> void:
	var scrolls: Array = _ui.find_children("*", "ScrollContainer", true, false)
	if scrolls.size() != 1:
		return
	var sc: ScrollContainer = scrolls[0] as ScrollContainer
	sc.scroll_vertical = 0.0
	await get_tree().process_frame
	await _settle(3)


func _settle(frames: int) -> void:
	for i: int in range(frames):
		await RenderingServer.frame_post_draw


## 坑 #20：get_image() 之后、save_png() 之前，当场把「证据图与状态」绑在同一时刻。
func _capture(file_name: String, label: String, anchor: Control) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var win: Vector2i = get_window().size
	_check(img.get_width() == win.x and img.get_height() == win.y,
		"%s 证据图尺寸 %dx%d == 窗口 %dx%d" % [label, img.get_width(), img.get_height(), win.x, win.y])
	var variety: int = _pixel_variety(img)
	_check(variety >= 8, "%s 画面有内容（采样色数 %d）" % [label, variety])
	_check(bool(_ui.is_open()), "%s 截图时刻航海记录仍 visible" % label)
	var vp: Rect2 = get_viewport().get_visible_rect()
	var inside: bool = false
	if anchor != null:
		inside = _rect_inside(anchor.get_global_rect(), vp)
	_check(inside, "%s 截图时刻 panel 仍在视口内" % label)
	var dir: String = ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var path: String = dir.path_join(file_name)
	img.save_png(path)
	_check(FileAccess.file_exists(path), "%s PNG 已落盘 %s" % [label, file_name])
	print("SHOT: %s -> %s" % [label, path])


func _rect_inside(r: Rect2, vp: Rect2) -> bool:
	var ok: bool = r.position.x >= vp.position.x - 1.0
	ok = ok and r.position.y >= vp.position.y - 1.0
	ok = ok and r.end.x <= vp.end.x + 1.0
	ok = ok and r.end.y <= vp.end.y + 1.0
	return ok


## 32×32 网格采样不同 rgba32 颜色数：纯色（黑屏/空场景）会得到个位数。
func _pixel_variety(img: Image) -> int:
	var seen: Dictionary = {}
	var w: int = img.get_width()
	var h: int = img.get_height()
	if w <= 0 or h <= 0:
		return 0
	var step_x: int = maxi(w / 32, 1)
	var step_y: int = maxi(h / 32, 1)
	var y: int = 0
	while y < h:
		var x: int = 0
		while x < w:
			seen[img.get_pixel(x, y).to_rgba32()] = true
			x += step_x
		y += step_y
	return seen.size()


func _check(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
