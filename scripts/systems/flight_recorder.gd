class_name FlightRecorder
extends Node
## 飞行轨迹录制器（D-033 回放的数据源）：环形缓冲记录机体位置 / 姿态 / 油门 /
## 空速，容量 90 s @ 30 Hz，禁止每帧分配（并行定长 Array + 下标取模）。
##
## 用法（集成方）：登机时 start()（自动清空上一段），驾驶中每物理帧
## sample(craft, delta)，下机时 stop()（数据保留供回放）。回放系统经
## points() / sample_at() / duration() 读取。

## 采样率（Hz）。
const SAMPLE_HZ := 30.0
## 环形缓冲容量（样本数）：90 s。
const CAPACITY := 2700
## 单帧推进量上限保护：卡顿后不补写一大堆历史样本。
const MAX_STEPS_PER_FRAME := 4

var _recording := false
## 并行定长缓冲（下标一致）。
var _t: Array[float] = []
var _pos: Array[Vector3] = []
var _quat: Array[Quaternion] = []
var _throttle: Array[float] = []
var _airspeed: Array[float] = []
## 下一写入下标与已填数量（写满后 _count 恒等于 CAPACITY，_head 循环推进）。
var _head := 0
var _count := 0
var _total := 0
var _acc := 0.0


func _init() -> void:
	_t.resize(CAPACITY)
	_pos.resize(CAPACITY)
	_quat.resize(CAPACITY)
	_throttle.resize(CAPACITY)
	_airspeed.resize(CAPACITY)


## 开始一段新录制（先清空旧数据）。
func start() -> void:
	clear()
	_recording = true


func stop() -> void:
	_recording = false


func clear() -> void:
	_recording = false
	_head = 0
	_count = 0
	_total = 0
	_acc = 0.0


func is_recording() -> bool:
	return _recording


## 每物理帧调用：内部按 SAMPLE_HZ 节流追加一样本。
func sample(craft: Aircraft, delta: float) -> void:
	if not _recording or not is_instance_valid(craft):
		return
	_acc += delta
	var interval := 1.0 / SAMPLE_HZ
	var steps := 0
	while _acc >= interval and steps < MAX_STEPS_PER_FRAME:
		_acc -= interval
		steps += 1
		_push(Time.get_ticks_msec() / 1000.0,
			craft.global_position,
			craft.global_transform.basis.get_rotation_quaternion(),
			craft.controls.throttle,
			craft.snapshot().get("airspeed", 0.0))


## 已录制时长（秒）。
func duration() -> float:
	return float(_count) / SAMPLE_HZ


func sample_count() -> int:
	return _count


## 位置序列（按时间顺序，回放建幽灵轨迹用）。调用方自行承担结果生命周期。
func points() -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(_count)
	for i in range(_count):
		out[i] = _pos[_ord(i)]
	return out


## 线性插值取 t 时刻的机体位姿（t 夹在 [0, duration]）。
func sample_at(t: float) -> Dictionary:
	if _count == 0:
		return {"pos": Vector3.ZERO, "quat": Quaternion.IDENTITY, "throttle": 0.0}
	var clamped := clampf(t, 0.0, duration())
	var f := clamped * SAMPLE_HZ
	var i := mini(int(f), _count - 1)
	if i >= _count - 1:
		return {
			"pos": _pos[_ord(_count - 1)],
			"quat": _quat[_ord(_count - 1)],
			"throttle": _throttle[_ord(_count - 1)],
		}
	var frac: float = f - float(i)
	return {
		"pos": _pos[_ord(i)].lerp(_pos[_ord(i + 1)], frac),
		"quat": _quat[_ord(i)].slerp(_quat[_ord(i + 1)], frac),
		"throttle": lerpf(_throttle[_ord(i)], _throttle[_ord(i + 1)], frac),
	}


## 环形下标 → 有序下标（0 = 最旧）。
func _ord(i: int) -> int:
	if _count < CAPACITY:
		return i
	return (_head + i) % CAPACITY


func _push(t: float, pos: Vector3, quat: Quaternion, throttle: float, airspeed: float) -> void:
	_t[_head] = t
	_pos[_head] = pos
	_quat[_head] = quat
	_throttle[_head] = throttle
	_airspeed[_head] = airspeed
	_head = (_head + 1) % CAPACITY
	_count = mini(_count + 1, CAPACITY)
	_total += 1
