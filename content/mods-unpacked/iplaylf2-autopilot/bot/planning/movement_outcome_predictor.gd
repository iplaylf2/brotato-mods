extends Reference

# Predicts the outcome of one feasible movement vector over a threat-timed
# forecast. Every evaluated action receives the shared base prediction; actions
# selected for full evaluation also receive automatic-weapon prediction.
# Scoring belongs to MovementUtilityModel.

const WeaponAttackPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapon_attack_predictor.gd"
)
const WeaponFireModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapon_fire_model.gd"
)
const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)
const BattlefieldExposureModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/battlefield_exposure_model.gd"
)
const VelocityObstacleRiskModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/velocity_obstacle_risk_model.gd"
)
const PlayerRuleOutcomePredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_rule_outcome_predictor.gd"
)
const PlayerMovementStateProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_movement_state_projector.gd"
)
const PlayerRuleProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_rule_projector.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const OpportunityValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_value_model.gd"
)
const SpatialOpportunityValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/spatial_opportunity_value_model.gd"
)
const CollisionHealthImpactModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/collision_health_impact_model.gd"
)

var _weapon_attack_predictor: Reference = WeaponAttackPredictor.new()
var _weapon_fire_model: Reference = WeaponFireModel.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _battlefield_exposure_model: Reference = BattlefieldExposureModel.new()
var _velocity_obstacle_risk_model: Reference = VelocityObstacleRiskModel.new()
var _player_rule_outcome_predictor: Reference = PlayerRuleOutcomePredictor.new()
var _movement_state_projector: Reference = PlayerMovementStateProjector.new()
var _rule_projector: Reference = PlayerRuleProjector.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _opportunity_value_model: Reference = OpportunityValueModel.new()
var _spatial_opportunity_value_model: Reference = SpatialOpportunityValueModel.new()
var _collision_health_impact_model: Reference = CollisionHealthImpactModel.new()


func predict_collision_outcome(
	observation: Dictionary, action: Dictionary, planning_context: Dictionary
) -> Dictionary:
	var result: Dictionary = _battlefield_exposure_model.predict_collision(
		observation, action, planning_context.exposure_policy
	)
	result.merge(_velocity_obstacle_risk_model.evaluate(observation, action), true)
	result.collision_risk = max(result.peak_path_collision_risk, result.velocity_obstacle_risk)
	result.hostile_collision_risk = max(
		result.peak_path_collision_risk, result.hostile_velocity_obstacle_risk
	)
	var predicted_hit_damage: float = max(
		result.maximum_path_collision_damage, result.maximum_velocity_obstacle_damage
	)
	result.merge(
		_collision_health_impact_model.evaluate(
			observation,
			action,
			result.hostile_collision_risk,
			predicted_hit_damage,
			planning_context.state_factors.positive_damage_is_terminal_rule
		),
		true
	)
	return result


func predict(
	observation: Dictionary,
	action: Dictionary,
	previous_movement: Vector2,
	include_weapon_prediction: bool,
	planning_context: Dictionary
) -> Dictionary:
	var base_outcome: Dictionary = predict_base(
		observation, action, previous_movement, planning_context
	)
	return complete_prediction(
		observation, action, base_outcome, include_weapon_prediction, planning_context
	)


# The expensive movement, battlefield, and collision projection is independent
# of weapon prediction. Full weapon prediction reuses this immutable base.
func predict_base(
	observation: Dictionary,
	action: Dictionary,
	previous_movement: Vector2,
	planning_context: Dictionary
) -> Dictionary:
	var outcome := {
		"weapon_prediction_included": false,
		"material_acquisition_value": 0.0,
		"material_approach_progress": 0.0,
		"consumable_recovery_approach_progress": 0.0,
		"wasted_consumable_recovery": 0.0,
		"consumed_consumable_recovery_supply": 0.0,
		"expected_weapon_damage": 0.0,
		"expected_enemy_removal_value_progress": 0.0,
		"enemy_removal_value_approach_progress": 0.0,
		"enemy_removal_value_in_range": 0.0,
		"tree_opportunity_progress": 0.0,
		"tree_harvest_value_in_range": 0.0,
		"expected_tree_harvest_value_progress": 0.0,
		"standing_seconds": 0.0,
		"moving_seconds": 0.0,
		"heading_continuity": 0.0,
		"navigation_terminal_value_gain": 0.0,
		"expected_attack_hits": 0.0,
		"expected_rule_damage": 0.0,
		"expected_recovery": 0.0,
		"expected_recovery_events": 0.0,
		"expected_stat_upgrade_equivalents": 0.0,
		"expected_stat_opportunity_value": 0.0,
		"expected_material_gain": 0.0,
		"expected_kill_weight": 0.0,
		"expected_critical_kill_weight": 0.0,
		"movement_damage_exposure_reduction": 0.0,
		"collision_risk": 0.0,
		"hostile_collision_risk": 0.0,
		"expected_health_loss": 0.0,
		"terminal_collision_risk": 0.0,
	}
	var battlefield_outcome: Dictionary = _battlefield_exposure_model.predict(
		observation, action, planning_context.exposure_policy
	)
	outcome.merge(battlefield_outcome, true)
	outcome.merge(_velocity_obstacle_risk_model.evaluate(observation, action), true)
	_predict_action_outcomes(observation, action, previous_movement, planning_context, outcome)
	outcome.collision_risk = max(outcome.peak_path_collision_risk, outcome.velocity_obstacle_risk)
	outcome.hostile_collision_risk = max(
		outcome.peak_path_collision_risk, outcome.hostile_velocity_obstacle_risk
	)
	var predicted_hit_damage: float = max(
		outcome.maximum_path_collision_damage, outcome.maximum_velocity_obstacle_damage
	)
	outcome.merge(
		_collision_health_impact_model.evaluate(
			observation,
			action,
			outcome.hostile_collision_risk,
			predicted_hit_damage,
			planning_context.state_factors.positive_damage_is_terminal_rule
		),
		true
	)
	outcome.movement_damage_exposure_reduction = (
		_movement_damage_exposure_reduction(observation, action)
		* outcome.collision_risk
	)
	outcome.navigation_terminal_value_gain = (
		action.movement.dot(planning_context.navigation_movement_preference)
		* planning_context.navigation_terminal_value_gain
	)
	return outcome


func complete_prediction(
	observation: Dictionary,
	action: Dictionary,
	base_outcome: Dictionary,
	include_weapon_prediction: bool,
	planning_context: Dictionary
) -> Dictionary:
	var outcome: Dictionary = base_outcome.duplicate(true)
	outcome.weapon_prediction_included = include_weapon_prediction
	if include_weapon_prediction:
		_weapon_attack_predictor.accumulate_outcome(observation, action, outcome, planning_context)
	_player_rule_outcome_predictor.accumulate_outcome(
		observation,
		action,
		outcome,
		_samples_through(action.samples, planning_context.control_interval_seconds)
	)
	return outcome


func _predict_action_outcomes(
	observation: Dictionary,
	action: Dictionary,
	previous_movement: Vector2,
	planning_context: Dictionary,
	outcome: Dictionary
) -> void:
	var samples: Array = action.samples
	assert(not samples.empty())
	var committed_samples: Array = _samples_through(
		samples, planning_context.control_interval_seconds
	)
	outcome.material_acquisition_value = _material_acquisition_value(observation, committed_samples)
	outcome.material_approach_progress = _material_approach_progress(observation, committed_samples)
	outcome.consumable_recovery_approach_progress = _consumable_recovery_approach_progress(
		observation, committed_samples
	)
	outcome.tree_opportunity_progress = _tree_opportunity_progress(
		observation, action, committed_samples.back().displacement, planning_context
	)
	outcome.tree_harvest_value_in_range = _weapon_attack_predictor.estimate_tree_harvest_value(
		observation, action, planning_context
	)
	var final_sample: Dictionary = samples.back()
	var enemy_approach_value: float = _spatial_opportunity_value_model.local_enemy_value_delta(
		observation, planning_context, final_sample.displacement, final_sample.time
	)
	outcome.enemy_removal_value_approach_progress = enemy_approach_value
	outcome.enemy_removal_value_in_range = _enemy_removal_value_in_range(
		observation, action, planning_context
	)

	if action.movement == Vector2.ZERO:
		outcome.standing_seconds = action.forecast_seconds
	else:
		outcome.moving_seconds = action.forecast_seconds
	if previous_movement.length_squared() > 0.0 and action.movement.length_squared() > 0.0:
		outcome.heading_continuity = previous_movement.normalized().dot(action.movement)


func _material_acquisition_value(observation: Dictionary, samples: Array) -> float:
	var value := 0.0
	for entity in observation.visible_world.materials:
		var closest_distance: float = entity.relative_position.length()
		for sample in samples:
			closest_distance = min(
				closest_distance, (entity.relative_position - sample.displacement).length()
			)
		if closest_distance <= observation.player_state.pickup.collection_radius:
			value += _opportunity_value_model.material_collection_value(observation)
	return value


func _material_approach_progress(observation: Dictionary, samples: Array) -> float:
	var collection_value: float = _opportunity_value_model.material_collection_value(observation)
	var reach_distance: float = _movement_geometry.derive(observation).opportunity_reach_distance
	var collection_radius: float = observation.player_state.pickup.collection_radius
	# The reachable frontier is the number of pickup diameters that fit in the
	# remaining opportunity horizon. This lets dense fields retain proportionate
	# value without summing every material (which would reward indecisive motion
	# between mutually exclusive targets).
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
		# Acquired materials are owned by material_acquisition_value. Compare the
		# same uncollected entity set so approach value cannot double-count them.
		if closest_distance <= collection_radius:
			continue
		initial_potentials.push_back(
			_interaction_potential(initial_distance, collection_radius, reach_distance)
		)
		final_potentials.push_back(
			_interaction_potential(
				(material.relative_position - final_displacement).length(),
				collection_radius,
				reach_distance
			)
		)
	return (
		(
			_sum_largest(final_potentials, frontier_capacity)
			- _sum_largest(initial_potentials, frontier_capacity)
		)
		* collection_value
	)


func _sum_largest(values: Array, capacity: int) -> float:
	values.sort()
	var result := 0.0
	for index in range(max(0, values.size() - capacity), values.size()):
		result += values[index]
	return result


func _consumable_recovery_approach_progress(observation: Dictionary, samples: Array) -> float:
	var progress := 0.0
	var pickup: Dictionary = observation.player_state.pickup
	for consumable in observation.visible_world.consumables:
		var recovery: float = _opportunity_value_model.consumable_recovery_value(
			observation, consumable
		)
		if recovery <= 0.0:
			continue
		var initial_distance: float = consumable.relative_position.length()
		var closest_distance := initial_distance
		for sample in samples:
			closest_distance = min(
				closest_distance, (consumable.relative_position - sample.displacement).length()
			)
		# Collection has an exact recovery outcome below. This channel only
		# represents progress toward a future event, never the event itself.
		if closest_distance <= pickup.collection_radius:
			continue
		var available_distance := max(1.0, initial_distance - pickup.collection_radius)
		progress += (
			clamp((initial_distance - closest_distance) / available_distance, 0.0, 1.0)
			* recovery
		)
	return progress


func _tree_opportunity_progress(
	observation: Dictionary,
	action: Dictionary,
	committed_displacement: Vector2,
	planning_context: Dictionary
) -> float:
	var maximum_range: float = _usable_weapon_range(
		observation.player_state.weapons, action.movement != Vector2.ZERO
	)
	if maximum_range <= 0.0:
		return 0.0
	var interaction := 0.0
	var reach_distance: float = _movement_geometry.derive(observation).opportunity_reach_distance
	for tree in observation.visible_world.trees:
		var initial_distance: float = tree.relative_position.length()
		var final_distance: float = (tree.relative_position - committed_displacement).length()
		interaction += (
			(
				_interaction_potential(final_distance, maximum_range, reach_distance)
				- _interaction_potential(initial_distance, maximum_range, reach_distance)
			)
			* _opportunity_value_model.tree_reward_value(
				observation, tree, planning_context.state_factors.health_resource_value
			)
		)
	return interaction


func _samples_through(samples: Array, committed_seconds: float) -> Array:
	var result := []
	for sample in samples:
		if sample.time > committed_seconds + 0.0001:
			break
		result.push_back(sample)
	if result.empty():
		result.push_back(samples[0])
	return result


func _interaction_potential(
	distance: float, interaction_radius: float, reach_distance: float
) -> float:
	var gap: float = max(0.0, distance - interaction_radius)
	return exp(-gap / max(1.0, reach_distance))


func _enemy_removal_value_in_range(
	observation: Dictionary, action: Dictionary, planning_context: Dictionary
) -> float:
	var remaining_health := {}
	for track in observation.enemy_tracks:
		if not track.visible:
			continue
		remaining_health[track.track_id] = max(
			1.0, float(track.behavior_profile.durability.maximum_health)
		)
	var value := 0.0
	var enemy_removal_value_ledger: Dictionary = planning_context.enemy_removal_value_ledger
	var is_moving: bool = action.movement != Vector2.ZERO
	for weapon in observation.player_state.weapons:
		if is_moving and not weapon.attack_model.timing.permitted_while_moving:
			continue
		var attack: Dictionary = _movement_state_projector.project_attack_model(
			weapon, observation, is_moving
		)
		var attack_times: Array = _weapon_fire_model.scheduled_attack_times(
			attack, 0.0, action.forecast_seconds
		)
		if attack_times.empty():
			continue
		var damage_per_attack: float = (
			_weapon_fire_model.expected_damage_per_hit(attack)
			* max(1.0, float(attack.delivery.paths.count))
			* clamp(attack.delivery.paths.primary_probability_floor, 0.05, 1.0)
		)
		for attack_time in attack_times:
			var player_displacement: Vector2 = _sample_displacement(action.samples, attack_time)
			var targets := []
			for track in observation.enemy_tracks:
				if not track.visible:
					continue
				var predicted_position: Vector2 = _predict_enemy_position(
					track, attack_time, player_displacement
				)
				var distance: float = (predicted_position - player_displacement).length()
				if (
					distance < attack.delivery.minimum_range
					or distance > attack.delivery.maximum_range + 50.0
				):
					continue
				targets.push_back({"track": track, "distance": distance})
			targets.sort_custom(self, "_closer_proxy_target")
			var damage_capacity := damage_per_attack
			for target in targets:
				if damage_capacity <= 0.0:
					break
				var track: Dictionary = target.track
				var maximum_health: float = max(
					1.0, float(track.behavior_profile.durability.maximum_health)
				)
				var applied_damage: float = min(
					damage_capacity, float(remaining_health[track.track_id])
				)
				remaining_health[track.track_id] -= applied_damage
				damage_capacity -= applied_damage
				value += (
					applied_damage
					/ maximum_health
					* track.recency_confidence
					* _opportunity_value_model.enemy_removal_value(
						enemy_removal_value_ledger, track
					)
				)
	return value


func _closer_proxy_target(left: Dictionary, right: Dictionary) -> bool:
	return left.distance < right.distance


func _sample_displacement(samples: Array, time: float) -> Vector2:
	for sample in samples:
		if sample.time >= time:
			return sample.displacement
	return samples.back().displacement


func _predict_enemy_position(
	track: Dictionary, time: float, player_displacement := Vector2.ZERO
) -> Vector2:
	return _enemy_motion_predictor.predict_position(track, time, player_displacement)


func _usable_weapon_range(weapons: Array, is_moving: bool) -> float:
	var result := 0.0
	for weapon in weapons:
		if is_moving and not weapon.attack_model.timing.permitted_while_moving:
			continue
		result = max(result, float(weapon.attack_model.delivery.maximum_range))
	return result


func _movement_damage_exposure_reduction(observation: Dictionary, action: Dictionary) -> float:
	var current: Dictionary = observation.player_state.runtime_stats
	var projected: Dictionary = _movement_state_projector.project_runtime_stats(
		observation, action.movement != Vector2.ZERO
	)
	var current_damage_exposure: float = (
		_armor_damage_multiplier(current.armor)
		* (1.0 - current.dodge_chance)
	)
	var projected_damage_exposure: float = (
		_armor_damage_multiplier(projected.armor)
		* (1.0 - projected.dodge_chance)
	)
	return (current_damage_exposure - projected_damage_exposure) * action.forecast_seconds


func _armor_damage_multiplier(armor: float) -> float:
	if armor >= 0.0:
		return 1.0 / (1.0 + armor / 15.0)
	return 2.0 - 1.0 / (1.0 - armor / 15.0)
