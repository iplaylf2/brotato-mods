extends Reference

# Owns spatial opportunity potential and same-time counterfactual deltas in
# material-equivalent utility. Enemy motion is advanced equally for the moving
# candidate and the stationary baseline, so only player-caused access changes
# receive action value.

const OpportunityPricingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_pricing_model.gd"
)
const TargetCompletionAllocationModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/target_completion_allocation_model.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)

var _opportunity_pricing_model: Reference = OpportunityPricingModel.new()
var _target_completion_allocation_model: Reference = TargetCompletionAllocationModel.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _prepared_physics_frame := -1
var _prepared_geometry := {}
var _prepared_maximum_targeting_distance := 0.0
var _prepared_entities := []
var _prepared_enemies := []
var _prepared_candidate_entries := []


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_enemy_motion_predictor = predictor


func _evaluate_route(
	observation: Dictionary, context: Dictionary, player_displacement: Vector2, time: float
) -> Dictionary:
	_prepare_inputs(observation, context)
	_enemy_motion_predictor.begin_physics_frame(observation.get("physics_frame", -1))
	var result := {
		"material_opportunity": 0.0,
		"recovery_opportunity": 0.0,
		"tree_opportunity": 0.0,
		"enemy_opportunity": 0.0,
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
			"tree":
				result.tree_opportunity += contribution
	for entry in _prepared_enemies:
		result.enemy_opportunity += (
			entry.value
			* _enemy_route_accessibility(entry.track, player_displacement, time, reach_distance)
		)
	result.total = (
		result.material_opportunity
		+ result.recovery_opportunity
		+ result.tree_opportunity
		+ result.enemy_opportunity
	)
	return result


func value_delta(
	observation: Dictionary,
	context: Dictionary,
	player_displacement: Vector2,
	time: float,
	stationary := {}
) -> Dictionary:
	_prepare_inputs(observation, context)
	if stationary.empty():
		stationary = _evaluate_route(observation, context, Vector2.ZERO, time)
	var candidate: Dictionary = _evaluate_route(observation, context, player_displacement, time)
	return {
		"material_opportunity": candidate.material_opportunity - stationary.material_opportunity,
		"recovery_opportunity": candidate.recovery_opportunity - stationary.recovery_opportunity,
		"tree_opportunity": candidate.tree_opportunity - stationary.tree_opportunity,
		"enemy_opportunity": candidate.enemy_opportunity - stationary.enemy_opportunity,
		"total": candidate.total - stationary.total,
	}


func stationary_value(observation: Dictionary, context: Dictionary, time: float) -> Dictionary:
	_prepare_inputs(observation, context)
	return _evaluate_route(observation, context, Vector2.ZERO, time)


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
	_prepared_enemies = []
	_prepared_candidate_entries = []
	var health_inventory_value: Dictionary = context.state_factors.health_inventory_value
	var completion_ledger: Dictionary = context.target_completion_ledger
	for entity in observation.get("remembered_entities", []):
		if entity.existence_confidence <= 0.0:
			continue
		var value: float = (
			_entity_value(observation, entity, health_inventory_value, completion_ledger)
			* entity.existence_confidence
		)
		if value <= 0.0:
			continue
		var entity_entry := {"entity": entity, "value": value}
		_prepared_entities.push_back(entity_entry)
		var gap: float = _entity_interaction_gap(observation, entity, Vector2.ZERO)
		_prepared_candidate_entries.push_back(
			{
				"position": entity.relative_position,
				"value": value * _accessibility(gap, _prepared_geometry.opportunity_reach_distance),
			}
		)
	for track in observation.enemy_tracks:
		var value: float = (
			_opportunity_pricing_model.enemy_removal_value(
				context.enemy_removal_value_ledger, track
			)
			* _target_completion_allocation_model.enemy_completion_likelihood(
				completion_ledger, track
			)
		)
		var enemy_entry := {"track": track, "value": value}
		_prepared_enemies.push_back(enemy_entry)
		if value <= 0.0:
			continue
		var gap: float = max(
			0.0, track.relative_position.length() - _prepared_maximum_targeting_distance
		)
		_prepared_candidate_entries.push_back(
			{
				"position": track.relative_position,
				"value": value * _accessibility(gap, _prepared_geometry.opportunity_reach_distance),
			}
		)


func _enemy_route_accessibility(
	track: Dictionary, player_displacement: Vector2, time: float, reach_distance: float
) -> float:
	var initial_accessibility := _enemy_accessibility(
		track.relative_position, Vector2.ZERO, reach_distance
	)
	if time <= 0.0:
		return initial_accessibility
	# Simpson integration values earlier access to an automatic attack window
	# without constructing a shot schedule or a pursue/retreat mode. This avoids
	# treating "the enemy eventually walks into range" as equivalent to a
	# candidate that creates useful firing time sooner.
	var midpoint_time := time * 0.5
	var midpoint_player_position := player_displacement * 0.5
	var midpoint_enemy_position: Vector2 = _enemy_motion_predictor.predict_position(
		track, midpoint_time, midpoint_player_position
	)
	var terminal_enemy_position: Vector2 = _enemy_motion_predictor.predict_position(
		track, time, player_displacement
	)
	var midpoint_accessibility := _enemy_accessibility(
		midpoint_enemy_position, midpoint_player_position, reach_distance
	)
	var terminal_accessibility := _enemy_accessibility(
		terminal_enemy_position, player_displacement, reach_distance
	)
	return (initial_accessibility + 4.0 * midpoint_accessibility + terminal_accessibility) / 6.0


func _enemy_accessibility(
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
	observation: Dictionary,
	entity: Dictionary,
	health_inventory_value: Dictionary,
	completion_ledger: Dictionary
) -> float:
	match entity.kind:
		"material":
			return _opportunity_pricing_model.material_collection_value(observation, entity)
		"consumable":
			return _opportunity_pricing_model.consumable_pickup_value(
				observation, entity, health_inventory_value
			)
		"tree":
			return (
				_opportunity_pricing_model.tree_destruction_value(
					observation, entity, health_inventory_value
				)
				* _target_completion_allocation_model.tree_completion_likelihood(
					completion_ledger, entity
				)
			)
	return 0.0


func _entity_interaction_gap(
	observation: Dictionary, entity: Dictionary, player_displacement: Vector2
) -> float:
	var interaction_radius: float = _entity_interaction_radius(observation)
	if entity.kind == "tree":
		interaction_radius = _prepared_maximum_targeting_distance
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
