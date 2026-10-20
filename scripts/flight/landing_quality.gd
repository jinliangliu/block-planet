class_name LandingQuality
## 接地质量连续评分（U-7）：把 LANDING 任务原有的二值判定（触地垂直速度 /
## 落点偏差 / 停稳滑跑速度）升级为连续打分，让**每一次落地**都有评价——原来
## 只有任务在跑时才算「过/不过」，自由飞落得多好/多糙都没有反馈（对比 MSFS
## Landing Challenge 三项 + Infinite Flight 落地播报）。
##
## 纯逻辑、无节点依赖：MissionManager（任务结算）与 Aircraft（每次落地自动
## 评价）共用同一份口径，探针直接构造输入断言。
##
## 打分口径（总分 0~100，儿童向：轻轻落地就该拿高分，苛刻但不刁难）：
##   vs   项 40 分：|触地垂直速度| 0 → 满分，≥ HARD_VS（3 m/s，即任务硬着陆
##                  阈值）线性扣到 0；
##   zone 项 30 分：落点与参照区中心的水平偏差 0 → 满分，≥ ZONE_FULL_MARK
##                  （50 m，即任务降落区半径）扣到 0；**无参照时给中性分**
##                  （自由飞没有「标准落点」，不该因此扣分）；
##   roll 项 30 分：停稳瞬间水平速度 0 → 满分，≥ STOP_REF_KMH（25 km/h，
##                  即任务停稳阈值）线性扣到 0。
##
## 等级文案（儿童友好、可朗读）：≥90 完美 / ≥75 漂亮 / ≥55 不错 / ≥35 勉强 /
## 其余粗糙。刻意不用「合格/不合格」——评分是鼓励，不是审判。

const VS_POINTS := 40.0
const ZONE_POINTS := 30.0
const ROLL_POINTS := 30.0
## 无参照落点的中性分（满分 30 的 60%）：自由飞不扣分也不白送。
const ZONE_NEUTRAL := 18.0
## 与 MissionData 出厂阈值同源（DEFAULT_TOUCHDOWN_VS / zone 半径 / 停稳速度），
## 硬编码处注释钉死，探针守护三者不漂移。
const HARD_VS := 3.0
const ZONE_FULL_MARK := 50.0
const STOP_REF_KMH := 25.0

## 等级阈值（总分下限）→ 文案 + 表情。顺序即降级，_grade 线性扫描。
const GRADES := [
	{"min": 90.0, "text": "完美降落！", "emoji": "🏆"},
	{"min": 75.0, "text": "飞得很漂亮", "emoji": "🌟"},
	{"min": 55.0, "text": "降落不错", "emoji": "👍"},
	{"min": 35.0, "text": "勉强站稳", "emoji": "😅"},
	{"min": 0.0, "text": "摔得有点疼", "emoji": "💥"},
]


## 打分入口。参数：
##   touchdown_vs  : 触地帧垂直速度（m/s，负为下沉；取绝对值）
##   zone_offset_m : 落点与参照区中心的水平距离（m）；传负数 = 无参照（中性分）
##   stop_speed_kmh: 停稳瞬间的水平速度（km/h）
## 返回 {vs_points, zone_points, roll_points, total, grade, emoji}，total 为
## 四舍五入整数（0~100）。
static func score(touchdown_vs: float, zone_offset_m: float,
		stop_speed_kmh: float) -> Dictionary:
	var vs := clampf(1.0 - absf(touchdown_vs) / HARD_VS, 0.0, 1.0)
	var zone := clampf(1.0 - zone_offset_m / ZONE_FULL_MARK, 0.0, 1.0) \
		if zone_offset_m >= 0.0 else ZONE_NEUTRAL / ZONE_POINTS
	var roll := clampf(1.0 - stop_speed_kmh / STOP_REF_KMH, 0.0, 1.0)
	var total := vs * VS_POINTS + zone * ZONE_POINTS + roll * ROLL_POINTS
	var grade: Dictionary = GRADES[GRADES.size() - 1]
	for g in GRADES:
		if total >= float(g["min"]):
			grade = g
			break
	return {
		"vs_points": round(vs * VS_POINTS),
		"zone_points": round(zone * ZONE_POINTS),
		"roll_points": round(roll * ROLL_POINTS),
		"total": int(round(total)),
		"grade": String(grade["text"]),
		"emoji": String(grade["emoji"]),
	}


## 一行展示文案（Toast / 任务面板共用）：「🛬 落地 87 分：飞得很漂亮」。
static func summary(result: Dictionary) -> String:
	return "🛬 落地 %d 分：%s%s" % [
		int(result.get("total", 0)),
		String(result.get("emoji", "")),
		String(result.get("grade", "")),
	]
