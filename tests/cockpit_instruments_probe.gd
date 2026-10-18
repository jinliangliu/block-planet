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
##   ⑥ 控件状态：refresh 后 ALT/SPD 文案与警告灯随 FlightInstruments 变。
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
    _finish()


## ① 俯仰钳制（用户 spec：±60° 超过截断）。
func _check_pitch_clamp() -> void:
    # 与 _AttitudeGauge 同式：窗半高 / PITCH_MAX。D-049 放大后
    # GAUGE_SZ=176、BEZEL=9 → 窗半高 (176-18)/2 = 79。
    var ppd := 79.0 / 60.0
    _check(absf(CockpitInstruments.pitch_offset_px(80.0, ppd) - 60.0 * ppd) < 1e-6,
        "① 俯仰 +80° 被钳到 +60°（偏移 %.2f px，不无限滚动）" % CockpitInstruments.pitch_offset_px(80.0, ppd))
    _check(absf(CockpitInstruments.pitch_offset_px(-95.0, ppd) + 60.0 * ppd) < 1e-6,
        "① 俯仰 -95° 被钳到 -60°")
    _check(absf(CockpitInstruments.pitch_offset_px(30.0, ppd) - 30.0 * ppd) < 1e-6,
        "① 区内 ±30° 不钳（线性 %.2f px）" % CockpitInstruments.pitch_offset_px(30.0, ppd))
    # 钳后偏移永不越出窗口半高（否则天地层整体跑出表盘）。
    _check(absf(CockpitInstruments.pitch_offset_px(1000.0, ppd)) <= 79.0 + 1e-6,
        "① 极端俯仰偏移仍 ≤ 窗半高（画面截断在窗内）")


## ② 航向取模连续性。
func _check_tape_wrap() -> void:
    var cx := 640.0
    var ppx := 6.0   # 与 TAPE_PPX 同步（D-049：712px 带 / 6px 每度）
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
