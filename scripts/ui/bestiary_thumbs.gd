class_name BestiaryThumbs
extends Node

## 图鉴卡片的 3D 微缩图渲染器（离屏 + 异步 + 缓存）。
##
## 175 张卡片不可能每张挂一个 SubViewport（170 多个活动视口会把帧率吃光），
## 所以这里只用一个共享视口：把某个物种的模型挂进去，等它画完一帧，把结果
## 拍成一张 ImageTexture 交给卡片，然后把模型撤走。渲染一帧、换下一个，
## 主线程不分批阻塞，看上去就是卡片逐渐「长出图来」。
##
## 为什么是异步队列而不是打开图鉴时一次性渲染：一次性渲染要连续几百帧等待，
## 界面会明显卡住；排成队列后每帧最多推进一步，玩家一边浏览已渲染好的部分，
## 后面的卡片陆续补上图，体感上没有等待。
##
## 无渲染设备时（--headless 跑探针）整套跳过：那里没有真实 GPU 管线，
## get_image() 拿不到画面，强行渲染只会拖慢探针，不如让卡片显示占位色块。

signal thumbnail_ready(entry_id: String, texture: Texture2D)

## 每张微缩图的像素尺寸。卡片上显示 56×56，取 128 是为了高分屏不被放大糊掉。
const THUMB_SIZE := Vector2i(128, 128)

## 每帧最多渲染几张。1 表示把开销摊得最薄；赶时间可以调高。
const STEPS_PER_FRAME := 1

var _viewport: SubViewport
var _stage: Node3D
var _camera: Camera3D
var _queue: Array[String] = []
var _cache: Dictionary = {}
var _busy := false
## 无显示设备（headless）时置 false，整套渲染流程跳过。
var _enabled := true


func _ready() -> void:
	# Godot 的 headless 用 DisplayServerHeadless，这里没有渲染设备可言。
	_enabled = DisplayServer.get_name() != "headless"
	if not _enabled:
		set_process(false)
		return
	_build_viewport()


## 用于离线渲染的共享舞台：自带动态光，模型挂进 _stage 就会被拍下来。
func _build_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.size = THUMB_SIZE
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.disable_3d = false
	add_child(_viewport)

	# 模型已归一化到 ~1.25 的包围盒，相机因此用固定参数即可，不必逐个调。
	_camera = Camera3D.new()
	# 注意顺序：look_at 依赖全局变换，必须等相机入了场景树再调用
	# （在树外调用会得到 "Node not inside tree" 警告且朝向不对）。
	_viewport.add_child(_camera)
	_camera.position = Vector3(1.55, 1.15, 1.55)
	_camera.look_at(Vector3(0.0, 0.0, 0.0))

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38.0, 32.0, 0.0)
	key.light_energy = 1.15
	_viewport.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(25.0, -145.0, 0.0)
	fill.light_energy = 0.5
	_viewport.add_child(fill)

	_stage = Node3D.new()
	_viewport.add_child(_stage)


## 排队等候渲染。已经在缓存里的会立刻回吐，不入队。
func request(entry_id: String) -> void:
	if entry_id.is_empty():
		return
	if _cache.has(entry_id):
		thumbnail_ready.emit(entry_id, _cache[entry_id])
		return
	if _queue.has(entry_id):
		return
	_queue.append(entry_id)


## 让某些条目优先排到前面：处理「当前筛选命中的卡片」比全量更贴近用户正在看的。
func prioritize(entry_ids: Array) -> void:
	var head: Array[String] = []
	var rest: Array[String] = []
	for entry_id: String in _queue:
		if entry_ids.has(entry_id):
			head.append(entry_id)
		else:
			rest.append(entry_id)
	_queue = head
	for entry_id: String in rest:
		_queue.append(entry_id)


func cached(entry_id: String) -> Texture2D:
	return _cache.get(entry_id, null)


func cache_size() -> int:
	return _cache.size()


func pending_count() -> int:
	return _queue.size()


## headless 时为 false，UI 据此显示占位色块而不是一片黑。
func is_enabled() -> bool:
	return _enabled


func _process(_delta: float) -> void:
	if _busy or not _enabled:
		return
	for _i in STEPS_PER_FRAME:
		if _queue.is_empty():
			return
		_busy = true
		_render_step(_queue.pop_front())


## 渲染一张：建模 → 等它画出来 → 拍图 → 拆模型。
## 用 await 而不是 whileSpin，是为了不让主线程在这几百毫秒里失去响应。
func _render_step(entry_id: String) -> void:
	var entry := BestiaryData.get_entry(entry_id)
	if entry.is_empty():
		_busy = false
		return
	var model := BestiaryModel.build(entry)
	_stage.add_child(model)
	# 必须在入树之后再藏名牌：Mob 的 Label3D 是在 _ready（即 add_child 那一刻）
	# 才创建的，提前调 hide_labels 什么都找不到。
	BestiaryModel.hide_labels(model)
	# Mob 的造型在 _ready 里才建出来，所以要等它被加进树之后才能算包围盒。
	await get_tree().process_frame
	BestiaryModel.normalize(model)
	# 再等一帧：确保这一帧的画面是 normalize 之后的结果。
	await get_tree().process_frame
	await RenderingServer.frame_post_draw

	if is_instance_valid(_viewport) and is_instance_valid(_viewport.get_texture()):
		var image := _viewport.get_texture().get_image()
		if image != null and not image.is_empty():
			var texture := ImageTexture.create_from_image(image)
			_cache[entry_id] = texture
			thumbnail_ready.emit(entry_id, texture)
	if is_instance_valid(model):
		model.queue_free()
	_busy = false
