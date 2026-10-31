class_name RaceSession
extends RefCounted
## 单场比赛的规则引擎（纯逻辑，可无头测试）：检查点顺序、圈数、圈速、排名。
##
## 检查点判定用「门平面穿越」而不是 Area3D：把每个检查点当作一条垂直于赛道
## 的线段，车从后往前穿过平面且在门的横向宽度内才算过门。相比区域触发，它
## 不会因为高速掠过而漏判，也不受帧率影响——而且完全在纯逻辑层，探针能断言。
## 场景里的拱门只是同一份数据的可视化（TrackLoader 画），不是判定源。

enum State { COUNTDOWN, RUNNING, FINISHED }

signal lap_completed(racer_id: String, lap: int, lap_time: float)
signal racer_finished(racer_id: String, finish_time: float, rank: int)
signal gate_passed(racer_id: String, gate: int)
signal race_finished


## 一名参赛者：物理体 + 进度 + 成绩。
class Racer:
	extends RefCounted

	var id := ""
	var display := ""
	var is_player := false
	var color := Color.WHITE
	var vehicle_id := ""
	var car: CarPhysics = null
	var ai: AiRacer = null          # 玩家为 null
	var next_gate := 1              # 下一个必须穿过的门（0 = 起跑线/终点）
	var lap := 0                    # 已完成圈数
	var lap_start := 0.0
	var lap_times: Array[float] = []
	var best_lap := -1.0
	var finish_time := -1.0
	var rank := 0
	var gates_passed := 0
	var used_handbrake := false
	var off_road_time := 0.0
	var prev_pos := Vector2.ZERO
	var gate_distance := 0.0

	func finished() -> bool:
		return finish_time >= 0.0


var layout: TrackLayout = null
var laps := 3
var racers: Array[Racer] = []
var state: State = State.COUNTDOWN
var countdown := 3.0
var elapsed := 0.0
var gate_lateral_limit := 14.0


## p_racers 收普通 Array 而不是 Array[Racer]：内部类做元素类型的字面量在调用方
## 很难构造（`[r] as Array[RaceSession.Racer]` 运行时会类型不符），这里收进来
## 再逐个装进强类型数组，调用方只管把 Racer 丢进来。
func setup(p_layout: TrackLayout, p_laps: int, p_racers: Array) -> void:
	layout = p_layout
	laps = maxi(1, p_laps)
	racers.clear()
	for item: Variant in p_racers:
		if item is Racer:
			racers.append(item as Racer)
	for r in racers:
		r.prev_pos = r.car.pos
		r.gate_distance = r.car.pos.distance_to(Vector2(layout.gate_position(r.next_gate).x,
			layout.gate_position(r.next_gate).z))
	gate_lateral_limit = layout.half_width + 8.0
	refresh_rankings()


## 开始倒计时（秒）。倒计时期间车不动、不计时。
func begin_countdown(seconds: float = 3.0) -> void:
	countdown = maxf(0.0, seconds)
	state = State.COUNTDOWN
	elapsed = 0.0


func is_counting() -> bool:
	return state == State.COUNTDOWN


func tick(dt: float) -> void:
	if state == State.COUNTDOWN:
		countdown -= dt
		if countdown <= 0.0:
			countdown = 0.0
			state = State.RUNNING
			elapsed = 0.0
			for r in racers:
				r.lap_start = 0.0
	elif state == State.RUNNING:
		elapsed += dt


## 一名参赛者本帧的进度推进（在物理步进之后调用）。
## dt 默认 1/60 s，只是为了让不传 dt 的旧调用（探针）行为不变；
## 场景必须传真实帧长，否则 off-road 计时在低帧率机器上会系统性偏小。
func update_progress(r: Racer, terrain_off_road: bool, dt: float = 0.0166) -> void:
	if r.finished():
		return
	if terrain_off_road:
		r.off_road_time += maxf(dt, 0.0)
	var gp := layout.gate_position(r.next_gate)
	var gd := layout.direction(layout.gate_index(r.next_gate))
	var g_xy := Vector2(gp.x, gp.z)
	var d_xy := Vector2(gd.x, gd.z)
	var s_prev := (r.prev_pos - g_xy).dot(d_xy)
	var s_cur := (r.car.pos - g_xy).dot(d_xy)
	var lateral := absf((r.car.pos - g_xy).dot(Vector2(-gd.z, gd.x)))
	if s_prev < 0.0 and s_cur >= 0.0 and lateral <= gate_lateral_limit:
		_pass_gate(r)
	r.prev_pos = r.car.pos
	r.gate_distance = r.car.pos.distance_to(g_xy)


func _pass_gate(r: Racer) -> void:
	if r.next_gate == 0:
		var lt := maxf(elapsed - r.lap_start, 0.0)
		r.lap += 1
		r.lap_times.append(lt)
		if r.best_lap < 0.0 or lt < r.best_lap:
			r.best_lap = lt
		r.lap_start = elapsed
		lap_completed.emit(r.id, r.lap, lt)
		if r.lap >= laps:
			r.finish_time = elapsed
			racer_finished.emit(r.id, r.finish_time, 0)
	r.gates_passed += 1
	var count := layout.gate_count()
	gate_passed.emit(r.id, r.next_gate)
	r.next_gate = (r.next_gate + 1) % count


## 是否所有参赛者都已完赛。
func all_finished() -> bool:
	for r in racers:
		if not r.finished():
			return false
	return true


func player() -> Racer:
	for r in racers:
		if r.is_player:
			return r
	return null


func racer_by_id(id: String) -> Racer:
	for r in racers:
		if r.id == id:
			return r
	return null


## 重算并写入每人的名次（1 起）。
func refresh_rankings() -> void:
	var arr := racers.duplicate()
	arr.sort_custom(_rank_before)
	for i in arr.size():
		(arr[i] as Racer).rank = i + 1


func _rank_before(a: Racer, b: Racer) -> bool:
	var af := a.finished()
	var bf := b.finished()
	if af and bf:
		return a.finish_time < b.finish_time
	if af != bf:
		return af
	if a.lap != b.lap:
		return a.lap > b.lap
	if a.gates_passed != b.gates_passed:
		return a.gates_passed > b.gates_passed
	return a.gate_distance < b.gate_distance


## 结算用：按名次排好的成绩表。
func results() -> Array:
	refresh_rankings()
	var arr := racers.duplicate()
	arr.sort_custom(_rank_before)
	var out: Array = []
	for r in arr:
		out.append({
			"id": r.id,
			"display": r.display,
			"is_player": r.is_player,
			"color": r.color,
			"rank": r.rank,
			"laps": r.lap,
			"best_lap": r.best_lap,
			"finish_time": r.finish_time,
			"vehicle_id": r.vehicle_id,
			"used_handbrake": r.used_handbrake,
			"finished": r.finished(),
		})
	return out


func racer_count() -> int:
	return racers.size()
