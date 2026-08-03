extends Reference

# Owns spatial opportunity potential and same-time counterfactual deltas in
# material-equivalent utility. Enemy motion is advanced equally for the moving
# candidate and the stationary baseline, so only player-caused access changes
# receive action value.

const OpportunityValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_value_model.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)

var _opportunity_value_model: Reference = OpportunityValueModel.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()


func _evaluate_remote_position(
	observation: Dictionary,
	context: Dictionary,
	player_displacement: Vector2,
	time: float,
	geometry: Dictionary
) -> Dictionary:
	var result := {
		"material_opportunity": 0.0,
		"recovery_opportunity": 0.0,
		"tree_opportunity": 0.0,
		"enemy_opportunity": 0.0,
		"total": 0.0,
	}
	var reach_distance: float = _reach_distance(observation)
	var maximum_weapon_range: float = _maximum_weapon_range(observation.player_state.weapons)
	var health_value: Dictionary = context.state_factors.health_resource_value
	for entity in observation.get("remembered_entities", []):
		if entity.existence_confidence <= 0.0:
			continue
		var remote_share: float = _remote_entity_share(entity, geometry)
		if remote_share <= 0.0:
			continue
		var gap: float = _entity_interaction_gap(
			observation, entity, player_displacement, maximum_weapon_range
		)
		var accessibility: float = _accessibility(gap, reach_distance)
		var value: float = _entity_value(observation, entity, health_value)
		var contribution: float = value * accessibility * entity.existence_confidence * remote_share
		match entity.kind:
			"material":
				result.material_opportunity += contribution
			"consumable":
				result.recovery_opportunity += contribution
			"tree":
				result.tree_opportunity += contribution
	for track in observation.enemy_tracks:
		if track.visible and track.relative_position.length() <= geometry.local_prediction_radius:
			continue
		var predicted_position: Vector2 = _enemy_motion_predictor.predict_position(
			track, time, player_displacement
		)
		result.enemy_opportunity += _enemy_opportunity_at_position(
			observation,
			context,
			track,
			predicted_position,
			player_displacement,
			maximum_weapon_range,
			reach_distance
		)
	result.total = (
		result.material_opportunity
		+ result.recovery_opportunity
		+ result.tree_opportunity
		+ result.enemy_opportunity
	)
	return result


func value_delta(
	observation: Dictionary, context: Dictionary, player_displacement: Vector2, time: float
) -> Dictionary:
	var geometry: Dictionary = _movement_geometry.derive(observation)
	var stationary: Dictionary = _evaluate_remote_position(
		observation, context, Vector2.ZERO, time, geometry
	)
	var candidate: Dictionary = _evaluate_remote_position(
		observation, context, player_displacement, time, geometry
	)
	return {
		"material_opportunity": candidate.material_opportunity - stationary.material_opportunity,
		"recovery_opportunity": candidate.recovery_opportunity - stationary.recovery_opportunity,
		"tree_opportunity": candidate.tree_opportunity - stationary.tree_opportunity,
		"enemy_opportunity": candidate.enemy_opportunity - stationary.enemy_opportunity,
		"total": candidate.total - stationary.total,
	}


func local_enemy_value_delta(
	observation: Dictionary, context: Dictionary, player_displacement: Vector2, time: float
) -> float:
	var result := 0.0
	var reach_distance: float = _reach_distance(observation)
	var maximum_weapon_range: float = _maximum_weapon_range(observation.player_state.weapons)
	var local_prediction_radius: float = _local_prediction_radius(observation)
	for track in observation.enemy_tracks:
		if not track.visible or track.relative_position.length() > local_prediction_radius:
			continue
		var stationary_position: Vector2 = _enemy_motion_predictor.predict_position(
			track, time, Vector2.ZERO
		)
		var candidate_position: Vector2 = _enemy_motion_predictor.predict_position(
			track, time, player_displacement
		)
		var stationary_value: float = _enemy_opportunity_at_position(
			observation,
			context,
			track,
			stationary_position,
			Vector2.ZERO,
			maximum_weapon_range,
			reach_distance
		)
		var candidate_value: float = _enemy_opportunity_at_position(
			observation,
			context,
			track,
			candidate_position,
			player_displacement,
			maximum_weapon_range,
			reach_distance
		)
		result += candidate_value - stationary_value
	return result


func local_material_value_delta(observation: Dictionary, samples: Array) -> float:
	var geometry: Dictionary = _movement_geometry.derive(observation)
	var collection_radius: float = observation.player_state.pickup.collection_radius
	var reach_distance: float = geometry.opportunity_reach_distance
	var frontier_capacity := int(max(1.0, ceil(reach_distance / max(1.0, collection_radius * 2.0))))
	var final_displacement: Vector2 = samples.back().displacement
	var initial_potentials := []
	var final_potentials := []
	for material in observation.visible_world.materials:
		var initial_distance: float = material.relative_position.length()
		var closest_distance := initial_distance
		for sample in samples:
			closest_distance = min(
				closest_distance, (material.relative_position - sample.displacement).length()
			)
		# Exact collection has a separate irreversible outcome. The remaining
		# potential is partitioned with navigation by a shared local/remote share.
		if closest_distance <= collection_radius:
			continue
		var local_share: float = _local_material_share(initial_distance, geometry)
		if local_share <= 0.0:
			continue
		initial_potentials.push_back(
			(
				_interaction_potential(initial_distance, collection_radius, reach_distance)
				* local_share
			)
		)
		final_potentials.push_back(
			(
				_interaction_potential(
					(material.relative_position - final_displacement).length(),
					collection_radius,
					reach_distance
				)
				* local_share
			)
		)
	return (
		(
			_sum_largest(final_potentials, frontier_capacity)
			- _sum_largest(initial_potentials, frontier_capacity)
		)
		* _opportunity_value_model.material_collection_value(observation)
	)


func candidate_directions(observation: Dictionary, context: Dictionary) -> Array:
	var candidates := []
	var geometry: Dictionary = _movement_geometry.derive(observation)
	var health_value: Dictionary = context.state_factors.health_resource_value
	var enemy_removal_value_ledger: Dictionary = context.enemy_removal_value_ledger
	for entity in observation.get("remembered_entities", []):
		var remote_share: float = _remote_entity_share(entity, geometry)
		var value: float = (
			_entity_value(observation, entity, health_value)
			* entity.existence_confidence
			* remote_share
		)
		_append_candidate(candidates, entity.relative_position, value)
	for track in observation.enemy_tracks:
		if track.visible and track.relative_position.length() <= geometry.local_prediction_radius:
			continue
		var value: float = (
			_opportunity_value_model.enemy_removal_value(enemy_removal_value_ledger, track)
			* _opportunity_value_model.enemy_kill_feasibility(observation, track)
			* track.recency_confidence
		)
		_append_candidate(candidates, track.relative_position, value)
	candidates.sort_custom(self, "_higher_candidate_value")
	return candidates


func _entity_value(observation: Dictionary, entity: Dictionary, health_value: Dictionary) -> float:
	match entity.kind:
		"material":
			return _opportunity_value_model.material_collection_value(observation)
		"consumable":
			return (
				_opportunity_value_model.consumable_recovery_value(observation, entity)
				* health_value.recovery_conversion_value
			)
		"tree":
			return _opportunity_value_model.tree_reward_value(observation, entity, health_value)
	return 0.0


func _entity_interaction_gap(
	observation: Dictionary,
	entity: Dictionary,
	player_displacement: Vector2,
	maximum_weapon_range: float
) -> float:
	var interaction_radius: float = observation.player_state.pickup.collection_radius
	if entity.kind == "tree":
		interaction_radius = maximum_weapon_range
	return max(
		0.0,
		(
			(entity.relative_position - player_displacement).length()
			- interaction_radius
			- entity.get("visual_radius", 0.0)
		)
	)


func _reach_distance(observation: Dictionary) -> float:
	return _movement_geometry.derive(observation).opportunity_reach_distance


func _local_prediction_radius(observation: Dictionary) -> float:
	return _movement_geometry.derive(observation).local_prediction_radius


func _enemy_opportunity_at_position(
	observation: Dictionary,
	context: Dictionary,
	track: Dictionary,
	predicted_position: Vector2,
	player_displacement: Vector2,
	maximum_weapon_range: float,
	reach_distance: float
) -> float:
	var gap: float = max(
		0.0,
		(
			(predicted_position - player_displacement).length()
			- maximum_weapon_range
			- track.last_measurement.visual_radius
		)
	)
	return (
		_opportunity_value_model.enemy_removal_value(context.enemy_removal_value_ledger, track)
		* _opportunity_value_model.enemy_kill_feasibility(observation, track)
		* _accessibility(gap, reach_distance)
		* track.recency_confidence
	)


func _accessibility(gap: float, reach_distance: float) -> float:
	return exp(-max(0.0, gap) / max(1.0, reach_distance))


func _interaction_potential(
	distance: float, interaction_radius: float, reach_distance: float
) -> float:
	return _accessibility(max(0.0, distance - interaction_radius), reach_distance)


func _local_material_share(distance: float, geometry: Dictionary) -> float:
	var transition_radius: float = geometry.control_distance
	var local_radius: float = geometry.local_prediction_radius
	var transition_start: float = max(0.0, local_radius - transition_radius)
	var transition_end: float = local_radius + transition_radius
	var remote_fraction := clamp(
		(distance - transition_start) / max(1.0, transition_end - transition_start), 0.0, 1.0
	)
	# Cubic smoothstep gives complementary, continuous ownership without a new
	# policy threshold: the transition half-width is one committed control distance.
	remote_fraction = remote_fraction * remote_fraction * (3.0 - 2.0 * remote_fraction)
	return 1.0 - remote_fraction


func _remote_material_share(distance: float, geometry: Dictionary) -> float:
	return 1.0 - _local_material_share(distance, geometry)


func _remote_entity_share(entity: Dictionary, geometry: Dictionary) -> float:
	if not entity.visible:
		return 1.0
	if entity.kind == "material":
		return _remote_material_share(entity.relative_position.length(), geometry)
	return 0.0 if entity.relative_position.length() <= geometry.local_prediction_radius else 1.0


func _sum_largest(values: Array, capacity: int) -> float:
	values.sort()
	var result := 0.0
	for index in range(max(0, values.size() - capacity), values.size()):
		result += values[index]
	return result


func _maximum_weapon_range(weapons: Array) -> float:
	var result := 0.0
	for weapon in weapons:
		result = max(result, weapon.attack_model.delivery.maximum_range)
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
