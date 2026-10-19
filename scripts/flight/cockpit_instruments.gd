class_name CockpitInstruments
extends Control
## 第一人称座舱 2D 像素仪表板（D-047 起，D-052 按战雷式重做）。
##
## 与 D-034 两套既有实现的分工（都不替代、都不冲突）：
##   · CockpitPanel（3D 仪表板，低头可见）——本文件不碰它；
##   · flight_instrument_hud 的玻璃文字带——本文件接管它：高度/航向/俯仰进
##     仪表，速度进 SPD 盘，信息不丢。
##
## 像素风约定（用户 spec，勿平滑化）：黑盘面 + 白色硬边刻度；图形一律用
## draw_rect / draw_colored_polygon / draw_circle(antialiased=false) 拼，
## 细线用「细多边形」而非 draw_line（避免抗锯齿）；参考战雷老式仪表。
##
## 四件仪表（用户 spec：地平仪 / 高度计 / 航向仪 / 空速）——
##   地平仪：底层天地（俯仰→垂直偏移、横滚→整体旋转、±60° 钳制截断不
##     无限滚动），上层固定十字 + 飞机标记不随姿态动；带俯仰阶梯与横滚刻度。
##   高度计：白色数字（ALT 4500m）；高度过低（FlightInstruments.alt_warn>0）
##     变红并按 600ms 周期闪烁。
##   航向仪：横向刻度带按航向水平滚动（359°→0° 取模连续不跳变），中央指针
##     标记机头朝向，带下附三位航向数。
##   空速：与高度计同款表盘（D-052 新增对称的另一半，D-034 的 SPD 读数）。
##
## 渲染层级：本控件是屏幕 HUD 覆盖层的子节点（最上层 2D 层），叠加在
## 座舱 3D 视野之上——纯 2D 绘制，不用 3D / ViewportTexture（用户 spec）。
##
## D-050：本控件同时画「驾驶舱像素内装」——顶檐 + 风挡支柱 + 侧 console +
## 仪表 dash 底板。第一人称下 3D 外部机模被隐藏（aircraft.set_cockpit_interior），
## 座舱内装完全由这层 2D 像素框提供，世界从框内开口看去。
##
## D-051：用户「仪表簇太大」→整体回缩；「更浓座舱感」→风挡支柱/侧 console/
## 磨损细节。
##
## D-052（用户：「当前 3D 驾驶舱缺陷较多，仪表部分显示尺寸不合理，参考战雷
## 游戏设计修改」）——根因与对策：
##   ① **比例失衡 + 留白失控**（观感主因）：D-047~D-051 的 SPD/ALT 是两个
##      「空黑方框」——150×116 的框里只放一个 24px 数字，信息占面积不到
##      24%，其余全空；而最重要的地平仪只有 148 见方、内部却塞满阶梯与
##      刻度。主次不分、密度两极，就是「尺寸不合理」的直觉来源。
##      改：SPD/ALT 换成战雷式圆盘（金属压环 + 黑盘面 + 环形刻度 + 琥珀
##      指针 + 盘下中央数字窗），地平仪改圆盘并升为主仪表（最大、居中）。
##   ② **姿态仪是方的、刻度糊成一团**：改圆形表盘（圆 ∩ 地平线半平面裁剪，
##      天地圆内截断），阶梯线/地平线一律裁进圆，横滚刻度沿盘内缘。
##   ③ **仪表面板像黑板**：dash 由纯黑改金属灰（拉丝横纹/螺钉/凹陷阴影环），
##      航向带由裸刻度改罗盘带（上下金属条 + 两端渐隐 + 琥珀指针 + 带下
##      数字牌）；盘排两侧补 THR/FUEL 竖条，填掉两侧空洞。
##   ④ **比例会随宽高比漂移**（次要但真实）：项目用 stretch=canvas_items +
##      aspect=expand，逻辑视口宽恒 1280、但**高度随宽高比在 590~720 之间
##      漂移**（19.5:9 手机实测 1280×590）。固定像素下仪表占屏高会从 21%
##      漂到 26%。改为「基准视口 + 等比缩放 s」（metrics(vp)）后，任何
##      宽高比都锁在 21%。
##   座舱框同步：顶檐加厚、console 收窄（少挡视野）、框体提亮到能在夜空里
##   看出结构、内缘 3px 高光、console 加检查单夹/开关排。
##
## ⚠️ 基准尺寸刻意维持 D-051「仪表簇太大了，缩小」后的量级（主表 148→152，
## 因为圆盘比方框视觉更紧、可略大一点点）：用户明确要求过一次「缩小」，
## 改版不得借「战雷化」把它又顶回去。

# ── 分辨率基准（D-052）──────────────────────────────────────────
## 基准视口 = project.godot 的 viewport_width/height（stretch=canvas_items
## 下这就是逻辑视口尺寸）。所有布局常量都写「这套基准下的实际像素」，
## 运行期实际值 = 基准值 × 缩放因子 s（s 由更窄的一边决定）。
const REF_VP := Vector2(1280.0, 720.0)
## 缩放上下限：太小（<0.7）刻度会糊成一片，太大（>2.8）面板会压掉视野。
const SCALE_MIN := 0.70
const SCALE_MAX := 2.80

# ── 配色（黑盘面白刻度 + 低饱和天地色 + 琥珀指针，战雷座舱色系）──────
const COL_BEZEL := Color(0.055, 0.06, 0.07)       # 仪表盘面（近黑，非纯黑）
const COL_RING := Color(0.30, 0.32, 0.37)         # 金属压环（受光面）
const COL_RING_D := Color(0.12, 0.13, 0.16)       # 压环暗部
const COL_MARK := Color(0.97, 0.97, 1.0)          # 白刻度 / 白字
const COL_MARK_DIM := Color(0.52, 0.54, 0.58)     # 次刻度 / 单位字
const COL_POINTER := Color(1.0, 0.72, 0.20)       # 琥珀指针 / 飞机标记
const COL_SKY := Color(0.30, 0.50, 0.80)
const COL_GROUND := Color(0.46, 0.36, 0.24)
const COL_WARN := Color(0.95, 0.30, 0.26)

# ── 簇布局基准（s=1，即 1280×720；全部自屏幕底边起算）─────────────
## 主表 152 + 边距 12 + 8 + 航向带 56 + 8 → dash 占屏底 236 px（32.8%），
## 与 D-051 交付的 30% 同一量级（用户要求过「缩小」，见文件头警告）。
const MARGIN_B := 12.0     # 簇底距屏幕底
const GAUGE_SZ := 152.0    # 地平仪外径（圆，最主仪表）
const SIDE_SZ := 140.0     # 空速/高度盘外径
const BEZEL := 9.0         # 金属压环总厚（含 3px 受光边）
const GAUGE_GAP := 20.0    # 盘与盘之间的间隙
const TAPE_W := 600.0      # 航向带宽（= D-051，不许再长）
const TAPE_H := 56.0       # 航向带总高（3 上条 + 34 刻度窗 + 数字窗）
const TAPE_STRIP := 34.0   # 刻度窗高
const TAPE_PPX := 5.0      # 航向带像素/度（600px ≈ ±60° 视野）
const DASH_PAD := 18.0     # dash 底板左右出簇外的 padding
const DASH_LIP := 4.0      # dash 顶沿受光条厚
const BAR_W := 32.0        # 油门/燃油竖条宽
## 盘排竖向压缩比（D-053）：用户圈出「盘排区」要求高度缩小 1/3。
## 只压盘排本身（表盘直径、盘间距、簇底留白、竖条宽）——航向带与 dash 宽
## 都不动：宽度由 TAPE_W 决定，用户没有要求收窄，收窄反而让航向带溢出底板。
## 表盘内部的像素细节（压环厚、字号、指针长、阶梯线）不在这里乘，而是各自
## 按「盘径 / 设计稿尺寸」取尺（见各 _draw() 的 `var s := sz / ...`），
## 否则会出现「小盘配 25px 大字」糊出盘外。
const GAUGE_K := 2.0 / 3.0
const PITCH_MAX := 60.0    # 俯仰钳制（用户 spec：超过截断、不无限滚动）
const BLINK_MS := 600.0    # 闪烁周期（与警告横幅一致）
const LADDER := [10.0, 20.0, 30.0]            # 俯仰阶梯标注角（度）
const ROLL_TICKS := [0.0, 10.0, 20.0, 30.0, 45.0, 60.0]  # 横滚刻度（正=右滚）
## SPD / ALT 盘量程（刻度用；数字窗永远显示真实值，超量程指针停满偏）。
## ALT 取 1000 m：儿童向飞行几乎全在 300 m 以下，0..2000 会让指针长期贴着
## 最低刻度不动（首版实测 48 m 时指针几乎「死了」）。
const SPD_MAX := 250.0
const ALT_MAX := 1000.0

# ── 座舱像素内装基准（s=1）───────────────────────────────────────
const FRAME_RAIL_H := 20.0   # 顶檐高（D-051 的 12 在夜空里几乎看不见）
const FRAME_EDGE := 3.0      # 框体内侧勾边宽
const CONSOLE_W := 92.0      # 侧 console 宽（D-051 是 120，吃了 11% 屏宽）
const PILLAR_TOP_W := 44.0   # 风挡支柱顶端半距（斜边起点）
const PILLAR_BASE_Y := 320.0 # 斜边收敛纵坐标（以下为直 console 壁）
const COL_FRAME := Color(0.09, 0.10, 0.13)         # 座舱框体（顶檐/风挡支柱）
const COL_FRAME_EDGE := Color(0.27, 0.29, 0.35)    # 框体内侧勾边
const COL_DASH := Color(0.145, 0.155, 0.185)       # 仪表板金属（D-052 提亮）
const COL_DASH_HI := Color(0.22, 0.235, 0.275)     # 板面受光条
const COL_DASH_LO := Color(0.085, 0.095, 0.115)    # 板面暗边/凹陷
const COL_STRUCT := Color(0.115, 0.125, 0.155)     # 侧 console 面板
const COL_SEAM := Color(0.22, 0.23, 0.27)          # 面板缝线 / 通风栅
const COL_RIVET := Color(0.40, 0.42, 0.47)         # 铆钉
const COL_KEY := Color(0.09, 0.10, 0.12)           # 按键（未点亮）
const COL_LED_G := Color(0.35, 0.85, 0.45)         # 按键 LED（绿）
const COL_LED_A := Color(0.95, 0.75, 0.25)         # 按键 LED（琥珀）
const COL_LED_R := Color(0.90, 0.32, 0.28)         # 按键 LED（红）
const COL_WEAR := Color(1.0, 1.0, 1.0, 0.10)       # 磨损亮点点
const COL_WEAR_D := Color(0.0, 0.0, 0.0, 0.35)     # 磨损暗点点
const COL_SCRATCH := Color(1.0, 1.0, 1.0, 0.16)    # 风挡划痕
const COL_PLATE_TXT := Color(0.52, 0.55, 0.60)     # 面板铭牌小字

## 六件子控件（公开供探针取几何矩形；tape/gauge/alt_box/spd_box 沿用
## D-047 命名，探针契约不变）。
var tape: _HeadingTape = null
var gauge: _AttitudeGauge = null
var alt_box: _RoundGauge = null
var spd_box: _RoundGauge = null
var thr_bar: _VBar = null
var fuel_bar: _VBar = null

## 当前生效的缩放因子（_relayout 写入，_draw 与子控件共用）。
var _s := 1.0


func _ready() -> void:
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    tape = _HeadingTape.new()
    gauge = _AttitudeGauge.new()
    alt_box = _RoundGauge.new()
    alt_box.set_range(ALT_MAX)
    spd_box = _RoundGauge.new()
    spd_box.set_range(SPD_MAX)
    thr_bar = _VBar.new()
    fuel_bar = _VBar.new()
    for n in [tape, gauge, spd_box, alt_box, thr_bar, fuel_bar]:
        add_child(n)
    # 分辨率自适应：视口变化（窗口缩放 / 手机旋转）必须重排，否则仪表会
    # 停在旧分辨率的位置上（D-052 的核心修复）。
    resized.connect(_relayout)
    _relayout()


## 按当前 size 重排六件子控件并重绘内装。锚点全 0 + 绝对偏移：本控件铺满
## 全屏，metrics 返回的已经是屏幕绝对坐标，渲染与探针断言用同一份几何。
func _relayout() -> void:
    var m := metrics(size)
    _s = float(m["s"])
    _set_rect(tape, m["tape"])
    _set_rect(gauge, m["gauge"])
    _set_rect(spd_box, m["spd"])
    _set_rect(alt_box, m["alt"])
    _set_rect(thr_bar, m["thr"])
    _set_rect(fuel_bar, m["fuel"])
    for n in [tape, gauge, spd_box, alt_box, thr_bar, fuel_bar]:
        n.set_scale_hint(_s)
    queue_redraw()


func _set_rect(node: Control, r: Rect2) -> void:
    node.anchor_left = 0.0
    node.anchor_top = 0.0
    node.anchor_right = 0.0
    node.anchor_bottom = 0.0
    node.offset_left = r.position.x
    node.offset_top = r.position.y
    node.offset_right = r.position.x + r.size.x
    node.offset_bottom = r.position.y + r.size.y


## 座舱像素内装绘制（D-050/D-051/D-052）：先画框体与 dash 底板，六件仪表
## 作为子控件永远画在其后——视觉上仪表「嵌在金属板上、板在座舱里」。
## 全部静态（尺寸不变不重绘）。
func _draw() -> void:
    var m := metrics(size)
    var s := float(m["s"])
    var w := size.x
    var h := size.y
    var rail: Rect2 = m["rail"]
    var dash: Rect2 = m["dash"]
    var lip: Rect2 = m["lip"]
    var cl: Rect2 = m["console_l"]
    var cr: Rect2 = m["console_r"]
    var ptw := float(m["pillar_top_w"])
    var pby := float(m["pillar_base_y"])
    var col_w := float(m["console_w"])

    # ① 风挡支柱 + 侧 console：斜边自顶檐 (ptw, 0) 内收到 (col_w, pby)，
    #    以下转直壁——世界从两道斜边之间望去。
    draw_colored_polygon(PackedVector2Array([
        Vector2(0.0, 0.0), Vector2(ptw, 0.0),
        Vector2(col_w, pby), Vector2(col_w, h), Vector2(0.0, h),
    ]), COL_STRUCT)
    draw_colored_polygon(PackedVector2Array([
        Vector2(w, 0.0), Vector2(w - ptw, 0.0),
        Vector2(w - col_w, pby), Vector2(w - col_w, h), Vector2(w, h),
    ]), COL_STRUCT)
    # ② dash 金属板：底色 → 暗下沿 → 拉丝横纹 → 顶沿受光条。
    draw_rect(dash, COL_DASH, true)
    draw_rect(Rect2(dash.position.x, dash.end.y - 3.0 * s, dash.size.x, 3.0 * s),
        COL_DASH_LO, true)
    var yarn := dash.position.y + 10.0 * s
    while yarn < dash.end.y - 6.0 * s:
        draw_rect(Rect2(dash.position.x + 2.0 * s, yarn, dash.size.x - 4.0 * s,
            1.0), Color(1.0, 1.0, 1.0, 0.028), true)
        yarn += 7.0 * s
    draw_rect(lip, COL_DASH_HI, true)
    draw_rect(Rect2(lip.position.x, lip.end.y, lip.size.x, 2.0 * s),
        COL_DASH_LO, true)
    # ③ 顶檐 + 底沿勾边。
    draw_rect(rail, COL_FRAME, true)
    draw_rect(Rect2(0.0, rail.end.y - FRAME_EDGE * s, w, FRAME_EDGE * s),
        COL_FRAME_EDGE, true)
    draw_rect(Rect2(0.0, rail.end.y - FRAME_EDGE * s - 1.0 * s, w, 1.0 * s),
        Color(0.0, 0.0, 0.0, 0.45), true)
    # ④ 斜边与直壁的内缘高光（四道「框住世界」的亮边，3px 宽）。
    var ew := FRAME_EDGE * s
    _edge(Vector2(ptw + 1.5 * s, rail.end.y), Vector2(col_w + 1.5 * s, pby),
        ew, COL_FRAME_EDGE)
    _edge(Vector2(col_w + 0.5 * s, pby), Vector2(col_w + 0.5 * s, h),
        ew, COL_FRAME_EDGE)
    _edge(Vector2(w - ptw - 1.5 * s, rail.end.y), Vector2(w - col_w - 1.5 * s, pby),
        ew, COL_FRAME_EDGE)
    _edge(Vector2(w - col_w - 0.5 * s, pby), Vector2(w - col_w - 0.5 * s, h),
        ew, COL_FRAME_EDGE)
    # ⑤ dash 四周的凹陷阴影环：板与框之间一道暗缝，让板「嵌」进座舱。
    draw_rect(Rect2(dash.position.x - 2.0 * s, dash.position.y - 1.0 * s,
        dash.size.x + 4.0 * s, 2.0 * s), Color(0.0, 0.0, 0.0, 0.5), true)
    # ⑥ 侧 console 细节。
    _left_console(cl, s)
    _right_console(cr, s)
    # ⑦ dash 上的硬件：铭牌、螺钉、警示灯排。
    _dash_hardware(dash, s)
    # ⑦b 封板（D-053）：盘排压缩 1/3 后，竖条与侧盘之间各空出约 100×93 的
    #     平铁皮。战雷老座舱在这种位置就是「未装仪表的封板」——一块略暗的
    #     凹陷钢板 + 四颗螺钉 + 一道压印槽，比留一片光板更像实物，也不抢
    #     仪表读数（低对比度、无文字）。
    var thr_r: Rect2 = m["thr"]
    var spd_r: Rect2 = m["spd"]
    var alt_r: Rect2 = m["alt"]
    var fuel_r: Rect2 = m["fuel"]
    var inset := 10.0 * s
    _blank_plate(Rect2(thr_r.end.x + inset, thr_r.position.y,
        spd_r.position.x - inset - (thr_r.end.x + inset), thr_r.size.y), s)
    _blank_plate(Rect2(alt_r.end.x + inset, alt_r.position.y,
        fuel_r.position.x - inset - (alt_r.end.x + inset), alt_r.size.y), s)
    # ⑧ 磨损：确定性噪点 + 风挡斜边划痕。只落在框体结构上——世界开口与
    #    dash 上的仪表区不铺（仪表是子节点，画在噪点上）。
    _wear_area(Rect2(0.0, 0.0, w, rail.size.y), 7.0 * s)
    _wear_pillar(m, 1.0)
    _wear_pillar(m, -1.0)
    _wear_area(cl, 7.0 * s)
    _wear_area(cr, 7.0 * s)
    _wear_area(dash, 9.0 * s)
    _edge(Vector2(ptw + 10.0 * s, 70.0 * s), Vector2(ptw + 26.0 * s, 104.0 * s),
        1.0, COL_SCRATCH)
    _edge(Vector2(ptw + 20.0 * s, 190.0 * s), Vector2(ptw + 36.0 * s, 218.0 * s),
        1.0, COL_SCRATCH)
    _edge(Vector2(w - ptw - 10.0 * s, 70.0 * s), Vector2(w - ptw - 26.0 * s, 104.0 * s),
        1.0, COL_SCRATCH)
    _edge(Vector2(w - ptw - 20.0 * s, 190.0 * s), Vector2(w - ptw - 36.0 * s, 218.0 * s),
        1.0, COL_SCRATCH)


## dash 板面硬件（D-052）：四角与沿边螺钉。铭牌由各竖条自己画在条顶——
## 放到 dash 顶沿会压住航向带（首版实测：THR 牌正落在带的渐隐区上）。
func _dash_hardware(dash: Rect2, s: float) -> void:
    var rv := 2.2 * s
    for px in [dash.position.x + 7.0 * s, dash.end.x - 7.0 * s]:
        for py in [dash.position.y + 7.0 * s, dash.end.y - 7.0 * s]:
            draw_rect(Rect2(px - rv * 0.5, py - rv * 0.5, rv, rv), COL_RIVET, true)
    var rx := dash.position.x + 60.0 * s
    while rx < dash.end.x - 60.0 * s:
        draw_rect(Rect2(rx, dash.position.y + 6.0 * s, rv, rv), COL_RIVET, true)
        rx += 120.0 * s


## 封板（D-053）：未装仪表的方孔盖板。**只比板面暗一档**（首版取 0.112
## 比 COL_DASH 0.145 暗 23%，实拍像两块挖空的洞）——凹陷感靠一道内黑缝 +
## 上沿受光 + 四颗角螺钉给，不靠压深底色。
func _blank_plate(r: Rect2, s: float) -> void:
    if r.size.x < 16.0 * s or r.size.y < 16.0 * s:
        return
    draw_rect(r, Color(0.133, 0.137, 0.148), true)
    draw_rect(r, Color(0.0, 0.0, 0.0, 0.30), false, maxf(1.0, s))
    draw_rect(Rect2(r.position.x + 1.0 * s, r.position.y + 1.0 * s,
        r.size.x - 2.0 * s, 1.0 * s), Color(1.0, 1.0, 1.0, 0.05), true)
    draw_rect(Rect2(r.position.x + 1.0 * s, r.end.y - 2.0 * s,
        r.size.x - 2.0 * s, 1.0 * s), Color(0.0, 0.0, 0.0, 0.22), true)
    var rv := 2.2 * s
    for px in [r.position.x + 6.0 * s, r.end.x - 6.0 * s]:
        for py in [r.position.y + 6.0 * s, r.end.y - 6.0 * s]:
            draw_rect(Rect2(px - rv * 0.5, py - rv * 0.5, rv, rv), COL_RIVET, true)


## 硬边粗线段：沿线方向的细四边形（不用 draw_line，避免抗锯齿）——
## 内缘勾边与风挡划痕用。
func _edge(p0: Vector2, p1: Vector2, w: float, col: Color) -> void:
    var dir := (p1 - p0).normalized()
    var nrm := Vector2(-dir.y, dir.x) * (w * 0.5)
    draw_colored_polygon(PackedVector2Array([
        p0 + nrm, p1 + nrm, p1 - nrm, p0 - nrm]), col)


## 左侧 console 细节（D-052 升级）：两道横缝 + 开关排 + 4×3 按键网格
## （带 LED）+ 检查单夹（战雷座舱标志件）+ 内缘铆钉竖排。
func _left_console(r: Rect2, s: float) -> void:
    var x0 := r.position.x
    var y := r.position.y
    draw_rect(Rect2(x0 + 5.0 * s, y + 26.0 * s, r.size.x - 10.0 * s, 1.0 * s),
        COL_SEAM, true)
    draw_rect(Rect2(x0 + 5.0 * s, y + 158.0 * s, r.size.x - 10.0 * s, 1.0 * s),
        COL_SEAM, true)
    # 检查单夹：一块带纸的卡夹（左 console 上半）。
    var clip := Rect2(x0 + 10.0 * s, y + 40.0 * s, r.size.x - 20.0 * s, 46.0 * s)
    draw_rect(clip, Color(0.20, 0.20, 0.21), true)
    draw_rect(Rect2(clip.position.x + 2.0 * s, clip.position.y + 4.0 * s,
        clip.size.x - 4.0 * s, clip.size.y - 8.0 * s), Color(0.62, 0.60, 0.52), true)
    for i in range(4):
        draw_rect(Rect2(clip.position.x + 5.0 * s, clip.position.y + (10.0 + float(i) * 8.0) * s,
            clip.size.x - 12.0 * s, 1.0 * s), Color(0.35, 0.34, 0.30), true)
    draw_rect(Rect2(clip.end.x - 9.0 * s, clip.position.y - 2.0 * s, 6.0 * s, 6.0 * s),
        COL_RIVET, true)
    # 开关排（三只拨杆）。
    for i in range(3):
        var sx := x0 + 14.0 * s + float(i) * 16.0 * s
        draw_rect(Rect2(sx, y + 100.0 * s, 8.0 * s, 16.0 * s), COL_KEY, true)
        draw_rect(Rect2(sx + 3.0 * s, y + 96.0 * s, 2.0 * s, 8.0 * s), COL_RIVET, true)
    # 4×3 按键网格（四颗 LED）。
    var gx := x0 + 16.0 * s
    var gy := y + 128.0 * s
    draw_rect(Rect2(gx - 3.0 * s, gy - 3.0 * s, 46.0 * s, 39.0 * s), COL_SEAM, false,
        maxf(1.0, s))
    var lit := {
        Vector2i(0, 1): COL_LED_G, Vector2i(1, 3): COL_LED_A,
        Vector2i(2, 0): COL_LED_R, Vector2i(2, 2): COL_LED_G,
    }
    for rr in range(3):
        for cc in range(4):
            var cell := Rect2(gx + float(cc) * 10.0 * s, gy + float(rr) * 10.0 * s,
                7.0 * s, 7.0 * s)
            draw_rect(cell, lit.get(Vector2i(rr, cc), COL_KEY), true)
    for i in range(9):
        draw_rect(Rect2(r.end.x - 5.0 * s, y + 190.0 * s + float(i) * 30.0 * s,
            2.0 * s, 2.0 * s), COL_RIVET, true)


## 右侧 console 细节：两道横缝 + 通风栅（5 道）+ 两颗警告灯 + 断路器排 +
## 内缘铆钉竖排（与左镜像）。
func _right_console(r: Rect2, s: float) -> void:
    var x0 := r.position.x
    var y := r.position.y
    draw_rect(Rect2(x0 + 5.0 * s, y + 26.0 * s, r.size.x - 10.0 * s, 1.0 * s),
        COL_SEAM, true)
    draw_rect(Rect2(x0 + 5.0 * s, y + 158.0 * s, r.size.x - 10.0 * s, 1.0 * s),
        COL_SEAM, true)
    for i in range(5):
        draw_rect(Rect2(x0 + 18.0 * s, y + (40.0 + float(i) * 7.0) * s,
            34.0 * s, 2.0 * s), COL_SEAM, true)
    draw_rect(Rect2(x0 + 22.0 * s, y + 84.0 * s, 6.0 * s, 6.0 * s), COL_LED_A, true)
    draw_rect(Rect2(x0 + 34.0 * s, y + 84.0 * s, 6.0 * s, 6.0 * s), COL_LED_R, true)
    # 断路器排（两列小方块）。
    for rr in range(4):
        for cc in range(2):
            draw_rect(Rect2(x0 + 16.0 * s + float(cc) * 22.0 * s,
                y + (110.0 + float(rr) * 14.0) * s, 14.0 * s, 9.0 * s), COL_KEY, true)
    for i in range(9):
        draw_rect(Rect2(x0 + 3.0 * s, y + 190.0 * s + float(i) * 30.0 * s,
            2.0 * s, 2.0 * s), COL_RIVET, true)


## 矩形区域内稀疏铺磨损点（step px 网格；亮/暗两极）。
func _wear_area(r: Rect2, step: float) -> void:
    var y := r.position.y + 2.0
    while y < r.end.y - 2.0:
        var x := r.position.x + 2.0
        while x < r.end.x - 2.0:
            _wear_dot(x, y)
            x += step
        y += step


## 风挡支柱斜边区域（side=+1 左 / −1 右）：只铺斜边外侧的梯形。
func _wear_pillar(m: Dictionary, side: float) -> void:
    var step := 6.0 * float(m["s"])
    var ptw := float(m["pillar_top_w"])
    var col_w := float(m["console_w"])
    var pby := float(m["pillar_base_y"])
    var rail_b := float(m["rail"].end.y)
    var y := rail_b + 3.0 * float(m["s"])
    while y < pby:
        var t := (y - rail_b) / maxf(pby - rail_b, 1e-3)
        var xe := ptw + t * (col_w - ptw)
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
    thr_bar.set_bar("THR", fi.throttle, fi.throttle < 0.01)
    fuel_bar.set_bar("FUEL", fi.fuel_ratio, fi.fuel_low or fi.fuel_empty)


## 调试/探针快照：六件控件的关键状态（文案 + 警告灯 + 姿态角 + 竖条）。
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
        "thr": thr_bar._ratio,
        "fuel": fuel_bar._ratio,
        "scale": _s,
    }


# ── 纯函数（探针直接断言，勿改语义）─────────────────────────────

## 统一缩放因子：宽度与高度各自相对基准的较小者（保证不溢出），钳进上下限。
## 1080×608 → 1.0；1920×1080 → 1.777（仪表占屏比例与设计稿一致）。
static func ui_scale(vp: Vector2) -> float:
    if vp.x < 1.0 or vp.y < 1.0:
        return 1.0
    return clampf(minf(vp.x / REF_VP.x, vp.y / REF_VP.y), SCALE_MIN, SCALE_MAX)


## 全部布局几何（D-052）：渲染、_relayout、探针共用这一份。返回屏幕绝对
## 坐标的 Rect2，键：s / rail / console_l / console_r / dash / lip / tape /
## gauge / spd / alt / thr / fuel / pillar_top_w / pillar_base_y / console_w。
static func metrics(vp: Vector2) -> Dictionary:
    var v := vp
    if v.x < 1.0 or v.y < 1.0:
        v = REF_VP
    var s := ui_scale(v)
    var w := v.x
    var h := v.y
    var cx := w * 0.5
    var margin_b := MARGIN_B * GAUGE_K * s
    var gsz := GAUGE_SZ * GAUGE_K * s
    var ssz := SIDE_SZ * GAUGE_K * s
    var gap := GAUGE_GAP * GAUGE_K * s
    var tape_w := TAPE_W * s
    var tape_h := TAPE_H * s
    # 盘排（自屏底向上）：主表居中，两侧盘与之垂直居中。
    var row_h := margin_b + gsz
    var gauge := Rect2(cx - gsz * 0.5, h - row_h, gsz, gsz)
    var side_t := margin_b + (gsz - ssz) * 0.5
    var spd := Rect2(cx - gsz * 0.5 - gap - ssz, h - (side_t + ssz), ssz, ssz)
    var alt := Rect2(cx + gsz * 0.5 + gap, h - (side_t + ssz), ssz, ssz)
    # 航向带压在盘排上方 8 px。
    var tape_b := row_h + 8.0 * s
    var tape := Rect2(cx - tape_w * 0.5, h - (tape_b + tape_h), tape_w, tape_h)
    # dash 底板：宽度包住航向带 + padding，高度到屏底（座舱地板）。
    var dash_w := tape_w + DASH_PAD * 2.0 * s
    var dash_h := tape_b + tape_h + 8.0 * s
    var dash := Rect2(cx - dash_w * 0.5, h - dash_h, dash_w, dash_h)
    var lip := Rect2(dash.position.x, dash.position.y, dash.size.x, DASH_LIP * s)
    # 油门 / 燃油竖条贴 dash 内沿（填掉盘排两侧的空洞）。
    var bw := BAR_W * GAUGE_K * s
    var thr := Rect2(dash.position.x + 16.0 * s, h - (side_t + ssz), bw, ssz)
    var fuel := Rect2(dash.end.x - 16.0 * s - bw, h - (side_t + ssz), bw, ssz)
    # 座舱框体。
    var rail_h := FRAME_RAIL_H * s
    var col_w := CONSOLE_W * s
    var pby := PILLAR_BASE_Y * s
    return {
        "s": s,
        "rail": Rect2(0.0, 0.0, w, rail_h),
        "console_l": Rect2(0.0, pby, col_w, maxf(0.0, h - pby)),
        "console_r": Rect2(w - col_w, pby, col_w, maxf(0.0, h - pby)),
        "dash": dash,
        "lip": lip,
        "tape": tape,
        "gauge": gauge,
        "spd": spd,
        "alt": alt,
        "thr": thr,
        "fuel": fuel,
        "pillar_top_w": PILLAR_TOP_W * s,
        "pillar_base_y": pby,
        "console_w": col_w,
    }


## 座舱框矩形（D-050 起的探针契约名，内部转 metrics；勿改语义）。
static func frame_rects(vp: Vector2) -> Dictionary:
    var m := metrics(vp)
    return {
        "rail": m["rail"],
        "console_l": m["console_l"],
        "console_r": m["console_r"],
        "dash": m["dash"],
        "lip": m["lip"],
    }


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


## 警告闪烁 alpha（t_ms 为毫秒时标）：0.55..1.0，600ms 周期。
## 最低值取 0.55 而不是 0.35：0.35 的暗红落在近黑数字窗上几乎看不见
## （D-052 截图实测：低空警告的 ALT 数字「若有若无」），警告等于没警告。
static func blink_alpha(t_ms: float) -> float:
    var phase := fmod(t_ms, BLINK_MS) / BLINK_MS
    return 0.55 + 0.45 * absf(sin(phase * PI))


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


## 线段 × 圆裁剪（D-052 圆盘用）：返回圆内的子段（0 或 2 点）。
static func clip_seg_circle(p0: Vector2, p1: Vector2, c: Vector2, r: float) -> PackedVector2Array:
    var d := p1 - p0
    var f := p0 - c
    var a := d.dot(d)
    if a < 1e-12:
        return PackedVector2Array()
    var b := 2.0 * f.dot(d)
    var cc := f.dot(f) - r * r
    var disc := b * b - 4.0 * a * cc
    if disc <= 0.0:
        if f.length() <= r and (p1 - c).length() <= r:
            return PackedVector2Array([p0, p1])
        return PackedVector2Array()
    var sq := sqrt(disc)
    var lo := maxf((-b - sq) / (2.0 * a), 0.0)
    var hi := minf((-b + sq) / (2.0 * a), 1.0)
    if lo >= hi:
        return PackedVector2Array()
    return PackedVector2Array([p0 + d * lo, p0 + d * hi])


## 圆的凸多边形近似（顺时针）：供「圆 ∩ 半平面」地面填充用。
static func circle_poly(c: Vector2, r: float, n: int = 64) -> PackedVector2Array:
    var out := PackedVector2Array()
    for i in range(n):
        var a := TAU * float(i) / float(n)
        out.append(c + Vector2(cos(a), sin(a)) * r)
    return out


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


## 从 "4500m" 这类读数里拆出数字段与单位段（探针契约保留完整字符串，
## 绘制时数字与单位要分行排）。返回 [数字, 单位]。
static func split_value(v: String) -> Array:
    var i := 0
    while i < v.length():
        var ch := v[i]
        if ch == "-" or ch == "." or (ch >= "0" and ch <= "9"):
            i += 1
        else:
            break
    return [v.substr(0, i), v.substr(i)]


# ── 航向仪：罗盘带（D-052 战雷式）──────────────────────────────
class _HeadingTape extends Control:
    var _heading := 0.0
    var _s := 1.0

    func set_scale_hint(s: float) -> void:
        if not is_equal_approx(_s, s):
            _s = s
            queue_redraw()

    func set_heading(h: float) -> void:
        _heading = wrapf(h, 0.0, 360.0)
        queue_redraw()

    func _draw() -> void:
        var s := _s
        var w := size.x
        var h := size.y
        var strip_h := TAPE_STRIP * s
        # 上下金属条 + 中间黑窗（战雷罗盘带的「镶框」感）。
        draw_rect(Rect2(0.0, 0.0, w, h), COL_RING_D, true)
        draw_rect(Rect2(0.0, 0.0, w, 3.0 * s), COL_RING, true)
        draw_rect(Rect2(0.0, h - 3.0 * s, w, 3.0 * s), COL_RING_D, true)
        draw_rect(Rect2(0.0, h - 1.0 * s, w, 1.0 * s), COL_RING, true)
        draw_rect(Rect2(0.0, 3.0 * s, w, strip_h), COL_BEZEL, true)
        var digit_y := 3.0 * s + strip_h
        draw_rect(Rect2(0.0, digit_y, w, h - digit_y - 3.0 * s), COL_BEZEL, true)
        draw_rect(Rect2(0.0, digit_y, w, 1.0 * s), COL_SEAM, true)
        # 刻度：±70° 覆盖（带宽 640 / 5.33 = ±60° 视野，留标签余量）。
        var cx := w * 0.5
        var d0 := floori((_heading - 70.0) / 5.0) * 5
        var d1 := ceili((_heading + 70.0) / 5.0) * 5
        var d := d0
        while d <= d1:
            var major := posmod(d, 30) == 0
            var mid := posmod(d, 10) == 0
            var x := CockpitInstruments.tape_x(float(d), _heading, cx, TAPE_PPX * s)
            if x >= -24.0 * s and x <= w + 24.0 * s:
                var th := (16.0 if major else (10.0 if mid else 6.0)) * s
                var tw := (2.0 if major else 1.0) * s
                draw_rect(Rect2(roundf(x - tw * 0.5), 3.0 * s + strip_h - th,
                    tw, th), COL_MARK if major else COL_MARK_DIM, true)
                if major:
                    var dd := wrapf(float(d), 0.0, 360.0)
                    var lbl := "N" if dd < 0.5 else ("E" if absf(dd - 90.0) < 0.5 \
                        else ("S" if absf(dd - 180.0) < 0.5 \
                        else ("W" if absf(dd - 270.0) < 0.5 else "%03d" % int(dd))))
                    draw_string(ThemeDB.fallback_font,
                        Vector2(roundf(x), 3.0 * s + 12.0 * s), lbl,
                        HORIZONTAL_ALIGNMENT_CENTER, 40.0 * s,
                        int(maxf(8.0, 10.0 * s)), COL_MARK)
            d += 5
        # 两端渐隐（战雷带式：视野边缘淡出，不硬切）。
        for i in range(6):
            var a := 0.10 + 0.12 * float(5 - i)
            var bw := 9.0 * s
            draw_rect(Rect2(float(i) * bw, 3.0 * s, bw, strip_h),
                Color(0.055, 0.06, 0.07, a), true)
            draw_rect(Rect2(w - float(i + 1) * bw, 3.0 * s, bw, strip_h),
                Color(0.055, 0.06, 0.07, a), true)
        # 中央琥珀指针（三角 + 竖线，跨刻度窗全高）——标记当前机头朝向。
        var lw := 2.0 * s
        draw_rect(Rect2(roundf(cx - lw * 0.5), 3.0 * s, lw, strip_h), COL_POINTER, true)
        draw_colored_polygon(PackedVector2Array([
            Vector2(cx - 6.0 * s, 3.0 * s), Vector2(cx + 6.0 * s, 3.0 * s),
            Vector2(cx, 3.0 * s + 7.0 * s)]), COL_POINTER)
        # 数字牌：带下三位航向数（战雷式「数字 + 带」双显）。
        draw_rect(Rect2(cx - 32.0 * s, digit_y + 2.0 * s, 64.0 * s, 14.0 * s),
            COL_DASH_LO, true)
        draw_string(ThemeDB.fallback_font, Vector2(cx - 32.0 * s, digit_y + 14.0 * s),
            "%03d°" % int(floorf(_heading)), HORIZONTAL_ALIGNMENT_CENTER, 64.0 * s,
            int(maxf(9.0, 13.0 * s)), COL_MARK)
        # 左右各一颗固定基准小三角（带框装饰，不随滚动）。
        for sign in [-1.0, 1.0]:
            var bx: float = cx + float(sign) * w * 0.5
            draw_colored_polygon(PackedVector2Array([
                Vector2(bx, 3.0 * s), Vector2(bx - float(sign) * 7.0 * s, 3.0 * s),
                Vector2(bx - float(sign) * 7.0 * s, 8.0 * s)]), COL_MARK_DIM)


# ── 地平仪：圆形天地 + 固定飞机标记（D-052 改圆盘）──────────────
class _AttitudeGauge extends Control:
    var _pitch := 0.0
    var _roll := 0.0
    var _s := 1.0

    ## D-053 起盘内细节按「盘径 / 设计稿」取尺，size 本身参与绘制——尺寸变化
    ## 必须重绘（不能只靠 set_scale_hint：宽高比变化时 ui_scale 可能不变而
    ## 盘径变了）。
    func _ready() -> void:
        resized.connect(queue_redraw)

    func set_scale_hint(s: float) -> void:
        if not is_equal_approx(_s, s):
            _s = s
            queue_redraw()

    func set_attitude(pitch: float, roll: float) -> void:
        _pitch = pitch
        _roll = roll
        queue_redraw()

    func _draw() -> void:
        var sz := size.x
        # D-053：盘内像素细节的尺子 = 盘径 / 设计稿 152。盘排压缩后压环、字号、
        # 指针、阶梯线跟着等比缩，不会出现「小盘配大字」糊出盘外。
        var s := sz / CockpitInstruments.GAUGE_SZ
        var c := size * 0.5
        var R := sz * 0.5
        var bez := BEZEL * s
        var rw := R - bez
        # 金属压环三层：受光边 → 暗部 → 盘面。
        draw_circle(c, R, COL_RING)
        draw_circle(c, R - 2.5 * s, COL_RING_D)
        draw_circle(c, rw, COL_BEZEL)
        # 天地：天铺满圆，地用「圆多边形 ∩ 地平线半平面」填充（圆内截断）。
        var ppd := (rw * 0.86) / PITCH_MAX
        var a := deg_to_rad(-_roll)
        var dy := CockpitInstruments.pitch_offset_px(_pitch, ppd)
        var n := CockpitInstruments.horizon_normal(_roll)
        var q := c + CockpitInstruments.rot2(a, 0.0, dy)
        draw_circle(c, rw, COL_SKY)
        var poly := CockpitInstruments.circle_poly(c, rw, 72)
        var ground := CockpitInstruments.clip_poly_half(poly, q, n, false)
        if ground.size() >= 3:
            draw_colored_polygon(ground, COL_GROUND)
        # 地平线（2px，裁进圆）。
        var hd := CockpitInstruments.rot2(a, 1.0, 0.0)
        var seg := CockpitInstruments.clip_seg_circle(q - hd * rw * 1.4,
            q + hd * rw * 1.4, c, rw)
        if seg.size() == 2:
            _thick_seg(seg[0], seg[1], 2.0 * s, COL_MARK)
        # 俯仰阶梯（随天地旋转）：只画圆盘两侧的外环段，中间留空给飞机标记。
        # 首版全宽 26px 线 + 10° 间距 11px，±30° 内六条线在圆心糊成一团
        # 栅栏、还压住琥珀标记——战雷的阶梯本来就在盘缘两侧，不在中间。
        for p in LADDER:
            var pf := float(p)
            for sgn in [-1.0, 1.0]:
                var ang := pf * float(sgn)
                var ly := dy - ang * ppd
                # 10° 阶梯往里收一截：平飞时 ±10/20/30 六条线间距只有 11px，
                # 全长会在地平线附近糊成一排栅栏；短一截立刻分层。
                var x0 := rw * (0.34 if pf >= 20.0 else 0.56)
                var x1 := rw * 0.94
                var e0 := c + CockpitInstruments.rot2(a, float(sgn) * x0, ly)
                var e1 := c + CockpitInstruments.rot2(a, float(sgn) * x1, ly)
                var lseg := CockpitInstruments.clip_seg_circle(e0, e1, c, rw - 1.0 * s)
                if lseg.size() == 2:
                    _thick_seg(lseg[0], lseg[1], 1.5 * s, COL_MARK)
                    if pf >= 20.0:
                        # 数字锚点往圆内收 14%：直接贴外端会压在圆缘/刻度上。
                        _draw_rot_text(lseg[1].lerp(lseg[0], 0.14), a,
                            "%d" % int(ang), s)
        # 横滚刻度（随天地转，沿盘内缘 ±60°）。
        var rr := rw - 5.0 * s
        for phi in ROLL_TICKS:
            for sign in [-1.0, 1.0]:
                var ang := float(phi) * float(sign)
                var rad := deg_to_rad(ang)
                var major := absf(ang) < 0.5 or absf(absf(ang) - 30.0) < 0.5 \
                    or absf(absf(ang) - 60.0) < 0.5
                var rh := (4.0 if major else 2.0) * s
                var c0 := Vector2(sin(rad) * rr, -cos(rad) * rr)
                var rd := Vector2(sin(rad), -cos(rad))
                var td := Vector2(rd.y, -rd.x)
                var tw := 1.6 * s
                var local := PackedVector2Array([
                    c0 - rd * rh - td * tw, c0 + rd * rh - td * tw,
                    c0 + rd * rh + td * tw, c0 - rd * rh + td * tw,
                ])
                var pl := PackedVector2Array()
                for v in local:
                    pl.append(c + CockpitInstruments.rot2(a, v.x, v.y))
                draw_colored_polygon(pl, COL_MARK if major else COL_MARK_DIM)
        # 固定层（不随姿态动）：顶部指针 + 琥珀飞机标记。
        # 刻意不画中心小十字：与飞机标记重叠成「米」字，且用户 spec 要求
        # 「上层固定的十字 + 飞机标记」——两者合一即可，多一层只会糊。
        draw_colored_polygon(PackedVector2Array([
            Vector2(c.x - 5.0 * s, c.y - rw), Vector2(c.x + 5.0 * s, c.y - rw),
            Vector2(c.x, c.y - rw + 7.0 * s)]), COL_MARK)
        # 飞机标记：两翼横线 + 中心点（琥珀，黑白天地下最醒目——战雷同款）。
        draw_rect(Rect2(c.x - 30.0 * s, c.y - 1.0 * s, 20.0 * s, 2.0 * s), COL_POINTER, true)
        draw_rect(Rect2(c.x + 10.0 * s, c.y - 1.0 * s, 20.0 * s, 2.0 * s), COL_POINTER, true)
        draw_rect(Rect2(c.x - 1.5 * s, c.y - 1.5 * s, 3.0 * s, 3.0 * s), COL_POINTER, true)
        # 玻璃反光：左上角一道 45° 淡斜条（座舱玻璃质感，不遮读数）。
        draw_colored_polygon(PackedVector2Array([
            c + Vector2(-rw * 0.92, -rw * 0.62), c + Vector2(-rw * 0.62, -rw * 0.92),
            c + Vector2(-rw * 0.42, -rw * 0.86), c + Vector2(-rw * 0.72, -rw * 0.56),
        ]), Color(1.0, 1.0, 1.0, 0.035))

    ## 硬边粗线段：沿线方向的细四边形（不用 draw_line，避免抗锯齿）。
    func _thick_seg(p0: Vector2, p1: Vector2, w: float, col: Color) -> void:
        var d := (p1 - p0).normalized()
        var nrm := Vector2(-d.y, d.x) * (w * 0.5)
        draw_colored_polygon(PackedVector2Array([
            p0 + nrm, p1 + nrm, p1 - nrm, p0 - nrm]), col)

    ## 随天地层旋转的小数字（绕锚点转，位置不缩放）。锚点是阶梯线的**外端**
    ## （圆上），文字必须往圆内画：首版用 (pos=-6s, width=30s, RIGHT)，右边界
    ## 落在 +24s，实测数字整个飘到圆盘右侧外面。
    func _draw_rot_text(anchor: Vector2, a: float, txt: String, s: float) -> void:
        draw_set_transform(anchor, a, Vector2.ONE)
        draw_string(ThemeDB.fallback_font, Vector2(-34.0 * s, -5.0 * s), txt,
            HORIZONTAL_ALIGNMENT_RIGHT, 30.0 * s, int(maxf(8.0, 10.0 * s)), COL_MARK)
        draw_set_transform(Vector2.ZERO)


# ── 圆形读数盘（D-052：SPD / ALT 由空方框改为战雷式圆表）────────
## 结构：金属压环 → 黑盘面 → 270° 环形刻度 → 琥珀指针 → 中心轴 →
## 盘下中央数字窗（用户 spec 的「白色数字」仍是唯一主读数）。
class _RoundGauge extends Control:
    var _label := ""
    var _value := ""
    var _warn := false
    var _max := 1.0
    var _s := 1.0

    ## 量程（刻度用；指针超量程停满偏，数字窗仍显示真实值）。
    ## 刻意不叫 max_value：Range 系节点有这个属性名，自定义 Control 上会与
    ## 引擎属性解析冲突（实测 "Invalid assignment of property 'max_value'"）。
    func set_range(mx: float) -> void:
        _max = maxf(mx, 1e-6)

    func _ready() -> void:
        resized.connect(queue_redraw)

    func set_scale_hint(s: float) -> void:
        if not is_equal_approx(_s, s):
            _s = s
            queue_redraw()

    func set_value(label: String, value: String, warn: bool) -> void:
        _label = label
        _value = value
        _warn = warn
        queue_redraw()

    func _draw() -> void:
        var sz := size.x
        # D-053：同 _AttitudeGauge，按盘径 / 设计稿 140 取尺。
        var s := sz / CockpitInstruments.SIDE_SZ
        var c := size * 0.5
        var R := sz * 0.5
        var bez := BEZEL * s
        var rw := R - bez
        var col := COL_MARK
        if _warn:
            col = Color(COL_WARN.r, COL_WARN.g, COL_WARN.b,
                CockpitInstruments.blink_alpha(Time.get_ticks_msec()))
        # 压环三层 + 盘面。
        draw_circle(c, R, COL_RING)
        draw_circle(c, R - 2.5 * s, COL_RING_D)
        draw_circle(c, rw, COL_BEZEL)
        # 环形刻度：270° 弧，0 在左下、满量程在右下，顺时针。
        var parts := CockpitInstruments.split_value(_value)
        var num := String(parts[0])
        var unit := String(parts[1])
        var numeric := num.to_float()
        var step := _max / 25.0
        var i := 0
        while i <= 25:
            var v := float(i) * step
            var t := clampf(v / maxf(_max, 1e-6), 0.0, 1.0)
            var ang := deg_to_rad(-135.0 + 270.0 * t)
            var dir := Vector2(sin(ang), -cos(ang))
            var major := i % 5 == 0
            var r0 := rw - (10.0 if major else 6.0) * s
            var r1 := rw - 1.5 * s
            var tw := (2.0 if major else 1.0) * s
            _thick_seg(c + dir * r0, c + dir * r1, tw,
                COL_MARK if major else COL_MARK_DIM)
            i += 1
        # 指针（琥珀）+ 中心轴。
        var pt := clampf(numeric / maxf(_max, 1e-6), 0.0, 1.0)
        var pang := deg_to_rad(-135.0 + 270.0 * pt)
        var pdir := Vector2(sin(pang), -cos(pang))
        var tip := c + pdir * (rw - 12.0 * s)
        var tail := c - pdir * 7.0 * s
        _thick_seg(tail, tip, 3.0 * s, col)
        draw_circle(c, 3.5 * s, COL_RING)
        draw_circle(c, 1.8 * s, COL_RING_D)
        # 数字窗：盘下方（270° 弧的开口处，不与刻度抢位）。数字大、单位小，
        # 同一行——单位放到盘外（首版做法）会飘到 dash 板上像无主文字。
        # D-053：宽度收到 0.62、高 0.28——0.68/0.30 时矩形下两角会切出盘缘
        #（盘排缩到 2/3 后在放大截图里能看出四角「出圈」）。
        var win_w := sz * 0.62
        var win_h := sz * 0.28
        var win := Rect2(c.x - win_w * 0.5, c.y + rw * 0.14, win_w, win_h)
        draw_rect(win, Color(0.03, 0.035, 0.045), true)
        draw_rect(win, COL_SEAM, false, maxf(1.0, s))
        # 盘标签（SPD / ALT）：贴数字窗上沿当「窗标题」，不放盘顶——盘顶
        # 正是指针 12 点方向的必经之路，实测指针从字上穿过糊成一团。
        draw_string(ThemeDB.fallback_font,
            Vector2(win.position.x, win.position.y - 3.0 * s), _label,
            HORIZONTAL_ALIGNMENT_CENTER, win_w,
            int(maxf(7.0, 9.0 * s)), COL_MARK_DIM)
        var fs := int(maxf(12.0, 25.0 * s))
        draw_string(ThemeDB.fallback_font,
            Vector2(win.position.x + 3.0 * s, win.get_center().y + float(fs) * 0.36),
            num, HORIZONTAL_ALIGNMENT_LEFT, win_w * 0.66, fs, col)
        var us := unit.strip_edges()
        if not us.is_empty():
            draw_string(ThemeDB.fallback_font,
                Vector2(win.position.x + win_w * 0.60, win.get_center().y + 3.0 * s),
                us, HORIZONTAL_ALIGNMENT_RIGHT, win_w * 0.36,
                int(maxf(7.0, 9.0 * s)), COL_MARK_DIM)

    func _thick_seg(p0: Vector2, p1: Vector2, w: float, col: Color) -> void:
        var d := (p1 - p0).normalized()
        var nrm := Vector2(-d.y, d.x) * (w * 0.5)
        draw_colored_polygon(PackedVector2Array([
            p0 + nrm, p1 + nrm, p1 - nrm, p0 - nrm]), col)


# ── 竖向条状指示器（D-052：油门 / 燃油，填掉盘排两侧的空白）──────
class _VBar extends Control:
    var _ratio := 0.0
    var _warn := false
    var _s := 1.0
    var _label := ""

    func _ready() -> void:
        resized.connect(queue_redraw)

    func set_scale_hint(s: float) -> void:
        if not is_equal_approx(_s, s):
            _s = s
            queue_redraw()

    func set_bar(label: String, ratio: float, warn: bool) -> void:
        _label = label
        _ratio = clampf(ratio, 0.0, 1.0)
        _warn = warn
        queue_redraw()

    func _draw() -> void:
        var w := size.x
        var h := size.y
        # D-053：竖条高 = ssz（已被盘排压缩带走），内部细节按 高 / 设计稿 140。
        var s := h / CockpitInstruments.SIDE_SZ
        draw_rect(Rect2(0.0, 0.0, w, h), COL_RING_D, true)
        draw_rect(Rect2(0.0, 0.0, w, 1.0 * s), COL_RING, true)
        # 条顶标签（THR / FUEL）：画在条自己头上，不侵占航向带。
        draw_string(ThemeDB.fallback_font, Vector2(0.0, 9.0 * s), _label,
            HORIZONTAL_ALIGNMENT_CENTER, w, int(maxf(7.0, 8.0 * s)), COL_PLATE_TXT)
        var slot := Rect2(4.0 * s, 12.0 * s, w - 8.0 * s, h - 30.0 * s)
        draw_rect(slot, Color(0.02, 0.025, 0.035), true)
        # 填充自下而上 + 10 段分隔线（与 HUD 油门条的 █/░ 同语言）。填充色
        # 刻意比指针暗一档：细条满屏都是，用指针同色会抢仪表读数的注意力。
        var fill_h := slot.size.y * _ratio
        var col := Color(0.86, 0.62, 0.18) if not _warn else COL_WARN
        draw_rect(Rect2(slot.position.x, slot.end.y - fill_h, slot.size.x, fill_h), col, true)
        for i in range(1, 10):
            var yy := slot.position.y + slot.size.y * float(i) / 10.0
            draw_rect(Rect2(slot.position.x, yy, slot.size.x, 1.0 * s),
                Color(0.0, 0.0, 0.0, 0.45), true)
        # 百分比：条底独立黑带（不叠在填充上——橙底白字实测读不清）。
        draw_string(ThemeDB.fallback_font, Vector2(0.0, h - 3.0 * s),
            "%d" % int(round(_ratio * 100.0)), HORIZONTAL_ALIGNMENT_CENTER, w,
            int(maxf(7.0, 9.0 * s)), COL_MARK)
