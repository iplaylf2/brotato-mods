extends Reference

# Searches reachable terminal states using observed opportunities.

const BattlefieldExposureModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/battlefield_exposure_model.gd"
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
# Far-field navigation yields angular resolution before near-field control: it
# shapes terminal intent, while local collision projection still retains its
# octant safety baseline in every quality mode.
const BASELINE_DIRECTION_COUNT := 8
const CONSTRAINED_DIRECTION_COUNT := 6
const CRITICAL_DIRECTION_COUNT := 4

var _exposure_model: Reference = BattlefieldExposureModel.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _direction_refiner: Reference = AdaptiveDirectionRefiner.new()
var _map_information_value_model: Reference = MapInformationValueModel.new()
var _spatial_opportunity_value_model: Reference = SpatialOpportunityValueModel.new()


func plan(
	observation: Dictionary,
	context: Dictionary,
	compute_budget: Dictionary,
	compute_budget_policy: Reference
) -> Dictionary:
	var scale: Dictionary = _spatial_scale(observation)
	var timing: Dictionary = MovementTimingModel.derive(observation)
	var navigation_horizon_seconds: float = timing.effective_navigation_horizon_seconds
	var map_extent: Dictionary = _map_extent(observation)
	var sampling_radius: float = min(
		map_extent.radius, scale.command_speed * navigation_horizon_seconds
	)
	var quality_mode: String = compute_budget.get("quality_mode", "full")
	var baseline_direction_count := BASELINE_DIRECTION_COUNT
	if quality_mode == "constrained":
		baseline_direction_count = CONSTRAINED_DIRECTION_COUNT
	elif quality_mode == "critical":
		baseline_direction_count = CRITICAL_DIRECTION_COUNT
	var baseline_directions: Array = _uniform_directions(baseline_direction_count)
	var opportunity_directions: Array = _spatial_opportunity_value_model.candidate_directions(
		observation, context
	)
	var origin: Dictionary = _evaluate_position(observation, context, Vector2.ZERO, 0.0)
	var best: Dictionary = origin
	var position_evaluation_count: int = 1
	var evaluated_directions := []
	var direction_scores := []
	var budgeted_position_evaluation_count: int = 0
	for direction in baseline_directions:
		var result: Dictionary = _evaluate_direction(
			observation,
			context,
			direction,
			sampling_radius,
			map_extent,
			scale,
			navigation_horizon_seconds
		)
		if result.empty():
			continue
		position_evaluation_count += 1
		evaluated_directions.push_back(direction)
		direction_scores.push_back({"movement": direction, "score": result.value})
		if result.value > best.value:
			best = result

	for candidate in opportunity_directions:
		var direction: Vector2 = candidate.direction
		if _has_similar_direction(evaluated_directions, direction):
			continue
		if not compute_budget_policy.can_start_budgeted_work(
			compute_budget, compute_budget_policy.WORK_NAVIGATION_EVALUATION
		):
			break
		var work_started_usec: int = OS.get_ticks_usec()
		var result: Dictionary = _evaluate_direction(
			observation,
			context,
			direction,
			sampling_radius,
			map_extent,
			scale,
			navigation_horizon_seconds
		)
		compute_budget_policy.observe_work_duration(
			compute_budget_policy.WORK_NAVIGATION_EVALUATION,
			float(OS.get_ticks_usec() - work_started_usec)
		)
		if result.empty():
			continue
		position_evaluation_count += 1
		budgeted_position_evaluation_count += 1
		evaluated_directions.push_back(direction)
		direction_scores.push_back({"movement": direction, "score": result.value})
		if result.value > best.value:
			best = result

	while compute_budget_policy.can_start_budgeted_work(
		compute_budget, compute_budget_policy.WORK_NAVIGATION_EVALUATION
	):
		var direction: Vector2 = _direction_refiner.propose_direction(direction_scores)
		if direction == Vector2.ZERO:
			break
		var work_started_usec: int = OS.get_ticks_usec()
		var result: Dictionary = _evaluate_direction(
			observation,
			context,
			direction,
			sampling_radius,
			map_extent,
			scale,
			navigation_horizon_seconds
		)
		compute_budget_policy.observe_work_duration(
			compute_budget_policy.WORK_NAVIGATION_EVALUATION,
			float(OS.get_ticks_usec() - work_started_usec)
		)
		if result.empty():
			direction_scores.push_back({"movement": direction, "score": -INF})
			continue
		position_evaluation_count += 1
		budgeted_position_evaluation_count += 1
		evaluated_directions.push_back(direction)
		direction_scores.push_back({"movement": direction, "score": result.value})
		if result.value > best.value:
			best = result

	var terminal_value_gain: float = max(0.0, best.value - origin.value)
	var movement_preference: Vector2 = (
		best.position.normalized()
		if best.position != Vector2.ZERO and terminal_value_gain > 0.0
		else Vector2.ZERO
	)
	return {
		"movement_preference": movement_preference,
		"terminal_value_gain": terminal_value_gain,
		"position_evaluation_count": position_evaluation_count,
		"baseline_position_evaluation_count":
		position_evaluation_count - budgeted_position_evaluation_count,
		"budgeted_position_evaluation_count": budgeted_position_evaluation_count,
		"origin_value": origin.value,
		"selected_value": best.value,
		"selected_value_breakdown": best.value_breakdown,
		"selected_displacement": best.position,
		"sampling_radius": sampling_radius,
		"local_prediction_radius": scale.local_prediction_radius,
		"control_distance": scale.control_distance,
		"source_scope": "visible_and_remembered",
	}


func _evaluate_direction(
	observation: Dictionary,
	context: Dictionary,
	direction: Vector2,
	sampling_radius: float,
	map_extent: Dictionary,
	scale: Dictionary,
	navigation_horizon_seconds: float
) -> Dictionary:
	var position: Vector2 = direction * sampling_radius
	if not _inside_domain(position, map_extent):
		position = _clip_to_domain(position, map_extent)
	if position.length() <= scale.control_distance:
		return {}
	var forecast_seconds: float = min(
		navigation_horizon_seconds, position.length() / max(1.0, scale.command_speed)
	)
	return _evaluate_position(observation, context, position, forecast_seconds)


func _evaluate_position(
	observation: Dictionary, context: Dictionary, position: Vector2, time: float
) -> Dictionary:
	var exposure: Dictionary = _exposure_model.sample_point(
		observation, position, time, context.exposure_policy
	)
	var stationary_exposure: Dictionary = _exposure_model.sample_point(
		observation, Vector2.ZERO, time, context.exposure_policy
	)
	var opportunity_delta: Dictionary = _spatial_opportunity_value_model.value_delta(
		observation, context, position, time
	)
	var information_value: float = (
		_map_information_value_model.value_delta(observation, position)
		* context.state_factors.information_value_per_viewport
	)
	var exposure_cost_delta: float = (
		(exposure.environmental_pressure - stationary_exposure.environmental_pressure)
		* context.state_factors.environmental_exposure_value
	)
	return {
		"position": position,
		"value": opportunity_delta.total + information_value - exposure_cost_delta,
		"value_breakdown":
		{
			"material_opportunity": opportunity_delta.material_opportunity,
			"recovery_opportunity": opportunity_delta.recovery_opportunity,
			"tree_opportunity": opportunity_delta.tree_opportunity,
			"enemy_opportunity": opportunity_delta.enemy_opportunity,
			"map_information": information_value,
			"environmental_exposure": -exposure_cost_delta,
		},
	}


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


func _spatial_scale(observation: Dictionary) -> Dictionary:
	var movement_geometry: Dictionary = _movement_geometry.derive(observation)
	var command_speed: float = movement_geometry.command_speed
	return {
		"command_speed": command_speed,
		"control_distance": movement_geometry.control_distance,
		"local_prediction_radius": movement_geometry.local_prediction_radius,
	}


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


func _inside_domain(position: Vector2, domain: Dictionary) -> bool:
	return (
		position.x >= domain.left
		and position.x <= domain.right
		and position.y >= domain.top
		and position.y <= domain.bottom
	)


func _clip_to_domain(position: Vector2, domain: Dictionary) -> Vector2:
	return Vector2(
		clamp(position.x, domain.left, domain.right), clamp(position.y, domain.top, domain.bottom)
	)
