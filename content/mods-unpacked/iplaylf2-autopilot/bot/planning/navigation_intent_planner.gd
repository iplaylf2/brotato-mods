extends Reference

# Searches feasible movement headings by sampling the action-conditioned value
# field along each reachable trajectory. It does not persist a target identity
# or optimize a terminal waypoint; the returned preference is the heading whose
# evolving opportunity, information, and exposure have the greatest marginal value.

const BattlefieldInfluenceModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/battlefield_influence_model.gd"
)
const MovementTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_timing_model.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const AdaptiveDirectionRefiner := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/adaptive_direction_refiner.gd"
)
const MapInformationValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/map_information_value_model.gd"
)
const SpatialOpportunityValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/spatial_opportunity_value_model.gd"
)

const SIMILAR_DIRECTION_DOT := 0.97

var _battlefield_influence_model: Reference = BattlefieldInfluenceModel.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _direction_refiner: Reference = AdaptiveDirectionRefiner.new()
var _map_information_value_model: Reference = MapInformationValueModel.new()
var _spatial_opportunity_value_model: Reference = SpatialOpportunityValueModel.new()


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_battlefield_influence_model.set_enemy_motion_predictor(predictor)
	_spatial_opportunity_value_model.set_enemy_motion_predictor(predictor)


func plan(
	observation: Dictionary,
	context: Dictionary,
	compute_budget: Dictionary,
	search_work_allocation: Dictionary,
	compute_budget_policy: Reference
) -> Dictionary:
	var geometry: Dictionary = _movement_geometry.derive(observation)
	var timing: Dictionary = MovementTimingModel.derive(observation)
	var horizon_seconds: float = timing.effective_navigation_horizon_seconds
	var map_extent: Dictionary = _map_extent(observation)
	var trajectory_distance: float = min(
		map_extent.radius, geometry.command_speed * horizon_seconds
	)
	var trajectory_sample_count: int = _trajectory_sample_count(trajectory_distance, geometry)
	var baseline_direction_count: int = search_work_allocation.navigation_baseline_direction_count
	var extra_direction_limit: int = search_work_allocation.navigation_extra_evaluation_limit
	var opportunity_directions: Array = _spatial_opportunity_value_model.candidate_directions(
		observation, context
	)
	var baseline_directions: Array = _uniform_directions(baseline_direction_count)
	var stationary_exposure_by_time := {}
	var evaluated_directions := []
	var direction_scores := []
	var trajectory_value_samples := []
	var best := _zero_trajectory()
	var baseline_field_sample_count := 0
	var extra_field_sample_count := 0
	var extra_direction_count := 0

	for direction in baseline_directions:
		var result: Dictionary = _evaluate_trajectory(
			observation,
			context,
			direction,
			trajectory_distance,
			horizon_seconds,
			trajectory_sample_count,
			map_extent,
			stationary_exposure_by_time
		)
		if result.empty():
			continue
		baseline_field_sample_count += result.field_sample_count
		evaluated_directions.push_back(direction)
		direction_scores.push_back({"movement": direction, "score": result.value})
		trajectory_value_samples.push_back(_trajectory_value_sample(result.direction, result))
		if result.value > best.value:
			best = result

	for candidate in opportunity_directions:
		if extra_direction_count >= extra_direction_limit:
			break
		var direction: Vector2 = candidate.direction
		if _has_similar_direction(evaluated_directions, direction):
			continue
		if not compute_budget_policy.can_start_budgeted_work(
			compute_budget, compute_budget_policy.WORK_NAVIGATION_EVALUATION
		):
			break
		var work_started_usec: int = OS.get_ticks_usec()
		var result: Dictionary = _evaluate_trajectory(
			observation,
			context,
			direction,
			trajectory_distance,
			horizon_seconds,
			trajectory_sample_count,
			map_extent,
			stationary_exposure_by_time
		)
		compute_budget_policy.observe_work_duration(
			compute_budget_policy.WORK_NAVIGATION_EVALUATION,
			float(OS.get_ticks_usec() - work_started_usec)
		)
		if result.empty():
			continue
		extra_direction_count += 1
		extra_field_sample_count += result.field_sample_count
		evaluated_directions.push_back(direction)
		direction_scores.push_back({"movement": direction, "score": result.value})
		trajectory_value_samples.push_back(_trajectory_value_sample(result.direction, result))
		if result.value > best.value:
			best = result

	while (
		extra_direction_count < extra_direction_limit
		and compute_budget_policy.can_start_budgeted_work(
			compute_budget, compute_budget_policy.WORK_NAVIGATION_EVALUATION
		)
	):
		var direction: Vector2 = _direction_refiner.propose_direction(direction_scores)
		if direction == Vector2.ZERO:
			break
		var work_started_usec: int = OS.get_ticks_usec()
		var result: Dictionary = _evaluate_trajectory(
			observation,
			context,
			direction,
			trajectory_distance,
			horizon_seconds,
			trajectory_sample_count,
			map_extent,
			stationary_exposure_by_time
		)
		compute_budget_policy.observe_work_duration(
			compute_budget_policy.WORK_NAVIGATION_EVALUATION,
			float(OS.get_ticks_usec() - work_started_usec)
		)
		if result.empty():
			direction_scores.push_back({"movement": direction, "score": -INF})
			continue
		extra_direction_count += 1
		extra_field_sample_count += result.field_sample_count
		evaluated_directions.push_back(direction)
		direction_scores.push_back({"movement": direction, "score": result.value})
		trajectory_value_samples.push_back(_trajectory_value_sample(result.direction, result))
		if result.value > best.value:
			best = result

	var movement_preference: Vector2 = best.direction if best.value > 0.0 else Vector2.ZERO
	return {
		"movement_preference": movement_preference,
		"trajectory_value_samples": trajectory_value_samples,
		"trajectory_value_gain": max(0.0, best.value),
		"selected_trajectory":
		{
			"direction": best.direction,
			"distance": best.distance,
			"horizon_seconds": best.horizon_seconds,
			"sample_count": best.field_sample_count,
			"value": best.value,
			"value_breakdown": best.value_breakdown.duplicate(true),
		},
		"baseline_direction_evaluation_count": evaluated_directions.size() - extra_direction_count,
		"extra_direction_evaluation_count": extra_direction_count,
		"extra_direction_evaluation_limit": extra_direction_limit,
		"baseline_field_sample_evaluation_count": baseline_field_sample_count,
		"extra_field_sample_evaluation_count": extra_field_sample_count,
		"trajectory_sample_count": trajectory_sample_count,
		"sampling_radius": trajectory_distance,
		"local_prediction_radius": geometry.local_prediction_radius,
		"control_distance": geometry.control_distance,
		"source_scope": "visible_and_remembered",
	}


func _evaluate_trajectory(
	observation: Dictionary,
	context: Dictionary,
	direction: Vector2,
	maximum_distance: float,
	horizon_seconds: float,
	sample_count: int,
	map_extent: Dictionary,
	stationary_exposure_by_time: Dictionary
) -> Dictionary:
	if maximum_distance <= 0.0 or horizon_seconds <= 0.0 or sample_count <= 0:
		return {}
	var terminal_position: Vector2 = _clip_to_domain(direction * maximum_distance, map_extent)
	if terminal_position.length() <= 0.0:
		return {}
	var breakdown := _empty_value_breakdown()
	for sample_index in sample_count:
		var fraction: float = float(sample_index + 1) / float(sample_count)
		var time: float = horizon_seconds * fraction
		var position: Vector2 = terminal_position * fraction
		var sample_value: Dictionary = _sample_field_delta(
			observation, context, position, time, stationary_exposure_by_time
		)
		for field in breakdown:
			breakdown[field] += sample_value[field] / float(sample_count)
	breakdown.map_information = (
		_map_information_value_model.value_delta_along_path(observation, terminal_position)
		* context.state_factors.information_value_per_viewport
	)
	var value := 0.0
	for contribution in breakdown.values():
		value += contribution
	return {
		"direction": terminal_position.normalized(),
		"distance": terminal_position.length(),
		"horizon_seconds": horizon_seconds,
		"field_sample_count": sample_count,
		"value": value,
		"value_breakdown": breakdown,
	}


func _sample_field_delta(
	observation: Dictionary,
	context: Dictionary,
	position: Vector2,
	time: float,
	stationary_exposure_by_time: Dictionary
) -> Dictionary:
	var exposure: Dictionary = _battlefield_influence_model.sample_point(
		observation, position, time, context.environmental_pressure_weights
	)
	if not stationary_exposure_by_time.has(time):
		stationary_exposure_by_time[time] = _battlefield_influence_model.sample_point(
			observation, Vector2.ZERO, time, context.environmental_pressure_weights
		)
	var stationary_exposure: Dictionary = stationary_exposure_by_time[time]
	var opportunity: Dictionary = _spatial_opportunity_value_model.point_value_delta(
		observation, context, position, time
	)
	var exposure_delta: float = (
		(exposure.environmental_pressure - stationary_exposure.environmental_pressure)
		* context.state_factors.environmental_exposure_value
	)
	return {
		"material_opportunity": opportunity.material_opportunity,
		"recovery_opportunity": opportunity.recovery_opportunity,
		"future_event_opportunity": opportunity.future_event_opportunity,
		"rule_event_opportunity": opportunity.rule_event_opportunity,
		"weapon_completion_opportunity": opportunity.weapon_completion_opportunity,
		"map_information": 0.0,
		"environmental_exposure": -exposure_delta,
	}


func _trajectory_value_sample(direction: Vector2, result: Dictionary) -> Dictionary:
	return {
		"direction": direction,
		"trajectory_distance": result.distance,
		"trajectory_value": result.value,
		"value_rate": result.value / result.distance,
		"value_breakdown": result.value_breakdown.duplicate(true),
	}


func _zero_trajectory() -> Dictionary:
	return {
		"direction": Vector2.ZERO,
		"distance": 0.0,
		"horizon_seconds": 0.0,
		"field_sample_count": 0,
		"value": 0.0,
		"value_breakdown": _empty_value_breakdown(),
	}


func _empty_value_breakdown() -> Dictionary:
	return {
		"material_opportunity": 0.0,
		"recovery_opportunity": 0.0,
		"future_event_opportunity": 0.0,
		"rule_event_opportunity": 0.0,
		"weapon_completion_opportunity": 0.0,
		"map_information": 0.0,
		"environmental_exposure": 0.0,
	}


func _trajectory_sample_count(distance: float, geometry: Dictionary) -> int:
	var sample_spacing: float = max(
		geometry.control_distance, geometry.default_local_horizon_distance
	)
	# A single right-endpoint sample lands exactly on wave cleanup when the
	# remaining horizon is short, erasing every combat opportunity that required
	# movement earlier in the interval. The first sample and terminal sample
	# preserve both setup value and the absorbing wave boundary.
	# Derived horizons and distances use single-precision engine values. At an
	# exact spacing multiple their quotient can land microscopically above an
	# integer, making ceil add a whole redundant field sample to every direction.
	var spacing_ratio: float = distance / max(1.0, sample_spacing)
	return int(max(2, ceil(spacing_ratio - 0.00001)))


func _uniform_directions(direction_count: int) -> Array:
	var result := []
	for direction_index in direction_count:
		result.push_back(
			Vector2.RIGHT.rotated(TAU * float(direction_index) / float(direction_count))
		)
	return result


func _has_similar_direction(directions: Array, candidate: Vector2) -> bool:
	for direction in directions:
		if direction.dot(candidate) > SIMILAR_DIRECTION_DOT:
			return true
	return false


func _map_extent(observation: Dictionary) -> Dictionary:
	var bounds: Dictionary = observation.localization.map_bounds
	var unknown_extent: float = _movement_geometry.derive(observation).roaming_distance
	var left: float = -bounds.distance_to_left if bounds.seen_left else -unknown_extent
	var right: float = bounds.distance_to_right if bounds.seen_right else unknown_extent
	var top: float = -bounds.distance_to_top if bounds.seen_top else -unknown_extent
	var bottom: float = bounds.distance_to_bottom if bounds.seen_bottom else unknown_extent
	for entity in observation.get("remembered_entities", []):
		var observed_position: Vector2 = entity.last_observed_relative_position
		left = min(left, observed_position.x)
		right = max(right, observed_position.x)
		top = min(top, observed_position.y)
		bottom = max(bottom, observed_position.y)
	var radius: float = 0.0
	for corner in [
		Vector2(left, top), Vector2(right, top), Vector2(left, bottom), Vector2(right, bottom)
	]:
		radius = max(radius, corner.length())
	return {"left": left, "right": right, "top": top, "bottom": bottom, "radius": radius}


func _clip_to_domain(position: Vector2, domain: Dictionary) -> Vector2:
	return Vector2(
		clamp(position.x, domain.left, domain.right), clamp(position.y, domain.top, domain.bottom)
	)
