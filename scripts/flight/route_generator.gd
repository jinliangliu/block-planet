class_name RouteGenerator
extends RefCounted
## 短程航线生成器：只依赖 world.get_surface_height(int, int)，不绑定 World 类型。

## 巡航层至少高于较高端点 12 m；本作航线仅数百米，避免无意义的大爬升。
const CRUISE_CLIMB_M := 12.0
## 侧移按 12 m 逐级外推，最多 12 次（144 m），兼顾 180 m 战术地图视野与停机保证。
const DETOUR_STEP_M := 12.0
const MAX_DETOUR_STEPS := 12
## 防止异常调用制造超大同步循环；正常建议值 16~32，128 已远高于玩法需要。
const MAX_SAMPLES := 128


static func plan_between(
		world: Object, from: Vector3, to: Vector3,
		clearance_m: float = 30.0, samples: int = 24) -> Array[Vector3]:
	var minimal := _minimal_route(from, to)
	if world == null or not is_instance_valid(world) or not world.has_method("get_surface_height"):
		return minimal
	if from.is_equal_approx(to) or samples <= 0:
		return minimal
	var horizontal := Vector2(to.x - from.x, to.z - from.z)
	if horizontal.length_squared() < 0.0001:
		return minimal

	var clearance := maxf(clearance_m, 0.0)
	var sample_count := clampi(samples, 2, MAX_SAMPLES)
	var direction := horizontal.normalized()
	var normal := Vector2(-direction.y, direction.x)
	var cruise_y := maxf(from.y, to.y) + CRUISE_CLIMB_M
	var preferred_side := 0
	var sampled: Array[Vector3] = []

	for i in sample_count:
		var ratio := float(i) / float(sample_count - 1)
		var base := from.lerp(to, ratio)
		base.y = cruise_y
		var surface := _surface_height(world, base)
		var point := base
		# 结论：超限采样节点改走水平法向；依据：抬高能保净空但不能形成避山航迹。
		if i > 0 and i < sample_count - 1 and float(surface) + clearance > cruise_y:
			point = _find_detour(world, base, normal, preferred_side, cruise_y, clearance)
			if preferred_side == 0:
				var side_offset := Vector2(point.x - base.x, point.z - base.z).dot(normal)
				if absf(side_offset) > 0.01:
					preferred_side = 1 if side_offset > 0.0 else -1
		sampled.append(point)

	var smoothed := _smooth_once(sampled)
	# 平滑会把点拉近山体，故最后按平滑后的 XZ 重新钳净空，验收看最终航线而非中间态。
	for i in smoothed.size():
		var final_point: Vector3 = smoothed[i]
		var final_surface := _surface_height(world, final_point)
		final_point.y = maxf(final_point.y, maxf(cruise_y, float(final_surface) + clearance))
		smoothed[i] = final_point
	return smoothed


static func _minimal_route(from: Vector3, to: Vector3) -> Array[Vector3]:
	var route: Array[Vector3] = []
	route.append(from)
	route.append(to)
	return route


## 首次遇障比较两侧；选定一侧后保持同侧外推，避免连续山段左右跳变成锯齿。
static func _find_detour(
		world: Object, base: Vector3, normal: Vector2, preferred_side: int,
		planned_y: float, clearance: float) -> Vector3:
	var best := base
	var best_surface := _surface_height(world, base)
	for step in range(1, MAX_DETOUR_STEPS + 1):
		var offset := float(step) * DETOUR_STEP_M
		if preferred_side != 0:
			var candidate := base + Vector3(
				normal.x * offset * float(preferred_side), 0.0,
				normal.y * offset * float(preferred_side))
			var candidate_surface := _surface_height(world, candidate)
			if candidate_surface < best_surface:
				best = candidate
				best_surface = candidate_surface
			if float(candidate_surface) + clearance <= planned_y:
				return candidate
			continue

		var positive := base + Vector3(normal.x * offset, 0.0, normal.y * offset)
		var negative := base - Vector3(normal.x * offset, 0.0, normal.y * offset)
		var positive_surface := _surface_height(world, positive)
		var negative_surface := _surface_height(world, negative)
		if positive_surface < best_surface:
			best = positive
			best_surface = positive_surface
		if negative_surface < best_surface:
			best = negative
			best_surface = negative_surface
		var positive_clear := float(positive_surface) + clearance <= planned_y
		var negative_clear := float(negative_surface) + clearance <= planned_y
		if positive_clear and negative_clear:
			return positive if positive_surface <= negative_surface else negative
		if positive_clear:
			return positive
		if negative_clear:
			return negative
	return best


## 三点加权平均只做一次并保留端点，足以压掉采样折角而不把短程路线过度圆滑。
static func _smooth_once(points: Array[Vector3]) -> Array[Vector3]:
	if points.size() <= 2:
		return points.duplicate()
	var result: Array[Vector3] = []
	result.append(points[0])
	for i in range(1, points.size() - 1):
		result.append((points[i - 1] + points[i] * 2.0 + points[i + 1]) * 0.25)
	result.append(points[points.size() - 1])
	return result


static func _surface_height(world: Object, point: Vector3) -> int:
	return int(world.call(
		"get_surface_height", int(roundf(point.x)), int(roundf(point.z))))
