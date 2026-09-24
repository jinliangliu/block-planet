extends Node
## 诊断探针：站着不动到底为什么掉血？
## 把三条可能的扣血路径分开测量——饥饿、夜间敌对围攻、掉落/卡死，
## 各跑一段游戏内时间并打印掉血速率，用于定位「不动也狂掉血」的来源。
## 运行：Godot_console.exe --headless --path . res://tests/health_diag.tscn

const FRAMES_PER_SEGMENT := 300
const TIME_SCALE := 10.0

var _failed := 0
## 死亡计数必须是成员：GDScript 的 lambda 捕获局部变量是拷贝，改不到外面。
var _deaths := 0


func _ready() -> void:
	await _run()


func _run() -> void:
	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(60):
		await get_tree().process_frame

	var world: World = main_scene.get_node("World")
	var player: Player = main_scene.get_node("Player")
	var hud: HUD = main_scene.get_node("UI")
	var spawner: MobSpawner = main_scene.get_node("MobSpawner")
	var dn: DayNightCycle = main_scene.get_node("DayNightCycle")

	spawner._spawn_timer = 9999.0
	spawner._passive_timer = 9999.0
	spawner._despawn_all()
	GameState.set_mode(GameState.Mode.SURVIVAL)
	if hud._map_selector != null and hud._map_selector.is_open():
		hud.close_map_selector()
	GameState.needs_region_pick = false

	var base_y := _probe_base_y(world)
	player.global_position = Vector3(8.5, float(base_y) + 1.0, 8.5)
	player.velocity = Vector3.ZERO
	player.spawn_position = player.global_position
	for i in range(30):
		await get_tree().physics_frame

	Engine.time_scale = TIME_SCALE
	var game_seconds := float(FRAMES_PER_SEGMENT) / 60.0 * TIME_SCALE

	# ── A：白天、无生物、饥饿满 ───────────────────────────
	dn._time = 60.0
	player.hunger = float(Player.MAX_HUNGER)
	player.health = Player.MAX_HEALTH
	var a: Array = await _measure(player, FRAMES_PER_SEGMENT)
	print("A 白天静止: %.0f 游戏秒 掉血 %d  饥饿 %.1f→%.1f  stuck=%d"
		% [game_seconds, a[0], a[1], a[2], player.stuck_rescues])

	# ── B：白天、无生物、饥饿归零 ─────────────────────────
	player.hunger = 0.0
	player.health = Player.MAX_HEALTH
	var b: Array = await _measure(player, FRAMES_PER_SEGMENT)
	print("B 饥饿耗尽: %.0f 游戏秒 掉血 %d（每 %.1f 秒 1 点）  stuck=%d"
		% [game_seconds, b[0], game_seconds / maxf(float(b[0]), 1.0), player.stuck_rescues])

	# ── C：夜晚、8 只僵尸贴身、站着不动 ────────────────────
	dn._time = dn.DAY_LENGTH + 30.0
	player.hunger = float(Player.MAX_HUNGER)
	player.health = Player.MAX_HEALTH
	player.died.connect(func(): _deaths += 1)
	var mobs: Array[Mob] = []
	for i in range(8):
		var ang := float(i) / 8.0 * TAU
		var pos := player.global_position + Vector3(cos(ang), 0.0, sin(ang))
		var mob := Mob.new()
		mob.setup(Mob.MobType.ZOMBIE, player, dn)
		main_scene.add_child(mob)
		mob.global_position = pos
		mobs.append(mob)
	for i in range(20):
		await get_tree().physics_frame
	var c: Array = await _measure(player, FRAMES_PER_SEGMENT)
	print("C 夜围 8 僵尸: %.0f 游戏秒 掉血 %d（每秒 %.1f 点）  stuck=%d  死亡 %d 次  终值 hp=%d"
		% [game_seconds, c[0], float(c[0]) / game_seconds, player.stuck_rescues, _deaths,
			player.health])

	Engine.time_scale = 1.0
	for mob in mobs:
		mob.queue_free()
	print("HEALTH_DIAG_DONE A=%d B=%d C=%d" % [a[0], b[0], c[0]])
	get_tree().quit(0)


## 静止推进 frames 个物理帧，返回 [掉血总量, 起始饥饿, 结束饥饿]。
func _measure(player: Player, frames: int) -> Array:
	var hp0 := player.health
	var hg0 := player.hunger
	for i in range(frames):
		await get_tree().physics_frame
	return [hp0 - player.health, hg0, player.hunger]


## 找一块站得住的地面高度（与 life_probe 同法）。
func _probe_base_y(world: World) -> int:
	for y in range(60, 4, -1):
		if BlockTypes.is_solid(world.get_block(Vector3i(8, y, 8))):
			return y
	return 0
