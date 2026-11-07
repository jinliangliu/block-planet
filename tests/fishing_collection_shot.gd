extends Node
## 鱼类收集册（D-087）窗口截图探针：16:9 / 20:9 两档比例、态②/态③、滚动到底，
## 共 5 张 PNG 供 full 档验收目检。
##
## D-010（照 fishing_collection_probe.gd）：开局 SaveGuard.snapshot() + 单独快照
## 开局 JOURNAL_PATH 原文本；收尾按**开局路径**逐字节还原、置 journal_ok=false
## 拒写闸、SaveGuard.restore()。_exit_tree 与看门狗共用同一份 _restore()。
## 「只改内存」≠「无需存档隔离」：FishingSystem._exit_tree 无条件调 _save_journal()，
## 其唯一闸门是 journal_ok；fishing_journal.json 不在 SaveGuard.EXTRA_FILES 内，
## 退出期补写必然造成 D-010 DIFF，故 journal_ok=false 拒写闸一个字都不能省。
## 本探针绝不主动调 FishingSystem.claim_bundle()（会真实写盘）。
##
## 运行：Godot_v4.6.3-stable_win64.exe --path . res://tests/fishing_collection_shot.tscn
## （勿加 --headless；无头下 frame_post_draw 永不触发会挂起）

const SHOT_DIR := "res://tmp"
const CollectionScript := preload("res://scripts/ui/fishing_collection_ui.gd")

var _failed := 0
var _passed := 0
var _restored := false
var _journal_path_at_start := ""
var _journal_text := ""
var _journal_existed := false

## 收集册脚本无 class_name，preload 实例是 Variant（坑 #33）：凡接 _ui.xxx()
## 返回值一律显式类型，绝不用 :=（会触发 Parse Error: Cannot infer the type）。
var _ui = null
var _panel_ctrl: Control = null


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		push_warning("fishing_collection_shot: 看门狗超时，强制退出")
		get_tree().quit(1))
	# 快照必须先于任何早退分支：headless 早退同样触发 _exit_tree → _restore()，
	# 若此时 snapshot 未执行，SaveGuard.restore() 会用空静态态删掉真实存档。
	SaveGuard.snapshot()
	_journal_path_at_start = FishingSystem.JOURNAL_PATH
	if FileAccess.file_exists(_journal_path_at_start):
		_journal_existed = true
		var jf: FileAccess = FileAccess.open(_journal_path_at_start, FileAccess.READ)
		_journal_text = jf.get_as_text()
		jf.close()
	if DisplayServer.get_name() == "headless":
		print("FISHING_COLLECTION_SHOT_SKIP: 需窗口渲染")
		get_tree().quit(0)
		return
	await _run()
	_finish()


func _finish() -> void:
	_restore()
	if _failed == 0:
		print("FISHING_COLLECTION_SHOT_OK passed=%d" % _passed)
	else:
		print("FISHING_COLLECTION_SHOT_FAILED count=%d passed=%d" % [_failed, _passed])
	get_tree().quit(0 if _failed == 0 else 1)


## 幂等收尾（正常路径 / _exit_tree 安全网 / 看门狗三条路共用）。
func _restore() -> void:
	if _restored:
		return
	_restored = true
	if _ui != null and is_instance_valid(_ui):
		_ui.queue_free()
	FishingSystem.JOURNAL_PATH = _journal_path_at_start
	if _journal_existed:
		var jf: FileAccess = FileAccess.open(_journal_path_at_start, FileAccess.WRITE)
		if jf != null:
			jf.store_string(_journal_text)
			jf.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_journal_path_at_start))
	FishingSystem.journal_ok = false
	SaveGuard.restore()


func _exit_tree() -> void:
	_restore()


# ────────────────────────── 内存态构造（只改内存、不主动调写盘 API、不发信号）──────────────────────────

func _reset_journal() -> void:
	FishingSystem.journal = {
		"version": 1, "records": {}, "gear": [], "lessons_seen": [],
		"replay": [], "stats": {},
	}


func _inject(fish_id: String, spot_id: String) -> void:
	var records: Dictionary = FishingSystem.journal["records"]
	records[fish_id] = {
		"catch_count": 1, "max_weight_kg": 0.42,
		"first_caught_spot": spot_id, "first_caught_at": "2026-01-01 00:00:00",
	}
	FishingSystem.journal["records"] = records


func _inject_region(region_id: String) -> void:
	var ids: Array[String] = FishingSystem.bundle_ids(region_id)
	for id: String in ids:
		_inject(id, "pacific_coast")


## 态②：部分解锁（pacific 集齐可领，其余 3 海域 + all 未集齐）。
func _state_partial() -> void:
	_reset_journal()
	_inject_region("pacific_ocean")
	_ui.open()
	await get_tree().process_frame
	await _settle(3)


## 态③：全 4 海域集齐 + all 已领取（直接改 stats 内存标记，绝不调 claim_bundle）。
func _state_full() -> void:
	_reset_journal()
	for region_id: String in FishingSystem.BUNDLE_REGIONS:
		_inject_region(region_id)
	var stats: Dictionary = FishingSystem.journal["stats"]
	stats["bundle_all"] = 1
	FishingSystem.journal["stats"] = stats
	_ui.refresh()
	await get_tree().process_frame
	await _settle(3)


# ────────────────────────── 主流程 ──────────────────────────

func _run() -> void:
	# add_child 前先让 Autoload 完成首帧暖机（照 race_result_probe.gd:27-28）。
	await get_tree().process_frame
	await _setup_ui()
	_check(_panel_ctrl != null, "① 收集册 UI 已实例化且 panel 已构建")
	await _state_partial()

	# ── 16:9 ──
	await _set_ratio(Vector2i(1280, 720), "16:9", "1280x720")
	_check_common("16:9")
	_check_state_partial("16:9")
	await _capture("fishing_collection_16x9.png", "① 16:9 态② 默认", _panel_ctrl)

	await _scroll_bottom()
	await _capture("fishing_collection_16x9_bottom.png", "② 16:9 态② 滚到底", _panel_ctrl)

	await _scroll_top()
	await _state_full()
	_check_state_full("16:9")
	await _capture("fishing_collection_16x9_all.png", "③ 16:9 态③ 全收集+已领取", _panel_ctrl)

	# ── 20:9 ──
	await _set_ratio(Vector2i(1280, 576), "20:9", "1280x576")
	await _state_partial()
	await _scroll_top()
	_check_common("20:9")
	_check_state_partial("20:9")
	await _capture("fishing_collection_20x9.png", "④ 20:9 态② 默认", _panel_ctrl)

	await _scroll_bottom()
	await _capture("fishing_collection_20x9_bottom.png", "⑤ 20:9 态② 滚到底", _panel_ctrl)


func _setup_ui() -> void:
	_ui = CollectionScript.new()
	add_child(_ui)
	await get_tree().process_frame
	var panels: Array = _ui.find_children("*", "PanelContainer", true, false)
	if panels.size() >= 1:
		_panel_ctrl = panels[0] as PanelContainer


# ────────────────────────── 断言组 ──────────────────────────

## 每档比例都要断言的结构项（两档各调一次）。
func _check_common(tag: String) -> void:
	_check(bool(_ui.is_open()), "%s 收集册 is_open()==true" % tag)
	var n: int = _ui.cell_count()
	_check(n == 20, "%s 20 个格子（实测 %d）" % [tag, n])
	var scrolls: Array = _ui.find_children("*", "ScrollContainer", true, false)
	_check(scrolls.size() == 1, "%s 恰好 1 个 ScrollContainer（禁止嵌套）" % tag)
	var buttons: Array = _ui.find_children("*", "Button", true, false)
	var hot_ok: bool = true
	for node: Variant in buttons:
		if node is Button:
			if (node as Button).get_global_rect().size.y < 44.0:
				hot_ok = false
	_check(hot_ok, "%s 全部 Button 热区高 ≥44px（共 %d 个）" % [tag, buttons.size()])
	var vp: Rect2 = get_viewport().get_visible_rect()
	var inside: bool = false
	var geom: String = "panel 缺失"
	if _panel_ctrl != null:
		var r: Rect2 = _panel_ctrl.get_global_rect()
		inside = _rect_inside(r, vp)
		geom = "panel=%s vp=%s" % [r, vp]
	_check(inside, "%s panel 四边落在视口内（%s）" % [tag, geom])


func _check_state_partial(tag: String) -> void:
	var badge: String = _ui.badge_text()
	_check(badge == "5 / 20", "%s 态② 徽标 5 / 20（实测 %s）" % [tag, badge])
	var st_pac: Dictionary = _ui.claim_state("pacific_ocean")
	var pac_text: String = String(st_pac.get("text", ""))
	var pac_disabled: bool = bool(st_pac.get("disabled", true))
	_check(pac_text == "◆ 领取奖励" and not pac_disabled,
		"%s 态② pacific 按钮「◆ 领取奖励」且可点" % tag)
	var st_atl: Dictionary = _ui.claim_state("atlantic_ocean")
	_check(String(st_atl.get("text", "")) == "还差 5 种，慢慢来",
		"%s 态② atlantic 按钮「还差 5 种，慢慢来」" % tag)
	var st_all: Dictionary = _ui.claim_state("all")
	_check(String(st_all.get("text", "")) == "还差 3 个海域，慢慢来",
		"%s 态② all 按钮「还差 3 个海域，慢慢来」" % tag)


func _check_state_full(tag: String) -> void:
	var badge: String = _ui.badge_text()
	_check(badge == "20 / 20", "%s 态③ 徽标 20 / 20（实测 %s）" % [tag, badge])
	var st_all: Dictionary = _ui.claim_state("all")
	_check(String(st_all.get("text", "")) == "已领取 ✓" and bool(st_all.get("disabled", false)),
		"%s 态③ all 按钮「已领取 ✓」且 disabled" % tag)


# ────────────────────────── 比例 / 滚动 / 截图工具 ──────────────────────────

func _set_ratio(size: Vector2i, tag: String, window_text: String) -> void:
	get_window().size = size
	await get_tree().process_frame
	await get_tree().process_frame
	await _settle(6)
	var vp: Vector2 = get_viewport().get_visible_rect().size
	print("SHOT_RATIO %s window=%s viewport=%s" % [tag, window_text, vp])
	_check(get_window().size == size, "%s 窗口尺寸 %s 已生效" % [tag, window_text])
	# project.godot: viewport 1280x720 + stretch/mode=canvas_items + aspect=expand。
	# expand 的语义是「逻辑视口高恒为 720、宽按窗口宽高比扩展」：16:9 -> 1280x720，
	# 20:9 窗口 1280x576 -> 逻辑 1600x720；物理 PNG 像素仍等于窗口尺寸（1280x576）。
	# 原断言写死「逻辑视口宽 1280」在 20:9 下必然 FAIL，是规格错误而非生产缺陷。
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


func _scroll_bottom() -> void:
	var scrolls: Array = _ui.find_children("*", "ScrollContainer", true, false)
	if scrolls.size() != 1:
		return
	await get_tree().process_frame
	var sc: ScrollContainer = scrolls[0] as ScrollContainer
	sc.scroll_vertical = sc.get_v_scroll_bar().max_value
	await get_tree().process_frame
	await _settle(3)


func _settle(frames: int) -> void:
	for i: int in range(frames):
		await RenderingServer.frame_post_draw


## 坑 #20：get_image() 之后、save_png() 之前，当场把「证据图与状态」绑在同一时刻。
func _capture(file_name: String, label: String, anchor: Control) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	# 坑 #20 耦合断言：把「证据图」与「比例」绑在同一时刻。
	# 渲染缓冲是窗口物理像素（canvas_items 只缩放 2D 坐标），故 20:9 档必须是 1280x576。
	var win: Vector2i = get_window().size
	_check(img.get_width() == win.x and img.get_height() == win.y,
		"%s 证据图尺寸 %dx%d == 窗口 %dx%d" % [label, img.get_width(), img.get_height(), win.x, win.y])
	var variety: int = _pixel_variety(img)
	_check(variety >= 8, "%s 画面有内容（采样色数 %d）" % [label, variety])
	_check(bool(_ui.is_open()), "%s 截图时刻收集册仍 visible（is_open）" % label)
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
