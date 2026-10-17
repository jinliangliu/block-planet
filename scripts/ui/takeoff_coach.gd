class_name TakeoffCoach
extends Control
## 起飞教练（D-043）：驾驶中在屏幕底部中央给出「下一步该做什么」的单步指引。
## 只做提示，不碰任何物理——所有数字来自 Aircraft.snapshot() 这一份数据。
##
## 存在的理由（新手飞不起来的两个真实卡点，都是提示缺失而非物理错误）：
##   ① 登机时发动机**默认熄火**（Aircraft.set_piloted 只满油、不点火），
##      熄火时油门锁 0，于是「推油门飞机不动」，玩家完全不知道要按 F 点火；
##   ② 拉杆是 ↑/↓ 方向键，鼠标只在**座舱视角**才是操纵杆，而默认视角是追尾
##      （CHASE）——说明书却只写「晃动鼠标拉杆」，默认视角下晃鼠标毫无反应。
## 故教练把起飞显式拆成四步：点火 → 推油门 → 等速度 → 按 ↑ 抬轮，
## 并且只在速度真的够了才喊「抬轮」，避免早抬轮失速。
##
## 隐藏时机：离地超过 TAKEOFF_ALT 后播一句「起飞成功」再淡出，巡航不占屏；
## 再次落回地面自动重新接管（准备下一次起飞）。空中失速随时重新出现。

const PANEL_BG := Color(0.04, 0.09, 0.16, 0.82)
const PANEL_BORDER := Color(0.40, 0.62, 0.85, 0.70)
const TEXT_MAIN := Color(0.94, 0.97, 1.0)
const TEXT_DIM := Color(0.72, 0.82, 0.92)
const COL_GO := Color(0.45, 0.95, 0.55)
const COL_WARN := Color(1.0, 0.55, 0.30)
const COL_DANGER := Color(1.0, 0.32, 0.28)
## 键位高亮色：需要玩家动手的步骤整句用这个色，一眼区分「要按键」还是「等着」。
const COL_KEY := Color(1.0, 0.88, 0.35)

## 抬轮速度 = 失速速度 × 该系数。地面被机轮限位只能抬头 12°，可用升力系数
## 低于 CLmax，故必须明显快过失速速度才抬得起来。跟着 stall_speed 走而不是
## 写死 50 km/h——襟翼档位/载重变化时写死值会失准（早抬轮直接失速）。
const VR_FACTOR := 1.2
## 判定「起飞成功」的离地高度（m）：低于 mission 的 30 m 目标，早点给正反馈。
const TAKEOFF_ALT := 15.0
## 「起飞成功」横幅停留时长（s），之后淡出。
const SUCCESS_HOLD := 3.5
## 油门算「推满」的阈值。
const FULL_THROTTLE := 0.85

var _craft: Aircraft = null
var _elapsed := 0.0
## 起飞成功时刻（<0 表示尚未成功）。
var _success_at := -1.0
## 本次驾驶是否已经完成过起飞（落回地面后重置，重新接管）。
var _finished := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


## 每次登机调用：重置阶梯，从头带一遍。
func setup(craft: Aircraft) -> void:
	_craft = craft
	_elapsed = 0.0
	_success_at = -1.0
	_finished = false
	visible = craft != null


func clear() -> void:
	_craft = null
	visible = false


## 由 HUD 每帧驱动（与 FlightInstrumentHUD.tick 同一处，驾驶中才调）。
func tick(delta: float) -> void:
	if _craft == null or not is_instance_valid(_craft):
		visible = false
		return
	visible = true
	_elapsed += delta
	queue_redraw()


func _draw() -> void:
	if _craft == null or not is_instance_valid(_craft):
		return
	var snap := _craft.snapshot()
	var step := _step_of(snap)
	if step.is_empty():
		return
	_draw_bar(step)


## 当前该做的一步。返回 {text, sub, color, progress, flash}。
## 空字典表示此刻不需要教练（已起飞且稳定爬升中）。
## 优先级：失速保命 > 熄火点火 > 地面四步 / 空中爬升。
func _step_of(snap: Dictionary) -> Dictionary:
	var on_ground := bool(snap.get("on_ground", false))
	var kmh := float(snap.get("kmh", 0.0))
	var alt_agl := float(snap.get("altitude_agl", 0.0))
	var stalled := bool(snap.get("stalled", false))
	var stall_warning := bool(snap.get("stall_warning", false))
	var engine := bool(snap.get("engine", false))

	# 落回地面 → 重新接管（准备下一次起飞）。
	if on_ground:
		_finished = false
		_success_at = -1.0

	# ① 失速最紧急，先保命（地面被机轮限位，实际只在空中触发）。
	if not on_ground and stalled:
		return {
			"text": "失速了！按【↓】低头 + 油门推满，等速度回来再拉",
			"sub": "失速时升力不够，先低头换速度", "color": COL_DANGER,
			"progress": -1.0, "flash": true,
		}
	if not on_ground and stall_warning:
		return {
			"text": "快失速了：轻点【↓】收一点杆，别再猛拉",
			"sub": "速度偏低，拉太猛会掉下来", "color": COL_WARN,
			"progress": -1.0, "flash": true,
		}

	# ② 发动机熄火：地面 / 空中都要先点火。熄火时油门锁 0——不点火，
	#    地面推油门完全没反应、空中也加不上速。这是新手最常卡住的一步。
	if not engine:
		return {
			"text": "按【F】启动发动机（不点火油门锁着，推油门没反应）",
			"sub": "发动机启动后才有推力，然后按 W 推满油门", "color": COL_KEY,
			"progress": -1.0, "flash": true,
		}

	# ③ 已点火：空中就报爬升/成功，地面就继续四步阶梯。
	if not on_ground:
		if alt_agl < TAKEOFF_ALT:
			return {
				"text": "爬升中：轻拉【↑】继续爬，别一口气拉到底",
				"sub": "拉太猛会失速，稳住爬到 %.0f m" % TAKEOFF_ALT,
				"color": COL_GO, "progress": alt_agl / TAKEOFF_ALT, "flash": false,
			}
		if not _finished:
			_finished = true
			_success_at = _elapsed
		if _success_at >= 0.0 and _elapsed - _success_at <= SUCCESS_HOLD:
			return {
				"text": "🎉 起飞成功！你已经飞起来了",
				"sub": "【H】看详细仪表 · 【M】地图导航 · 慢慢落，别扎树冠",
				"color": COL_GO, "progress": -1.0, "flash": false,
			}
		return {}

	# 地面滑跑：按顺序卡住——前一步没做完就不提示下一步。
	var throttle := float(snap.get("throttle", 0.0))
	if throttle < FULL_THROTTLE:
		return {
			"text": "② 按住【W】把油门推到底（或【Shift】一键推满）",
			"sub": "油门 %.0f%%，推满才有足够推力" % (throttle * 100.0),
			"color": COL_KEY, "progress": throttle, "flash": false,
		}
	var vs_kmh := float(snap.get("stall_speed", 13.0)) * 3.6
	var vr_kmh := vs_kmh * VR_FACTOR
	if kmh < vr_kmh:
		return {
			"text": "③ 继续滑跑加速：%.0f / %.0f km/h" % [kmh, vr_kmh],
			"sub": "速度不够就抬头会失速，再等等", "color": TEXT_MAIN,
			"progress": clampf(kmh / maxf(vr_kmh, 1.0), 0.0, 1.0), "flash": false,
		}
	return {
		"text": "④ 现在轻按【↑】抬轮——速度够了，拉起来！",
		"sub": "一下一下轻点，别按住不放（会失速）", "color": COL_GO,
		"progress": 1.0, "flash": true,
	}


## 底部中央横条：主句 + 副句 + 可选进度条。
func _draw_bar(step: Dictionary) -> void:
	var size := get_size()
	var w := 520.0
	var h := 58.0
	var rect := Rect2(Vector2(size.x * 0.5 - w * 0.5, size.y - 122.0), Vector2(w, h))
	var color: Color = step.get("color", TEXT_MAIN)
	var flash := bool(step.get("flash", false))
	# 需要动手的步骤用呼吸式闪烁抓住注意力（儿童向：低对比、不刺眼）。
	var alpha := 1.0
	if flash:
		alpha = 0.72 + 0.28 * (0.5 + 0.5 * sin(_elapsed * 6.0))
	draw_rect(rect, PANEL_BG)
	draw_rect(rect, Color(color.r, color.g, color.b, alpha), false, 2.0)

	var font := ThemeDB.fallback_font
	var text := String(step.get("text", ""))
	var sub := String(step.get("sub", ""))
	var main_col := Color(color.r, color.g, color.b, alpha)
	draw_string(font, Vector2(rect.position.x + 16.0, rect.position.y + 26.0), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 17, main_col)
	draw_string(font, Vector2(rect.position.x + 16.0, rect.position.y + 46.0), sub,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, TEXT_DIM)

	# 进度条（油门 / 空速 / 爬升高度）：只在有明确目标量时画。
	var progress := float(step.get("progress", -1.0))
	if progress >= 0.0:
		var bar := Rect2(Vector2(rect.position.x + 16.0, rect.position.y + h - 7.0),
			Vector2(w - 32.0, 4.0))
		draw_rect(bar, Color(0.10, 0.16, 0.24, 0.9))
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(progress, 0.0, 1.0),
			bar.size.y)), main_col)
