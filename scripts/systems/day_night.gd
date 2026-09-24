extends Node3D
class_name DayNightCycle
## 简单昼夜循环：白天 10 分钟，夜晚 5 分钟，控制方向光角度/颜色/强度。
## 同时调制环境光与背景色：仅压暗方向光不足以"入夜变黑"（环境光恒定会
## 把场景整体抬亮），夜晚须同步把环境光与天幕压至近黑。
## time_changed 每秒发射一次，供 HUD 刷新时钟，避免每帧刷新文本。
##
## 区域色调：set_sky_tint 传入该区域的天空色调，乘到天幕与环境光上，
## 让沙漠偏暖黄、雨林偏绿、极地偏冷白——昼夜明暗规律不受影响。

const DAY_LENGTH := 600.0
const NIGHT_LENGTH := 300.0
const FULL_CYCLE := DAY_LENGTH + NIGHT_LENGTH

# 场景默认环境参数（main.tscn 的 Environment），白天按此恢复。
const DAY_AMBIENT_ENERGY := 0.6
const DAY_AMBIENT_COLOR := Color(0.75, 0.78, 0.85)
const DAY_BACKGROUND_COLOR := Color(0.47, 0.68, 0.94)
# 日落边缘（sun=0）过渡色：与夜晚起始值衔接，避免黄昏瞬间跳变。
const DUSK_AMBIENT_COLOR := Color(0.30, 0.32, 0.45)
const DUSK_BACKGROUND_COLOR := Color(0.08, 0.10, 0.18)
# 夜晚目标值：环境光近黑、天幕深蓝近黑。
const NIGHT_AMBIENT_ENERGY := 0.05
const NIGHT_AMBIENT_COLOR := Color(0.16, 0.18, 0.32)
const NIGHT_BACKGROUND_COLOR := Color(0.012, 0.018, 0.05)

# 夜空特效：月亮与星星挂在 _sky_root（每帧贴到相机位置 = 无穷远天幕）。
const SKY_FX_DISTANCE := 115.0
const STAR_LAYER_COUNT := 3
const STARS_PER_LAYER := 60

signal time_changed(day_percent: float, is_day: bool)
## 跨过一整个昼夜循环时发射（第 2 天为 2）。生物生长以「游戏天数」为节拍。
signal day_changed(day: int)

var _light: DirectionalLight3D
var _env: Environment
var _time := 0.0
var _last_emitted_second := -1
## 累计经过的真实秒数，用于换算游戏天数（1 天 = FULL_CYCLE）。
var _elapsed := 0.0
var _day := 1
## 区域天空色调：默认中性白（不改变原配色）。
var _sky_tint := Color(1.0, 1.0, 1.0)
## 夜空特效节点与当前可见度（0=隐形，1=全亮）。
var _sky_root: Node3D
var _moon_material: StandardMaterial3D
var _star_materials: Array[StandardMaterial3D] = []
var _fx_alpha := 0.0


func _ready() -> void:
	_build_sky_fx()


func setup(light: DirectionalLight3D) -> void:
	_light = light


func setup_environment(env: Environment) -> void:
	_env = env


## 设置区域天空色调（乘算），立即刷新一帧配色。
func set_sky_tint(tint: Color) -> void:
	_sky_tint = tint
	_apply_lighting()


func get_sky_tint() -> Color:
	return _sky_tint


func _process(delta: float) -> void:
	_time = fmod(_time + delta, FULL_CYCLE)
	_elapsed += delta
	_track_day()
	_apply_lighting()
	_update_sky_fx(delta)
	var second := int(_time)
	if second != _last_emitted_second:
		_last_emitted_second = second
		time_changed.emit(_time / FULL_CYCLE, is_day())


## 睡觉：把时间直接拨到次日清晨（只在夜晚有效）。
## elapsed 同步补足跨过的时长，保证 day_changed / 生物成长节拍正确。
func sleep_to_morning() -> bool:
	if is_day():
		return false
	_elapsed += FULL_CYCLE - _time
	_time = 0.0
	_track_day()
	_apply_lighting()
	return true


## 当前游戏天数（开局为第 1 天，每过一整个昼夜循环 +1）。
func day_count() -> int:
	return _day


## 累计经过的秒数（探针可用它把天数推进到指定值）。
func elapsed_seconds() -> float:
	return _elapsed


## 直接推进天数（生物生长以天为节拍，探针据此跨过等待）。
func advance_days(amount: int) -> void:
	if amount <= 0:
		return
	_elapsed += float(amount) * FULL_CYCLE
	_track_day()


func _track_day() -> void:
	var day := int(_elapsed / FULL_CYCLE) + 1
	if day != _day:
		_day = day
		day_changed.emit(_day)


func is_day() -> bool:
	return _time < DAY_LENGTH


func get_clock() -> String:
	var minutes := 0.0
	if _time < DAY_LENGTH:
		minutes = 360.0 + (_time / DAY_LENGTH) * 720.0
	else:
		minutes = 1080.0 + ((_time - DAY_LENGTH) / NIGHT_LENGTH) * 720.0
	minutes = fmod(minutes, 1440.0)

	var h := int(minutes / 60.0)
	var m := int(minutes) % 60
	return "%02d:%02d" % [h, m]


func _apply_lighting() -> void:
	if _light == null:
		return

	if is_day():
		var t := _time / DAY_LENGTH
		var sun := sin(PI * t)
		_light.rotation_degrees.x = lerpf(-85.0, -10.0, sun)
		_light.light_energy = maxf(lerpf(0.2, 1.0, sun), 0.2)
		_light.light_color = Color(1.0, 0.98, 0.92) * _sky_tint
		if _env != null:
			# 环境光随日落渐暗并向暮色过渡，与夜晚起始值衔接不跳变。
			_env.ambient_light_energy = lerpf(0.35, DAY_AMBIENT_ENERGY, sun)
			_env.ambient_light_color = DAY_AMBIENT_COLOR.lerp(DUSK_AMBIENT_COLOR, 1.0 - sun) * _sky_tint
			_env.background_color = DAY_BACKGROUND_COLOR.lerp(DUSK_BACKGROUND_COLOR, 1.0 - sun) * _sky_tint
	else:
		var t := (_time - DAY_LENGTH) / NIGHT_LENGTH
		_light.rotation_degrees.x = -85.0
		_light.light_energy = lerpf(0.35, 0.04, t)
		_light.light_color = Color(0.55, 0.60, 0.85)
		if _env != null:
			# 夜晚：环境光与天幕压至近黑，保证"晚上天是黑的"可感知。
			# 渐暗在入夜前 40% 内完成，其余时间保持近黑，避免整夜缓慢变暗。
			var fade := minf(1.0, t / 0.4)
			_env.ambient_light_energy = lerpf(0.30, NIGHT_AMBIENT_ENERGY, fade)
			_env.ambient_light_color = DUSK_AMBIENT_COLOR.lerp(NIGHT_AMBIENT_COLOR, fade)
			_env.background_color = DUSK_BACKGROUND_COLOR.lerp(NIGHT_BACKGROUND_COLOR, fade)


## ── 夜空特效：卡通月亮 + 三层闪烁星星 ─────────────────────────
## 全部程序化贴图，跟随相机位置（等效无穷远），夜晚随夜色淡入、黎明淡出。

func _build_sky_fx() -> void:
	_sky_root = Node3D.new()
	_sky_root.top_level = true
	add_child(_sky_root)

	# 月亮：32×32 像素画——奶黄圆脸 + 陨石坑 + 卡通眯眼笑，挂在西北高空。
	# 仰角刻意压在 30° 左右：默认视角（水平）抬头也能看到，藏太高等于没有。
	var moon := MeshInstance3D.new()
	var moon_quad := QuadMesh.new()
	moon_quad.size = Vector2(16.0, 16.0)
	moon_quad.material = _make_sky_material(_make_moon_texture())
	_moon_material = moon_quad.material
	moon.mesh = moon_quad
	moon.position = Vector3(-58.0, 56.0, -62.0)
	_sky_root.add_child(moon)

	# 星星：三层各 60 颗，不同相位错开闪烁，看起来是一点一点各自眨眼。
	for layer in range(STAR_LAYER_COUNT):
		var mat := _make_sky_material(_make_star_texture())
		_star_materials.append(mat)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		var quad := QuadMesh.new()
		quad.size = Vector2(1.4, 1.4)
		quad.material = mat
		mm.mesh = quad
		mm.instance_count = STARS_PER_LAYER
		var rng := RandomNumberGenerator.new()
		rng.seed = 20260924 + layer
		for i in range(STARS_PER_LAYER):
			var dir := Vector3(
				rng.randf_range(-1.0, 1.0),
				rng.randf_range(0.15, 1.0),
				rng.randf_range(-1.0, 1.0)
			).normalized()
			mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, dir * SKY_FX_DISTANCE))
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		_sky_root.add_child(mi)

	_set_fx_visible(false)


## 未着色 + 公告板 + alpha 混合 + 像素滤波：夜空贴图的通用材质。
func _make_sky_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return mat


## 卡通月亮贴图：奶黄圆脸 + 三枚陨石坑 + 眯眼微笑——完整圆形，远看也认得出。
func _make_moon_texture() -> ImageTexture:
	var size := 32
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(15.5, 15.5)
	var radius := 13.5
	for y in range(size):
		for x in range(size):
			if Vector2(x, y).distance_to(center) > radius:
				continue
			var c := Color(0.99, 0.94, 0.72)
			# 圆环边缘一圈稍暗，像素游戏常见的描边手法。
			if Vector2(x, y).distance_to(center) > radius - 1.5:
				c = Color(0.90, 0.82, 0.58)
			# 陨石坑：三个暗色小圆。
			for crater: Vector2 in [Vector2(9.0, 10.0), Vector2(20.0, 15.0), Vector2(12.0, 22.0)]:
				if Vector2(x, y).distance_to(crater) < 2.2:
					c = Color(0.86, 0.78, 0.55)
			# 卡通眯眼（两道短横）与微笑（下缘一排点）。
			if (x in range(10, 13) and y == 14) or (x in range(18, 21) and y == 14):
				c = Color(0.45, 0.38, 0.22)
			elif y == 20 and x in range(12, 20) and (x + y) % 2 == 0:
				c = Color(0.45, 0.38, 0.22)
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)


## 星星贴图：8×8 十字星点（中心亮、四臂渐隐）。
func _make_star_texture() -> ImageTexture:
	var img := Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)
	for y in range(8):
		for x in range(8):
			var d := absi(x - 3) + absi(y - 3)
			if d == 0:
				img.set_pixel(x, y, Color(1, 1, 1, 1))
			elif d <= 2:
				img.set_pixel(x, y, Color(1, 1, 1, 0.75 - 0.2 * d))
	return ImageTexture.create_from_image(img)


## 每帧：天幕贴着相机（等效无穷远），按夜色淡入淡出，星星错相位闪烁。
func _update_sky_fx(delta: float) -> void:
	if _sky_root == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		_sky_root.global_position = cam.global_position

	var target := 0.0
	if not is_day():
		var t := (_time - DAY_LENGTH) / NIGHT_LENGTH
		target = minf(1.0, t / 0.15) * minf(1.0, (1.0 - t) / 0.1)
	_fx_alpha = lerpf(_fx_alpha, target, minf(1.0, delta * 3.0))
	_set_fx_visible(_fx_alpha > 0.01)
	if _fx_alpha <= 0.01:
		return

	if _moon_material != null:
		_moon_material.albedo_color.a = _fx_alpha
	var now := Time.get_ticks_msec() * 0.001
	for i in range(_star_materials.size()):
		var twinkle := 0.45 + 0.55 * (0.5 + 0.5 * sin(now * (1.6 + 0.7 * i) + i * 2.1))
		_star_materials[i].albedo_color.a = _fx_alpha * twinkle


func _set_fx_visible(visible: bool) -> void:
	if _sky_root != null:
		_sky_root.visible = visible
