extends Reference

# Plans a strategic movement preference from a compact set of reachable terminal
# positions. Tactical swept-path evaluation remains in MovementOutcomePredictor;
# this planner prices only the longer-horizon opportunity and exposure that
# distinguish useful directions. It deliberately has no persistent spatial graph.

const BattlefieldExposureModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/battlefield_exposure_model.gd"
)
const WeaponEngagementModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapon_engagement_model.gd"
)
const MovementTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_timing_model.gd"
)
const PlayerKinematicsModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_kinematics_model.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const OpportunityValuationModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_valuation_model.gd"
)
const AdaptiveDirectionRefiner := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/adaptive_direction_refiner.gd"
)

const MATERIAL_PULL_RADIUS := 420.0
const CONSUMABLE_PULL_RADIUS := 360.0
const TREE_PULL_RADIUS := 500.0
const ENEMY_PRODUCER_PULL_RADIUS := 600.0
const BONUS_REWARD_TARGET_PULL_RADIUS := 600.0
const RANGED_SOURCE_PULL_RADIUS := 700.0
const CONTACT_COMBAT_PULL_RADIUS := 420.0
const SIMILAR_DIRECTION_DOT := 0.97
const BASELINE_DIRECTION_COUNT := 8

var _exposure_model: Reference = BattlefieldExposureModel.new()
var _engagement_model: Reference = WeaponEngagementModel.new()
var _player_kinematics: Reference = PlayerKinematicsModel.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _opportunity_valuation: Reference = OpportunityValuationModel.new()
var _direction_refiner: Reference = AdaptiveDirectionRefiner.new()


func plan(
	observation: Dictionary,
	context: Dictionary,
	compute_budget: Dictionary,
	compute_budget_policy: Reference
) -> Dictionary:
	var scale: Dictionary = _spatial_scale(observation)
	var timing: Dictionary = MovementTimingModel.derive(observation)
	var map_extent: Dictionary = _map_extent(observation)
	var sampling_radius: float = min(
		map_extent.radius, scale.command_speed * timing.maximum_navigation_horizon_seconds
	)
	var baseline_directions := _uniform_directions(BASELINE_DIRECTION_COUNT)
	var target_directions := _target_directions(observation, scale.local_prediction_radius)
	var origin := _evaluate_position(
		observation,
		context,
		Vector2.ZERO,
		0.0,
		scale.local_prediction_radius,
		scale.navigation_distance
	)
	var best := origin
	var position_evaluation_count := 1
	var evaluated_directions := []
	var direction_scores := []
	var budgeted_position_evaluation_count := 0
	for direction in baseline_directions:
		var result := _evaluate_direction(
			observation, context, direction, sampling_radius, map_extent, scale, timing
		)
		if result.empty():
			continue
		position_evaluation_count += 1
		evaluated_directions.push_back(direction)
		direction_scores.push_back({"movement": direction, "score": result.value})
		if result.value > best.value:
			best = result

	for target_direction in target_directions:
		var direction: Vector2 = target_direction.direction
		if _has_similar_direction(evaluated_directions, direction):
			continue
		if not compute_budget_policy.can_start_budgeted_work(
			compute_budget, compute_budget_policy.WORK_NAVIGATION_EVALUATION
		):
			break
		var work_started_usec := OS.get_ticks_usec()
		var result := _evaluate_direction(
			observation, context, direction, sampling_radius, map_extent, scale, timing
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
		var work_started_usec := OS.get_ticks_usec()
		var result := _evaluate_direction(
			observation, context, direction, sampling_radius, map_extent, scale, timing
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

	var value_gain: float = best.value - origin.value
	var movement_preference := Vector2.ZERO
	if best.position != Vector2.ZERO and value_gain > 0.0:
		movement_preference = best.position.normalized() * clamp(value_gain, 0.0, 1.0)
	return {
		"movement_preference": movement_preference,
		"position_evaluation_count": position_evaluation_count,
		"baseline_position_evaluation_count":
		position_evaluation_count - budgeted_position_evaluation_count,
		"budgeted_position_evaluation_count": budgeted_position_evaluation_count,
		"origin_value": origin.value,
		"selected_value": best.value,
		"value_gain": value_gain,
		"selected_displacement": best.position,
		"sampling_radius": sampling_radius,
		"local_prediction_radius": scale.local_prediction_radius,
		"control_distance": scale.control_distance,
		"engagement_capacity": scale.engagement_capacity,
		"current_engagement_estimate": scale.current_engagement_estimate,
		"source_scope": "visible_and_remembered",
	}


func _evaluate_direction(
	observation: Dictionary,
	context: Dictionary,
	direction: Vector2,
	sampling_radius: float,
	map_extent: Dictionary,
	scale: Dictionary,
	timing: Dictionary
) -> Dictionary:
	var position: Vector2 = direction * sampling_radius
	if not _inside_domain(position, map_extent):
		position = _clip_to_domain(position, map_extent)
	if position.length() <= scale.control_distance:
		return {}
	var forecast_seconds := min(
		timing.maximum_navigation_horizon_seconds, position.length() / max(1.0, scale.command_speed)
	)
	return _evaluate_position(
		observation,
		context,
		position,
		forecast_seconds,
		scale.local_prediction_radius,
		scale.navigation_distance
	)


func _evaluate_position(
	observation: Dictionary,
	context: Dictionary,
	position: Vector2,
	time: float,
	local_prediction_radius: float,
	navigation_distance: float
) -> Dictionary:
	var exposure: Dictionary = _exposure_model.sample_point(
		observation, position, time, context.exposure_policy
	)
	var strategic_value: float = _strategic_value(
		observation, context, position, time, local_prediction_radius
	)
	var engagement: Dictionary = _engagement_model.estimate_at_position(
		observation,
		position,
		time,
		MovementTimingModel.derive(observation).maximum_navigation_horizon_seconds
	)
	var engagement_value: float = (
		engagement.expected_damage
		* context.objective_weights.combat.expected_weapon_damage
	)
	var travel_cost: float = (
		context.navigation_policy.travel_cost
		* position.length()
		/ max(1.0, navigation_distance)
	)
	var exposure_cost: float = (
		exposure.environmental_pressure
		* context.navigation_policy.environmental_exposure_cost
	)
	return {
		"position": position,
		"value": strategic_value + engagement_value - exposure_cost - travel_cost,
	}


func _strategic_value(
	observation: Dictionary,
	context: Dictionary,
	position: Vector2,
	time: float,
	local_prediction_radius: float
) -> float:
	var value := 0.0
	for entity in observation.get("remembered_entities", []):
		# Visible goals inside the local prediction radius already have an exact
		# action outcome. Everything else is owned here.
		if entity.visible and entity.relative_position.length() <= local_prediction_radius:
			continue
		var distance: float = (entity.relative_position - position).length()
		var confidence: float = entity.existence_confidence
		match entity.kind:
			"material":
				value += (
					_radial_pull(distance, MATERIAL_PULL_RADIUS)
					* confidence
					* context.navigation_policy.material
				)
			"consumable":
				value += (
					_radial_pull(distance, CONSUMABLE_PULL_RADIUS)
					* confidence
					* context.navigation_policy.recovery_pickup
					* _opportunity_valuation.consumable_recovery_value(observation, entity)
				)
			"tree":
				value += (
					_radial_pull(distance, TREE_PULL_RADIUS)
					* confidence
					* context.navigation_policy.tree
					* _opportunity_valuation.tree_reward_value(observation, entity)
				)

	for track in observation.enemy_tracks:
		var predicted_position: Vector2 = track.relative_position + track.estimated_velocity * time
		var distance: float = (predicted_position - position).length()
		var confidence: float = track.recency_confidence
		var roles: Dictionary = track.behavior_profile.strategic_roles
		if roles.enemy_producer:
			value += (
				_radial_pull(distance, ENEMY_PRODUCER_PULL_RADIUS)
				* confidence
				* context.navigation_policy.enemy_producer
			)
		if roles.bonus_reward_target:
			value += (
				_radial_pull(distance, BONUS_REWARD_TARGET_PULL_RADIUS)
				* confidence
				* context.navigation_policy.bonus_reward_target
				* _opportunity_valuation.bonus_kill_reward_value(observation, track)
				* _opportunity_valuation.enemy_kill_feasibility(observation, track)
			)
		if roles.ranged_pressure_source:
			value += (
				_radial_pull(distance, RANGED_SOURCE_PULL_RADIUS)
				* confidence
				* context.navigation_policy.ranged_source
			)
		if context.navigation_policy.contact_combat > 0.0:
			value += (
				_radial_pull(distance, CONTACT_COMBAT_PULL_RADIUS)
				* confidence
				* context.navigation_policy.contact_combat
			)
	return _saturate_signed(value)


func _target_directions(observation: Dictionary, local_prediction_radius: float) -> Array:
	var result := []
	for entity in observation.get("remembered_entities", []):
		if entity.visible and entity.relative_position.length() <= local_prediction_radius:
			continue
		if entity.kind in ["material", "consumable", "tree"]:
			_insert_target_direction(result, entity.relative_position)
	for track in observation.enemy_tracks:
		var roles: Dictionary = track.behavior_profile.strategic_roles
		if roles.enemy_producer or roles.bonus_reward_target or roles.ranged_pressure_source:
			_insert_target_direction(result, track.relative_position)
	return result


func _uniform_directions(direction_count: int) -> Array:
	var result := []
	for direction_index in direction_count:
		var direction := Vector2.RIGHT.rotated(
			TAU * float(direction_index) / float(direction_count)
		)
		result.push_back(direction)
	return result


func _insert_target_direction(directions: Array, displacement: Vector2) -> void:
	if displacement.length_squared() <= 0.0:
		return
	var candidate := displacement.normalized()
	for entry in directions:
		if entry.direction.dot(candidate) > SIMILAR_DIRECTION_DOT:
			return
	var candidate_entry := {"direction": candidate, "distance": displacement.length()}
	for index in directions.size():
		if candidate_entry.distance < directions[index].distance:
			directions.insert(index, candidate_entry)
			return
	directions.push_back(candidate_entry)


func _has_similar_direction(directions: Array, candidate: Vector2) -> bool:
	for direction in directions:
		if direction.dot(candidate) > SIMILAR_DIRECTION_DOT:
			return true
	return false


func _spatial_scale(observation: Dictionary) -> Dictionary:
	var movement_geometry: Dictionary = _movement_geometry.derive(observation)
	var timing: Dictionary = MovementTimingModel.derive(observation)
	var command_speed: float = movement_geometry.command_speed
	var engagement_capacity: Dictionary = _engagement_model.estimate_capacity(
		observation, timing.maximum_navigation_horizon_seconds
	)
	var current_engagement: Dictionary = _engagement_model.estimate_at_position(
		observation, Vector2.ZERO, 0.0, timing.maximum_navigation_horizon_seconds
	)
	return {
		"command_speed": command_speed,
		"control_distance": movement_geometry.control_distance,
		"local_prediction_radius": command_speed * timing.maximum_local_horizon_seconds,
		"navigation_distance": movement_geometry.roaming_distance,
		"engagement_capacity": engagement_capacity,
		"current_engagement_estimate": current_engagement,
	}


func _map_extent(observation: Dictionary) -> Dictionary:
	var bounds: Dictionary = observation.localization.map_bounds
	var viewport_size: Vector2 = observation.visibility.viewport_size
	var viewport_offset: Vector2 = observation.visibility.viewport_offset_from_player
	var left: float = (
		-bounds.distance_to_left
		if bounds.distance_to_left != null
		else viewport_offset.x
	)
	var right: float = (
		bounds.distance_to_right
		if bounds.distance_to_right != null
		else viewport_offset.x + viewport_size.x
	)
	var top: float = (
		-bounds.distance_to_top
		if bounds.distance_to_top != null
		else viewport_offset.y
	)
	var bottom: float = (
		bounds.distance_to_bottom
		if bounds.distance_to_bottom != null
		else viewport_offset.y + viewport_size.y
	)
	for entity in observation.get("remembered_entities", []):
		var observed_position: Vector2 = entity.last_observed_relative_position
		left = min(left, observed_position.x)
		right = max(right, observed_position.x)
		top = min(top, observed_position.y)
		bottom = max(bottom, observed_position.y)
	var radius := 0.0
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


func _radial_pull(distance: float, radius: float) -> float:
	var proximity := clamp((radius - distance) / radius, 0.0, 1.0)
	return proximity * proximity


func _saturate_signed(value: float) -> float:
	return sign(value) * (1.0 - exp(-abs(value)))
