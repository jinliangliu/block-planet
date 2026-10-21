class_name FlightReplay
extends Node3D
## 飞行回放（D-033）：任务成功 / 手动触发后，机体沿录制轨迹「重演」，
## 相机按分镜表做电影运镜，并叠加一条幽灵轨迹条带。
##
## 机体重演而非纯相机秀：回放期间把真实机体按录制位姿摆放（物理冻结），
## 座舱 / 追尾 / 翼侧镜头里才有「那架飞机」；结束时机体复位到回放前状态。
##
## 用法（集成方）：cam.set_mode(AircraftCamera.ViewMode.REPLAY) →
## replay.begin(recorder, craft)；跳过 / 自然结束都发 replay_finished，
## 集成方负责 cam.exit_replay() 与恢复输入。

signal replay_finished

## 镜头间过渡时长（s）：相邻镜头在切换前做位移 + 朝向混合，不硬切。
const BLEND := 0.6
## 单镜头默认时长（s）。
const SHOT_DUR := 3.0
## 末镜头最短时长（s）：避免结尾闪过 0.1 s 的碎镜头。
const SHOT_MIN := 1.5
## 环绕半径 / 追尾距离 / 俯视高度（m）。
const ORBIT_RADIUS := 10.0
const CHASE_DIST := 13.0
const TOPDOWN_H := 45.0
## 幽灵轨迹条带半宽（m）。
const TRAIL_HALF_W := 0.28
## 轨迹颜色（早段 → 近段渐变，儿童友好的青蓝色）。
const TRAIL_COLOR_A := Color(0.35, 0.85, 1.0, 0.15)
const TRAIL_COLOR_B := Color(0.55, 0.95, 1.0, 0.95)

enum Shot { ORBIT, COCKPIT, CHASE, TOPDOWN, WING }

var _rec: FlightRecorder = null
var _craft: Aircraft = null
var _camera: AircraftCamera = null
var _playing := false
var _time := 0.0
var _shots: Array[Dictionary] = []
var _trail: MeshInstance3D = null
## 回放前机体位姿与物理开关（结束复位用）。
var _saved_xform := Transform3D.IDENTITY
var _saved_physics := true
## 回放前速度态（_state.velocity 权威 + velocity 同步属性）：
## 回放对机体是「时间未流逝」的运镜，结束时连速度态一起还原，
## 否则会带着回放前的陈旧速度继续滑行（探针实测 3 帧蠕滑 0.5 m）。
var _saved_velocity := Vector3.ZERO
var _saved_state_velocity := Vector3.ZERO
## 浮动原点搬迁（D-062）：录制轨迹已整体重基，幽灵条带按旧坐标建成即失效。
## 置脏后下一帧重建一次（_build_trail 本身禁每帧重建，搬迁一帧一次不破例）。
var _trail_dirty := false


func begin(rec: FlightRecorder, craft: Aircraft, camera: AircraftCamera) -> void:
	if rec == null or rec.sample_count() < 2 or craft == null or craft.is_wrecked():
		return
	_rec = rec
	_craft = craft
	_camera = camera
	_saved_xform = craft.global_transform
	_saved_velocity = craft.velocity
	_saved_state_velocity = craft._state.velocity
	_saved_physics = craft.is_physics_processing()
	craft.set_physics_process(false)
	craft.use_player_input = false
	_time = 0.0
	_build_shots()
	_build_trail()
	_playing = true


func skip() -> void:
	if _playing:
		_finish()


## 浮动原点搬迁通知（D-062，由 main 在 Events.origin_shifted 里调用）：
## 录制缓冲已重基，回放中的幽灵条带置脏待重建。
func note_origin_shifted() -> void:
	if _playing:
		_trail_dirty = true


func is_playing() -> bool:
	return _playing


func process_replay(delta: float) -> void:
	if not _playing:
		return
	# 搬迁后幽灵轨迹失效：先按重基后的录制点重建（机体与相机每帧从
	# sample_at 现取，天然跟随；只有一次性建成的条带需要显式刷新）。
	if _trail_dirty:
		_trail_dirty = false
		_build_trail()
	_time += delta
	var d := _rec.duration()
	if _time >= d:
		_finish()
		return
	var xf := _shot_transform(_shot_at(_time), _time)
	# 镜头间平滑过渡：切换前 BLEND 秒内与下一镜头混合。
	var idx := _shot_index_at(_time)
	if idx + 1 < _shots.size():
		var nxt: Dictionary = _shots[idx + 1]
		var to_next: float = float(nxt["start"]) - _time
		if to_next < BLEND:
			var k := smoothstep(0.0, 1.0, 1.0 - to_next / BLEND)
			xf = _blend(xf, _shot_transform(nxt, _time), k)
	_camera.set_replay_transform(xf)
	_camera.fov = 70.0 if _shot_at(_time)["type"] == Shot.TOPDOWN else 75.0
	# 机体重演：按录制位姿摆放（物理已冻结）。
	var s := _rec.sample_at(_time)
	_craft.global_transform = Transform3D(Basis(s["quat"]), s["pos"])


## ── 分镜表 ───────────────────────────────────────────────────

func _build_shots() -> void:
	_shots.clear()
	var d := _rec.duration()
	var order := [Shot.ORBIT, Shot.COCKPIT, Shot.CHASE, Shot.TOPDOWN, Shot.WING]
	var i := 0
	var t := 0.0
	while t < d - 0.001:
		var dur := minf(SHOT_DUR, maxf(SHOT_MIN, d - t))
		_shots.append({"type": order[i % order.size()], "start": t, "dur": dur})
		t += dur
		i += 1


func _shot_at(t: float) -> Dictionary:
	return _shots[_shot_index_at(t)]


func _shot_index_at(t: float) -> int:
	for i in range(_shots.size()):
		var shot: Dictionary = _shots[i]
		if t < float(shot["start"]) + float(shot["dur"]):
			return i
	return _shots.size() - 1


## 单镜头在时刻 t 的相机位姿（世界坐标）。
func _shot_transform(shot: Dictionary, t: float) -> Transform3D:
	var s := _rec.sample_at(t)
	var basis := Basis(s["quat"])
	var nose: Vector3 = basis * Vector3(0.0, 0.0, -1.0)
	var pos: Vector3 = s["pos"]
	var up: Vector3 = basis * Vector3.UP
	var xf := Transform3D()
	var local := t - float(shot["start"])
	match int(shot["type"]):
		Shot.ORBIT:
			var angle := local * 0.5
			var h := 3.0 + sin(local * 0.7) * 2.0
			xf.origin = pos + Vector3(sin(angle) * ORBIT_RADIUS, h, cos(angle) * ORBIT_RADIUS)
			xf = xf.looking_at(pos + nose * 1.0, Vector3.UP)
		Shot.COCKPIT:
			var eye: Vector3 = pos + basis * Vector3(0.0, 1.15, -3.4)
			xf.origin = eye
			xf = xf.looking_at(eye + nose * 10.0 + up * 1.1, up)
		Shot.CHASE:
			# leveled 基 +Z = 机头方向，追尾相机在机体后方：偏移取 −Z。
			var yaw := atan2(nose.x, nose.z)
			var leveled := Basis(Vector3.UP, yaw)
			xf.origin = pos + leveled * Vector3(0.0, 4.5, -CHASE_DIST)
			xf = xf.looking_at(pos + nose * 2.0, Vector3.UP)
		Shot.TOPDOWN:
			xf.origin = pos + Vector3.UP * TOPDOWN_H
			xf = xf.looking_at(xf.origin + Vector3.DOWN * 10.0, Vector3(0.0, 0.0, 1.0))
		Shot.WING:
			xf.origin = pos + basis * Vector3(6.5, 1.0, 1.0)
			xf = xf.looking_at(pos + nose * 3.0, up)
		_:
			# 同 CHASE：机体正后上方。
			var yaw2 := atan2(nose.x, nose.z)
			var leveled2 := Basis(Vector3.UP, yaw2)
			xf.origin = pos + leveled2 * Vector3(0.0, 4.5, -CHASE_DIST)
			xf = xf.looking_at(pos, Vector3.UP)
	return xf


func _blend(a: Transform3D, b: Transform3D, k: float) -> Transform3D:
	var xf := Transform3D()
	xf.origin = a.origin.lerp(b.origin, k)
	xf.basis = Basis(Quaternion(a.basis).slerp(Quaternion(b.basis), k))
	return xf


## ── 幽灵轨迹 ─────────────────────────────────────────────────

## 一次性建竖直条带：每段一个 quad（世界竖直方向），顶点色按时间渐变。
## 禁每帧重建；只在 begin() 建一次。
func _build_trail() -> void:
	if _trail != null and is_instance_valid(_trail):
		_trail.queue_free()
		_trail = null
	var pts := _rec.points()
	if pts.size() < 2:
		return
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var n := pts.size()
	verts.resize((n - 1) * 4)
	colors.resize((n - 1) * 4)
	var w := Vector3(TRAIL_HALF_W, 0.0, 0.0)
	var idx := 0
	for i in range(n - 1):
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[i + 1]
		# 顶点色：整条轨迹按进度从淡青到亮青。
		var ca := TRAIL_COLOR_A.lerp(TRAIL_COLOR_B, float(i) / float(n - 1))
		var cb := TRAIL_COLOR_A.lerp(TRAIL_COLOR_B, float(i + 1) / float(n - 1))
		verts[idx] = a + w
		verts[idx + 1] = a - w
		verts[idx + 2] = b - w
		verts[idx + 3] = b + w
		colors[idx] = ca
		colors[idx + 1] = ca
		colors[idx + 2] = cb
		colors[idx + 3] = cb
		idx += 4
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	# 每段一个 quad（4 顶点）→ 6 索引，PRIMITIVE_TRIANGLES。
	var indices := PackedInt32Array()
	indices.resize((n - 1) * 6)
	for i in range(n - 1):
		var v := i * 4
		var o := i * 6
		indices[o + 0] = v
		indices[o + 1] = v + 1
		indices[o + 2] = v + 2
		indices[o + 3] = v
		indices[o + 4] = v + 2
		indices[o + 5] = v + 3
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = false
	_trail = MeshInstance3D.new()
	_trail.mesh = mesh
	_trail.material_override = mat
	add_child(_trail)


## ── 收尾 ─────────────────────────────────────────────────────

func _finish() -> void:
	if not _playing:
		return
	_playing = false
	if _craft != null and is_instance_valid(_craft):
		_craft.set_physics_process(_saved_physics)
		_craft.use_player_input = true
		_craft.global_transform = _saved_xform
		# 连速度态一起还原：回放=时间未流逝，机体按原速继续（滑跑中的
		# 任务成功回放结束后照样滑行至停，不会瞬停）。
		_craft._state.velocity = _saved_state_velocity
		_craft.velocity = _saved_velocity
	if _trail != null and is_instance_valid(_trail):
		_trail.visible = false
	_camera = null
	_craft = null
	_rec = null
	replay_finished.emit()
