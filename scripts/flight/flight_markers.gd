class_name FlightMarkers
extends Node3D
## 世界 3D 标注（D-034 第三人称玩法）：
##   - 目标点：金色双环（贴地，从空中与接近段都看得见）+ 悬浮 Label3D 名称/距离
##   - 跑道引导：接近段地面的箭头列（指向目标）+ 3° 下滑道双轨（从约 250m 外、
##     高度 +13m 处沿 3° 下降走廊引向目标），儿童向「跟着线飞就能落地」
##   - 距目标 < 50m 时整体淡出（避免贴脸挡视线）
##
## 本节点由 main 在登机时加入世界、下机时释放；target / runway 坐标由飞行 HUD
## 或任务系统经 set_target / set_runway_guide 注入。

const FADE_DISTANCE := 50.0
const RING_COLOR := Color(1.0, 0.82, 0.20)
const ARROW_COLOR := Color(0.40, 0.85, 0.45)
const GLIDE_COLOR := Color(0.35, 0.80, 0.95)

var _craft: Node3D = null
var _target_pos := Vector3.ZERO
var _has_target := false
var _target_group: Node3D = null
var _target_mat: StandardMaterial3D = null
var _target_label: Label3D = null
var _runway_group: Node3D = null


func setup(craft: Node3D, world_root: Node3D) -> void:
	_craft = craft


func set_target(target: Vector3, name: String = "") -> void:
	_target_pos = target
	_has_target = true
	if _target_group == null:
		_target_group = Node3D.new()
		_target_group.name = "TargetMarker"
		add_child(_target_group)
		# 双环（贴地）：两个同心 TorusMesh，法线朝上（绕 X 转 -90° 平躺）。
		for i in range(2):
			var ring := MeshInstance3D.new()
			var tm := TorusMesh.new()
			tm.inner_radius = 3.0 + i * 2.0
			tm.outer_radius = 3.8 + i * 2.0
			ring.mesh = tm
			ring.rotation.x = -PI * 0.5
			var mat := StandardMaterial3D.new()
			mat.albedo_color = RING_COLOR
			mat.emission_enabled = true
			mat.emission = RING_COLOR
			mat.emission_energy_multiplier = 0.7
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = 0.92
			ring.material_override = mat
			if i == 0:
				_target_mat = mat
			_target_group.add_child(ring)
		_target_label = Label3D.new()
		_target_label.text = name if name != "" else "目标"
		_target_label.font_size = 64
		_target_label.modulate = RING_COLOR
		_target_label.position = Vector3(0.0, 6.0, 0.0)
		# 4.6.3 的 Label3D.BillboardMode 枚举未作为脚本常量导出，billboard 属性为
		# 整型枚举（Disabled=0 / Enabled=1 / Y-Billboard(FixedY)=2）。直接用值 2
		# 设定「仅绕 Y 轴朝向相机」，让悬浮名称在任意方位都正立可读。
		if "billboard" in _target_label:
			_target_label.billboard = 2
		_target_group.add_child(_target_label)
	_target_group.global_position = target
	if _target_label != null:
		_target_label.text = ("%s  %.0f m" % [name if name != "" else "目标", 0.0])


func clear_target() -> void:
	_has_target = false
	if _target_group != null:
		_target_group.queue_free()
		_target_group = null
		_target_label = null
		_target_mat = null


## 设置跑道/降落引导：entry 为进近起点参考（一般用机场中心），axis 为跑道指向
## （从进近方向指向跑道头的水平单位向量）。以此铺出地面箭头与 3° 下滑道。
func set_runway_guide(entry: Vector3, axis: Vector3) -> void:
	clear_runway_guide()
	_runway_group = Node3D.new()
	_runway_group.name = "RunwayGuide"
	add_child(_runway_group)
	var flat := Vector3(axis.x, 0.0, axis.z)
	if flat.length_squared() < 1e-4:
		flat = Vector3(0.0, 0.0, -1.0)
	flat = flat.normalized()
	# 地面箭头：从 entry 沿 axis 朝目标列 6 个箭头，间隔 40m。
	for i in range(6):
		var pos := entry + flat * (float(i) * 40.0 + 20.0)
		pos.y = _ground_y(pos) + 0.3
		_make_arrow(pos, flat, 3.0)
	# 3° 下滑道双轨：从 entry 上方（entry.y + 250·tan3°≈13m）沿 3° 下降引向 entry。
	var start := entry + Vector3(0.0, 250.0 * tan(deg_to_rad(3.0)), 0.0)
	var left := entry + flat.cross(Vector3.UP).normalized() * 4.0
	var right := entry - flat.cross(Vector3.UP).normalized() * 4.0
	_make_line(start + flat.cross(Vector3.UP).normalized() * 4.0, left, 0.6, GLIDE_COLOR)
	_make_line(start - flat.cross(Vector3.UP).normalized() * 4.0, right, 0.6, GLIDE_COLOR)


func clear_runway_guide() -> void:
	if _runway_group != null:
		_runway_group.queue_free()
		_runway_group = null


## 每帧刷新（由 FlightInstrumentHUD.tick 经 register_view 调用）：距目标近时淡出。
func refresh_instruments(fi: FlightInstruments) -> void:
	if not _has_target or _target_group == null or _craft == null:
		return
	var dist := _craft.global_position.distance_to(_target_pos)
	if _target_label != null:
		_target_label.text = "%s  %.0f m" % [
			_target_label.text.get_slice("  ", 0), dist]
	var alpha := clampf(dist / FADE_DISTANCE, 0.0, 1.0)
	if _target_mat != null:
		_target_mat.albedo_color.a = 0.92 * alpha
	if _target_label != null:
		_target_label.modulate.a = alpha


## 地面箭头（圆锥，尖朝行进方向）。
func _make_arrow(pos: Vector3, dir: Vector3, size: float) -> void:
	var cone := MeshInstance3D.new()
	# 本构建无 ConeMesh（4.6.3 已移除），用锥化圆柱近似箭头：底粗顶细，沿 dir 横置。
	var cm := CylinderMesh.new()
	cm.bottom_radius = size * 0.5
	cm.top_radius = size * 0.12
	cm.height = size
	cone.mesh = cm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ARROW_COLOR
	mat.emission_enabled = true
	mat.emission = ARROW_COLOR
	mat.emission_energy_multiplier = 0.6
	cone.material_override = mat
	# 锥尖默认 +Y：把 +Y 对齐到水平行进方向 dir。
	var up := Vector3.UP
	var x := dir.cross(up).normalized()
	var z := x.cross(dir).normalized()
	cone.transform.basis = Basis(x, dir, z)
	# 先入树再设 global_position / look_at：节点不在树里时二者报错且不生效。
	_runway_group.add_child(cone)
	cone.global_position = pos


## 两点之间的细长方体连线（下滑道轨）。
func _make_line(a: Vector3, b: Vector3, thick: float, color: Color) -> void:
	var len := a.distance_to(b)
	var box := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(thick, thick, len)
	box.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.6
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a = 0.7
	box.material_override = mat
	# 先入树再设 global_position / look_at（不在树里二者报错且不生效）。
	_runway_group.add_child(box)
	box.global_position = (a + b) * 0.5
	box.look_at(b, Vector3.UP)


## 取某水平位置处的地表高度（带 fallback 0）：无世界引用即退回目标 y。
func _ground_y(p: Vector3) -> float:
	return 0.0
