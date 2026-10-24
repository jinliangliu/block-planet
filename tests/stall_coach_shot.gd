extends Node
## 失速改出教案（U-8）窗口取证（D-069 目检缺图补证）+ U-9 一次性提示取证。
##
## UI/UX 专家目检结论：U-8 只取到①（接近失速黄闪）与②两张图，缺「① 完全
## 失速红闪 / ③ 等速度恢复 / 改出成功」三张；U-9 因判据被起飞教练占用
## （coach_busy）零视觉证据。本探针一次跑齐六张：
##   stall_1_warning.png  ① 黄闪「要失速了！轻点【↓】低头」（仅接近失速）
##   stall_1_full.png     ① 红闪「失速了！按【↓】低头」（完全失速）
##   stall_2_power.png    ② 「油门推满！按【W】」+ 10 格油门条
##   stall_3_speed.png    ③ 「保持低头，等速度恢复」+ 20 格速度条
##   stall_4_success.png  「改出成功！」+ 副句
##   flight_hud_lookdown.png  U-9「低头可以看 3D 仪表台」Toast（前导段教练区
##                          收起后的自然触发点——六个 gate 首次全部打开）
##
## 控制序列与 stall_coach_probe C 段逐字同源（该序列在无头档验证过全流程
## 可达）：关风（最大随机源）、怠速 + 0.45 中度拉杆 + 仰角 45° 上限保护逼出
## 教科书式减速失速、−0.3 缓改出、逐进程帧采样。差异只在截图与肉眼判据。
## 关键经验：③ 的可见时长取决于余量从 0 爬到 10 km/h 的快慢——窗口截图
## （检测→保存 ≈2 进程帧 + frame_post_draw）必须让③活得比这更久，否则
## 证据图与断言脱钩（断言绿、图里已是成功页）。做法是② 拍完后进「③ 保活
## 段」：改平 + 油门 P 控制把余量钳在 +5 km/h，拍完③ 再主动俯冲冲过 10。
##
## 前导段不做真实滑跑起飞（takeoff_coach_shot 已覆盖）：点火 + 高空刷入 +
## 满油门爬升，起飞教练见「已点火 + 空中 + AGL>TAKOFF_ALT」直接走成功保持，
## 3.5 s 后教练区收起——U-9 的 coach_busy 判据此刻放行，提示自然触发。
##
## 需窗口运行，勿加 --headless。
## 运行：Godot_v4.6.3-stable_win64_console.exe --path . res://tests/stall_coach_shot.tscn

const PROBE_PAD := preload("res://tests/probe_pad.gd")
const SHOT_DIR := "res://tmp"
## 诱发失速前的目标离地高度（m）：留足深失速保持 + 改出俯冲的高度余量。
const CRUISE_AGL := 70.0
## 单阶段等待上限（秒），超时即失败，避免探针卡死。
const PHASE_TIMEOUT := 30.0
## 深失速保持时长（物理帧）：红闪①截图后再保持一小段，让红闪状态稳一下
## 给截图（不宜长——保持越久机体沉得越低、速度掉得越深，改出剖面越难控；
## run4~run7 反复教训：③ 的生死全看改出摆态期间速度有没有冲过带宽）。
const DEEP_STALL_HOLD := 30
## 转瞬态截图专用时间缩放（见 `_snap` 的 `slow` 参数）：进程帧数不变，模拟
## 时间走 1/6.7，把「③ 在截图完成前翻进成功页」这条竞态压到可忽略。
const SNAPSHOT_TIME_SCALE := 0.15
## 诱发段仰角目标（度）：**浅姿态失速**（run4/run5/run6/run7 教训）。45°
## 上限下失速点在 ≈57° 仰角，改出要摆 60° 姿态——摆态期间飞机弹道下坠
## 100+ m、速度从 6.7 m/s 冲到 17 m/s，余量在③ 出生前就越过 10 km/h 门槛
## （②→③→成功同一帧走完，窗口截图追不上；无头探针逐进程帧 latch 能抓到，
## 窗口不行）。浅目标让失速发生在爬升顶点的浅姿态（经典动力失速），
## −3° 俯角门只差十几度，摆态期间速度始终贴在失速线附近，③ 才有带内
## 停留可拍。
const INDUCE_PITCH_CAP := 12.0

var _craft: Aircraft = null
var _player: Player = null
var _hud: HUD = null
var _fails := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("PASS: ", msg)
	else:
		_fails += 1
		print("FAIL: ", msg)


func _shot_path(file_name: String) -> String:
	var dir := ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(file_name)


func _wait(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


func _wait_physics(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


func _snap(file_name: String, slow: bool = false) -> void:
	# `slow`：③→成功是**余量越限即翻转**（`stall_coach.gd` R4，不是计时器），
	# 而本函数内部要过 2 个进程帧 + `frame_post_draw`。进程帧的**墙钟**长度
	# 随机器负载浮动——full 回归（前面已跑 40+ 探针）实测比单独跑慢近一倍，
	# ③ 在截图完成前就翻成了成功页：断言 `shot3` 仍绿（检测那一刻文本确实
	# 是③），**证据图与断言脱钩**。把 `Engine.time_scale` 压到 0.15 再拍：
	# 进程帧数不变（图一定拿得到），但模拟时间只走 1/6.7，余量增速同步降到
	# 1/6.7，截图窗口内的状态漂移可忽略。渲染不受 time_scale 影响，图内容与
	# 常速一致；探针退出前在收尾段复位（见文件末）。
	if slow:
		Engine.time_scale = SNAPSHOT_TIME_SCALE
	await _wait(2)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot_path(file_name))
	Engine.time_scale = 1.0
	# 机体可能已被坠机回收（残骸 4 s 自消散）：对已释放对象发消息会抛
	# SCRIPT ERROR 杀掉协程，restore/quit 都跑不到——进程挂到超时 rc=124，
	# 而回归脚本只看 PASS/FAIL 汇总，会把这当成「探针本身坏了」。
	if not is_instance_valid(_craft):
		_fails += 1
		print("FAIL: 截图时机体已释放（", file_name, " 之前已坠机）")
		return
	var s := _craft.snapshot()
	print("DBG ", file_name, " engine=", s["engine"],
		" throttle=%.2f" % float(s["throttle"]),
		" kmh=%.1f" % float(s["kmh"]), " vs=%.1f m/s" % float(s["stall_speed"]),
		" on_ground=", s["on_ground"], " agl=%.1f" % float(s["altitude_agl"]),
		" pitch=%.1f" % float(s["pitch_deg"]),
		" stalled=", s["stalled"], " warn=", s["stall_warning"],
		" coach=", _hud._coach_main.text)


## 写入杆量：机体已释放时静默跳过（见 _snap 注释）。
func _set_pitch(value: float) -> void:
	if is_instance_valid(_craft):
		_craft.controls.pitch = value


func _agl() -> float:
	if not is_instance_valid(_craft):
		return -1.0
	return float(_craft.snapshot()["altitude_agl"])


## 失速态合并口径（与 stall_coach_probe 同款）：stalled / stall_warning 都带
## speed > 3.0 门且随 alpha 摆动，深失速后瞬时读数会翻回 false——「出现过」
## 而不是「此刻是」。
func _stalling() -> bool:
	if not is_instance_valid(_craft):
		return false
	var s := _craft.snapshot()
	return bool(s["stalled"]) or bool(s["stall_warning"])


func _ready() -> void:
	await _run()


func _run() -> void:
	# 存档隔离（D-010 铁律 3）：快照须在实例化 main.tscn 之前。
	SaveGuard.snapshot()
	# U-9 可复现性：清掉可能已存在的教学进度（本机若已看过提示，hint_for
	# 直接返回空，取证段全部作废）。SaveGuard.restore() 会把原样写回——
	# 最坏后果（探针中途死掉没还原）只是提示复发一次，flight_teaching.gd
	# 头注释已论证无害。
	var teach_path := ProjectSettings.globalize_path(FlightTeaching.SAVE_PATH)
	if FileAccess.file_exists(teach_path):
		DirAccess.remove_absolute(teach_path)
	# 探针可复现性（对齐 stall_coach_probe）：钉死标准难度 + 关风——风是
	# 最大的随机源，开着它两次复跑的失速时序会漂移。只改内存态，不落盘。
	var profile := FlightSettings.for_difficulty(FlightSettings.Difficulty.NORMAL)
	profile.wind_enabled = false
	FlightSettings.set_current(profile)
	GameState.needs_region_pick = false
	GameState.current_region = RegionAtlas.ASIA

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	await _wait(120)

	_hud = main_scene.get_node("UI")
	if _hud._map_selector != null and _hud._map_selector.is_open():
		_hud.close_map_selector()
	# 停刷怪：生物撞机会扰动失速时序（对齐 flight_hud_shot）。
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	await _wait(20)

	_player = main_scene.get_node("Player")
	var world: World = main_scene.get_node("World")
	# 场地：出生点周围铺平整平台并给出安全落位点（落位为什么要偏开玩家、
	# 平台高度为什么要实心面扫描，见 tests/probe_pad.gd 的类注释）。
	var pad := PROBE_PAD.prepare(world, _player)
	await _wait_physics(12)
	# 显式标类型：字典取值是 Variant，直接传参触发 UNSAFE_CALL_ARGUMENT
	# （本项目 GDScript 警告即错误）。
	var spawn_pos: Vector3 = pad["spawn"]
	_craft = Aircraft.spawn(main_scene, spawn_pos, PI)
	await _wait_physics(2)

	# 先登机 + 远程驾驶：飞机在**未驾驶**时物理积分不跑，先等落地会永远悬空。
	_player.ride_aircraft(_craft)
	_craft.drive_remotely()
	for i in range(300):
		await get_tree().physics_frame
		if not is_instance_valid(_craft):
			break
		if _craft.is_on_floor() and _craft.velocity.length() < 0.5:
			break
	await _wait_physics(6)
	if not is_instance_valid(_craft):
		_check(false, "就位阶段机体解体并被回收（落位点压到玩家/地形）")
		SaveGuard.restore()
		print("STALL_SHOT_DONE fails=%d" % _fails)
		get_tree().quit(1)
		return
	_check(not _craft.is_wrecked(), "就位后机体完好（未被地形顶穿解体）")

	# ── 空中前导：点火 + 高空刷入 + 满油门爬升 + 等 U-9 自然触发 ──
	# 不做真实滑跑起飞（takeoff_coach_shot 已覆盖）：直接点火、抬到净空再给
	# 巡航速度。**必须带油门爬升**（flight_hud_shot 同款配方）：怠速刷入后
	# 30 m/s 速度爬不了几秒就耗进失速线，实测只爬到 40 m 且诱发段坠机。
	# 起飞教练见「已点火 + 空中 + AGL>TAKOFF_ALT」会走「🎉 起飞成功」
	# 3.5 s 保持后自动收起——教练区空了，U-9 的 coach_busy 判据才放行。
	_craft.set_engine(true)
	_craft.controls.throttle = 1.0
	_craft.controls.pitch = 0.0
	_craft.global_position.y += 40.0
	_craft.launch(30.0)
	await _wait_physics(4)
	# 爬升 + 等 U-9 在**同一个循环**里做：爬到目标高度带后转比例改平，并盯
	# FlightTeaching 的 pending 窗口。判据是 **has_pending() 而不是 Toast
	# 文本**——Toast 播完后文本残留（只有 modulate.a 淡出到 0），判文本会
	# 抓到已播完的陈旧态（run3 两条假 FAIL 的根因：pending 已确认、is_seen
	# 已真，截图里 Toast 早已淡出）。
	var phase_ms := Time.get_ticks_msec()
	var phase_frames := 0
	var climbed := false
	var pending_seen := false
	while Time.get_ticks_msec() - phase_ms < 30000 and phase_frames < 3000:
		var agl := _agl()
		if agl < 0.0:
			break
		if not climbed:
			_craft.controls.pitch = clampf((CRUISE_AGL - 5.0 - agl) * 0.06, -0.2, 0.45)
			if agl >= CRUISE_AGL - 5.0:
				climbed = true
		else:
			# 改平后弱比例保持（只为取证时姿态好看，不追求长时平飞）。
			_craft.controls.pitch = clampf((CRUISE_AGL - agl) * 0.04, -0.2, 0.3)
		if _hud._flight_teaching != null and _hud._flight_teaching.has_pending():
			pending_seen = true
			break
		await get_tree().physics_frame
		phase_frames += 1
		if not is_instance_valid(_craft) or _craft.is_wrecked():
			break
	if not is_instance_valid(_craft) or _craft.is_wrecked():
		_check(false, "空中前导阶段机体解体（后续断言全部作废）")
		SaveGuard.restore()
		print("STALL_SHOT_DONE fails=%d" % _fails)
		get_tree().quit(1)
		return
	_check(_agl() >= CRUISE_AGL * 0.7,
		"前导爬升到目标高度带（%.1f m ≥ %.1f m）" % [_agl(), CRUISE_AGL * 0.7])
	_check(pending_seen,
		"U-9 教练区收起后座舱视角弹出「低头可以看 3D 仪表台」（pending 窗口内捕获）")
	if pending_seen:
		_check(not _hud._coach_main.is_visible_in_tree(),
			"起飞教练成功保持过期后教练区收起（U-9 coach_busy 判据放行）")
		var ft := _hud._flight_teaching
		_check(ft != null and ft.has_pending(),
			"F-13 投递后处于待确认状态（pending，未落盘）")
		_check(ft != null and not ft.is_seen(FlightTeaching.HINT_LOOKDOWN),
			"F-13 Toast 未播完前不算看过（is_seen = false）")
		# 几何取证：Toast 必须整块落在 dash 顶沿上方（D-053 放大仪表簇后，
		# 旧固定锚点落回 2D 仪表台盘排内部、被后置兄弟 _instrument_hud
		# 糊住；D-069 改按 metrics 的 dash 顶沿取相对位）。
		var vp := get_viewport().get_visible_rect().size
		var dash_top: float = (CockpitInstruments.metrics(vp)["dash"] as Rect2).position.y
		var tr: Rect2 = _hud._toast_label.get_global_rect()
		print("DBG toast rect=", tr, " dash_top=%.1f vp=%s" % [dash_top, vp])
		_check(tr.position.y >= 0.0 and tr.end.y <= dash_top,
			"Toast 整块在 dash 顶沿上方且未出屏（toast y %.0f…%.0f ≤ dash 顶 %.0f）"
				% [tr.position.y, tr.end.y, dash_top])
		await _snap("flight_hud_lookdown.png")
		# 等 Toast 完整播完（2.2 s 保持 + 0.6 s 淡出 = 2.8 s）→ tween
		# finished 回调 confirm_shown → mark_seen 落盘（墙钟计时）。
		await get_tree().create_timer(3.4).timeout
		_check(ft != null and ft.is_seen(FlightTeaching.HINT_LOOKDOWN),
			"F-13 Toast 播完后确认看过（confirm_shown → mark_seen）")
		_check(FileAccess.file_exists(FlightTeaching.SAVE_PATH),
			"F-13 确认后落盘 user://flight_teaching.json")

	# ── 失速诱发：怠速 + 比例姿态保持 ────────────────────────
	# 拉杆量与 stall_coach_probe C 段同源（0.45 中度拉杆，满杆会把机体带成
	# 89° 垂直爬升、舵面没有权限，改出拉不回来），但姿态控制用**比例保持**
	# 而不是 bang-bang：bang-bang 的「超上限就松到 0.15」停不住旋转动量，
	# run7 实测机体仍凭惯性冲到 44° 仰角，改出摆态 47°、速度冲过带宽，
	# ③ 出生即死。比例控制把姿态稳在目标附近，失速才发生在浅姿态。
	var saw_warn := false
	var saw_stalled := false
	var elapsed := 0.0
	_craft.controls.throttle = 0.0
	while elapsed < PHASE_TIMEOUT:
		var pd := float(_craft.snapshot()["pitch_deg"])
		_set_pitch(clampf((INDUCE_PITCH_CAP - pd) * 0.12, -0.25, 0.45))
		await get_tree().physics_frame
		elapsed += get_physics_process_delta_time()
		if not is_instance_valid(_craft) or _craft.is_wrecked():
			break
		var txt := String(_hud._coach_main.text)
		if not saw_warn and txt.contains("要失速了"):
			saw_warn = true
			_check(_hud._coach_main.visible, "接近失速：教练区显示第①步黄闪文案")
			await _snap("stall_1_warning.png")
			print("DBG 黄闪①已截图 t=%.1f" % elapsed)
		if _stalling() and float(_craft.snapshot()["stalled"]):
			saw_stalled = true
			break
	if not is_instance_valid(_craft) or _craft.is_wrecked():
		_check(false, "失速诱发阶段机体解体（教案断言全部作废）")
		SaveGuard.restore()
		print("STALL_SHOT_DONE fails=%d" % _fails)
		get_tree().quit(1)
		return
	_check(saw_warn, "诱发段出现过接近失速黄闪文案（① 的两种语气之一）")

	# ── 深失速保持 + 红闪①截图 ──────────────────────────────
	# 红闪变体要等 alpha 越过 STALL_ALPHA（0.32 rad）——能量继续耗尽时自然
	# 到来。保持段同时让速度衰减到贴近失速线：否则改出时余量一口气越过
	# 10 km/h 门槛，第③步只存在 1 帧，截图追不上。
	for i in range(DEEP_STALL_HOLD):
		var hpd := float(_craft.snapshot()["pitch_deg"])
		_set_pitch(clampf((INDUCE_PITCH_CAP - hpd) * 0.12, -0.25, 0.45))
		await get_tree().physics_frame
		if not is_instance_valid(_craft) or _craft.is_wrecked():
			break
	if not is_instance_valid(_craft) or _craft.is_wrecked():
		_check(false, "深失速保持段机体解体（教案断言全部作废）")
		SaveGuard.restore()
		print("STALL_SHOT_DONE fails=%d" % _fails)
		get_tree().quit(1)
		return
	var full_txt := String(_hud._coach_main.text)
	_check(bool(_craft.snapshot()["stalled"]) and full_txt.contains("！按【↓】"),
		"完全失速：① 自适应为红闪「失速了！按【↓】低头」（「%s」）" % full_txt)
	await _snap("stall_1_full.png")

	# ── 分步改出：①→②→③→成功 ──────────────────────────────
	# **摆态零油门 + 速度剖面脚本化**（run4~run8 教训链）：③ 的生死全看
	# ②→③ 迁移那一刻余量有没有越过 10 km/h。深失速后机体头朝天，改出摆态
	# 期间任何推进都会把速度推过带宽（run7 油门 0.2 摆 5 s ≈ +7 m/s，③ 出生
	# 即死）。配方（run8 实测② 入场余量 +9.0，只差一步）：
	#   ① 摆态段**油门归零**、−0.35 杆快摆——旋转快则下坠少，过 −3° 俯角
	#      门时速度还贴在失速线附近（run8 用 −0.2 慢摆，过门已 15.7 m/s）；
	#   ② 过门后（教练区显示②）给 0.5 油门让进度条有内容，**拍完② 立即收
	#      回 0**——②→③ 的 0.3 s 保持窗口里 Full 油门会把余量推过 10；
	#   ③ 进保活段（PD 改平 + 油门 P 控制）稳定存活，拍完③ 再由恢复行程
	#      （−0.3 杆 + 满油）主动冲过 10 → 成功。
	_craft.controls.throttle = 0.0
	_set_pitch(-0.35)
	var shot2 := false
	var shot3 := false
	var shot_ok := false
	# ③ 保活段（`hold3`）：② 露面后**先放掉俯冲动量、把余量钳住**，让③ 有
	# 足够长的可见窗口。②→③ 迁移只要求 margin ≥ 0 维持 0.3 s，而深失速改出
	# 的摆态会把机体留在大俯冲角——剩余动量在迁移前后继续加速，余量一口气
	# 贴近甚至越过 ③→成功的 10 km/h 门槛（full 回归实测复现：③ 只活 2 帧）。
	# ③ 是单向态（`stall_coach.gd` STEP3_SPEED 只能进 SUCCESS / 回① / 回
	# IDLE，不会退回②），所以这里收油门、改平是安全的。
	var hold3 := false
	var rec_ms := Time.get_ticks_msec()
	var rec_frames := 0
	while Time.get_ticks_msec() - rec_ms < 30000 and rec_frames < 3000:
		var snap := _craft.snapshot()
		var margin_kmh := float(snap["kmh"]) - float(snap["stall_speed"]) * 3.6
		var txt := String(_hud._coach_main.text)
		if hold3:
			# 目标余量 +4 km/h：离 0 有 4 km/h 余量（不会再次失速边沿打回①），
			# 离 10 门槛有 6 km/h 缓冲（③ 不会自己走进成功）。
			#
			# 俯仰必须用 **PD 而不是纯 P**：`controls.pitch` 经
			# `target_pitch = pitch × PITCH_RATE_MAX(1.1)` 映射成**角速度**
			# 目标，而角速度以 RATE_RESPONSE(4.5)/s 的时间常数跟随。摆态段
			# （−0.35 杆）留下的残余 pitch_rate ≈ −0.20 rad/s，纯 P 姿态控制
			# 要 ~1 s 才能把它反转——③ 只活 0.3~0.5 s，等不起（run12/run13
			# 实测：cmd 一直 +0.18 而 pd 仍从 −7.5 滑到 −8.8、vs 从 −4.8 恶化
			# 到 −5.3）。故先按 `−pitch_rate` 抵消残余速率，再叠一个小的姿态
			# 收敛项（目标 −2°，与③「保持低头」措辞一致，也避免大仰角二次失速）。
			var prate := float(snap["pitch_rate"])
			var pd := float(snap["pitch_deg"])
			var rate_cmd := -prate + deg_to_rad((-2.0 - pd) * 1.5)
			_set_pitch(clampf(rate_cmd / 1.1, -0.1, 0.45))
			_craft.controls.throttle = clampf((4.0 - margin_kmh) * 0.06, 0.0, 0.4)
		if not shot2 and txt.contains("油门推满"):
			shot2 = true
			hold3 = true
			# 过门后才给油门：② 的进度条要有内容，但拍完即收（见配方②）。
			_craft.controls.throttle = 0.5
			await _snap("stall_2_power.png", true)
			_craft.controls.throttle = 0.0
			print("DBG ②已截图")
		elif not shot3 and txt.contains("保持低头"):
			shot3 = true
			await _snap("stall_3_speed.png", true)
			hold3 = false
			print("DBG ③已截图")
			# 证据-断言耦合闸：慢放已把截图窗口内的状态漂移压到可忽略，但保留
			# 这条断言作为兜底——一旦将来有人删掉慢放或改了帧序，它会立刻红。
			_check(String(_hud._coach_main.text).contains("保持低头"),
				"③ 截图保存时教练区仍停在③（证据图与断言未脱钩）")
			_set_pitch(-0.3)
			_craft.controls.throttle = 1.0
		elif shot3 and txt.contains("改出成功"):
			shot_ok = true
			await _snap("stall_4_success.png", true)
			print("DBG 成功已截图")
			break
		await get_tree().process_frame
		rec_frames += 1
		if not is_instance_valid(_craft) or _craft.is_wrecked():
			break
	_check(shot2, "改出段第②步入镜（油门推满 + 油门条）")
	_check(shot3, "改出段第③步入镜（等速度恢复 + 速度条）")
	_check(shot_ok, "改出段「改出成功！」入镜")
	if not is_instance_valid(_craft) or _craft.is_wrecked():
		_check(false, "改出段机体解体（U-9 取证作废）")
		SaveGuard.restore()
		print("STALL_SHOT_DONE fails=%d" % _fails)
		get_tree().quit(1)
		return

	# ── 收尾：浅改平 + 等教案成功保持过期 ─────────────────────
	# U-9 取证已在前导段（自然触发点）完成，这里只做优雅收尾：成功态拍照
	# 时飞机还在 −0.3 杆的浅俯冲（跑完 ①→②→③→成功 全流程的固有姿态），
	# 先轻拉杆改平，再等成功保持 2.5 s 过期、教练区收起。**不做长时高度
	# 保持**（run2 实测：12 s 比例保持段高度耗尽坠机——成功态俯冲率
	# ≈9.5 m/s，P 控制器对姿态滞后反应太慢）。
	Engine.time_scale = 1.0  # 慢放只服务于转瞬态截图，收尾恢复正常时序
	_set_pitch(0.15)
	var quiet2 := 0
	var quiet2_ms := Time.get_ticks_msec()
	while Time.get_ticks_msec() - quiet2_ms < 12000 and quiet2 < 40:
		if not _hud._coach_main.is_visible_in_tree():
			quiet2 += 1
		else:
			quiet2 = 0
		await get_tree().process_frame
	_check(not _hud._coach_main.is_visible_in_tree(),
		"失速教案成功保持过期后教练区收起（双教练都静默）")

	SaveGuard.restore()
	print("STALL_SHOT_DONE fails=%d" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)
