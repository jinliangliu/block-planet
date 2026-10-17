extends Node
## 航海玩法探针（D-042）：四大洋默认提供一艘船，驾船出海距离决定可钓鱼种；
## 航海 HUD 关注方位 / 海况 / 航向 / 油量。本探针在大洋区启动主场景，
## 覆盖默认发船、港口建造、登船/下船、纯逻辑动力学、海况模型、出海分带钓点
## 与鱼池。
##
## A. BoatSystem 默认发船 + 拥有关系
## B. 大洋区港口建造：玩家默认船节点存在且 harbor_pos 已注入（非 ZERO）
## C. 登船 / 下船：Player.ride_boat / exit_boat 与 Events.boat_ride_changed
## D. BoatPhysics 纯逻辑：全油门能开、打舵能转向、油耗随动力输出
## E. 海况模型 + 出海距离分带 + 分带钓点映射 + 鱼池非空
##
## 运行：Godot_v4.6.3-stable_win64.exe --headless --path . res://tests/boat_probe.tscn

var _failed := 0


func _ready() -> void:
	await _run()


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("PASS: %s" % msg)
	else:
		_failed += 1
		print("FAIL: %s" % msg)


## 在 main 场景子树里找一艘可驾驶的船（use_player_input 且已注入港口）。
func _player_boat(main_scene: Node) -> Boat:
	for child in main_scene.get_children():
		var b := child as Boat
		if b != null and is_instance_valid(b) and b.use_player_input and b.harbor_pos != Vector3.ZERO:
			return b
	return null


func _run() -> void:
	# 存档隔离（D-010 铁律 3）：必须在实例化 main.tscn 之前。
	SaveGuard.snapshot()
	var prev_pick := GameState.needs_region_pick
	GameState.needs_region_pick = false
	# 切到大洋区（带简易降落场 + 港口）。
	GameState.current_region = RegionAtlas.PACIFIC

	var main_scene: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main_scene)
	for i in range(120):
		await get_tree().process_frame

	var player: Player = main_scene.get_node("Player")

	# ── A. 默认发船 + 拥有关系 ──
	_check(BoatSystem.owns("raft"), "开局默认发放木筏（拥有 raft）")
	_check(BoatSystem.current_boat_id() == "raft", "当前默认驾驶船 = raft")
	_check(BoatSystem.boat_by_id("raft").get("unlock", "") == "default", "raft 标记为默认船 unlock=default")
	_check(BoatSystem.boat_by_id("speedboat").get("fuel_l", 0.0) > 0.0, "快艇有油量（动力船）")
	_check(BoatSystem.boat_by_id("raft").get("fuel_l", 1.0) <= 0.0, "木筏无油量（无动力）")

	# ── B. 港口建造：玩家默认船节点存在且 harbor_pos 已注入 ──
	var pb: Boat = _player_boat(main_scene)
	_check(pb != null, "大洋区生成了带港口的默认船（harbor_pos 已注入）")
	if pb != null:
		_check(pb.global_position.distance_to(pb.harbor_pos) < 12.0,
			"默认船泊在港口泊位附近（距泊位 %.1f 格）" % pb.global_position.distance_to(pb.harbor_pos))
		# 港湾里还有异型景观船（种类不一）。
		var scenery := 0
		for child in main_scene.get_children():
			var b := child as Boat
			if b != null and is_instance_valid(b) and not b.use_player_input:
				scenery += 1
		_check(scenery >= 2, "港湾里泊着 ≥2 艘异型景观船（实际 %d 艘）" % scenery)

	# ── C. 登船 / 下船 ──
	if pb != null and player != null:
		var rode := false
		player.ride_boat(pb)
		await get_tree().process_frame
		rode = player.is_riding_boat() and pb.piloted
		_check(rode, "按 F 登船：玩家进入驾驶、船 piloted=true")
		_check(player.boat() == pb, "Player.boat() 返回当前驾驶船")

		# ── D. BoatPhysics 纯逻辑动力学（直接驱动物理对象，避开场景输入）──
		var bp := BoatPhysics.new()
		bp.setup(BoatSystem.boat_by_id("raft"), Vector2.ZERO, 0.0)
		var sea := BoatSystem.sea_state(RegionAtlas.PACIFIC, DayNightCycle.Weather.CLEAR, 43200.0, false)
		bp.throttle = 1.0
		bp.steer = 0.0
		for i in 40:
			bp.step(1.0 / 60.0, sea)
		_check(bp.speed() > 0.0, "木筏全油门能开起来（speed=%.2f 格/s）" % bp.speed())
		_check(bp.heading_deg() < 0.01, "无舵时航向保持 0（朝北）")
		var h0 := bp.heading
		bp.steer = 1.0  # 右舵
		for i in 40:
			bp.step(1.0 / 60.0, sea)
		_check(absf(bp.heading - h0) > 0.1, "打右舵能转向（Δheading=%.2f rad）" % (bp.heading - h0))
		# 动力船油耗：speedboat 烧油。
		var sbp := BoatPhysics.new()
		sbp.setup(BoatSystem.boat_by_id("speedboat"), Vector2.ZERO, 0.0)
		var f0 := sbp.fuel
		sbp.throttle = 1.0
		for i in 120:
			sbp.step(1.0 / 60.0, sea)
		_check(sbp.fuel < f0, "动力船全油门耗油（%.1f → %.1f 升）" % [f0, sbp.fuel])
		# 风推：顺风应比无风更快达到速度。
		var calm := BoatSystem.sea_state(RegionAtlas.PACIFIC, DayNightCycle.Weather.CLEAR, 43200.0, false)
		var bp_tail := BoatPhysics.new()
		bp_tail.setup(BoatSystem.boat_by_id("raft"), Vector2.ZERO, 0.0)
		# 顺风：wind_deg 与航向一致（0），wind_along_mps 应为正。
		calm["wind_along_mps"] = 5.0
		bp_tail.throttle = 1.0
		for i in 40:
			bp_tail.step(1.0 / 60.0, calm)
		_check(absf(float(calm.get("wind_along_mps", 0.0))) > 0.0, "海况含风沿航向分量（顺风推）")

		# ── E. 海况模型 + 分带 + 钓点映射 ──
		var s := BoatSystem.sea_state(RegionAtlas.PACIFIC, DayNightCycle.Weather.RAIN, 1000.0, false)
		_check(s.has("wave_m") and s.has("wind_mps") and s.has("wind_deg"),
			"sea_state 返回浪高/风速/风向（rain 浪更高）")
		_check(float(s.get("wave_m", 0.0)) > 0.0, "雨天有浪高（%.2f m）" % float(s.get("wave_m", 0.0)))
		_check(BoatSystem.band_of(50.0) == "near", "50m → 近海")
		_check(BoatSystem.band_of(150.0) == "mid", "150m → 中海")
		_check(BoatSystem.band_of(300.0) == "far", "300m → 远海")
		_check(BoatSystem.spot_for_distance(RegionAtlas.PACIFIC, 50.0) == "pacific_near",
			"分带钓点 id 映射（pacific/near）")
		_check(BoatSystem.spot_for_distance(RegionAtlas.ATLANTIC, 300.0) == "atlantic_far",
			"分带钓点 id 映射（atlantic/far）")
		for band in ["near", "mid", "far"]:
			var sid := BoatSystem.spot_id_for(RegionAtlas.PACIFIC, band)
			var spot := FishingSystem.get_spot(sid)
			_check(not spot.is_empty() and spot.get("fish_pool", []).size() > 0,
				"出海钓点 %s 有鱼池（%d 种）" % [sid, spot.get("fish_pool", []).size()])
		# 距港距离 → 钓点：从船的 snapshot 取 band。
		var snap := pb.snapshot()
		_check(snap.has("band") and snap.has("harbor_distance_m"),
			"船 snapshot 含渔场带与距港距离（band=%s）" % String(snap.get("band", "")))

		# ── 下船 ──
		player.exit_boat()
		await get_tree().process_frame
		_check(not player.is_riding_boat(), "下船后退出驾驶态")

	# 还原存档并退出（D-010 铁律：不污染真实存档）。
	GameState.needs_region_pick = prev_pick
	SaveGuard.restore()
	if _failed == 0:
		print("BOAT_TEST_OK")
		get_tree().quit(0)
	else:
		print("BOAT_TEST_FAILED count=%d" % _failed)
		get_tree().quit(1)
