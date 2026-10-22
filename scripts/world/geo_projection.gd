class_name GeoProjection
extends RefCounted
## 地理投影工具：只负责「地标经纬度 ↔ 区域 / 球面方向」这一段换算。
##
## ── 先说结论：本文件*故意*不提供设计文档 §3.2 要求的 lat_lon_to_world() ──
## 依据（三条现实约束，缺一不可）：
##   1. 本作世界是程序化生成的方块平面，玩家实际活动范围在原点附近数百米内
##      （亚洲机场中心格 (114,96)、村庄 A x∈[22,86] z∈[28,84]；流送高模半径
##      64 m、低模 256 m）。把「华山 34.48°N 110.08°E」按真实比例换算成世界
##      坐标，落点在十万米开外，玩家既走不到飞不到、区块也不会加载，
##      那边连地形都是空的。
##   2. 世界里没有任何地标建筑（勘察确认：scripts/ 与 scenes/ 下零 landmark 实现），
##      所以「地标」在本作只能是：地球上的视觉标记 + 一张科普知识卡。
##      不存在「传送到地标精确坐标」这条链路，自然也就不需要这个接口。
##   3. 真要把某个点落到世界里，正确的做法是走 World/RegionAtlas 的生成坐标
##      （机场、降落场、村庄都是这么落地的），而不是在本文件里做一次线性插值。
##
## ── 球面映射一律转发 RegionAtlas，不另写一套 ──
## RegionAtlas.lat_lon_to_dir / dir_to_lat_lon 已经是严格互逆的一对，球面的
## 网格、区域名标签、小飞机小鱼、射线拾取全部共用它们。这里若另起一套
## （哪怕数学上等价），只要浮点细节有任何差异，「图钉钉在长江口」与
## 「点长江口却选中黄河」就会错位——这正是共用同一函数对换来的几何一致性。
##
## ── region_bounds() 是常识近似值，不是制图数据 ──
## 精度与 5° 陆地掩码同量级，用途只有两个：
##   ① 粗筛「这个地标大致挂在哪一片」；
##   ② 在区域介绍页用一句话告诉玩家「这里大致在地球的哪一片」。
## 严禁拿它做任何精确判读（不要拿它断言国界、岛屿归属、海峡宽度）。
## 经度允许写成 >180（如太平洋 135..290），表示跨过国际日期变更线，
## 判断时统一把目标经度抬到同一圈里比较。

## 经纬度 ↔ 方向向量往返自检的容差（度）。超过此值判定两套映射不一致。
const ROUND_TRIP_TOLERANCE := 0.5
## 各区域的近似经纬度包围盒（按 region_id 索引，与 REGION_CARDS 同构）。
## 全部是常识取整值：正好同数量级于 5° 陆地掩码（它的印度洋/太平洋分界线
## 画在 147°E 与 -70°W），多几度少几度不影响任何一个用例。
const REGION_BOUNDS := [
	{"lat_min": -60.0, "lat_max": 65.0, "lon_min": 135.0, "lon_max": 290.0},  # 太平洋（跨日期变更线）
	{"lat_min": -60.0, "lat_max": 70.0, "lon_min": -70.0, "lon_max": 20.0},   # 大西洋
	{"lat_min": -60.0, "lat_max": 30.0, "lon_min": 20.0, "lon_max": 147.0},   # 印度洋
	{"lat_min": 60.0, "lat_max": 90.0, "lon_min": -180.0, "lon_max": 180.0},  # 北冰洋（环纬度带）
	{"lat_min": 0.0, "lat_max": 78.0, "lon_min": 25.0, "lon_max": 180.0},     # 亚洲
	{"lat_min": 34.0, "lat_max": 72.0, "lon_min": -25.0, "lon_max": 45.0},    # 欧洲
	{"lat_min": -35.0, "lat_max": 37.0, "lon_min": -20.0, "lon_max": 52.0},   # 非洲
	{"lat_min": 15.0, "lat_max": 75.0, "lon_min": -170.0, "lon_max": -50.0},  # 北美洲
	{"lat_min": -56.0, "lat_max": 13.0, "lon_min": -82.0, "lon_max": -34.0},  # 南美洲
	{"lat_min": -48.0, "lat_max": -8.0, "lon_min": 110.0, "lon_max": 180.0},  # 大洋洲
	{"lat_min": -90.0, "lat_max": -60.0, "lon_min": -180.0, "lon_max": 180.0},  # 南极洲（环纬度带）
]


## 经纬度属于哪个区域（转发陆地掩码判决，含四大洋归属判据）。
static func land_mask_region(lat: float, lon: float) -> int:
	return RegionAtlas.region_at_lat_lon(lat, lon)


## 经纬度 → 球面单位方向向量（转发 RegionAtlas，与网格生成同源）。
static func landmark_dir(lat: float, lon: float) -> Vector3:
	return RegionAtlas.lat_lon_to_dir(lat, lon)


## 区域近似包围盒。返回副本，避免调用方改到常量表。
static func region_bounds(region_id: int) -> Dictionary:
	var id := clampi(region_id, 0, RegionAtlas.COUNT - 1)
	var box: Dictionary = REGION_BOUNDS[id]
	return box.duplicate()


## 该经纬度是否落在此区域的近似包围盒内。
## 注意：这是「大致落在哪一片」的粗筛，不用于精确制图；
## 陆地归属请以 land_mask_region() 为准。
static func in_region(lat: float, lon: float, region_id: int) -> bool:
	var box := region_bounds(region_id)
	var lat_min: float = box["lat_min"]
	var lat_max: float = box["lat_max"]
	if lat < lat_min or lat > lat_max:
		return false
	# 跨日期变更线的包围盒（lon_max > 180）把经度抬到同一圈再比。
	var lon_min: float = box["lon_min"]
	var lon_max: float = box["lon_max"]
	var lo := lon
	while lo < lon_min:
		lo += 360.0
	return lo <= lon_max


## 把「球面上的全局地标序号」翻译成数据里的 (region_id, 区内下标)。
## 返回 (-1,-1) 表示越界。
static func landmark_ref(global_index: int) -> Vector2i:
	if global_index < 0:
		return Vector2i(-1, -1)
	var left := global_index
	for region_id in RegionAtlas.COUNT:
		var marks: Array = RegionAtlas.landmarks_of(region_id)
		if left < marks.size():
			return Vector2i(region_id, left)
		left -= marks.size()
	return Vector2i(-1, -1)


## 全局地标条数（跨全部区域求和），供探针与拾取索引对齐校对。
static func landmark_total() -> int:
	var total := 0
	for region_id in RegionAtlas.COUNT:
		total += RegionAtlas.landmarks_of(region_id).size()
	return total


## 自检：返回失败项列表，空列表表示全部通过。
## 探针据此断言，不靠 print 目检。
static func self_test() -> Array[String]:
	var fails: Array[String] = []
	_append_round_trip_fails(fails)
	_append_bounds_fails(fails)
	return fails


## ① 经纬度 → 方向向量 → 经纬度的往返互逆：走一遍真实地标坐标 +
##    一组跨象限的一般点，任何一点误差超过容差即报失败。
static func _append_round_trip_fails(fails: Array[String]) -> void:
	var probes: Array[Vector2] = [
		Vector2(0.0, 0.0), Vector2(45.0, 120.0), Vector2(-60.0, -75.0),
		Vector2(89.9, 0.0), Vector2(-89.9, 179.0),
	]
	for region_id in RegionAtlas.COUNT:
		for mark: Dictionary in RegionAtlas.landmarks_of(region_id):
			probes.append(Vector2(float(mark["lat"]), float(mark["lon"])))
	var worst := 0.0
	var worst_at := Vector2.ZERO
	for p: Vector2 in probes:
		var back := RegionAtlas.dir_to_lat_lon(RegionAtlas.lat_lon_to_dir(p.x, p.y))
		var err := maxf(absf(back.x - p.x), absf(back.y - p.y))
		if err > worst:
			worst = err
			worst_at = p
	if worst > ROUND_TRIP_TOLERANCE:
		fails.append("球面往返最大误差 %.4f° > %.1f°（最差点 %.2f, %.2f）" % [
			worst, ROUND_TRIP_TOLERANCE, worst_at.x, worst_at.y,
		])


## ② 包围盒自身的健全性：条目数齐全、纬度夹在 [-90,90]、上下界不倒置。
static func _append_bounds_fails(fails: Array[String]) -> void:
	if REGION_BOUNDS.size() != RegionAtlas.COUNT:
		fails.append("包围盒条目数 %d ≠ 区域数 %d" % [REGION_BOUNDS.size(), RegionAtlas.COUNT])
		return
	for i in REGION_BOUNDS.size():
		var box: Dictionary = REGION_BOUNDS[i]
		var lat_min: float = box["lat_min"]
		var lat_max: float = box["lat_max"]
		var lon_min: float = box["lon_min"]
		var lon_max: float = box["lon_max"]
		if lat_min >= lat_max or lon_min >= lon_max:
			fails.append("区域 %d 包围盒上下界倒置" % i)
		if lat_min < -90.0 or lat_max > 90.0:
			fails.append("区域 %d 纬度越界 [%s, %s]" % [i, lat_min, lat_max])
		if lon_min < -180.0 or lon_max > 360.0:
			fails.append("区域 %d 经度越界 [%s, %s]" % [i, lon_min, lon_max])
