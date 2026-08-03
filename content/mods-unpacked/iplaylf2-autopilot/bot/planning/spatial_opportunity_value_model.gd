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
var _prepared_physics_frame := -1
var _prepared_geometry := {}
var _prepared_maximum_weapon_range := 0.0
var _prepared_remote_entities := []
var _prepared_remote_enemies := []
var _prepared_local_enemies := []
var _prepared_candidate_entries := []


func _evaluate_remote_position(
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
	for entry in _prepared_remote_entities:
		var entity: Dictionary = entry.entity
		var gap: float = _entity_interaction_gap(
			observation, entity, player_displacement, _prepared_maximum_weapon_range
		)
		var accessibility: float = _accessibility(gap, reach_distance)
		var contribution: float = entry.value * accessibility
		match entity.kind:
			"material":
				result.material_opportunity += contribution
			"consumable":
				result.recovery_opportunity += contribution
			"tree":
				result.tree_opportunity += contribution
	for entry in _prepared_remote_enemies:
		var track: Dictionary = entry.track
		var predicted_position: Vector2 = _enemy_motion_predictor.predict_position(
			track, time, player_displacement
		)
		result.enemy_opportunity += _prepared_enemy_value_at_position(
			entry, predicted_position, player_displacement
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
		stationary = _evaluate_remote_position(observation, context, Vector2.ZERO, time)
	var candidate: Dictionary = _evaluate_remote_position(
		observation, context, player_displacement, time
	)
	return {
		"material_opportunity": candidate.material_opportunity - stationary.material_opportunity,
		"recovery_opportunity": candidate.recovery_opportunity - stationary.recovery_opportunity,
		"tree_opportunity": candidate.tree_opportunity - stationary.tree_opportunity,
		"enemy_opportunity": candidate.enemy_opportunity - stationary.enemy_opportunity,
		"total": candidate.total - stationary.total,
	}


func stationary_value(observation: Dictionary, context: Dictionary, time: float) -> Dictionary:
	_prepare_inputs(observation, context)
	return _evaluate_remote_position(observation, context, Vector2.ZERO, time)


func local_enemy_value_delta(
	observation: Dictionary, context: Dictionary, player_displacement: Vector2, time: float
) -> float:
	_prepare_inputs(observation, context)
	_enemy_motion_predictor.begin_physics_frame(observation.get("physics_frame", -1))
	var result := 0.0
	for entry in _prepared_local_enemies:
		var track: Dictionary = entry.track
		var stationary_position: Vector2 = _enemy_motion_predictor.predict_position(
			track, time, Vector2.ZERO
		)
		var candidate_position: Vector2 = _enemy_motion_predictor.predict_position(
			track, time, player_displacement
		)
		var stationary_value: float = _prepared_enemy_value_at_position(
			entry, stationary_position, Vector2.ZERO
		)
		var candidate_value: float = _prepared_enemy_value_at_position(
			entry, candidate_position, player_displacement
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
	_prepared_maximum_weapon_range = _maximum_weapon_range(observation.player_state.weapons)
	_prepared_remote_entities = []
	_prepared_remote_enemies = []
	_prepared_local_enemies = []
	_prepared_candidate_entries = []
	var health_value: Dictionary = context.state_factors.health_resource_value
	for entity in observation.get("remembered_entities", []):
		if entity.existence_confidence <= 0.0:
			continue
		var remote_share: float = _remote_entity_share(entity, _prepared_geometry)
		var value: float = (
			_entity_value(observation, entity, health_value)
			* entity.existence_confidence
			* remote_share
		)
		if value <= 0.0:
			continue
		var entity_entry := {"entity": entity, "value": value}
		_prepared_remote_entities.push_back(entity_entry)
		var gap: float = _entity_interaction_gap(
			observation, entity, Vector2.ZERO, _prepared_maximum_weapon_range
		)
		_prepared_candidate_entries.push_back(
			{
				"position": entity.relative_position,
				"value": value * _accessibility(gap, _prepared_geometry.opportunity_reach_distance),
			}
		)
	for track in observation.enemy_tracks:
		var value: float = (
			_opportunity_value_model.enemy_removal_value(context.enemy_removal_value_ledger, track)
			* _opportunity_value_model.enemy_kill_feasibility(observation, track)
			* track.recency_confidence
		)
		var enemy_entry := {"track": track, "value": value}
		if (
			track.visible
			and track.relative_position.length() <= _prepared_geometry.local_prediction_radius
		):
			_prepared_local_enemies.push_back(enemy_entry)
		else:
			_prepared_remote_enemies.push_back(enemy_entry)
		if value <= 0.0:
			continue
		var gap: float = max(
			0.0,
			(
				track.relative_position.length()
				- _prepared_maximum_weapon_range
				- track.last_measurement.visual_radius
			)
		)
		_prepared_candidate_entries.push_back(
			{
				"position": track.relative_position,
				"value": value * _accessibility(gap, _prepared_geometry.opportunity_reach_distance),
			}
		)


func _prepared_enemy_value_at_position(
	entry: Dictionary, predicted_position: Vector2, player_displacement: Vector2
) -> float:
	var track: Dictionary = entry.track
	var gap: float = max(
		0.0,
		(
			(predicted_position - player_displacement).length()
			- _prepared_maximum_weapon_range
			- track.last_measurement.visual_radius
		)
	)
	return entry.value * _accessibility(gap, _prepared_geometry.opportunity_reach_distance)


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
