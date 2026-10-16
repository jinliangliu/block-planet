class_name TrackLayout
extends RefCounted
## 闭合赛道的几何与地形分段（纯逻辑，不碰节点，可无头测试）。
##
## 赛道是一圈闭合的中心线：r(θ) = R·(1 + amp·sin(lobes·θ+phase) + amp2·sin(lobes2·θ+phase2))。
## 先按目标长度（length_m）解出 R，再等距重采样成 points（每 SPACING 米一个点）。
## 地形按 terrain_segments 的「圈程百分比」逐点贴标签，供 CarPhysics 查抓地力/极速。
##
## 为什么不用体素铺路：世界是流式加载的，一条 1200 m 的赛道要跨 150 个区块，
## 远超加载窗口；赛道因此是独立的 3D 几何（见 TrackLoader），不与体素世界耦合。

const SPACING := 4.0        # 中心线采样间距（m）
const DENSE := 2048         # 解 R 用的密集采样数
const ROAD_Y := 0.0         # 路面高度（竞技场是平的）
const GATE_SPACING_M := 300.0   # 检查点大致间距

var id: String = ""
var name_zh: String = ""
var name_en: String = ""
var theme: String = ""
var difficulty: int = 1
var laps: int = 3
var seed: int = 0
var half_width: float = 6.0
var total: float = 0.0                          # 中心线周长（m）
var points := PackedVector3Array()              # 闭合中心线（首点不重复出现）
var terrain_ids := PackedStringArray()          # 与 points 等长
var gate_indices := PackedInt32Array()          # 检查点所在下标，[0] 为起跑线


## 由 tracks.json 的一条定义构建。
static func build(def: Dictionary) -> TrackLayout:
	var l := TrackLayout.new()
	l.id = String(def.get("id", ""))
	l.name_zh = String(def.get("name_zh", l.id))
	l.name_en = String(def.get("name_en", l.id))
	l.theme = String(def.get("theme", "mixed"))
	l.difficulty = int(def.get("difficulty", 1))
	l.laps = int(def.get("laps", 3))
	l.seed = int(def.get("seed", 0))
	l.half_width = float(def.get("half_width_m", 6.0))
	var length_target := float(def.get("length_m", 1200.0))

	var shape: Dictionary = def.get("shape", {})
	var amp := float(shape.get("amp", 0.1))
	var lobes := int(shape.get("lobes", 3))
	var phase := float(shape.get("phase", 0.0))
	var amp2 := float(shape.get("amp2", 0.04))
	var lobes2 := int(shape.get("lobes2", 5))
	var phase2 := float(shape.get("phase2", 0.0))

	# ① 密集采样求实际周长，反解 R 使周长落在 length_target。
	var r0 := length_target / TAU
	var raw := PackedVector2Array()
	var cum_raw := PackedFloat32Array()
	for i in DENSE:
		var th := TAU * float(i) / float(DENSE)
		var r := r0 * (1.0 + amp * sin(float(lobes) * th + phase)
			+ amp2 * sin(float(lobes2) * th + phase2))
		raw.append(Vector2(r * cos(th), r * sin(th)))
	var perimeter := 0.0
	cum_raw.resize(DENSE + 1)
	for i in DENSE:
		cum_raw[i] = perimeter
		perimeter += raw[i].distance_to(raw[(i + 1) % DENSE])
	cum_raw[DENSE] = perimeter
	var scale := length_target / maxf(perimeter, 0.001)
	for i in raw.size():
		raw[i] *= scale
	for i in cum_raw.size():
		cum_raw[i] *= scale
	var total_len := perimeter * scale

	# ② 等距重采样（含首点、不含重复末点）。
	var count := maxi(8, int(floor(total_len / SPACING)))
	l.points = PackedVector3Array()
	l.points.resize(count)
	var d := 0.0
	for k in count:
		var p := l._sample_polyline(raw, cum_raw, d)
		l.points[k] = Vector3(p.x, ROAD_Y, p.y)
		d += SPACING
	l.total = float(count) * SPACING

	# ③ 地形分段（按圈程百分比）。
	l.terrain_ids = PackedStringArray()
	l.terrain_ids.resize(count)
	var segments: Array = def.get("terrain_segments", [])
	if segments.is_empty():
		segments = [{"terrain_id": "asphalt", "start": 0.0, "end": 1.0}]
	for k in count:
		var frac := float(k) * SPACING / l.total
		l.terrain_ids[k] = l._terrain_for_frac(segments, frac)

	# ④ 检查点：起跑线在 0，之后大致每 GATE_SPACING_M 一个，至少 3 个。
	var gates := maxi(3, int(round(l.total / GATE_SPACING_M)))
	gates = mini(gates, 8)
	l.gate_indices = PackedInt32Array()
	l.gate_indices.resize(gates)
	for g in gates:
		l.gate_indices[g] = int(round(float(g) * float(count) / float(gates))) % count
	return l


func _sample_polyline(raw: PackedVector2Array, cum_raw: PackedFloat32Array, d: float) -> Vector2:
	var n := raw.size()
	var dist := fposmod(d, maxf(cum_raw[n], 0.001))
	var lo := 0
	var hi := n
	while lo < hi:
		var mid := (lo + hi) / 2
		if cum_raw[mid] < dist:
			lo = mid + 1
		else:
			hi = mid
	var i := clampi(lo - 1, 0, n - 1)
	var seg := maxf(cum_raw[i + 1] - cum_raw[i], 0.0001)
	var t := clampf((dist - cum_raw[i]) / seg, 0.0, 1.0)
	return raw[i].lerp(raw[(i + 1) % n], t)


func _terrain_for_frac(segments: Array, frac: float) -> String:
	for seg: Variant in segments:
		if seg is not Dictionary:
			continue
		var s: Dictionary = seg
		if frac >= float(s.get("start", 0.0)) and frac < float(s.get("end", 1.0)):
			return String(s.get("terrain_id", "asphalt"))
	return String((segments[segments.size() - 1] as Dictionary).get("terrain_id", "asphalt"))


# ── 查询 ──────────────────────────────────────────────────
func size() -> int:
	return points.size()


## 环绕取模。
func wrap_index(i: int) -> int:
	var n := size()
	return ((i % n) + n) % n


func point(i: int) -> Vector3:
	return points[wrap_index(i)]


## 该点的行进方向（单位向量，指向下一个采样点）。
func direction(i: int) -> Vector3:
	var a := point(i)
	var b := point(i + 1)
	var d := b - a
	if d.length_squared() < 0.000001:
		return Vector3(0.0, 0.0, 1.0)
	return d.normalized()


## 该点到下一采样点的法向（水平，指向行进方向左侧）。
func normal(i: int) -> Vector3:
	var d := direction(i)
	return Vector3(d.z, 0.0, -d.x)


func terrain_at_index(i: int) -> String:
	if terrain_ids.is_empty():
		return "asphalt"
	return terrain_ids[wrap_index(i)]


func terrain_at_distance(d: float) -> String:
	return terrain_at_index(int(floor(fposmod(d, maxf(total, 0.001)) / SPACING)))


## 沿圈程取位姿：{pos: Vector3, dir: Vector3, index: int}。
func pose_at_distance(d: float) -> Dictionary:
	var clamped := fposmod(d, maxf(total, 0.001))
	var k := int(floor(clamped / SPACING))
	return {"pos": point(k), "dir": direction(k), "index": wrap_index(k)}


func distance_of_index(i: int) -> float:
	return float(wrap_index(i)) * SPACING


## 起点（起跑线）位姿。
func start_pose() -> Dictionary:
	return {"pos": point(0), "dir": direction(0), "index": 0}


func gate_count() -> int:
	return gate_indices.size()


func gate_index(g: int) -> int:
	return wrap_index(gate_indices[((g % gate_count()) + gate_count()) % gate_count()])


func gate_position(g: int) -> Vector3:
	return points[gate_index(g)]


## 从 from 出发、在前 window 个采样点内找离 pos 最近的下标（环绕）。
## 用于每帧推进「大致跑到哪了」，比全局最近点更抗抄近道/掉头。
func nearest_index_forward(from: int, pos: Vector3, window: int) -> int:
	var best := wrap_index(from)
	var best_d := INF
	for step in window:
		var i := wrap_index(from + step)
		var dd := points[i].distance_squared_to(pos)
		if dd < best_d:
			best_d = dd
			best = i
	return best


## pos 相对第 i 点的横向偏移（左正右负，单位 m）。
func lateral_offset(pos: Vector3, i: int) -> float:
	var n := normal(i)
	var rel := pos - point(i)
	return rel.dot(n)
