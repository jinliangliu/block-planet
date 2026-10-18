class_name TakeoffCoach
extends RefCounted
## 起飞教练（D-043 / D-046）：把「下一步该做什么」算成一步提示。
## 只做提示，不碰任何物理——所有数字来自 Aircraft.snapshot() 这一份数据。
##
## D-046 起本类**不再绘制任何界面**：原屏幕底部独立横条按用户要求合并进
## hud.gd 的飞行面板卡片（「2区和3区合并按照2区风格展示」），本类退化为纯
## 逻辑——输入 snapshot，输出一步 {text, sub, bar, color, flash}，由 HUD 用
## 飞行面板的卡片风格渲染。底部横条曾有的座舱视角避让（reserve 122→200）
## 随之失去存在理由：教练区在卡片内、位于顶部居中，与座舱玻璃 HUD 的底部
## 三行读数带（y H-120…H-60）天然不冲突。
##
## 存在的理由（新手飞不起来的两个真实卡点，都是提示缺失而非物理错误）：
##   ① 登机时发动机**默认熄火**（Aircraft.set_piloted 只满油、不点火），
##      熄火时油门锁 0，于是「推油门飞机不动」，玩家完全不知道要按 F 点火；
##   ② 拉杆是 ↑/↓ 方向键，鼠标只在**座舱视角**才是操纵杆，而默认视角是追尾
##      （CHASE）——说明书却只写「晃动鼠标拉杆」，默认视角下晃鼠标毫无反应。
## 故教练把起飞显式拆成四步：点火 → 推油门 → 等速度 → 按 ↑ 抬轮，
## 并且只在速度真的够了才喊「抬轮」，避免早抬轮失速。
##
## 隐藏时机：离地超过 TAKEOFF_ALT 后播一句「起飞成功」再返回空字典
## （HUD 见空字典即隐藏教练区），巡航不占屏；再次落回地面自动重新接管。
## 失速不归教练管：卡片自带失速行 + 仪表 HUD 全宽警告横幅都在报它，
## 教练再插一条只会和横幅抢顶部居中（见 _step_of 注释）。

## 数据行主色（与卡片数据行一致的白）。
const TEXT_MAIN := Color(0.94, 0.97, 1.0)
const COL_GO := Color(0.45, 0.95, 0.55)
## 键位高亮色：需要玩家动手的步骤整句用这个色，一眼区分「要按键」还是「等着」。
const COL_KEY := Color(1.0, 0.88, 0.35)

## 抬轮速度 = 失速速度 × 该系数。地面被机轮限位只能抬头 12°，可用升力系数
## 低于 CLmax，故必须明显快过失速速度才抬得起来。跟着 stall_speed 走而不是
## 写死 50 km/h——襟翼档位/载重变化时写死值会失准（早抬轮直接失速）。
const VR_FACTOR := 1.2
## 判定「起飞成功」的离地高度（m）：低于 mission 的 30 m 目标，早点给正反馈。
const TAKEOFF_ALT := 15.0
## 「起飞成功」停留时长（s），之后返回空字典让 HUD 收起教练区。
const SUCCESS_HOLD := 3.5
## 油门算「推满」的阈值。
const FULL_THROTTLE := 0.85

var _craft: Aircraft = null
var _elapsed := 0.0
## 起飞成功时刻（<0 表示尚未成功）。
var _success_at := -1.0
## 本次驾驶是否已经完成过起飞（落回地面后重置，重新接管）。
var _finished := false


## 登机时调用：绑定飞机并把阶梯重置回第①步（从头带一遍）。
func bind(craft: Aircraft) -> void:
	_craft = craft
	_elapsed = 0.0
	_success_at = -1.0
	_finished = false


## 下机时调用：解绑（HUD 随即隐藏教练区）。
func unbind() -> void:
	_craft = null
	_elapsed = 0.0
	_success_at = -1.0
	_finished = false


## 内部计时（s）：HUD 用它算「要按键」步骤的呼吸闪烁透明度。
func elapsed() -> float:
	return _elapsed


## 每帧由 HUD 的 _refresh_flight_panel 调用：推进内部计时并算出当前这一步。
## 返回 {text, sub, bar, color, flash}；bar 为空串表示不画进度条。
## 空字典表示此刻不需要教练（巡航中，或失速——交给卡片失速行与警告横幅）。
func step_for(snap: Dictionary, delta: float) -> Dictionary:
	if _craft == null:
		return {}
	_elapsed += delta
	return _step_of(snap)


## 当前该做的一步。优先级：熄火点火 > 地面四步 / 空中爬升成功。
## 失速（stalled / stall_warning）故意不返回步骤：仪表 HUD 的全宽警告横幅
## （y 150…190，闪烁 22px 大字）与飞行卡片自带失速行已经在报，且都在卡片
## 上半部；教练区若再插一条失速提示，会和横幅在顶部居中互相压字。
func _step_of(snap: Dictionary) -> Dictionary:
	var on_ground := bool(snap.get("on_ground", false))
	var kmh := float(snap.get("kmh", 0.0))
	var alt_agl := float(snap.get("altitude_agl", 0.0))
	var engine := bool(snap.get("engine", false))

	# 落回地面 → 重新接管（准备下一次起飞）。
	if on_ground:
		_finished = false
		_success_at = -1.0

	# ① 发动机熄火：地面 / 空中都要先点火。熄火时油门锁 0——不点火，
	#    地面推油门完全没反应、空中也加不上速。这是新手最常卡住的一步。
	if not engine:
		return {
			"text": "① 按【F】启动发动机",
			"sub": "不点火油门锁着，推油门没反应", "color": COL_KEY,
			"bar": "", "flash": true,
		}

	# ② 已点火：空中就报爬升/成功，地面就继续四步阶梯。
	if not on_ground:
		if alt_agl < TAKEOFF_ALT:
			return {
				"text": "爬升中：轻拉【↑】",
				"sub": "别一口气拉到底，会失速", "color": COL_GO,
				"bar": _bar(alt_agl / TAKEOFF_ALT), "flash": false,
			}
		if not _finished:
			_finished = true
			_success_at = _elapsed
		if _success_at >= 0.0 and _elapsed - _success_at <= SUCCESS_HOLD:
			return {
				"text": "🎉 起飞成功！",
				"sub": "【H】看仪表 ·【M】地图 · 慢慢落", "color": COL_GO,
				"bar": "", "flash": false,
			}
		return {}

	# 地面滑跑：按顺序卡住——前一步没做完就不提示下一步。
	var throttle := float(snap.get("throttle", 0.0))
	if throttle < FULL_THROTTLE:
		return {
			"text": "② 按住【W】推满油门",
			"sub": "或按【Shift】一键推满", "color": COL_KEY,
			"bar": _bar(throttle), "flash": false,
		}
	var vs_kmh := float(snap.get("stall_speed", 13.0)) * 3.6
	var vr_kmh := vs_kmh * VR_FACTOR
	if kmh < vr_kmh:
		return {
			"text": "③ 继续滑跑加速  %.0f / %.0f km/h" % [kmh, vr_kmh],
			"sub": "速度不够就抬头会失速，再等等", "color": TEXT_MAIN,
			"bar": _bar(kmh / maxf(vr_kmh, 1.0)), "flash": false,
		}
	return {
		"text": "④ 轻按【↑】抬轮",
		"sub": "速度够了，一下一下轻点", "color": COL_GO,
		"bar": "", "flash": true,
	}


## 进度条文本：10 格方块 + 百分比，与飞行面板油门条同一套字形（█/░），
## 保持「2 区风格」——教练区不引入新的视觉语言。
func _bar(ratio: float) -> String:
	var r := clampf(ratio, 0.0, 1.0)
	var filled := clampi(int(round(r * 10.0)), 0, 10)
	return "█".repeat(filled) + "░".repeat(10 - filled) + "  %d%%" % int(r * 100.0)
