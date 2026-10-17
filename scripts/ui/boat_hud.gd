class_name BoatHUD
extends Control
## 航海模式主界面（D-042）：驾船出海后替代徒步 HUD 的驾驶仪表层。
## 关注四件事——地理方位（罗经 + 坐标）、海况（浪高/风向）、航向与船速、
## 油量；外加距港距离与当前渔场带（钓鱼分带的距离来源）。
##
## 数据只信一份：Player.boat() 的 snapshot()（BoatSystem 海况 + BoatPhysics
## 读数），本界面不做任何物理计算。只在登船期间可见（Events.boat_ride_changed）。

const PANEL_BG := Color(0.05, 0.10, 0.18, 0.72)
const PANEL_BORDER := Color(0.35, 0.55, 0.75, 0.55)
const TEXT_MAIN := Color(0.92, 0.96, 1.0)
const TEXT_DIM := Color(0.68, 0.78, 0.90)
const ACCENT := Color(0.45, 0.80, 1.0)
const WARN := Color(1.0, 0.45, 0.30)
const FUEL_OK := Color(0.50, 0.85, 0.45)

## 罗经带：可视角度范围与像素宽。
const COMPASS_SPAN_DEG := 120.0
const COMPASS_W := 460.0
## 罗经刻度（每 15° 一小刻）。
const COMPASS_TICK_DEG := 15.0

var _player: Player = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	queue_redraw()


func setup(player: Player) -> void:
	_player = player


func _process(_delta: float) -> void:
	if not visible:
		return
	queue_redraw()


func _draw() -> void:
	var boat := _player.boat() if _player != null else null
	if boat == null:
		return
	var snap := boat.snapshot()
	var phys: Dictionary = snap["physics"]
	var size := get_size()
	_draw_compass(size, float(phys["heading_deg"]))
	_draw_position_panel(snap)
	_draw_sea_panel(snap)
	_draw_speed_panel(size, phys)
	_draw_fuel_panel(size, phys)
	_draw_hints(size)


## 罗经带：顶部居中的水平刻度带，N/E/S/W 大字，当前朝向恒在带中央。
func _draw_compass(size: Vector2, heading_deg: float) -> void:
	var cx := size.x * 0.5
	var top := 14.0
	var h := 34.0
	var rect := Rect2(Vector2(cx - COMPASS_W * 0.5, top), Vector2(COMPASS_W, h))
	draw_rect(rect, PANEL_BG)
	draw_rect(rect, PANEL_BORDER, false, 1.5)
	# 刻度：以当前朝向为中心，左右各 COMPASS_SPAN_DEG/2。
	var half := COMPASS_SPAN_DEG * 0.5
	var start_deg := heading_deg - half
	var first_tick: float = ceil(start_deg / COMPASS_TICK_DEG) * COMPASS_TICK_DEG
	var t: float = first_tick
	while t <= heading_deg + half:
		var frac: float = (t - heading_deg) / half  # -1 ~ 1
		var x: float = cx + frac * (COMPASS_W * 0.5 - 8.0)
		# 只有恰好落在 45° 整数刻度（N/NE/E/…）才写方位名；其余 15° 小刻只画短竖线。
		# 原写法用 _cardinal_of 的四舍五入会把 ±22.5° 内的三个 15° 刻都归到同一方位名，
		# 于是出现「西北 西北 西北」连刷。t 是 15 的倍数、45 也是其倍数，故取模即可精确判定。
		var w_deg := int(round(wrapf(t, 0.0, 360.0)))
		if w_deg % 45 == 0:
			var cardinal := _cardinal_of(float(w_deg))
			var font := ThemeDB.fallback_font
			var tw := font.get_string_size(cardinal, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x
			draw_string(font, Vector2(x - tw * 0.5, top + 24.0), cardinal,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 17, TEXT_MAIN)
			draw_line(Vector2(x, top + h - 4.0), Vector2(x, top + h - 12.0), TEXT_DIM, 1.5)
		else:
			draw_line(Vector2(x, top + h - 4.0), Vector2(x, top + h - 8.0), TEXT_DIM, 1.0)
		t += COMPASS_TICK_DEG
	# 中央指针（当前朝向）。
	draw_line(Vector2(cx, top + h), Vector2(cx, top + h + 8.0), ACCENT, 2.5)
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx - 5.0, top + h), Vector2(cx + 5.0, top + h), Vector2(cx, top + h + 8.0),
	]), ACCENT)
	# 朝向读数（指针下方）。
	var font := ThemeDB.fallback_font
	var label := "%03d° %s" % [int(round(wrapf(heading_deg, 0.0, 360.0))), _cardinal_of(heading_deg, true)]
	draw_string(font, Vector2(cx - 40.0, top + h + 24.0), label,
		HORIZONTAL_ALIGNMENT_LEFT, 80.0, 15, TEXT_DIM)


## 方位面板（左上）：坐标 + 距港距离 + 当前渔场带。
func _draw_position_panel(snap: Dictionary) -> void:
	var pos: Vector3 = snap["pos"]
	var dist_m := float(snap["harbor_distance_m"])
	var band := String(snap["band"])
	# 把整块面板下移到生命/饥饿块（_stats_box，约占 y16~100）下方，两块不再相互压字。
	# 面板内文字一律以 rect.position 为基准——原写法用绝对 y（40/60/82/100），面板一挪
	# 文字不跟随，会与上方姓名/爱心/饥饿叠成一团。
	var rect := Rect2(Vector2(16.0, 116.0), Vector2(210.0, 92.0))
	draw_rect(rect, PANEL_BG)
	draw_rect(rect, PANEL_BORDER, false, 1.0)
	var font := ThemeDB.fallback_font
	var ox := rect.position.x + 10.0
	var oy := rect.position.y
	var x_text := "X %+.0f m" % (pos.x * 0.5)
	var z_text := "Z %+.0f m" % (pos.z * 0.5)
	draw_string(font, Vector2(ox, oy + 24.0), x_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, TEXT_MAIN)
	draw_string(font, Vector2(ox, oy + 44.0), z_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, TEXT_MAIN)
	var dist_text := "距港 %.0f m" % dist_m if dist_m >= 0.0 else "距港 —（无港口）"
	draw_string(font, Vector2(ox, oy + 66.0), dist_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, TEXT_DIM)
	var band_text := "渔场：%s" % BoatSystem.band_title(band)
	draw_string(font, Vector2(ox, oy + 84.0), band_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, ACCENT)


## 海况面板（右上）：浪高、风向风级、天气一句。
func _draw_sea_panel(snap: Dictionary) -> void:
	var wave := float(snap["wave_m"])
	var rect := Rect2(Vector2(get_size().x - 226.0, 16.0), Vector2(210.0, 92.0))
	draw_rect(rect, PANEL_BG)
	draw_rect(rect, PANEL_BORDER, false, 1.0)
	var font := ThemeDB.fallback_font
	# 浪高条（0~3 m 量程）。
	var bar := Rect2(Vector2(rect.position.x + 16.0, 34.0), Vector2(120.0, 10.0))
	draw_rect(bar, Color(0.10, 0.16, 0.24))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(wave / 3.0, 0.0, 1.0), bar.size.y)),
		ACCENT)
	draw_string(font, Vector2(bar.position.x + bar.size.x + 8.0, 44.0), "%.1f m" % wave,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, TEXT_MAIN)
	draw_string(font, Vector2(rect.position.x + 16.0, 66.0), "浪高",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, TEXT_DIM)
	var wind := _wind_text()
	draw_string(font, Vector2(rect.position.x + 16.0, 88.0), wind,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, TEXT_MAIN)


## 风的一句（风向罗经名 + 蒲福风级简化）。海况快照里只有度数/速度，
## 这里补显示名；数据仍来自 BoatSystem（探针可复现）。
func _wind_text() -> String:
	var boat := _player.boat() if _player != null else null
	if boat == null:
		return "风 —"
	var sea := boat.current_sea_state()
	var deg := float(sea.get("wind_deg", 0.0))
	var mps := float(sea.get("wind_mps", 0.0))
	# wind_deg 是「风吹向」的方向（ BoatPhysics 顺风推力的方向），显示说「吹向」。
	return "风吹向%s · %.0f 级" % [BoatSystem.wind_name(deg), _beaufort(mps)]


## 蒲福风级（简化线性折算，儿童向显示用）。
static func _beaufort(mps: float) -> int:
	return clampi(int(round(mps / 2.0)), 0, 8)


## 速度面板（底部居中）：大数字 km/h + 油门条。
func _draw_speed_panel(size: Vector2, phys: Dictionary) -> void:
	var kmh := float(phys["kmh"])
	var throttle := float(phys["throttle"])
	var rect := Rect2(Vector2(size.x * 0.5 - 130.0, size.y - 96.0), Vector2(260.0, 82.0))
	draw_rect(rect, PANEL_BG)
	draw_rect(rect, PANEL_BORDER, false, 1.0)
	var font := ThemeDB.fallback_font
	var speed_text := "%.0f" % kmh
	draw_string(font, Vector2(rect.position.x + 18.0, rect.position.y + 46.0), speed_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 40, TEXT_MAIN)
	draw_string(font, Vector2(rect.position.x + 18.0 + 66.0, rect.position.y + 46.0), "km/h",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, TEXT_DIM)
	# 油门条（支持倒车：中线两侧）。
	var bar := Rect2(Vector2(rect.position.x + 150.0, rect.position.y + 18.0), Vector2(88.0, 10.0))
	draw_rect(bar, Color(0.10, 0.16, 0.24))
	draw_line(Vector2(bar.position.x + bar.size.x * 0.5, bar.position.y),
		Vector2(bar.position.x + bar.size.x * 0.5, bar.position.y + bar.size.y), TEXT_DIM, 1.0)
	var fill_w: float = bar.size.x * 0.5 * clampf(throttle, -1.0, 1.0)
	if fill_w >= 0.0:
		draw_rect(Rect2(Vector2(bar.position.x + bar.size.x * 0.5, bar.position.y),
			Vector2(fill_w, bar.size.y)), ACCENT)
	else:
		draw_rect(Rect2(Vector2(bar.position.x + bar.size.x * 0.5 + fill_w, bar.position.y),
			Vector2(-fill_w, bar.size.y)), WARN)
	draw_string(font, Vector2(bar.position.x, bar.position.y + 24.0), "油门",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, TEXT_DIM)
	# 发动机状态（熄火时显眼）。
	if not bool(phys["engine_on"]) and bool(phys["has_engine"]):
		draw_string(font, Vector2(rect.position.x + 150.0, rect.position.y + 58.0), "发动机熄火",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, WARN)


## 油量面板（右下）：条 + 余量升；低油警告；木筏显示「无动力」。
func _draw_fuel_panel(size: Vector2, phys: Dictionary) -> void:
	var rect := Rect2(Vector2(size.x - 226.0, size.y - 96.0), Vector2(210.0, 82.0))
	draw_rect(rect, PANEL_BG)
	draw_rect(rect, PANEL_BORDER, false, 1.0)
	var font := ThemeDB.fallback_font
	if not bool(phys["has_engine"]):
		draw_string(font, Vector2(rect.position.x + 16.0, rect.position.y + 36.0), "⛽ 木筏无发动机",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, TEXT_DIM)
		draw_string(font, Vector2(rect.position.x + 16.0, rect.position.y + 58.0), "靠划桨与风，不耗油",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, TEXT_DIM)
		return
	var ratio := float(phys["fuel_ratio"])
	var bar := Rect2(Vector2(rect.position.x + 16.0, rect.position.y + 22.0), Vector2(140.0, 12.0))
	draw_rect(bar, Color(0.10, 0.16, 0.24))
	var color := FUEL_OK
	if ratio <= 0.2:
		color = WARN
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * ratio, bar.size.y)), color)
	draw_string(font, Vector2(bar.position.x + bar.size.x + 8.0, rect.position.y + 32.0),
		"%d%%" % int(round(ratio * 100.0)), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, TEXT_MAIN)
	draw_string(font, Vector2(rect.position.x + 16.0, rect.position.y + 56.0),
		"剩 %.0f 升 · 回港自动加" % float(phys["fuel"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, TEXT_DIM)


## 操作提示（左下）：登船后常驻，儿童玩家随时看得见键位。
func _draw_hints(size: Vector2) -> void:
	var font := ThemeDB.fallback_font
	var lines := ["W/S 油门（S 倒船）", "A/D 转舵", "F 发动机", "X 下船", "M 地图 → 下竿钓鱼"]
	var y := size.y - 118.0
	for line: String in lines:
		draw_string(font, Vector2(16.0, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, TEXT_DIM)
		y += 18.0


## 度数 → 罗经名（cardinal_only = 只给八字名，否则空串由刻度线画）。
func _cardinal_of(deg: float, cardinal_only: bool = false) -> String:
	var d := wrapf(deg, 0.0, 360.0)
	match int(round(d / 45.0)) % 8:
		0:
			return "北"
		1:
			return "东北"
		2:
			return "东"
		3:
			return "东南"
		4:
			return "南"
		5:
			return "西南"
		6:
			return "西"
		7:
			return "西北"
	return ""
