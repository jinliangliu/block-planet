class_name FlightDirector
extends Control
## 飞行指引十字（Flight Director Cross，D-054）——座舱 HUD 上的航径指令标记。
##
## 语义（与真实飞行指引仪一致，儿童向简化）：
##   屏幕中心那个白色细十字是「准星」= 机头现在指向哪（固定不动）。
##   本控件画的粗十字是「指令十字」= 机头**应该**指向哪。玩家操纵飞机让
##   准星套进指令十字，就等于沿着正确的航径在飞（对准跑道、保持 3° 下滑、
##   起飞保持爬升角）。十字相对中心的偏移量 = 当前航径偏差。
##
## 为什么不复用世界 3D 引导（FlightMarkers 的箭头 / 下滑道双轨）：那些只在
## 追尾视角看得见，第一人称座舱里低头看仪表、抬头看外面，中间没有一层
## 「我现在偏了多少」的读数。本控件补的就是这一层——且是纯 2D 屏幕层，
## 不依赖相机 / 不参与 3D 剔除，任何视角（含夜间、雨雾）都稳定可见。
##
## 引导律（偏差角 → 屏幕偏移，固定增益 + 限幅，ILS/FD 的经典做法）：
##   水平 dev_h = 目标方位 − 当前航向（正 = 目标在右 → 十字右移 → 右转）
##   垂直 dev_v = 下滑道高度偏差取反（高于下滑道→负→低头追回 → 十字下移）
##   偏移 px  = dev × GAIN_PX_PER_DEG，限幅 ±MAX_OFF（超量程画外指示箭头）
## 用角度而非「把航径点投影到屏幕」是有意的：后者在远距离时几乎不动、
## 近距离又过于敏感，灵敏度随距离漂移，儿童玩家读不出来。
##
## 模式（mode_for）：
##   OFF      无导航目标 / 空速过低（停在地面）——不显示
##   ROLL     贴地滑跑（AGL<2m）——保持起飞航向，不引导俯仰
##   TAKEOFF  离地爬升（AGL<100m 且升降率>1m/s 且距机场<250m）——保持起飞
##            航向 + 引导 10° 爬升角（D-072：原 8°/60m/200m）
##   APPROACH 进近（水平距离 ≤400m）——直飞目标 + 引导 3° 下滑道
##   CRUISE   巡航（距离 >400m）——只引导航向，俯仰不干预（避免被迫下降）
## ⚠️ TAKEOFF 必须靠「升降率 + 离地高度」判，不能靠距离：起飞时机场就在
##    脚下（距离≈0），只按距离会立刻被判成 APPROACH 并引导下降——起飞瞬间
##    被提示低头是最危险的错引导。
##
## 渲染：屏幕最上层 2D 覆盖层，硬边像素风（draw_rect 拼，不抗锯齿），
## 尺寸按 CockpitInstruments.ui_scale() 随视口等比缩放。

enum Mode { OFF, ROLL, TAKEOFF, APPROACH, CRUISE }

# ── 引导律常量 ──────────────────────────────────────────────────
const GLIDE_DEG := 3.0       # 进近期望下滑角（与 FlightMarkers 的 3° 双轨同源）
## D-072：起飞期望爬升角 8°→10°。机场口袋外 200~500 m 即有 120~150 m 高差
## 山体，8°（35 m/s 时仅 ≈4.9 m/s 垂直）爬不出可用的高度余量；10° ≈6.1 m/s，
## 配 CLIMB_CEIL 100 让孩子默认爬到巡航层再平飞（P2 近场限高后更宽裕）。
const CLIMB_DEG := 10.0
const APPROACH_DIST := 400.0 # 进近段判定距离（m，水平）
const ROLL_AGL := 2.0        # 贴地判定（m，离地高度）
## D-072：起飞爬升段高度上限 60→100 m——覆盖到绕场巡航层（80 m AGL），
## 否则孩子爬到 60 m 就被切进 APPROACH，对着（已修对海拔的）航点被
## 下滑道提前往下带。
const CLIMB_CEIL := 100.0
## D-072：起飞段机场距离上限 200→250 m——绕场矩形近边 90~110 m + 转弯
## 半径，250 m 内保持「锁航向 + 爬升」不抢方向舵。
const TAKEOFF_DIST := 250.0
const MIN_SPEED_KMH := 10.0  # 低于此速视为停机，不显示
const MIN_DIST := 30.0       # 下滑角分母下限（防止贴脸时角度飙到 ±90°）
const DEV_CLAMP := 12.0      # 单轴偏差角钳制（度）
const GAIN_PX_PER_DEG := 11.0  # 偏差 1° → 十字偏移 11 px
const MAX_OFF := 120.0       # 十字偏移限幅（px，s=1 基准）
const CRUISE_FADE_DIST := 800.0  # 巡航段：距目标 > 此值（m）时指引十字淡出，
                                 # 避免「飞离机场后十字长期贴边红」误导儿童（D-054 留项）
const CAPTURE_DEG := 1.5     # 捕获阈值（两轴都小于它 = 已对准，绿色 + 括号）
## 红色阈值。**不能设太小**：起飞段 pitch 从 0 起，8° 爬升指令是常态，阈值
## 6° 会让每次起飞都满屏报警（首版实测）。12° 才是「真的偏了一大截」。
const WARN_DEG := 12.0

# ── 十字几何基准（s=1，即 1280×720）────────────────────────────
const ARM := 34.0        # 臂长（中心到端帽）
const ARM_T := 3.0       # 臂厚
const GAP := 11.0        # 中心留空半径（不挡准星与目标）
const CAP_W := 15.0      # 端帽长
const BRACKET := 46.0    # 捕获角括号距中心
const BRACKET_L := 11.0  # 角括号边长
const ARROW := 15.0      # 超量程外指示箭头尺寸
## 标签固定挂在十字**上方**（负值 = 上移）：十字最多下移 MAX_OFF，若标签
## 在下会顶到仪表板顶沿（s=1 时实测 594 > dash 顶 539，压住航向带）。挂上方
## 后最坏情况 y≈445，永不与底部仪表板相交。
const LABEL_DY := -46.0
const LABEL_W := 140.0   # 标签可用宽（居中对齐用）
## 四象限符号（typed：Array 无类型时迭代出 Variant，会让 `sx * b` 无法推断）。
const SIGNS: Array[float] = [-1.0, 1.0]

# ── 配色（与座舱仪表同源：绿=对准 / 琥珀=偏差 / 红=大量程）──────
const COL_LOCK := Color(0.45, 0.95, 0.55)
const COL_DEV := Color(1.0, 0.72, 0.20)
const COL_FAR := Color(0.95, 0.30, 0.26)
const COL_EDGE := Color(0.0, 0.0, 0.0, 0.55)  # 描边（保证在亮天空上也看得见）

var _target := Vector3.ZERO
var _has_target := false
var _mode := Mode.OFF
var _dev_h := 0.0
var _dist_h := 0.0
var _dev_v := 0.0
var _s := 1.0
var _lock_hdg := 0.0
var _lock_valid := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	resized.connect(_relayout)
	_relayout()


func _relayout() -> void:
	_s = CockpitInstruments.ui_scale(size)
	queue_redraw()


## 设置/清除引导目标（导航点：机场/任务锚点的世界坐标）。
func set_guide(target: Vector3) -> void:
	_target = target
	_has_target = true
	_lock_valid = false
	queue_redraw()


func clear_guide() -> void:
	_has_target = false
	_mode = Mode.OFF
	_lock_valid = false
	queue_redraw()


func current_mode() -> int:
	return _mode


## 当前偏差角（度）：x = 水平（正=目标在右），y = 垂直（正=该抬头）。
func deviation_deg() -> Vector2:
	return Vector2(_dev_h, _dev_v)


## 每帧驱动：由 FlightInstrumentHUD.tick 调用（第一人称座舱）。
## craft_pos 为机体世界坐标，fi 为本帧加工后的仪表读数。
func refresh(craft_pos: Vector3, fi: FlightInstruments) -> void:
	if not _has_target:
		if _mode != Mode.OFF:
			_mode = Mode.OFF
			queue_redraw()
		return
	var to := _target - craft_pos
	var dist_h := Vector2(to.x, to.z).length()
	_dist_h = dist_h
	var m := mode_for(fi.nav_active, fi.altitude_agl, fi.vertical_speed,
		dist_h, fi.airspeed_kmh)
	if m == Mode.OFF:
		_lock_valid = false
		if _mode != Mode.OFF:
			_mode = Mode.OFF
			queue_redraw()
		return
	# 航向：起飞/滑跑段锁定起飞航向（滑跑要保持直线，直飞导航在地面没意义）；
	# 其余段直飞目标（复用 FlightInstruments 已算好的 CDI 偏差，不重复造轮子）。
	if m == Mode.ROLL or m == Mode.TAKEOFF:
		if not _lock_valid:
			_lock_hdg = fi.heading_deg
			_lock_valid = true
		_dev_h = heading_dev_deg(_lock_hdg, fi.heading_deg)
	else:
		_lock_valid = false
		_dev_h = fi.nav_dev_deg
	# 俯仰：滑跑不干预；起飞看爬升角；进近看 3° 下滑道；巡航不干预。
	match m:
		Mode.ROLL, Mode.CRUISE:
			_dev_v = 0.0
		Mode.TAKEOFF:
			_dev_v = clampf(CLIMB_DEG - fi.pitch_deg, -DEV_CLAMP, DEV_CLAMP)
		Mode.APPROACH:
			_dev_v = glide_dev_deg(_target.y, craft_pos.y, dist_h, GLIDE_DEG)
	_mode = m
	queue_redraw()


# ── 纯函数（探针直接断言，不依赖渲染）────────────────────────────

## 模式判定：见文件头的模式表与 TAKEOFF 判据警告。
static func mode_for(nav_active: bool, agl: float, vs: float,
		dist_h: float, kmh: float) -> int:
	if not nav_active or kmh < MIN_SPEED_KMH:
		return Mode.OFF
	if agl < ROLL_AGL:
		return Mode.ROLL
	if vs > 1.0 and agl < CLIMB_CEIL and dist_h < TAKEOFF_DIST:
		return Mode.TAKEOFF
	if dist_h <= APPROACH_DIST:
		return Mode.APPROACH
	return Mode.CRUISE


## 下滑道垂直指令（度）：正 = 该抬头，负 = 该低头。
## **必须用「相对下滑道平面的高度偏差」，不能用「期望下滑角 − 实际下滑角」**
## ——后者符号是反的：飞机高于下滑道时它算出「抬头」，玩家会越飞越高、
## 永远落不下来（首版实测：高 30m @400m 给出 +4.26° 抬头指令）。
## 正确算法（ILS GS 语义）：该距离处下滑道应有高度 gs_y = target.y +
## d·tan(GLIDE)，偏差 Δh = craft.y − gs_y；Δh>0（高于道）→ 低头追回。
## 分母有下限，避免贴近目标时 atan2 飙到 ±90° 让十字乱跳。
static func glide_dev_deg(target_y: float, craft_y: float,
		dist_h: float, glide_deg: float = GLIDE_DEG) -> float:
	var d := maxf(dist_h, MIN_DIST)
	var gs_y := target_y + d * tan(deg_to_rad(glide_deg))
	return clampf(-rad_to_deg(atan2(craft_y - gs_y, d)), -DEV_CLAMP, DEV_CLAMP)


## 航向偏差（度）：正 = 目标/期望航向在右侧。
static func heading_dev_deg(bearing: float, heading: float) -> float:
	return wrapf(bearing - heading, -180.0, 180.0)


## 偏差角 → 屏幕偏移（px，相对屏幕中心）。垂直取负：dev_v 正（该抬头）
## 对应十字上移（屏幕 y 减小）。两轴各自限幅到 ±MAX_OFF×s。
static func cross_offset(dev_h: float, dev_v: float, s: float) -> Vector2:
	var g := GAIN_PX_PER_DEG * s
	var m := MAX_OFF * s
	return Vector2(clampf(dev_h * g, -m, m), clampf(-dev_v * g, -m, m))


## 是否超量程（任一轴被限幅）——超量程时画外指示箭头。
static func is_saturated(dev_h: float, dev_v: float, s: float) -> bool:
	var g := GAIN_PX_PER_DEG * s
	var m := MAX_OFF * s
	return absf(dev_h * g) > m or absf(dev_v * g) > m


static func mode_name(m: int) -> String:
	match m:
		Mode.ROLL:
			return "滑跑"
		Mode.TAKEOFF:
			return "起飞"
		Mode.APPROACH:
			return "进近"
		Mode.CRUISE:
			return "巡航"
	return "—"


# ── 绘制 ────────────────────────────────────────────────────────
func _draw() -> void:
	if _mode == Mode.OFF:
		return
	var s := _s
	var c := size * 0.5
	var p := c + cross_offset(_dev_h, _dev_v, s)
	var col := _color_for()
	# D-090：巡航段且远离目标时指引十字淡出（仅降透明度，不改模式/几何/文案）——
	# 化解「飞离机场后十字长期贴边红」让儿童误以为「一直飞错」（D-054 留项）。
	if _mode == Mode.CRUISE and _dist_h > CRUISE_FADE_DIST:
		var f := clampf(1.0 - (_dist_h - CRUISE_FADE_DIST) / 4000.0, 0.3, 1.0)
		col.a *= f
	var arm := ARM * s
	var t := maxf(2.0, ARM_T * s)
	var gap := GAP * s
	var cap := CAP_W * s
	# 中心留空：四段臂（不画中心，避免挡住准星与目标本身）。
	_bar(Rect2(p.x - t * 0.5, p.y - arm, t, arm - gap), col, s)
	_bar(Rect2(p.x - t * 0.5, p.y + gap, t, arm - gap), col, s)
	_bar(Rect2(p.x - arm, p.y - t * 0.5, arm - gap, t), col, s)
	_bar(Rect2(p.x + gap, p.y - t * 0.5, arm - gap, t), col, s)
	# 端帽（臂末端的垂直短杠，形成「十字 + 端帽」的战雷式指令杆轮廓）。
	_bar(Rect2(p.x - cap * 0.5, p.y - arm - t * 0.5, cap, t), col, s)
	_bar(Rect2(p.x - cap * 0.5, p.y + arm - t * 0.5, cap, t), col, s)
	_bar(Rect2(p.x - arm - t * 0.5, p.y - cap * 0.5, t, cap), col, s)
	_bar(Rect2(p.x + arm - t * 0.5, p.y - cap * 0.5, t, cap), col, s)
	# 捕获：两轴偏差都很小时画四角括号（「套住了」），并让标签改口。
	if absf(_dev_h) < CAPTURE_DEG and absf(_dev_v) < CAPTURE_DEG:
		var b := BRACKET * s
		var bl := BRACKET_L * s
		var bt := maxf(1.5, 2.0 * s)
		for sx in SIGNS:
			for sy in SIGNS:
				var cx: float = p.x + float(sx) * b
				var cy: float = p.y + float(sy) * b
				_bar(Rect2(cx - (bl if sx > 0.0 else 0.0), cy - bt * 0.5, bl, bt), col, s)
				_bar(Rect2(cx - bt * 0.5, cy - (bl if sy > 0.0 else 0.0), bt, bl), col, s)
	# 超量程：十字已顶到边界，在更外侧画同向箭头（提示「继续往这边修」）。
	if is_saturated(_dev_h, _dev_v, s):
		var a := ARROW * s
		var o := cross_offset(_dev_h, _dev_v, s)
		# 箭头必须画在「十字外缘 + 间隙」之外：首版画在 p±a 处，正好落在
		# 端帽与臂之间，整枚箭头被十字自己盖住，等于没画。
		var reach := (ARM + 8.0) * s
		if absf(o.x) >= MAX_OFF * s - 0.5:
			var sgn := signf(_dev_h)
			_arrow(Vector2(p.x + sgn * (reach + a), p.y),
				Vector2(sgn, 0.0), a, col)
		if absf(o.y) >= MAX_OFF * s - 0.5:
			var sgy := signf(-_dev_v)
			_arrow(Vector2(p.x, p.y + sgy * (reach + a)),
				Vector2(0.0, sgy), a, col)
	# 标签：优先「该怎么做」的动作词（左转/右转/掉头/抬头/低头），只在无大
	# 偏差时才退回模式名。儿童向玩家看不懂「进近」，但看得懂「左转」；
	# 首版只写模式名，实测十字贴在左下角红着、玩家不知道要做什么。
	var txt := label_text()
	var lw := LABEL_W * s
	var fs := maxi(10, int(14.0 * s))
	var lp := Vector2(p.x - lw * 0.5, p.y + LABEL_DY * s)
	draw_string(ThemeDB.fallback_font, lp + Vector2(1.0, 1.0), txt,
		HORIZONTAL_ALIGNMENT_CENTER, lw, fs, COL_EDGE)
	draw_string(ThemeDB.fallback_font, lp, txt,
		HORIZONTAL_ALIGNMENT_CENTER, lw, fs, col)


## 带描边的实心条（先画一圈放大的黑边，再画彩色本体）：座舱外是天空，
## 亮度跨度极大，纯色十字在亮云上会消失。
func _bar(r: Rect2, col: Color, s: float) -> void:
	draw_rect(r.grow(maxf(1.0, 1.2 * s)), COL_EDGE, true)
	draw_rect(r, col, true)


## 实心三角箭头（尖端朝 dir），带同形放大黑描边（亮天空上也要看得见）。
func _arrow(tip: Vector2, dir: Vector2, size: float, col: Color) -> void:
	var side := Vector2(-dir.y, dir.x)
	var base := tip - dir * size
	var pts := PackedVector2Array([tip, base + side * size * 0.55,
		base - side * size * 0.55])
	var mid := (pts[0] + pts[1] + pts[2]) / 3.0
	var big := PackedVector2Array()
	for q in pts:
		big.append(mid + (q - mid) * 1.35)
	draw_colored_polygon(big, COL_EDGE)
	draw_colored_polygon(pts, col)


## 指令文字：偏差大到需要明显修正时给动作词，否则给模式名/对准。
## 公开供探针断言（绘制与断言必须同一份逻辑，不许各写一套）。
func label_text() -> String:
	if absf(_dev_h) < CAPTURE_DEG and absf(_dev_v) < CAPTURE_DEG:
		return "对准"
	var parts: Array[String] = []
	var sat := MAX_OFF / GAIN_PX_PER_DEG   # 单轴超量程阈值（度，与 s 无关）
	if absf(_dev_h) > 150.0:
		parts.append("掉头")
	elif absf(_dev_h) > sat:
		parts.append("右转" if _dev_h > 0.0 else "左转")
	if absf(_dev_v) > sat:
		parts.append("抬头" if _dev_v > 0.0 else "低头")
	if parts.is_empty():
		return mode_name(_mode)
	if parts.size() == 2:
		return "%s %s" % [parts[0], parts[1]]
	return parts[0]


func _color_for() -> Color:
	var worst := maxf(absf(_dev_h), absf(_dev_v))
	if worst < CAPTURE_DEG:
		return COL_LOCK
	if worst < WARN_DEG:
		return COL_DEV
	return COL_FAR
