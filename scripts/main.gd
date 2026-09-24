extends Node3D
## 主场景装配：按 GameState 选定的区域生成世界，并驱动地图选择器。
##
## 区域切换走「重载主场景」这一条路径：GameState（Autoload）存活并把区域 ID
## 带给新场景实例，区块、村庄、生物、HUD 全部随场景重建，无需手工清理世界
## 状态，也就不会残留旧区域的方块改动与储物箱内容。

@onready var _player: Player = $Player
@onready var _hud: HUD = $UI
@onready var _light: DirectionalLight3D = $DirectionalLight3D
@onready var _world: World = $World
@onready var _day_night: DayNightCycle = $DayNightCycle
@onready var _mob_spawner: MobSpawner = $MobSpawner
@onready var _env: Environment = ($WorldEnvironment as WorldEnvironment).environment


func _ready() -> void:
	InputActions.register()

	# 区域参数必须先于世界生成落地：World._ready 用默认区域初始化了噪声，
	# 这里按 GameState 的当前区域覆盖种子、地形起伏与地表材质。
	var profile := RegionAtlas.profile(GameState.current_region)
	_world.set_region(GameState.current_region)
	_day_night.setup(_light)
	_day_night.setup_environment(_env)
	_day_night.set_sky_tint(profile["sky"])

	# 切换区域时随身携带背包，避免换图丢光家当。
	if GameState.carried_inventory != null:
		_player.inventory = GameState.carried_inventory
		GameState.carried_inventory = null

	_world.set_player(_player)
	var spawn_pos := _find_spawn_position()
	_player.global_position = spawn_pos
	_player.set_spawn_position(spawn_pos)
	_player.setup_world(_world)
	_hud.setup(_player)
	_hud.set_day_night(_day_night)
	_hud.set_map_name(String(profile["title"]))
	_mob_spawner.setup(_player, _world, _day_night)
	_mob_spawner.set_region(profile)
	_player.died.connect(func(): Events.player_died.emit())
	Events.region_entered.connect(_on_region_entered)
	_build_village()

	# 首次进入游戏先选地图；之后随时可用 M 键重新选择。
	# 无头环境（探针 / CI）不自动弹出：模态界面会冻结玩家，阻塞自动化流程。
	if GameState.needs_region_pick and DisplayServer.get_name() != "headless":
		_hud.open_map_selector()


## 选图确认：记录区域并重载场景，由新实例按该区域重新生成世界。
func _on_region_entered(region_id: int) -> void:
	GameState.carried_inventory = _player.inventory
	GameState.set_region(region_id)
	get_tree().reload_current_scene()


## 生成固定村庄与掠夺塔（含村民与掠夺者，挂载于本节点，不受昼夜清空管理）。
func _build_village() -> void:
	var builder := VillageBuilder.new()
	builder.build(_world, _player, _day_night, self)


## 出生点：在出生列按真实方块向上扫描"两格空气 + 实心底"，双脚精确落在
## 实心底块顶面——胶囊高 1.8 m 恰占已验证的两格空气；任何悬空偏移都会
## 让身体上部嵌进头顶方块（如邻树树冠）。高度取样必须用出生列本身。
func _find_spawn_position() -> Vector3:
	var x := 8
	var z := 8
	var base_y := _world.get_surface_height(x, z)
	for i in range(32):
		var cell := Vector3i(x, base_y + i, z)
		if (
			_world.get_block(cell) == BlockTypes.Block.AIR
			and _world.get_block(cell + Vector3i(0, 1, 0)) == BlockTypes.Block.AIR
			and _world.get_block(cell + Vector3i(0, -1, 0)) != BlockTypes.Block.AIR
		):
			return Vector3(x + 0.5, float(base_y + i), z + 0.5)
	return Vector3(x + 0.5, float(base_y), z + 0.5)
