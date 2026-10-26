class_name PoiRegistry
extends RefCounted
## 世界 POI 注册表（D-073 P3）：把世界里**真实存在**的设施（机场 / 降落场 /
## 村庄 / 港口）登记成可直飞的兴趣点，供「POI 直飞」（RouteGenerator 按地形
## 规划航线 + RoutePlan 接管 + 世界环廊可视化）消费。
##
## 数据来源是各建造器的真实落点（main 在场景就绪时登记）——**不是**经纬度
## 地标：REGION_LANDMARKS 只生活在地球 UI，lat_lon→world 映射已被归档否决
## （geo_projection.gd:5-16：玩家活动范围仅原点数百米，真实比例换算的落点
## 无区块、世界内零地标建筑）。
##
## 坐标口径：**世界坐标**（浮动原点搬迁后不变），与任务航点同源；注入导航
## 层前由 main 统一 to_render。

enum Kind { AIRPORT, FIELD, VILLAGE, HARBOR }

## 面板/提示用的中文类名（探针与 UI 共用，避免两处文案漂移）。
const KIND_NAMES := {
	Kind.AIRPORT: "机场",
	Kind.FIELD: "降落场",
	Kind.VILLAGE: "村庄",
	Kind.HARBOR: "港口",
}

## 单条 POI 契契：{id: String, title: String, kind: int, pos: Vector3}。
var _pois: Array[Dictionary] = []


func clear() -> void:
	_pois.clear()


## 登记一个 POI。同 id 重复登记视为覆盖（换区重建等场景的幂等保护）。
func register(id: String, title: String, kind: int, pos: Vector3) -> void:
	var entry := {"id": id, "title": title, "kind": int(kind), "pos": pos}
	for i in range(_pois.size()):
		if String(_pois[i].get("id", "")) == id:
			_pois[i] = entry
			return
	_pois.append(entry)


func size() -> int:
	return _pois.size()


## 全部 POI（元素为拷贝，外部改写不污染注册表）。
func all() -> Array:
	var out: Array = []
	for p in _pois:
		out.append(p.duplicate())
	return out


## 按 id 取单个 POI；不存在返回空字典（调用方据此静默/提示）。
func by_id(id: String) -> Dictionary:
	for p in _pois:
		if String(p.get("id", "")) == id:
			return p.duplicate()
	return {}


func by_kind(kind: int) -> Array:
	var out: Array = []
	for p in _pois:
		if int(p.get("kind", -1)) == kind:
			out.append(p.duplicate())
	return out


## 水平（xz）距离最近的 POI；空表或超距返回空字典。max_dist < 0 = 不限。
func nearest(pos: Vector3, max_dist: float = -1.0) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for p in _pois:
		var q: Vector3 = p.get("pos", Vector3.ZERO)
		var d := Vector2(pos.x - q.x, pos.z - q.z).length()
		if d < best_d and (max_dist < 0.0 or d <= max_dist):
			best_d = d
			best = p.duplicate()
	return best
