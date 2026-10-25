class_name TerrainWarning
extends RefCounted
## 地形前视预警（D-072 P2b，GPWS 式）：沿当前航迹线性外推，预测前方余量，
## 在「还有得救」的时候喊「前方有山」——装山事故的根因是引导层缺陷（P1 已修）
## 与近场山体压迫（P2a 已限高），本条是最后一道保险：山不会永远让路，
## 孩子直线飞向渐变带外的山脊时，仪表必须比山先说话。
##
## 纯逻辑、不持有节点：高度场经 Callable 采样器注入 `(wx: int, wz: int) -> int`，
## 探针可喂合成高度场做构造式断言；真实世界由 hud.gd 登机时注入
## `World.get_surface_height`（经 player.world() 惰性解析，换区后仍指向当前世界）。
##
## 判据（decisions.md D-072 P2b②，实现期修正过一次，见下）：
##   · 沿 snapshot 速度矢量（地速航迹）外推 LOOKAHEAD_S 秒、每 SAMPLE_STEP 米
##     采一点——单点采样会漏两档之间的山脊（实测谷地外 44 m 墙距平地仅 8 m）；
##   · `min_ahead` = 预测航迹上的最小余量（点高 − 地表）；
##   · `rise` = 前方最高地表 − 脚下地表（**同一采样器**，源头一致无交叉噪声——
##     AGL 射线打低模网格、get_surface_height 是精确面，两者相差可达 ±15 m，
##     跨源比较会抖）；
##   · 警告「前方有山！快拉升」：min_ahead < 25（绝对值——窗口内必撞，Intentional
##     低空刺激飞也该被拦一下，安全优先于安静）；
##   · 注意「前方有山，准备拉升」：min_ahead < 40 **且** rise > 20。
##     rise 条件是「ALT 过低警告刻意要求下沉率」的同款教训：没有它，40 m 巡航
##     （FD 封顶 100 m − 谷地粗模 45 m = 55 m 余量）会全程黄牌——警报疲劳比
##     没警报更糟。rise 把「山在迎面上来」与「只是在低空飞」区分开；
##   · 清除带 +20 m 滞环（25→45 / 40→60），防边界抖闪，同低油警告范式。
##
## 三门控（命中即整体置 0，不冻结——门控结束后按新鲜读数重算，不吐陈旧警告）：
##   1. 未离地（AGL ≤ AIRBORNE_AGL）不报——滑跑正前方永远有「山」（跑道尽头
##      的坡），报了孩子只会学会忽略警报；
##   2. 失速中让位——StallCoach 是失速唯一权威文字通道，「推杆低头」与「快拉升」
##      实时冲突，同 D-071 范式（含 stall_warning：教案①在接近失速就亮）；
##   3. 着陆下降段屏蔽（AGL < LANDING_AGL 且下沉）——否则每次正常进近全程误报。

## 外推时长（秒）：10 s 是「看到 → 反应 → 拉起」的儿童向预算（拉升率 ≈6 m/s，
## 10 s ≈ 60 m 爬升，盖住注意档 40 m 余量）。
const LOOKAHEAD_S := 10.0
## 航迹采样间隔（米）：50 m 兼顾成本（≤11 次/帧，get_surface_height 是纯数学）
## 与覆盖度（真实山脊宽度都 ≥ 数十米；窄于 50 m 且正好落在两采样点之间的
## 锐脊是已记录的设计限制）。
const SAMPLE_STEP := 50.0
## 警告余量门限（米）：预测航迹最近点低于它 → 红色「快拉升」。
const WARN_MARGIN := 25.0
## 注意余量门限（米）：配合 rise 条件使用，见类注释。
const CAUTION_MARGIN := 40.0
## rise 门限（米）：前方地表比脚下高出超过它，才算「山在迎面而来」。
const RISE_MARGIN := 20.0
## 滞环（米）：清除带 = 门限 + 20。
const HYSTERESIS := 20.0
## 航迹速度下限（m/s）：低于它方向不可信，不预警。
const MIN_TRACK_SPEED := 1.0
## 着陆下降段屏蔽：AGL 低于此值且下沉率低于 LANDING_VS 时整体不报。
const LANDING_AGL := 60.0
const LANDING_VS := -1.5

## 当前级别：0 = 无 / 1 = 注意 / 2 = 警告。update() 维护，探针可直接读。
var level := 0

var _sampler: Callable


## 注入高度场采样器 `(wx: int, wz: int) -> int`（世界坐标）。传空 Callable
## 或之后置 null 即停报（level 保持到下次 update 置 0）。
func set_sampler(cb: Callable) -> void:
	_sampler = cb


## 清空状态（登机/下机时与 reset_voice_cues 同步调）。
func reset() -> void:
	level = 0


## 每帧调。reading 为 Aircraft.snapshot()（探针可手搓同名字典）。
## 用到的键：position / velocity / altitude_agl / vertical_speed /
## stalled / stall_warning。缺键按安全默认处理（不报）。
func update(reading: Dictionary) -> void:
	# ── 门控 1：未离地不报（滑跑） ──
	var agl := float(reading.get("altitude_agl", 0.0))
	if agl <= FlightInstruments.AIRBORNE_AGL:
		level = 0
		return
	# ── 门控 2：失速中让位 StallCoach（含接近失速——教案①在 warning 就亮） ──
	if bool(reading.get("stalled", false)) or bool(reading.get("stall_warning", false)):
		level = 0
		return
	# ── 门控 3：着陆下降段屏蔽（AGL<60 且明确下沉） ──
	if agl < LANDING_AGL and float(reading.get("vertical_speed", 0.0)) < LANDING_VS:
		level = 0
		return
	# ── 航迹不可信 / 无采样器：不报 ──
	var vel: Vector3 = reading.get("velocity", Vector3.ZERO)
	var speed := vel.length()
	if speed < MIN_TRACK_SPEED or not _sampler.is_valid():
		level = 0
		return
	var pos: Vector3 = reading.get("position", Vector3.ZERO)

	var horizon := speed * LOOKAHEAD_S
	var min_ahead := INF
	var max_ground := -INF
	var ground_here := float(_sampler.call(
		int(floorf(pos.x)), int(floorf(pos.z))))
	var d := SAMPLE_STEP
	while d <= horizon:
		var p := pos + vel * (d / speed)
		var g := float(_sampler.call(int(floorf(p.x)), int(floorf(p.z))))
		min_ahead = minf(min_ahead, p.y - g)
		max_ground = maxf(max_ground, g)
		d += SAMPLE_STEP
	var rise := max_ground - ground_here

	# ── 原始级别 + 滞环 ──
	var raw := 0
	if min_ahead < WARN_MARGIN:
		raw = 2
	elif min_ahead < CAUTION_MARGIN and rise > RISE_MARGIN:
		raw = 1
	if raw > level:
		level = raw
	elif raw < level:
		var clear_at: float = (WARN_MARGIN if level == 2 else CAUTION_MARGIN) + HYSTERESIS
		if min_ahead >= clear_at:
			level = raw
