extends Reference

# Evaluates observed opportunities at a candidate terminal state in
# material-equivalent utility.

const OpportunityValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_value_model.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const ObservedMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/observed_motion_predictor.gd"
)

var _opportunity_value_model: Reference = OpportunityValueModel.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _motion_predictor: Reference = ObservedMotionPredictor.new()


func evaluate_position(
	observation: Dictionary,
	context: Dictionary,
	player_displacement: Vector2,
	time: float,
	local_prediction_radius: float
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
	var enemy_removal_value_ledger: Dictionary = context.enemy_removal_value_ledger
	for entity in observation.get("remembered_entities", []):
		if entity.existence_confidence <= 0.0:
			continue
		if entity.visible and entity.relative_position.length() <= local_prediction_radius:
			continue
		var gap: float = _entity_interaction_gap(
			observation, entity, player_displacement, maximum_weapon_range
		)
		var accessibility: float = _accessibility(gap, reach_distance)
		var value: float = _entity_value(observation, entity, health_value)
		var contribution: float = value * accessibility * entity.existence_confidence
		match entity.kind:
			"material":
				result.material_opportunity += contribution
			"consumable":
				result.recovery_opportunity += contribution
			"tree":
				result.tree_opportunity += contribution
	for track in observation.enemy_tracks:
		if track.visible and track.relative_position.length() <= local_prediction_radius:
			continue
		var predicted_position: Vector2 = _motion_predictor.predict_position(
			track.relative_position,
			track.estimated_velocity,
			track.estimated_acceleration,
			track.motion_confidence,
			time
		)
		var gap: float = max(
			0.0,
			(
				(predicted_position - player_displacement).length()
				- maximum_weapon_range
				- track.last_measurement.visual_radius
			)
		)
		var removal_value: float = _opportunity_value_model.enemy_removal_value(
			enemy_removal_value_ledger, track
		)
		result.enemy_opportunity += (
			removal_value
			* _opportunity_value_model.enemy_kill_feasibility(observation, track)
			* _accessibility(gap, reach_distance)
			* track.recency_confidence
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
	local_prediction_radius: float
) -> Dictionary:
	var origin: Dictionary = evaluate_position(
		observation, context, Vector2.ZERO, 0.0, local_prediction_radius
	)
	var candidate: Dictionary = evaluate_position(
		observation, context, player_displacement, time, local_prediction_radius
	)
	return {
		"material_opportunity": candidate.material_opportunity - origin.material_opportunity,
		"recovery_opportunity": candidate.recovery_opportunity - origin.recovery_opportunity,
		"tree_opportunity": candidate.tree_opportunity - origin.tree_opportunity,
		"enemy_opportunity": candidate.enemy_opportunity - origin.enemy_opportunity,
		"total": candidate.total - origin.total,
	}


func candidate_directions(observation: Dictionary, context: Dictionary) -> Array:
	var candidates := []
	var health_value: Dictionary = context.state_factors.health_resource_value
	var enemy_removal_value_ledger: Dictionary = context.enemy_removal_value_ledger
	for entity in observation.get("remembered_entities", []):
		var value: float = (
			_entity_value(observation, entity, health_value)
			* entity.existence_confidence
		)
		_append_candidate(candidates, entity.relative_position, value)
	for track in observation.enemy_tracks:
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
			return 1.0
		"consumable":
			return (
				_opportunity_value_model.consumable_recovery_value(observation, entity)
				* health_value.recovery_conversion_value
			)
		"tree":
			return _opportunity_value_model.tree_reward_value(observation, entity)
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
	return max(1.0, _movement_geometry.derive(observation).roaming_distance)


func _accessibility(gap: float, reach_distance: float) -> float:
	return exp(-max(0.0, gap) / max(1.0, reach_distance))


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
