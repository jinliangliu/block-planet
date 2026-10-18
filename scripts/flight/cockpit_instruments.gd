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
##
## D-050：本控件同时画「驾驶舱像素背景」（D-047 spec 遗留项）——顶导轨 +
## 左右座舱立柱 + 仪表 dash 底板，四件仪表坐在 dash 上。第一人称下 3D
## 外部机模被隐藏（aircraft.set_cockpit_interior），座舱内装完全由这层
## 2D 像素框提供，世界从框内开口看去。
##
## D-051（用户试玩反馈两条）：①「仪表簇太大了，缩小」——四件整体回缩
## ~15%（176→148 等，仍略大于 D-047 原始尺寸：世界视野优先）；②「想要
## 更浓的座舱感」——立柱升级为风挡支柱（顶檐下斜边内收）+ 左右侧 console
## （缝线/按键网格/通风栅/警告灯/铆钉）+ dash 铆钉与确定性磨损噪点/划痕。
## 磨损一律静态坐标哈希：不随姿态闪烁（ALT 闪烁只重绘数字框自己）。

# ── 配色（黑底白刻度 + 低饱和天地色）────────────────────────────
const COL_BEZEL := Color(0.05, 0.05, 0.06)
const COL_MARK := Color(1.0, 1.0, 1.0)
const COL_SKY := Color(0.32, 0.52, 0.80)
const COL_GROUND := Color(0.46, 0.36, 0.24)
const COL_WARN := Color(0.95, 0.30, 0.26)

# ── 簇布局（四件均锚底居中，偏移自屏幕底边起算）──────────────────
## D-049 曾放大 ~16%（152→176），D-051 用户反馈「仪表簇太大了」回缩 ~15%
## （176→148 等，仍略大于 D-047 原始尺寸）：座舱视角下世界视野优先，仪表
## 够读即可。所有内部刻度/字号同步缩放，几何关系（零重叠/不出屏）由探针断言。
const MARGIN_B := 52.0     # 簇底距屏幕底（下方即 dash 地板，无额外留白）
const GAUGE_SZ := 148.0    # 地平仪外径（方）
const BEZEL := 8.0         # 地平仪黑框宽
const TAPE_W := 600.0      # 航向带宽
const TAPE_H := 56.0       # 航向带总高（38 刻度带 + 18 航向数字）
const TAPE_STRIP := 38.0
const BOX_W := 150.0       # 数字读数框（ALT / SPD）
const BOX_H := 116.0
const TAPE_PPX := 5.0      # 航向带像素/度（600px ≈ ±60° 视野）
const PITCH_MAX := 60.0    # 俯仰钳制（用户 spec：超过截断、不无限滚动）
const BLINK_MS := 600.0    # 闪烁周期（与警告横幅一致）
const LADDER := [10.0, 20.0, 30.0]            # 俯仰阶梯标注角（度）
const ROLL_TICKS := [0.0, 10.0, 20.0, 30.0, 45.0, 60.0]  # 横滚刻度（正=右滚）
## 读数框内边距屏幕中心的水平距（地平仪半宽 + 间隙）：与 GAUGE_SZ 联动，
## 改外径不用手改这里的魔数。
const BOX_GAP := 18.0

# ── 座舱像素内装（D-050 / D-051）─────────────────────────────────
## D-047 spec 的「驾驶舱像素背景」：顶导轨 + 风挡支柱 + 侧 console + 仪表
## dash 底板 + 磨损细节。与簇同一套像素风：硬边矩形（2D 画布默认不开 MSAA）、
## 黑底、内侧勾边；噪点/铆钉/划痕一律确定性坐标哈希（静态帧，不随姿态闪烁）。
const FRAME_RAIL_H := 12.0   # 顶导轨高（座舱顶檐）
const FRAME_EDGE := 2.0      # 框体内侧勾边宽
const CONSOLE_W := 120.0     # 侧 console 宽（风挡支柱以下）
const PILLAR_TOP_W := 70.0   # 风挡支柱顶端半距（斜边起点，< CONSOLE_W 才成斜）
const PILLAR_BASE_Y := 320.0 # 斜边收敛纵坐标（以下为直 console 壁）
const DASH_PAD := 14.0       # dash 底板四出簇外的 padding
const DASH_LIP := 3.0        # dash 顶沿勾边厚
const COL_FRAME := Color(0.04, 0.05, 0.07)        # 座舱框体（顶檐/风挡支柱）
const COL_FRAME_EDGE := Color(0.17, 0.19, 0.24)   # 框体内侧勾边
const COL_DASH := Color(0.07, 0.08, 0.11)         # dash 底板
const COL_STRUCT := Color(0.055, 0.06, 0.08)      # 侧 console 面板（比框体微亮）
const COL_SEAM := Color(0.12, 0.13, 0.16)         # 面板缝线 / 通风栅
const COL_RIVET := Color(0.26, 0.28, 0.33)        # 铆钉
const COL_KEY := Color(0.10, 0.11, 0.13)          # 按键（未点亮）
const COL_LED_G := Color(0.35, 0.85, 0.45)        # 按键 LED（绿）
const COL_LED_A := Color(0.95, 0.75, 0.25)        # 按键 LED（琥珀）
const COL_LED_R := Color(0.90, 0.32, 0.28)        # 按键 LED（红）
const COL_WEAR := Color(1.0, 1.0, 1.0, 0.10)      # 磨损亮点点
const COL_WEAR_D := Color(0.0, 0.0, 0.0, 0.35)    # 磨损暗点点
const COL_SCRATCH := Color(1.0, 1.0, 1.0, 0.20)   # 风挡划痕

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


## 座舱像素内装绘制（D-050/D-051）：先画框体与 dash 底板，四件仪表作为子控件
## 永远画在其后（Control 子节点晚于父节点 _draw）——视觉上仪表「坐在
## dash 上、框在座舱里」。仅本控件可见（第一人称）时才会执行。
## 顺序：风挡支柱+console 底板 → dash → 顶檐 → 内缘勾边 → console 细节 →
## dash 铆钉 → 磨损噪点/划痕。全部静态（尺寸不变不重绘）。
func _draw() -> void:
    var w := size.x
    var h := size.y
    var r := frame_rects(size)
    var d: Rect2 = r["dash"]
    # 风挡支柱 + 侧 console（左）：斜边自顶檐 (PILLAR_TOP_W,0) 向内收到
    # (CONSOLE_W, PILLAR_BASE_Y)，以下转为直壁——世界从两道斜边之间望去。
    draw_colored_polygon(PackedVector2Array([
        Vector2(0.0, 0.0), Vector2(PILLAR_TOP_W, 0.0),
        Vector2(CONSOLE_W, PILLAR_BASE_Y), Vector2(CONSOLE_W, h), Vector2(0.0, h),
    ]), COL_STRUCT)
    draw_colored_polygon(PackedVector2Array([
        Vector2(w, 0.0), Vector2(w - PILLAR_TOP_W, 0.0),
        Vector2(w - CONSOLE_W, PILLAR_BASE_Y), Vector2(w - CONSOLE_W, h), Vector2(w, h),
    ]), COL_STRUCT)
    # dash 底板（伸到屏底＝座舱地板）+ 顶沿勾边。
    draw_rect(d, COL_DASH, true)
    draw_rect(r["lip"], COL_FRAME_EDGE, true)
    # 顶檐 + 底沿勾边。
    draw_rect(r["rail"], COL_FRAME, true)
    draw_rect(Rect2(0.0, FRAME_RAIL_H, w, FRAME_EDGE), COL_FRAME_EDGE, true)
    # 斜边与直壁的内缘高光（四道「框住世界」的亮边）。
    _edge(Vector2(PILLAR_TOP_W + 2.0, 0.0), Vector2(CONSOLE_W + 2.0, PILLAR_BASE_Y),
        2.0, COL_FRAME_EDGE)
    _edge(Vector2(CONSOLE_W + 1.0, PILLAR_BASE_Y), Vector2(CONSOLE_W + 1.0, h),
        2.0, COL_FRAME_EDGE)
    _edge(Vector2(w - PILLAR_TOP_W - 2.0, 0.0), Vector2(w - CONSOLE_W - 2.0, PILLAR_BASE_Y),
        2.0, COL_FRAME_EDGE)
    _edge(Vector2(w - CONSOLE_W - 1.0, PILLAR_BASE_Y), Vector2(w - CONSOLE_W - 1.0, h),
        2.0, COL_FRAME_EDGE)
    # 侧 console 细节：缝线 / 按键网格 / 通风栅 / 警告灯 / 铆钉。
    _left_console()
    _right_console()
    # dash 顶沿下一排铆钉（间距 44，避开两端）。
    var rx := d.position.x + 20.0
    while rx < d.end.x - 20.0:
        draw_rect(Rect2(rx, d.position.y + 5.0, 2.0, 2.0), COL_RIVET, true)
        rx += 44.0
    # 磨损：确定性噪点（亮/暗两极，稀疏）+ 风挡斜边两道划痕。只落在框体
    # 结构上——世界开口与 dash 上的仪表区不铺（仪表是子节点，画在噪点上）。
    _wear_area(Rect2(0.0, FRAME_RAIL_H, w, FRAME_RAIL_H), 7.0)
    _wear_pillar(1.0)
    _wear_pillar(-1.0)
    _wear_area(r["console_l"], 7.0)
    _wear_area(r["console_r"], 7.0)
    _wear_area(d, 9.0)
    _edge(Vector2(PILLAR_TOP_W + 10.0, 70.0), Vector2(PILLAR_TOP_W + 26.0, 104.0),
        1.0, COL_SCRATCH)
    _edge(Vector2(PILLAR_TOP_W + 20.0, 190.0), Vector2(PILLAR_TOP_W + 36.0, 218.0),
        1.0, COL_SCRATCH)
    _edge(Vector2(w - PILLAR_TOP_W - 10.0, 70.0), Vector2(w - PILLAR_TOP_W - 26.0, 104.0),
        1.0, COL_SCRATCH)
    _edge(Vector2(w - PILLAR_TOP_W - 20.0, 190.0), Vector2(w - PILLAR_TOP_W - 36.0, 218.0),
        1.0, COL_SCRATCH)


## 硬边粗线段：沿线方向的细四边形（不用 draw_line，避免抗锯齿）——
## 内缘勾边与风挡划痕用。与 _AttitudeGauge._thick_seg 同式，但那在内
## 部类里，外层框体自帶一份。
func _edge(p0: Vector2, p1: Vector2, w: float, col: Color) -> void:
    var dir := (p1 - p0).normalized()
    var nrm := Vector2(-dir.y, dir.x) * (w * 0.5)
    draw_colored_polygon(PackedVector2Array([
        p0 + nrm, p1 + nrm, p1 - nrm, p0 - nrm]), col)


## 左侧 console 细节：两道横缝 + 4×3 按键网格（三颗 LED）+ 内缘铆钉竖排。
func _left_console() -> void:
    draw_rect(Rect2(6.0, 330.0, CONSOLE_W - 12.0, 1.0), COL_SEAM, true)
    draw_rect(Rect2(6.0, 640.0, CONSOLE_W - 12.0, 1.0), COL_SEAM, true)
    var gx := 16.0
    var gy := 352.0
    draw_rect(Rect2(gx - 3.0, gy - 3.0, 46.0, 39.0), COL_SEAM, false, 1.0)
    var lit := {
        Vector2i(0, 1): COL_LED_G, Vector2i(1, 3): COL_LED_A,
        Vector2i(2, 0): COL_LED_R, Vector2i(2, 2): COL_LED_G,
    }
    for rr in range(3):
        for cc in range(4):
            var cell := Rect2(gx + cc * 10.0, gy + rr * 10.0, 7.0, 7.0)
            draw_rect(cell, lit.get(Vector2i(rr, cc), COL_KEY), true)
    for i in range(10):
        draw_rect(Rect2(CONSOLE_W - 4.0, 400.0 + i * 30.0, 2.0, 2.0), COL_RIVET, true)


## 右侧 console 细节：两道横缝 + 通风栅（5 道水平栅条）+ 两颗警告灯 +
## 内缘铆钉竖排（与左镜像）。
func _right_console() -> void:
    var x0 := size.x - CONSOLE_W
    draw_rect(Rect2(x0 + 6.0, 330.0, CONSOLE_W - 12.0, 1.0), COL_SEAM, true)
    draw_rect(Rect2(x0 + 6.0, 640.0, CONSOLE_W - 12.0, 1.0), COL_SEAM, true)
    for i in range(5):
        draw_rect(Rect2(x0 + 20.0, 352.0 + i * 7.0, 32.0, 2.0), COL_SEAM, true)
    draw_rect(Rect2(x0 + 24.0, 420.0, 5.0, 5.0), COL_LED_A, true)
    draw_rect(Rect2(x0 + 36.0, 420.0, 5.0, 5.0), COL_LED_R, true)
    for i in range(10):
        draw_rect(Rect2(x0 + 2.0, 400.0 + i * 30.0, 2.0, 2.0), COL_RIVET, true)


## 矩形区域内稀疏铺磨损点（step px 网格；亮/暗两极，概率 ~6%/5%）。
## 区域下的内容（如 dash 上的仪表）是子节点、后画，会被盖住——无浪费感。
func _wear_area(r: Rect2, step: float) -> void:
    var y := r.position.y + 2.0
    while y < r.end.y - 2.0:
        var x := r.position.x + 2.0
        while x < r.end.x - 2.0:
            _wear_dot(x, y)
            x += step
        y += step


## 风挡支柱斜边区域（side=+1 左 / −1 右）：只铺斜边以左（右）的梯形，
## 不越进世界开口。斜边方程 x_edge(y) = PILLAR_TOP_W + y·Δ/CONSOLE 差。
func _wear_pillar(side: float) -> void:
    var step := 6.0
    var y := FRAME_RAIL_H + 3.0
    while y < PILLAR_BASE_Y:
        var xe := PILLAR_TOP_W + (y / PILLAR_BASE_Y) * (CONSOLE_W - PILLAR_TOP_W)
        var x := 3.0
        while x < xe:
            _wear_dot(x if side > 0.0 else size.x - x, y)
            x += step
        y += step


## 单点磨损：坐标哈希（Vector2i hash 跨运行确定）→ 亮/暗/无三档。
func _wear_dot(x: float, y: float) -> void:
    var v := _wear01(x, y)
    if v > 0.94:
        draw_rect(Rect2(floorf(x), floorf(y), 1.0, 1.0), COL_WEAR, true)
    elif v < 0.05:
        draw_rect(Rect2(floorf(x), floorf(y), 1.0, 1.0), COL_WEAR_D, true)


## 确定性坐标哈希 → 0..1（静态帧共用：同一格永远同一结果，不随姿态闪烁）。
static func _wear01(x: float, y: float) -> float:
    var hv: int = hash(Vector2i(int(floorf(x)), int(floorf(y))))
    return float(abs(hv) % 1024) / 1024.0


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


## 座舱框各矩形（D-050/D-051，纯函数：_draw 与探针共用同一几何，勿改语义）。
## vp = 视口尺寸。dash 由簇常量派生——改簇尺寸不用手改这里的魔数。
## dash 顶沿在簇上方 DASH_PAD、底沿即屏底（座舱地板），四件仪表坐在其上。
## console 为风挡支柱以下的直壁段（斜边是多边形，见 _draw；其几何由
## PILLAR_TOP_W / PILLAR_BASE_Y / CONSOLE_W 三个常量决定）。
static func frame_rects(vp: Vector2) -> Dictionary:
    var w := vp.x
    var h := vp.y
    var rail := Rect2(0.0, 0.0, w, FRAME_RAIL_H)
    var console_l := Rect2(0.0, PILLAR_BASE_Y, CONSOLE_W, h - PILLAR_BASE_Y)
    var console_r := Rect2(w - CONSOLE_W, PILLAR_BASE_Y, CONSOLE_W, h - PILLAR_BASE_Y)
    var dash_w := TAPE_W + DASH_PAD * 2.0
    var dash_top := h - (MARGIN_B + GAUGE_SZ + 8.0 + TAPE_H + DASH_PAD)
    var dash := Rect2(w * 0.5 - dash_w * 0.5, dash_top, dash_w, h - dash_top)
    var lip := Rect2(dash.position.x, dash.position.y, dash.size.x, DASH_LIP)
    return {
        "rail": rail,
        "console_l": console_l,
        "console_r": console_r,
        "dash": dash,
        "lip": lip,
    }


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
        # 刻度：±70° 覆盖（带宽 600 / 5 = ±60° 视野，留标签余量）。
        # deg 先归一再取最短角差 → 359°→0° 无缝。
        var d0 := floori((_heading - 70.0) / 5.0) * 5
        var d1 := ceili((_heading + 70.0) / 5.0) * 5
        var d := d0
        while d <= d1:
            var major := posmod(d, 30) == 0
            var mid := posmod(d, 10) == 0
            var x := CockpitInstruments.tape_x(float(d), _heading, cx, TAPE_PPX)
            if x >= -24.0 and x <= s.x + 24.0:
                var th := 12.0 if major else (7.0 if mid else 4.0)
                var tw := 2.0 if major else 1.0
                draw_rect(Rect2(Vector2(roundf(x - tw * 0.5), 0.0), Vector2(tw, th)),
                    COL_MARK, true)
                if major:
                    var dd := wrapf(float(d), 0.0, 360.0)
                    var lbl := "N" if dd < 0.5 else ("E" if absf(dd - 90.0) < 0.5 \
                        else ("S" if absf(dd - 180.0) < 0.5 \
                        else ("W" if absf(dd - 270.0) < 0.5 else "%03d" % int(dd))))
                    draw_string(ThemeDB.fallback_font, Vector2(roundf(x), 16.0), lbl,
                        HORIZONTAL_ALIGNMENT_CENTER, 40.0, 12, COL_MARK)
            d += 5
        # 中间竖线（当前机头朝向）+ 顶部倒三角。
        draw_rect(Rect2(Vector2(roundf(cx - 1.0), 0.0), Vector2(2.0, TAPE_STRIP)),
            COL_MARK, true)
        draw_colored_polygon(PackedVector2Array([
            Vector2(cx - 6.0, 0.0), Vector2(cx + 6.0, 0.0), Vector2(cx, 6.0)]), COL_MARK)
        # 带下三位航向数。
        draw_string(ThemeDB.fallback_font, Vector2(cx, TAPE_STRIP + 3.0),
            "%03d°" % int(floorf(_heading)), HORIZONTAL_ALIGNMENT_CENTER, 140.0, 14, COL_MARK)


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
                var hl := 22.0 if pf >= 20.0 else 14.0
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
                var rh := 3.0 if major else 1.5
                var c0 := Vector2(sin(rad) * rr, -cos(rad) * rr)
                var rd := Vector2(sin(rad), -cos(rad))
                var td := Vector2(rd.y, -rd.x)
                var local := PackedVector2Array([
                    c0 - rd * rh - td * 1.5,
                    c0 + rd * rh - td * 1.5,
                    c0 + rd * rh + td * 1.5,
                    c0 - rd * rh + td * 1.5,
                ])
                var poly := PackedVector2Array()
                for v in local:
                    poly.append(wc + CockpitInstruments.rot2(a, v.x, v.y))
                draw_colored_polygon(poly, COL_MARK)
        # 固定层（不随姿态动）：顶部指针 + 窗框 + 小十字 + 飞机标记。
        draw_colored_polygon(PackedVector2Array([
            Vector2(wc.x - 5.0, win.position.y),
            Vector2(wc.x + 5.0, win.position.y),
            Vector2(wc.x, win.position.y + 7.0)]), COL_MARK)
        draw_rect(win, COL_MARK, false, 1.0)
        var cross := Color(1.0, 1.0, 1.0, 0.55)
        draw_rect(Rect2(Vector2(wc.x - 7.0, wc.y - 0.5), Vector2(14.0, 1.0)), cross, true)
        draw_rect(Rect2(Vector2(wc.x - 0.5, wc.y - 7.0), Vector2(1.0, 14.0)), cross, true)
        draw_rect(Rect2(Vector2(wc.x - 28.0, wc.y - 1.0), Vector2(20.0, 2.0)), COL_MARK, true)
        draw_rect(Rect2(Vector2(wc.x + 8.0, wc.y - 1.0), Vector2(20.0, 2.0)), COL_MARK, true)
        draw_rect(Rect2(Vector2(wc.x - 1.0, wc.y - 8.0), Vector2(2.0, 8.0)), COL_MARK, true)

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
        draw_string(ThemeDB.fallback_font, Vector2(-6.0, -5.0), txt,
            HORIZONTAL_ALIGNMENT_RIGHT, 30.0, 11, COL_MARK)
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
        draw_string(ThemeDB.fallback_font, Vector2(10.0, 13.0), _label,
            HORIZONTAL_ALIGNMENT_LEFT, -1, 12, COL_MARK)
        var col := COL_MARK
        if _warn:
            col = Color(COL_WARN.r, COL_WARN.g, COL_WARN.b,
                CockpitInstruments.blink_alpha(Time.get_ticks_msec()))
        draw_string(ThemeDB.fallback_font, Vector2(size.x * 0.5, size.y * 0.5 + 14.0), _value,
            HORIZONTAL_ALIGNMENT_CENTER, size.x - 12.0, 24, col)
