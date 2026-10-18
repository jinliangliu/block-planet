extends Node
## 座舱 2D 仪表簇纯逻辑探针（D-047，无头）：不渲染、不断言像素，只锁
## 「不会因取整/取模/类型问题悄悄坏掉」的契约：
##   ① 地平仪俯仰钳制：|pitch|>60° 偏移停在 ±60°（天地截断不无限滚动）；
##   ② 航向带取模：359°→0° 附近刻度位置连续（步长恒为 1°×PPX），
##      0° 与 360° 同位置；
##   ③ 横滚方向：右滚为正 → 地平线法线指向左上（90° 右坡天在左半屏）；
##   ④ 闪烁：0.35..1.0、600ms 周期（高度计过低警告用）；
##   ⑤ 裁剪：线段×矩形（全在外返回空 / 跨边返回 2 点且都在窗内）；
##      多边形×半平面保留正确半侧；
##   ⑥ 控件状态：refresh 后 ALT/SPD 文案与警告灯随 FlightInstruments 变；
##   ⑦ 座舱像素内装几何（D-050/D-051/D-052）：框体/console/dash/六件仪表
##      不出屏、dash 包住六件（底板在仪表后）、console 不侵占航向带与 dash、
##      风挡斜边在 dash 上方收敛完、导轨不压顶部卡片、盘与盘/带互不重叠。
##   ⑧ 分辨率自适应（D-052）：同一套基准常量在 960×540 / 1080×608 /
##      1280×720 / 1920×1080 下，仪表「占屏比例」一致（这才是用户说的
##      「尺寸不合理」的根因：固定像素在小窗口好看、在 1080p 手机缩一半）。
##   ⑨ 读数拆字：split_value("4500m") → ["4500","m"]（数字窗分行排字用）。
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/cockpit_instruments_probe.tscn

var _failed := 0
const _ID := Basis.IDENTITY


func _ready() -> void:
    await _run()


func _run() -> void:
    _check_pitch_clamp()
    _check_tape_wrap()
    _check_roll_direction()
    _check_blink()
    _check_clip()
    _check_widget_state()
    _check_frame()
    _check_scaling()
    _check_split_value()
    _finish()


## ① 俯仰钳制（用户 spec：±60° 超过截断）。
func _check_pitch_clamp() -> void:
    # 与 _AttitudeGauge 同式：钳制与半径无关，ppd 取任意值验证公式本身。
    var ppd := 1.25
    _check(absf(CockpitInstruments.pitch_offset_px(80.0, ppd) - 60.0 * ppd) < 1e-6,
        "① 俯仰 +80° 被钳到 +60°（偏移 %.2f px，不无限滚动）" % CockpitInstruments.pitch_offset_px(80.0, ppd))
    _check(absf(CockpitInstruments.pitch_offset_px(-95.0, ppd) + 60.0 * ppd) < 1e-6,
        "① 俯仰 -95° 被钳到 -60°")
    _check(absf(CockpitInstruments.pitch_offset_px(30.0, ppd) - 30.0 * ppd) < 1e-6,
        "① 区内 ±30° 不钳（线性 %.2f px）" % CockpitInstruments.pitch_offset_px(30.0, ppd))
    # 真实盘的 ppd（D-052 圆盘）：半窗 0.86×内半径 / 60°。
    var s := CockpitInstruments.ui_scale(Vector2(1080.0, 608.0))
    var rw := (CockpitInstruments.GAUGE_SZ * s) * 0.5 - CockpitInstruments.BEZEL * s
    var ppd_real := (rw * 0.86) / CockpitInstruments.PITCH_MAX
    _check(absf(CockpitInstruments.pitch_offset_px(1000.0, ppd_real)) <= rw * 0.87,
        "① 极端俯仰偏移仍 ≤ 有效半径（天地截断在圆内，%.1f px）"
            % CockpitInstruments.pitch_offset_px(1000.0, ppd_real))


## ② 航向取模连续性。
func _check_tape_wrap() -> void:
    var cx := 640.0
    var ppx := 5.0   # 与 TAPE_PPX 同步（D-051：600px 带 / 5px 每度）
    var h := 359.5
    var x359 := CockpitInstruments.tape_x(359.0, h, cx, ppx)
    var x0 := CockpitInstruments.tape_x(0.0, h, cx, ppx)
    var x1 := CockpitInstruments.tape_x(1.0, h, cx, ppx)
    _check(absf((x0 - x359) - ppx) < 1e-6 and absf((x1 - x0) - ppx) < 1e-6,
        "② 359°→0°→1° 刻度步长恒为 %.0f px（无跳变）" % ppx)
    _check(absf(CockpitInstruments.tape_x(0.0, 0.5, cx, ppx)
        - CockpitInstruments.tape_x(360.0, 0.5, cx, ppx)) < 1e-6,
        "② 0° 与 360° 刻度同位置（循环无缝）")
    # 反向差 ≤180°：heading 0.5 时 90° 在东（+）、270° 在西（−）。
    _check(CockpitInstruments.tape_x(90.0, 0.5, cx, ppx) > cx
        and CockpitInstruments.tape_x(270.0, 0.5, cx, ppx) < cx,
        "② 航向 0° 时 90° 在右、270° 在左（指北 0°、指东 +90°）")


## ③ 横滚方向（右滚为正）。
func _check_roll_direction() -> void:
    var n0: Vector2 = CockpitInstruments.horizon_normal(0.0)
    _check(absf(n0.x) < 1e-6 and n0.y < 0.0, "③ 无滚转时法线朝天（0,-1）")
    var n90: Vector2 = CockpitInstruments.horizon_normal(90.0)
    _check(n90.x < -0.99 and absf(n90.y) < 0.01,
        "③ 右坡 90° 法线朝左（天在左半屏、地在右半屏）")
    var n180: Vector2 = CockpitInstruments.horizon_normal(180.0)
    _check(n180.y > 0.99, "③ 倒飞 180° 法线朝地（天地翻转）")


## ④ 闪烁相位。
func _check_blink() -> void:
    var lo := 99.0
    var hi := -99.0
    for t in range(0, 600, 25):
        var v := CockpitInstruments.blink_alpha(float(t))
        lo = minf(lo, v)
        hi = maxf(hi, v)
    _check(lo >= 0.34 and hi <= 1.01 and hi > 0.9,
        "④ 闪烁 alpha 落在 0.35..1.0（实测 %.2f..%.2f，600ms 周期）" % [lo, hi])


## ⑤ 裁剪不变量。
func _check_clip() -> void:
    var r := Rect2(0.0, 0.0, 100.0, 100.0)
    var out := CockpitInstruments.clip_seg_rect(Vector2(-50.0, -50.0), Vector2(-10.0, -10.0), r)
    _check(out.is_empty(), "⑤ 全在窗外的线段被裁空")
    out = CockpitInstruments.clip_seg_rect(Vector2(-10.0, 50.0), Vector2(200.0, 50.0), r)
    # 容差 1e-3：Vector2 是 float32，100 量级坐标的除法/lerp 固有误差 ~1e-5；
    # 真实裁剪失败会差 ≥1 px，1e-3 足以区分。
    _check(out.size() == 2 and out[0].x >= -1e-3 and out[1].x <= 100.0 + 1e-3
        and absf(out[0].distance_to(Vector2(0.0, 50.0))) < 1e-3
        and absf(out[1].distance_to(Vector2(100.0, 50.0))) < 1e-3,
        "⑤ 横穿窗边的线段保留窗内部分（%.4f..%.4f ≈ 0..100）" % [out[0].x, out[1].x])
    out = CockpitInstruments.clip_seg_rect(Vector2(10.0, 10.0), Vector2(20.0, 20.0), r)
    _check(out.size() == 2 and out[0].distance_to(Vector2(10.0, 10.0)) < 1e-6,
        "⑤ 完全在窗内的线段原样保留")
    # 半平面：地平线 y=50，法线 (0,-1) 朝天 → 上半保留。
    var quad := PackedVector2Array([
        Vector2(0.0, 0.0), Vector2(100.0, 0.0), Vector2(100.0, 100.0), Vector2(0.0, 100.0)])
    var upper := CockpitInstruments.clip_poly_half(quad, Vector2(0.0, 50.0), Vector2(0.0, -1.0), true)
    var lower := CockpitInstruments.clip_poly_half(quad, Vector2(0.0, 50.0), Vector2(0.0, -1.0), false)
    _check(upper.size() == 4 and absf(upper[2].y - 50.0) < 1e-6,
        "⑤ 上半裁剪后贴地平线（y=50）")
    _check(lower.size() == 4 and absf(lower[0].y - 50.0) < 1e-6,
        "⑤ 下半裁剪后贴地平线（天地互补）")


## ⑥ 控件状态：喂合成读数，断言文案与警告灯。
func _check_widget_state() -> void:
    var cluster := CockpitInstruments.new()
    add_child(cluster)
    var fi := FlightInstruments.new()
    # 正常巡航：4500m MSL / 120 km/h。
    for i in range(40):
        fi.update({
            "kmh": 120.0, "altitude": 4500.0, "altitude_agl": 300.0,
            "vertical_speed": 0.0, "throttle": 0.55, "engine": true,
            "stall_speed": 13.1, "fuel_liters": 40.0, "fuel_capacity": 55.0,
        }, _ID, 0.1)
    cluster.refresh(fi)
    var st: Dictionary = cluster.debug_state()
    _check(st["alt_value"] == "4500m", "⑥ 高度计文案 ALT 4500m（实测 %s）" % st["alt_value"])
    _check(st["spd_value"] == "120 km/h", "⑥ 空速框文案 120 km/h（实测 %s）" % st["spd_value"])
    _check(not st["alt_warn"] and not st["spd_warn"], "⑥ 巡航无警告灯")
    # 低空近地 + 下沉：alt_warn 应置 1（AGL<15 且下沉率<-2.5）。
    for i in range(40):
        fi.update({
            "kmh": 90.0, "altitude": 42.0, "altitude_agl": 10.0,
            "vertical_speed": -3.0, "throttle": 0.3, "engine": true,
            "stall_speed": 13.1, "fuel_liters": 40.0, "fuel_capacity": 55.0,
        }, _ID, 0.1)
    cluster.refresh(fi)
    st = cluster.debug_state()
    _check(fi.alt_warn > 0, "⑥ 合成读数触发 alt_warn=%d（AGL 10m / 下沉 3m/s）" % fi.alt_warn)
    _check(st["alt_warn"], "⑥ alt_warn>0 → 高度计警告灯亮（变红闪烁）")
    _check(st["alt_value"] == "42m", "⑥ 低空文案随读数刷新（42m）")
    # 超速 → SPD 警告灯。
    for i in range(5):
        fi.update({
            "kmh": 200.0, "altitude": 42.0, "altitude_agl": 10.0,
            "vertical_speed": -3.0, "throttle": 1.0, "engine": true,
            "stall_speed": 13.1, "overspeed": true,
            "fuel_liters": 40.0, "fuel_capacity": 55.0,
        }, _ID, 0.1)
    cluster.refresh(fi)
    st = cluster.debug_state()
    _check(st["spd_warn"], "⑥ 超速 → SPD 框警告灯亮")
    cluster.queue_free()


## ⑦ 座舱像素内装几何（D-050/D-051/D-052）：纯函数 metrics 的布局不变量。
## 四档分辨率全跑一遍——几何契约必须在任何视口下成立（D-052 的核心）。
func _check_frame() -> void:
    for vp in [Vector2(960.0, 540.0), Vector2(1080.0, 608.0),
            Vector2(1280.0, 720.0), Vector2(1920.0, 1080.0)]:
        _check_frame_at(vp)


func _check_frame_at(vp: Vector2) -> void:
    var m := CockpitInstruments.metrics(vp)
    var tag := "%dx%d" % [int(vp.x), int(vp.y)]
    var s := float(m["s"])
    var rail: Rect2 = m["rail"]
    var console_l: Rect2 = m["console_l"]
    var console_r: Rect2 = m["console_r"]
    var dash: Rect2 = m["dash"]
    var lip: Rect2 = m["lip"]
    var tape: Rect2 = m["tape"]
    var gauge: Rect2 = m["gauge"]
    var alt: Rect2 = m["alt"]
    var spd: Rect2 = m["spd"]
    var thr: Rect2 = m["thr"]
    var fuel: Rect2 = m["fuel"]
    _check_rect_in(rail, vp, tag + " 顶导轨")
    _check_rect_in(console_l, vp, tag + " 左 console")
    _check_rect_in(console_r, vp, tag + " 右 console")
    _check_rect_in(dash, vp, tag + " dash 底板")
    _check_rect_in(lip, vp, tag + " dash 顶沿")
    _check_rect_in(tape, vp, tag + " 航向带")
    _check_rect_in(gauge, vp, tag + " 地平仪")
    _check_rect_in(alt, vp, tag + " ALT 盘")
    _check_rect_in(spd, vp, tag + " SPD 盘")
    _check_rect_in(thr, vp, tag + " 油门条")
    _check_rect_in(fuel, vp, tag + " 燃油条")
    # dash 是六件的底板：每件必须整个落在 dash 内（先画 dash、仪表画其上）。
    _check(dash.encloses(tape) and dash.encloses(gauge) and dash.encloses(alt)
        and dash.encloses(spd) and dash.encloses(thr) and dash.encloses(fuel),
        "⑦ %s dash 包住六件仪表（底板在仪表后）" % tag)
    # console / 导轨不侵占仪表与 dash。
    _check(console_l.end.x <= tape.position.x + 1e-6
        and console_r.position.x >= tape.end.x - 1e-6,
        "⑦ %s 侧 console 不压航向带（%.0f / %.0f ≤ %s）"
            % [tag, console_l.end.x, console_r.position.x, str(tape)])
    _check(console_l.end.x <= dash.position.x + 1e-6
        and console_r.position.x >= dash.end.x - 1e-6,
        "⑦ %s dash 不侵入左右 console" % tag)
    _check(rail.end.y <= tape.position.y + 1e-6, "⑦ %s 顶导轨不压航向带" % tag)
    # 风挡斜边：顶端比 console 直壁窄（真的向内收）+ 斜边在 dash 上方收敛完。
    _check(float(m["pillar_top_w"]) < float(m["console_w"]),
        "⑦ %s 风挡斜边顶端比 console 窄（%.0f < %.0f，真的向内收）"
            % [tag, float(m["pillar_top_w"]), float(m["console_w"])])
    _check(float(m["pillar_base_y"]) < dash.position.y,
        "⑦ %s 斜边在 dash 上方收敛完（%.0f < %.0f）"
            % [tag, float(m["pillar_base_y"]), dash.position.y])
    # 六件互不重叠（航向带 / 三盘 / 两竖条）——两两检查，10 对。
    var rects := {"tape": tape, "gauge": gauge, "alt": alt, "spd": spd,
        "thr": thr, "fuel": fuel}
    var keys := rects.keys()
    var overlap := ""
    for i in range(keys.size()):
        for j in range(i + 1, keys.size()):
            var a: Rect2 = rects[keys[i]]
            var b: Rect2 = rects[keys[j]]
            if a.intersects(b):
                overlap += "%s×%s " % [keys[i], keys[j]]
    _check(overlap.is_empty(), "⑦ %s 六件仪表互不重叠（%s）"
        % [tag, "无重叠" if overlap.is_empty() else overlap])
    # 盘排水平居中（主表圆心 = 屏宽中线）+ 左右对称。
    # 容差 1e-3：metrics 是 double 计算但 Rect2 存 float32，1.184 倍缩放链
    # 在 1000 量级坐标上固有误差 ~1e-4；真实布局错误差 ≥1 px。
    _check(absf(gauge.get_center().x - vp.x * 0.5) < 1e-3,
        "⑦ %s 地平仪居中（圆心 x=%.1f）" % [tag, gauge.get_center().x])
    _check(absf((spd.position.x - dash.position.x)
        - (dash.end.x - alt.end.x)) < 1e-3,
        "⑦ %s 左右仪表槽对称（%.3f / %.3f）" % [tag,
            spd.position.x - dash.position.x, dash.end.x - alt.end.x])
    # dash 底沿即屏底（座舱地板）、lip 贴 dash 顶沿、宽 = 航向带 + 2×DASH_PAD。
    _check(absf(dash.end.y - vp.y) < 1e-3, "⑦ %s dash 底沿 = 屏底（座舱地板）" % tag)
    _check(absf(lip.position.y - dash.position.y) < 1e-3
        and absf(lip.size.x - dash.size.x) < 1e-3, "⑦ %s dash 顶沿与 dash 对齐" % tag)
    _check(absf(dash.size.x - (tape.size.x
        + CockpitInstruments.DASH_PAD * 2.0 * s)) < 1e-3,
        "⑦ %s dash 宽 = 航向带 + 2×DASH_PAD（%.1f px）" % [tag, dash.size.x])
    # 仪表板占屏高的比例落在战雷式区间（0.28..0.40），不压掉视野。
    # D-051 交付值为 30%（用户已要求「缩小」过一次），D-052 圆盘化后 32.8%
    # —— 判定区间以此为准，上调即视为回归。
    var ratio := dash.size.y / vp.y
    _check(ratio > 0.28 and ratio < 0.40,
        "⑦ %s 仪表板占屏高 %.1f%%（D-051 量级 28~40%%）" % [tag, ratio * 100.0])


## ⑧ 宽高比自适应（D-052）：项目用 stretch=canvas_items + aspect=expand，逻辑
## 视口宽恒 1280，但**高度随宽高比在 590~720 漂移**——固定像素布局会让仪表
## 占屏高在 21%~26% 之间摆。等比缩放后必须恒定。
func _check_scaling() -> void:
    _check(absf(CockpitInstruments.ui_scale(Vector2(1280.0, 720.0)) - 1.0) < 1e-6,
        "⑧ 基准视口 1280×720 缩放 = 1.0（= project.godot 逻辑视口）")
    var s_hd := CockpitInstruments.ui_scale(Vector2(1920.0, 1080.0))
    _check(absf(s_hd - 1.5) < 1e-6,
        "⑧ 1920×1080 缩放 = 1.5（纯函数按物理尺寸等比；运行时 canvas_items "
        + "传进来的是逻辑尺寸 1280×720，故实际恒为 1.0）")
    # 19.5:9 手机：aspect=expand 让逻辑高度掉到 1280×590.8。
    var s_wide := CockpitInstruments.ui_scale(Vector2(1280.0, 590.8))
    _check(absf(s_wide - 590.8 / 720.0) < 1e-3,
        "⑧ 宽屏手机 1280×591 缩放 = %.3f（按高度约束收紧）" % s_wide)
    _check(absf(CockpitInstruments.ui_scale(Vector2(320.0, 240.0))
        - CockpitInstruments.SCALE_MIN) < 1e-6, "⑧ 极小视口钳到 SCALE_MIN")
    _check(absf(CockpitInstruments.ui_scale(Vector2(7680.0, 4320.0))
        - CockpitInstruments.SCALE_MAX) < 1e-6, "⑧ 8K 视口钳到 SCALE_MAX")
    # 主表「直径 / 屏高」在各宽高比下的离散度 < 0.5%（固定像素实现会差 ~20%）。
    # 只列「宽度足够（≥1280）」的视口：等比缩放按窄边取值，4:3 竖屏由宽度
    # 约束、仪表会整体变小——那是刻意的防溢出行为，不是漂移。
    var ratios: Array[float] = []
    for vp in [Vector2(1280.0, 590.8), Vector2(1280.0, 720.0),
            Vector2(1280.0, 640.0), Vector2(1920.0, 1080.0),
            Vector2(2340.0, 1080.0)]:
        var m := CockpitInstruments.metrics(vp)
        ratios.append((m["gauge"] as Rect2).size.y / vp.y)
    var lo := 9.0
    var hi := 0.0
    for r in ratios:
        lo = minf(lo, r)
        hi = maxf(hi, r)
    _check(hi - lo < 0.005,
        "⑧ 主表占屏高比例跨宽高比恒定（%.3f..%.3f，离散 %.4f < 0.005）"
            % [lo, hi, hi - lo])
    _check(lo > 0.19 and hi < 0.23,
        "⑧ 主表占屏高 ≈ 21%%（D-051 缩小后的量级，实测 %.1f%%）" % (lo * 100.0))


## ⑨ 读数拆字：数字窗分「数字 + 单位」两行排（探针契约保留完整字符串）。
func _check_split_value() -> void:
    var a: Array = CockpitInstruments.split_value("4500m")
    _check(a[0] == "4500" and a[1] == "m", "⑨ split_value(\"4500m\") → 4500 / m")
    var b: Array = CockpitInstruments.split_value("113 km/h")
    _check(b[0] == "113" and b[1] == " km/h", "⑨ split_value(\"113 km/h\") → 113 / ' km/h'")
    var c: Array = CockpitInstruments.split_value("—")
    _check(c[0] == "" and c[1] == "—", "⑨ 无数字时整体归入单位段（不吞字）")


## 矩形完全落在视口内（容差 1e-6，float32 几何）。
func _check_rect_in(rr: Rect2, vp: Vector2, tag: String) -> void:
    _check(rr.position.x >= -1e-6 and rr.position.y >= -1e-6
        and rr.end.x <= vp.x + 1e-6 and rr.end.y <= vp.y + 1e-6,
        "⑦ %s不出屏（%s）" % [tag, str(rr)])


func _finish() -> void:
    if _failed == 0:
        print("COCKPIT_INSTRUMENTS_OK")
        get_tree().quit(0)
    else:
        print("COCKPIT_INSTRUMENTS_FAILED fails=%d" % _failed)
        get_tree().quit(1)


func _check(cond: bool, msg: String) -> void:
    if cond:
        print("PASS: ", msg)
    else:
        _failed += 1
        print("FAIL: ", msg)
