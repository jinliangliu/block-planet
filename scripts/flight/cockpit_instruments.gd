class_name CockpitInstruments
extends Control
## 第一人称座舱 2D 像素仪表簇（D-047）：地平仪 + 高度计 + 航向仪。
##
## 与 D-034 两套既有实现的分工（都不替代、都不冲突）：
##   · CockpitPanel（3D 仪表板，低头可见）——本文件不碰它；
##   · flight_instrument_hud 的玻璃文字带（速度/高度/航向/坡度三行）——
##     本文件按用户「座舱仪表」需求替换它：高度/航向/坡度进仪表，速度
##     进 SPD 读数框，信息不丢（D-047 决策）。
##
## 像素风约定（用户 spec，勿平滑化）：黑底 + 白色硬边刻度；图形一律用
## draw_rect / draw_colored_polygon 拼（2D 画布默认不开 MSAA，即硬边），
## 细线用「细多边形」而非 draw_line（避免抗锯齿）；参考战雷老式仪表。
##
## 三件仪表（用户 spec 原样落地）：
##   地平仪：底层天地背景（俯仰→垂直偏移、横滚→整体旋转、±60° 钳制
##     截断不无限滚动），上层固定十字 + 飞机标记不随姿态动；带俯仰
##     阶梯与顶部横滚刻度（刻度随天地转、指针固定）。
##   高度计：白色数字 ALT 4500m；高度过低（FlightInstruments.alt_warn>0）
##     变红并按 600ms 周期闪烁。
##   航向仪：横向刻度带按航向水平滚动（359°→0° 取模连续不跳变），
##     中间竖线标记当前机头朝向，带下附三位航向数。
##
## 渲染层级：本控件是屏幕 HUD 覆盖层的子节点（最上层 2D 层），叠加在
## 座舱 3D 视野之上——纯 2D 绘制，不用 3D / ViewportTexture（用户 spec）。
##
## D-049：登机默认第一人称 + 「界面突出座舱驾驶界面」——整套尺寸放大
## ~16%（152→176 等），座舱视角下左侧 12 行详细清单让位（见
## flight_instrument_hud._apply_visibility），本簇成为座舱唯一飞行读数。

# ── 配色（黑底白刻度 + 低饱和天地色）────────────────────────────
const COL_BEZEL := Color(0.05, 0.05, 0.06)
const COL_MARK := Color(1.0, 1.0, 1.0)
const COL_SKY := Color(0.32, 0.52, 0.80)
const COL_GROUND := Color(0.46, 0.36, 0.24)
const COL_WARN := Color(0.95, 0.30, 0.26)

# ── 簇布局（四件均锚底居中，偏移自屏幕底边起算）──────────────────
## D-049 起整套放大 ~16%（152→176 等）：登机默认座舱视角，仪表簇是飞行
## 画面的主视觉，原尺寸在 1280×720 上偏小、「界面突出座舱驾驶界面」要求
## 放大。所有内部刻度/字号同步放大，几何关系（零重叠/不出屏）由窗口探针断言。
const MARGIN_B := 60.0     # 簇底距屏幕底（下方留 8 px 给驾驶提示行，见 HUD）
const GAUGE_SZ := 176.0    # 地平仪外径（方）
const BEZEL := 9.0         # 地平仪黑框宽
const TAPE_W := 712.0      # 航向带宽
const TAPE_H := 68.0       # 航向带总高（46 刻度带 + 22 航向数字）
const TAPE_STRIP := 46.0
const BOX_W := 178.0       # 数字读数框（ALT / SPD）
const BOX_H := 138.0
const TAPE_PPX := 6.0      # 航向带像素/度（712px ≈ ±59° 视野）
const PITCH_MAX := 60.0    # 俯仰钳制（用户 spec：超过截断、不无限滚动）
const BLINK_MS := 600.0    # 闪烁周期（与警告横幅一致）
const LADDER := [10.0, 20.0, 30.0]            # 俯仰阶梯标注角（度）
const ROLL_TICKS := [0.0, 10.0, 20.0, 30.0, 45.0, 60.0]  # 横滚刻度（正=右滚）
## 读数框内边距屏幕中心的水平距（地平仪半宽 + 间隙）：与 GAUGE_SZ 联动，
## 改外径不用手改这里的魔数。
const BOX_GAP := 20.0

## 四件子控件（公开供探针取几何矩形）。
var tape: _HeadingTape = null
var gauge: _AttitudeGauge = null
var alt_box: _DigitalBox = null
var spd_box: _DigitalBox = null


func _ready() -> void:
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    # 航向带（最上）→ 地平仪 → 左右读数框，自底向上堆叠。
    tape = _HeadingTape.new()
    _place(tape, -TAPE_W * 0.5, TAPE_W * 0.5,
        MARGIN_B + GAUGE_SZ + 8.0 + TAPE_H, MARGIN_B + GAUGE_SZ + 8.0)
    gauge = _AttitudeGauge.new()
    _place(gauge, -GAUGE_SZ * 0.5, GAUGE_SZ * 0.5,
        MARGIN_B + GAUGE_SZ, MARGIN_B)
    # 左右读数框垂直居中于地平仪（地平仪中心在底边上方 MARGIN_B+GAUGE/2）。
    var mid := MARGIN_B + GAUGE_SZ * 0.5
    var off := GAUGE_SZ * 0.5 + BOX_GAP
    alt_box = _DigitalBox.new()
    _place(alt_box, off, off + BOX_W, mid + BOX_H * 0.5, mid - BOX_H * 0.5)
    spd_box = _DigitalBox.new()
    _place(spd_box, -off - BOX_W, -off, mid + BOX_H * 0.5, mid - BOX_H * 0.5)


## 锚底居中的放置：l/r 为相对屏幕中心横线的偏移，t/b 为自屏幕底边的高度。
func _place(node: Control, l: float, r: float, t: float, b: float) -> void:
    node.anchor_left = 0.5
    node.anchor_right = 0.5
    node.anchor_top = 1.0
    node.anchor_bottom = 1.0
    node.offset_left = l
    node.offset_right = r
    node.offset_top = -t
    node.offset_bottom = -b
    add_child(node)


## 每帧从 FlightInstruments 喂数（由 FlightInstrumentHUD.tick 调用，
## 仅第一人称可见时）。各子控件自行 queue_redraw。
func refresh(fi: FlightInstruments) -> void:
    if fi == null:
        return
    tape.set_heading(fi.heading_deg)
    gauge.set_attitude(fi.pitch_deg, fi.roll_deg)
    alt_box.set_value("ALT", "%dm" % int(round(fi.altitude_msl)), fi.alt_warn > 0)
    spd_box.set_value("SPD", "%d km/h" % int(fi.airspeed_kmh),
        fi.overspeed or fi.stalled or fi.stall_warning)


## 调试/探针快照：四件控件的关键状态（文案 + 警告灯 + 姿态角）。
## 避免探针直接摸内部类私有成员（enable_all_warnings 下会报 unsafe）。
func debug_state() -> Dictionary:
    return {
        "alt_value": alt_box._value,
        "alt_warn": alt_box._warn,
        "spd_value": spd_box._value,
        "spd_warn": spd_box._warn,
        "heading": tape._heading,
        "pitch": gauge._pitch,
        "roll": gauge._roll,
    }


# ── 纯函数（探针直接断言，勿改语义）─────────────────────────────

## 地平仪俯仰像素偏移：钳制 ±PITCH_MAX——超过后天地画面截断，
## 不会无限滚动（用户 spec 第 1 条）。
static func pitch_offset_px(pitch_deg: float, px_per_deg: float) -> float:
    return clampf(pitch_deg, -PITCH_MAX, PITCH_MAX) * px_per_deg


## 航向带某刻度角的屏幕横坐标：deg 与 heading 都先归一到 0-360，
## 再取最短角差——359°→0° 附近位置连续，不跳变（用户 spec 第 3 条）。
static func tape_x(deg: float, heading_deg: float, center_x: float, px_per_deg: float) -> float:
    var d := wrapf(deg, 0.0, 360.0)
    var h := wrapf(heading_deg, 0.0, 360.0)
    return center_x + wrapf(d - h, -180.0, 180.0) * px_per_deg


## 地平仪地平线法线（指向天）：右滚为正 → 天地层视觉逆时针
## （右坡时天在左上、地在右下；90° 右坡天在左半屏）。
static func horizon_normal(roll_deg: float) -> Vector2:
    var a := deg_to_rad(-roll_deg)
    return Vector2(sin(a), -cos(a))


## 警告闪烁 alpha（t_ms 为毫秒时标）：0.35..1.0，600ms 周期。
static func blink_alpha(t_ms: float) -> float:
    var phase := fmod(t_ms, BLINK_MS) / BLINK_MS
    return 0.35 + 0.65 * absf(sin(phase * PI))


## 屏幕坐标旋转（Godot 2D y 向下，正角 = 视觉顺时针）。
static func rot2(a: float, x: float, y: float) -> Vector2:
    return Vector2(cos(a) * x - sin(a) * y, sin(a) * x + cos(a) * y)


## 线段 × 轴对齐矩形裁剪（Liang-Barsky）：返回 0 或 2 个点。
static func clip_seg_rect(p0: Vector2, p1: Vector2, r: Rect2) -> PackedVector2Array:
    var dx := p1.x - p0.x
    var dy := p1.y - p0.y
    var t0 := 0.0
    var t1 := 1.0
    var edges := [
        [-dx, p0.x - r.position.x],
        [dx, r.end.x - p0.x],
        [-dy, p0.y - r.position.y],
        [dy, r.end.y - p0.y],
    ]
    for e in edges:
        var pq := float(e[0])
        var qq := float(e[1])
        if absf(pq) < 1e-9:
            if qq < 0.0:
                return PackedVector2Array()
        else:
            var t := qq / pq
            if pq < 0.0:
                if t > t1:
                    return PackedVector2Array()
                if t > t0:
                    t0 = t
            else:
                if t < t0:
                    return PackedVector2Array()
                if t < t1:
                    t1 = t
    return PackedVector2Array([p0.lerp(p1, t0), p0.lerp(p1, t1)])


## 凸多边形 × 半平面裁剪（Sutherland-Hodgman 单边）：keep_above 保留
## n·(p-q) ≥ 0 的一侧。用于天地背景裁进仪表窗。
static func clip_poly_half(poly: PackedVector2Array, q: Vector2, n: Vector2,
        keep_above: bool) -> PackedVector2Array:
    var out := PackedVector2Array()
    var m := poly.size()
    for i in range(m):
        var cur: Vector2 = poly[i]
        var nxt: Vector2 = poly[(i + 1) % m]
        var dc := n.dot(cur - q)
        var dn := n.dot(nxt - q)
        var cin := dc >= 0.0 if keep_above else dc <= 0.0
        var nin := dn >= 0.0 if keep_above else dn <= 0.0
        if cin:
            out.append(cur)
        if cin != nin:
            out.append(cur.lerp(nxt, dc / (dc - dn)))
    return out


# ── 航向仪：横向刻度带 ─────────────────────────────────────────
class _HeadingTape extends Control:
    var _heading := 0.0

    func set_heading(h: float) -> void:
        _heading = wrapf(h, 0.0, 360.0)
        queue_redraw()

    func _draw() -> void:
        var s := size
        draw_rect(Rect2(Vector2.ZERO, s), COL_BEZEL, true)
        var strip := Rect2(Vector2.ZERO, Vector2(s.x, TAPE_STRIP))
        draw_rect(strip, COL_MARK, false, 1.0)
        var cx := s.x * 0.5
        # 刻度：±70° 覆盖（带宽 712 / 6 ≈ ±59° 视野，留标签余量）。
        # deg 先归一再取最短角差 → 359°→0° 无缝。
        var d0 := floori((_heading - 70.0) / 5.0) * 5
        var d1 := ceili((_heading + 70.0) / 5.0) * 5
        var d := d0
        while d <= d1:
            var major := posmod(d, 30) == 0
            var mid := posmod(d, 10) == 0
            var x := CockpitInstruments.tape_x(float(d), _heading, cx, TAPE_PPX)
            if x >= -24.0 and x <= s.x + 24.0:
                var th := 14.0 if major else (8.0 if mid else 5.0)
                var tw := 2.0 if major else 1.0
                draw_rect(Rect2(Vector2(roundf(x - tw * 0.5), 0.0), Vector2(tw, th)),
                    COL_MARK, true)
                if major:
                    var dd := wrapf(float(d), 0.0, 360.0)
                    var lbl := "N" if dd < 0.5 else ("E" if absf(dd - 90.0) < 0.5 \
                        else ("S" if absf(dd - 180.0) < 0.5 \
                        else ("W" if absf(dd - 270.0) < 0.5 else "%03d" % int(dd))))
                    draw_string(ThemeDB.fallback_font, Vector2(roundf(x), 19.0), lbl,
                        HORIZONTAL_ALIGNMENT_CENTER, 48.0, 14, COL_MARK)
            d += 5
        # 中间竖线（当前机头朝向）+ 顶部倒三角。
        draw_rect(Rect2(Vector2(roundf(cx - 1.0), 0.0), Vector2(2.0, TAPE_STRIP)),
            COL_MARK, true)
        draw_colored_polygon(PackedVector2Array([
            Vector2(cx - 7.0, 0.0), Vector2(cx + 7.0, 0.0), Vector2(cx, 7.0)]), COL_MARK)
        # 带下三位航向数。
        draw_string(ThemeDB.fallback_font, Vector2(cx, TAPE_STRIP + 4.0),
            "%03d°" % int(floorf(_heading)), HORIZONTAL_ALIGNMENT_CENTER, 140.0, 18, COL_MARK)


# ── 地平仪：天地背景 + 固定飞机标记 ─────────────────────────────
class _AttitudeGauge extends Control:
    var _pitch := 0.0
    var _roll := 0.0

    func set_attitude(pitch: float, roll: float) -> void:
        _pitch = pitch
        _roll = roll
        queue_redraw()

    func _draw() -> void:
        var s := size
        draw_rect(Rect2(Vector2.ZERO, s), COL_BEZEL, true)
        var win := Rect2(Vector2(BEZEL, BEZEL), s - Vector2(BEZEL * 2.0, BEZEL * 2.0))
        var wc := win.get_center()
        var wh := win.size.x * 0.5
        var ppd := wh / PITCH_MAX
        var a := deg_to_rad(-_roll)
        # 俯仰 → 天地层垂直偏移（钳 ±60°）；横滚 → 整层旋转。
        var dy := CockpitInstruments.pitch_offset_px(_pitch, ppd)
        var n := CockpitInstruments.horizon_normal(_roll)
        var q := wc + CockpitInstruments.rot2(a, 0.0, dy)
        # 天：整窗铺底（永不越界）。
        draw_rect(win, COL_SKY, true)
        # 地：窗口矩形按地平线半平面裁剪后填充。
        var corners := PackedVector2Array([
            win.position,
            Vector2(win.end.x, win.position.y),
            win.end,
            Vector2(win.position.x, win.end.y),
        ])
        var ground := CockpitInstruments.clip_poly_half(corners, q, n, false)
        if ground.size() >= 3:
            draw_colored_polygon(ground, COL_GROUND)
        # 地平线（2px 粗，裁进窗内）。
        var hd := CockpitInstruments.rot2(a, 1.0, 0.0)
        var seg := CockpitInstruments.clip_seg_rect(q - hd * wh * 1.6, q + hd * wh * 1.6, win)
        if seg.size() == 2:
            _thick_seg(seg[0], seg[1], 2.0, COL_MARK)
        # 俯仰阶梯（随天地旋转；20/30 带数字，标在可见端）。
        for p in LADDER:
            var pf := float(p)
            for sign in [-1.0, 1.0]:
                var ang := pf * float(sign)
                var ly := dy - ang * ppd
                var hl := 26.0 if pf >= 20.0 else 16.0
                var e0 := wc + CockpitInstruments.rot2(a, -hl, ly)
                var e1 := wc + CockpitInstruments.rot2(a, hl, ly)
                var lseg := CockpitInstruments.clip_seg_rect(e0, e1, win)
                if lseg.size() == 2:
                    _thick_seg(lseg[0], lseg[1], 1.5, COL_MARK)
                    if pf >= 20.0:
                        _draw_rot_text(lseg[0], a, "%d" % int(ang))
        # 横滚刻度（随天地转，顶部弧线；±60°）。
        var rr := wh - 7.0
        for phi in ROLL_TICKS:
            for sign in [-1.0, 1.0]:
                var ang := float(phi) * float(sign)
                var rad := deg_to_rad(ang)
                var major := absf(ang) < 0.5 or absf(absf(ang) - 30.0) < 0.5 \
                    or absf(absf(ang) - 60.0) < 0.5
                var rh := 3.5 if major else 2.0
                var c0 := Vector2(sin(rad) * rr, -cos(rad) * rr)
                var rd := Vector2(sin(rad), -cos(rad))
                var td := Vector2(rd.y, -rd.x)
                var local := PackedVector2Array([
                    c0 - rd * rh - td * 2.0,
                    c0 + rd * rh - td * 2.0,
                    c0 + rd * rh + td * 2.0,
                    c0 - rd * rh + td * 2.0,
                ])
                var poly := PackedVector2Array()
                for v in local:
                    poly.append(wc + CockpitInstruments.rot2(a, v.x, v.y))
                draw_colored_polygon(poly, COL_MARK)
        # 固定层（不随姿态动）：顶部指针 + 窗框 + 小十字 + 飞机标记。
        draw_colored_polygon(PackedVector2Array([
            Vector2(wc.x - 6.0, win.position.y),
            Vector2(wc.x + 6.0, win.position.y),
            Vector2(wc.x, win.position.y + 8.0)]), COL_MARK)
        draw_rect(win, COL_MARK, false, 1.0)
        var cross := Color(1.0, 1.0, 1.0, 0.55)
        draw_rect(Rect2(Vector2(wc.x - 8.0, wc.y - 0.5), Vector2(16.0, 1.0)), cross, true)
        draw_rect(Rect2(Vector2(wc.x - 0.5, wc.y - 8.0), Vector2(1.0, 16.0)), cross, true)
        draw_rect(Rect2(Vector2(wc.x - 34.0, wc.y - 1.0), Vector2(24.0, 2.0)), COL_MARK, true)
        draw_rect(Rect2(Vector2(wc.x + 10.0, wc.y - 1.0), Vector2(24.0, 2.0)), COL_MARK, true)
        draw_rect(Rect2(Vector2(wc.x - 1.0, wc.y - 10.0), Vector2(2.0, 10.0)), COL_MARK, true)

    ## 硬边粗线段：沿线方向的细四边形（不用 draw_line，避免抗锯齿）。
    func _thick_seg(p0: Vector2, p1: Vector2, w: float, col: Color) -> void:
        var d := (p1 - p0).normalized()
        var nrm := Vector2(-d.y, d.x) * (w * 0.5)
        draw_colored_polygon(PackedVector2Array([
            p0 + nrm, p1 + nrm, p1 - nrm, p0 - nrm]), col)

    ## 随天地层旋转的小数字（绕锚点转，位置不缩放）。
    ## Godot 4 的 draw_set_transform 签名是 (position, rotation, scale)，
    ## 不是 Transform2D——位置即锚点，旋转角即天地层角度。
    func _draw_rot_text(anchor: Vector2, a: float, txt: String) -> void:
        draw_set_transform(anchor, a, Vector2.ONE)
        draw_string(ThemeDB.fallback_font, Vector2(-7.0, -6.0), txt,
            HORIZONTAL_ALIGNMENT_RIGHT, 34.0, 12, COL_MARK)
        draw_set_transform(Vector2.ZERO)


# ── 数字读数框（高度计 ALT / 空速 SPD）──────────────────────────
class _DigitalBox extends Control:
    var _label := ""
    var _value := ""
    var _warn := false

    func set_value(label: String, value: String, warn: bool) -> void:
        _label = label
        _value = value
        _warn = warn
        queue_redraw()

    func _draw() -> void:
        draw_rect(Rect2(Vector2.ZERO, size), COL_BEZEL, true)
        draw_rect(Rect2(Vector2.ZERO, size), COL_MARK, false, 1.0)
        draw_string(ThemeDB.fallback_font, Vector2(11.0, 15.0), _label,
            HORIZONTAL_ALIGNMENT_LEFT, -1, 14, COL_MARK)
        var col := COL_MARK
        if _warn:
            col = Color(COL_WARN.r, COL_WARN.g, COL_WARN.b,
                CockpitInstruments.blink_alpha(Time.get_ticks_msec()))
        draw_string(ThemeDB.fallback_font, Vector2(size.x * 0.5, size.y * 0.5 + 16.0), _value,
            HORIZONTAL_ALIGNMENT_CENTER, size.x - 14.0, 30, col)
