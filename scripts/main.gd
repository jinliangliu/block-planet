extends Node3D

@onready var _player: Player = $Player
@onready var _hud: HUD = $UI
@onready var _light: DirectionalLight3D = $DirectionalLight3D
@onready var _world: World = $World
@onready var _day_night: DayNightCycle = $DayNightCycle
@onready var _mob_spawner: MobSpawner = $MobSpawner
@onready var _env: Environment = ($WorldEnvironment as WorldEnvironment).environment


func _ready() -> void:
	InputActions.register()
	_day_night.setup(_light)
	_day_night.setup_environment(_env)
	_world.set_player(_player)
	var spawn_pos := _find_spawn_position()
	_player.global_position = spawn_pos
	_player.set_spawn_position(spawn_pos)
	_player.setup_world(_world)
	_hud.setup(_player)
	_hud.set_day_night(_day_night)
	_mob_spawner.setup(_player, _world, _day_night)
	_build_village()


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
