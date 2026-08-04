extends Reference

# Owns spatial opportunity potential and same-time counterfactual deltas in
# material-equivalent utility. Enemy motion is advanced equally for the moving
# candidate and the stationary baseline, so only player-caused access changes
# receive action value.

const OpportunityPricingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_pricing_model.gd"
)
const EngagementTargetProjector := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "engagement_target_projector.gd"
	)
)
const WeaponClusterOutcomeModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/weapon_cluster_outcome_model.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)
var _opportunity_pricing_model: Reference = OpportunityPricingModel.new()
var _engagement_target_projector: Reference = EngagementTargetProjector.new()
var _weapon_cluster_outcome_model: Reference = WeaponClusterOutcomeModel.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _prepared_physics_frame := -1
var _prepared_geometry := {}
var _prepared_maximum_targeting_distance := 0.0
var _prepared_entities := []
var _prepared_targets := []
var _prepared_candidate_entries := []


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_enemy_motion_predictor = predictor
	_weapon_cluster_outcome_model.set_enemy_motion_predictor(predictor)


func _evaluate_route(
	observation: Dictionary,
	context: Dictionary,
	player_displacement: Vector2,
	forecast_seconds: float
) -> Dictionary:
	_prepare_inputs(observation, context)
	_enemy_motion_predictor.begin_physics_frame(observation.get("physics_frame", -1))
	var result := {
		"material_opportunity": 0.0,
		"recovery_opportunity": 0.0,
		"engagement_completion_opportunity": 0.0,
		"weapon_cluster_outcome": 0.0,
		"engagement_opportunity": 0.0,
		"total": 0.0,
	}
	var reach_distance: float = _prepared_geometry.opportunity_reach_distance
	for entry in _prepared_entities:
		var entity: Dictionary = entry.entity
		var gap: float = _route_interaction_gap(observation, entity, player_displacement)
		var accessibility: float = _accessibility(gap, reach_distance)
		var contribution: float = entry.value * accessibility
		match entity.kind:
			"material":
				result.material_opportunity += contribution
			"consumable":
				result.recovery_opportunity += contribution
	for entry in _prepared_targets:
		var target: Dictionary = entry.target
		result.engagement_completion_opportunity += (
			entry.value
			* _target_route_accessibility(
				target, player_displacement, forecast_seconds, reach_distance
			)
		)
	result.weapon_cluster_outcome = _weapon_cluster_outcome_model.estimate_value(
		observation, context, player_displacement, forecast_seconds
	)
	result.engagement_opportunity = (
		result.engagement_completion_opportunity
		+ result.weapon_cluster_outcome
	)
	result.total = (
		result.material_opportunity
		+ result.recovery_opportunity
		+ result.engagement_opportunity
	)
	return result


func value_delta(
	observation: Dictionary,
	context: Dictionary,
	player_displacement: Vector2,
	forecast_seconds: float,
	stationary := {}
) -> Dictionary:
	_prepare_inputs(observation, context)
	if stationary.empty():
		stationary = _evaluate_route(observation, context, Vector2.ZERO, forecast_seconds)
	var candidate: Dictionary = _evaluate_route(
		observation, context, player_displacement, forecast_seconds
	)
	return {
		"material_opportunity": candidate.material_opportunity - stationary.material_opportunity,
		"recovery_opportunity": candidate.recovery_opportunity - stationary.recovery_opportunity,
		"engagement_completion_opportunity":
		candidate.engagement_completion_opportunity - stationary.engagement_completion_opportunity,
		"weapon_cluster_outcome":
		candidate.weapon_cluster_outcome - stationary.weapon_cluster_outcome,
		"engagement_opportunity":
		candidate.engagement_opportunity - stationary.engagement_opportunity,
		"total": candidate.total - stationary.total,
	}


func stationary_value(
	observation: Dictionary, context: Dictionary, forecast_seconds: float
) -> Dictionary:
	_prepare_inputs(observation, context)
	return _evaluate_route(observation, context, Vector2.ZERO, forecast_seconds)


func candidate_directions(observation: Dictionary, context: Dictionary) -> Array:
	_prepare_inputs(observation, context)
	var candidates := []
	var bins := {}
	var bin_count: int = max(1, int(_prepared_geometry.direction_count))
	for entry in _prepared_candidate_entries:
		var direction: Vector2 = entry.position.normalized()
		var bin_index := int(round(fposmod(direction.angle(), TAU) / TAU * bin_count)) % bin_count
		if not bins.has(bin_index):
			bins[bin_index] = {"weighted_direction": Vector2.ZERO, "value": 0.0}
		bins[bin_index].weighted_direction += direction * entry.value
		bins[bin_index].value += entry.value
	for bin in bins.values():
		_append_candidate(candidates, bin.weighted_direction, bin.value)
	candidates.sort_custom(self, "_higher_candidate_value")
	return candidates


func _prepare_inputs(observation: Dictionary, context: Dictionary) -> void:
	var physics_frame: int = observation.get("physics_frame", -1)
	if physics_frame >= 0 and physics_frame == _prepared_physics_frame:
		return
	_prepared_physics_frame = physics_frame
	_prepared_geometry = _movement_geometry.derive(observation)
	_prepared_maximum_targeting_distance = _maximum_targeting_distance(
		observation.player_state.weapons
	)
	_prepared_entities = []
	_prepared_targets = []
	_prepared_candidate_entries = []
	var health_inventory_value: Dictionary = context.state_factors.health_inventory_value
	for entity in observation.get("remembered_entities", []):
		if entity.kind == "tree":
			continue
		if entity.existence_confidence <= 0.0:
			continue
		var value: float = (
			_entity_value(observation, entity, health_inventory_value)
			* entity.existence_confidence
		)
		if value <= 0.0:
			continue
		var entity_entry := {
			"entity": entity,
			"value": value,
		}
		_prepared_entities.push_back(entity_entry)
		var gap: float = _entity_interaction_gap(observation, entity, Vector2.ZERO)
		_prepared_candidate_entries.push_back(
			{
				"position": entity.relative_position,
				"value": value * _accessibility(gap, _prepared_geometry.opportunity_reach_distance),
			}
		)
	for target in _engagement_target_projector.project_navigation_targets(observation, context):
		var value: float = (
			target.value.net_completion_value
			* target.completion.forecast_fraction
			* target.confidence
		)
		var target_entry := {
			"target": target,
			"value": value,
		}
		_prepared_targets.push_back(target_entry)
		if value <= 0.0:
			continue
		var gap: float = max(
			0.0, target.relative_position.length() - _prepared_maximum_targeting_distance
		)
		_prepared_candidate_entries.push_back(
			{
				"position": target.relative_position,
				"value": value * _accessibility(gap, _prepared_geometry.opportunity_reach_distance),
			}
		)


func _target_route_accessibility(
	target: Dictionary, player_displacement: Vector2, forecast_seconds: float, reach_distance: float
) -> float:
	var initial_accessibility := _target_accessibility(
		target.relative_position, Vector2.ZERO, reach_distance
	)
	if forecast_seconds <= 0.0:
		return initial_accessibility
	# Simpson integration values earlier access to an automatic attack window
	# without constructing a shot schedule or a pursue/retreat mode. This avoids
	# treating "the enemy eventually walks into range" as equivalent to a
	# candidate that creates useful firing time sooner.
	var midpoint_time := forecast_seconds * 0.5
	var midpoint_player_position := player_displacement * 0.5
	var midpoint_target_position: Vector2 = _enemy_motion_predictor.predict_position(
		target.motion_track, midpoint_time, midpoint_player_position
	)
	var terminal_target_position: Vector2 = _enemy_motion_predictor.predict_position(
		target.motion_track, forecast_seconds, player_displacement
	)
	var midpoint_accessibility := _target_accessibility(
		midpoint_target_position, midpoint_player_position, reach_distance
	)
	var terminal_accessibility := _target_accessibility(
		terminal_target_position, player_displacement, reach_distance
	)
	return (initial_accessibility + 4.0 * midpoint_accessibility + terminal_accessibility) / 6.0


func _target_accessibility(
	predicted_position: Vector2, player_displacement: Vector2, reach_distance: float
) -> float:
	# Strategic movement earns value only by creating an attack window sooner.
	# Once a target is in range, center-distance and nearest-target competition are
	# local weapon-field responsibilities. Keeping a radial attraction inside the
	# range made the planner chase followers that would approach on their own.
	var gap: float = max(
		0.0,
		(predicted_position - player_displacement).length() - _prepared_maximum_targeting_distance
	)
	return _accessibility(gap, reach_distance)


func _entity_value(
	observation: Dictionary, entity: Dictionary, health_inventory_value: Dictionary
) -> float:
	match entity.kind:
		"material":
			return _opportunity_pricing_model.material_collection_value(observation, entity)
		"consumable":
			return _opportunity_pricing_model.consumable_pickup_value(
				observation, entity, health_inventory_value
			)
	return 0.0


func _entity_interaction_gap(
	observation: Dictionary, entity: Dictionary, player_displacement: Vector2
) -> float:
	var interaction_radius: float = _entity_interaction_radius(observation)
	return max(0.0, (entity.relative_position - player_displacement).length() - interaction_radius)


func _route_interaction_gap(
	observation: Dictionary, entity: Dictionary, player_displacement: Vector2
) -> float:
	var closest_position := _closest_point_on_segment(
		Vector2.ZERO, player_displacement, entity.relative_position
	)
	return _entity_interaction_gap(observation, entity, closest_position)


func _entity_interaction_radius(observation: Dictionary) -> float:
	# Entering the attraction area starts motion but does not realize a pickup.
	# Navigation keeps the opportunity until the observed center can reach the
	# same collection circle used by the local outcome and memory contracts.
	return observation.player_state.pickup.collection_radius


func _closest_point_on_segment(
	segment_start: Vector2, segment_end: Vector2, point: Vector2
) -> Vector2:
	var segment: Vector2 = segment_end - segment_start
	var length_squared: float = segment.length_squared()
	if length_squared <= 0.0:
		return segment_start
	var fraction: float = clamp((point - segment_start).dot(segment) / length_squared, 0.0, 1.0)
	return segment_start.linear_interpolate(segment_end, fraction)


func _accessibility(gap: float, reach_distance: float) -> float:
	return exp(-max(0.0, gap) / max(1.0, reach_distance))


func _maximum_targeting_distance(weapons: Array) -> float:
	var result := 0.0
	for weapon in weapons:
		result = max(result, weapon.attack_model.delivery.maximum_targeting_distance)
	return result


func _append_candidate(candidates: Array, displacement: Vector2, value: float) -> void:
	if value <= 0.0 or displacement.length_squared() <= 0.0:
		return
	candidates.push_back(
		{
			"direction": displacement.normalized(),
			"distance": displacement.length(),
			"upper_bound_value": value,
		}
	)


func _higher_candidate_value(left: Dictionary, right: Dictionary) -> bool:
	return left.upper_bound_value > right.upper_bound_value
