extends Reference

# Predicts the outcome of one feasible movement vector over a threat-timed
# forecast. Every evaluated action receives the shared base prediction; actions
# selected for full evaluation also receive automatic-weapon prediction.
# Scoring belongs to MovementUtilityModel.

const WeaponAttackPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapon_attack_predictor.gd"
)
const ObservedMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/observed_motion_predictor.gd"
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
const OpportunityValuationModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_valuation_model.gd"
)
const CollisionHealthCostModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/collision_health_cost_model.gd"
)

var _weapon_attack_predictor: Reference = WeaponAttackPredictor.new()
var _motion_predictor: Reference = ObservedMotionPredictor.new()
var _battlefield_exposure_model: Reference = BattlefieldExposureModel.new()
var _velocity_obstacle_risk_model: Reference = VelocityObstacleRiskModel.new()
var _player_rule_outcome_predictor: Reference = PlayerRuleOutcomePredictor.new()
var _movement_state_projector: Reference = PlayerMovementStateProjector.new()
var _rule_projector: Reference = PlayerRuleProjector.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _opportunity_valuation: Reference = OpportunityValuationModel.new()
var _collision_health_cost_model: Reference = CollisionHealthCostModel.new()


func predict_collision_cost(
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
		_collision_health_cost_model.evaluate(
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
	return complete_prediction(observation, action, base_outcome, include_weapon_prediction)


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
		"recovery_approach_progress": 0.0,
		"expected_weapon_damage": 0.0,
		"expected_producer_damage": 0.0,
		"expected_bonus_kill_reward_progress": 0.0,
		"ranged_source_suppression_value": 0.0,
		"producer_approach_progress": 0.0,
		"bonus_kill_reward_approach_progress": 0.0,
		"ranged_source_engagement_progress": 0.0,
		"targets_in_weapon_range": 0.0,
		"tree_opportunity_progress": 0.0,
		"roaming_progress": 0.0,
		"standing_seconds": 0.0,
		"moving_seconds": 0.0,
		"heading_continuity": 0.0,
		"navigation_preference_alignment": 0.0,
		"expected_attack_hits": 0.0,
		"expected_effect_damage": 0.0,
		"expected_recovery": 0.0,
		"expected_recovery_events": 0.0,
		"expected_stat_change_value": 0.0,
		"expected_material_gain": 0.0,
		"expected_kill_weight": 0.0,
		"expected_critical_kill_weight": 0.0,
		"movement_damage_exposure_reduction": 0.0,
		"collision_risk": 0.0,
		"hostile_collision_risk": 0.0,
		"expected_health_loss": 0.0,
		"expendable_health_consumption_ratio": 0.0,
		"terminal_collision_risk": 0.0,
	}
	var battlefield_outcome: Dictionary = _battlefield_exposure_model.predict(
		observation, action, planning_context.exposure_policy
	)
	outcome.merge(battlefield_outcome, true)
	outcome.merge(_velocity_obstacle_risk_model.evaluate(observation, action), true)
	_predict_action_outcomes(observation, action, previous_movement, outcome)
	if planning_context.navigation_movement_preference != Vector2.ZERO:
		# Roaming is an uninformed exploration fallback, not a second reward for
		# following an already-valued navigation terminal.
		outcome.roaming_progress = 0.0
	outcome.collision_risk = max(outcome.peak_path_collision_risk, outcome.velocity_obstacle_risk)
	outcome.hostile_collision_risk = max(
		outcome.peak_path_collision_risk, outcome.hostile_velocity_obstacle_risk
	)
	var predicted_hit_damage: float = max(
		outcome.maximum_path_collision_damage, outcome.maximum_velocity_obstacle_damage
	)
	outcome.merge(
		_collision_health_cost_model.evaluate(
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
	outcome.navigation_preference_alignment = action.movement.dot(
		planning_context.navigation_movement_preference
	)
	return outcome


func complete_prediction(
	observation: Dictionary,
	action: Dictionary,
	base_outcome: Dictionary,
	include_weapon_prediction: bool
) -> Dictionary:
	var outcome: Dictionary = base_outcome.duplicate(true)
	outcome.weapon_prediction_included = include_weapon_prediction
	if include_weapon_prediction:
		_weapon_attack_predictor.accumulate_outcome(observation, action, outcome)
	_player_rule_outcome_predictor.accumulate_outcome(observation, action, outcome)
	return outcome


func _predict_action_outcomes(
	observation: Dictionary, action: Dictionary, previous_movement: Vector2, outcome: Dictionary
) -> void:
	var samples: Array = action.samples
	assert(not samples.empty())
	outcome.material_acquisition_value = _material_acquisition_value(
		observation.visible_world.materials, samples, observation.player_state.pickup
	)
	outcome.recovery_approach_progress = _recovery_approach_progress(observation, samples)
	outcome.tree_opportunity_progress = _tree_opportunity_progress(observation, action)
	outcome.producer_approach_progress = _target_approach_progress(
		observation.enemy_tracks, samples, "enemy_producer"
	)
	outcome.bonus_kill_reward_approach_progress = _bonus_kill_reward_approach_progress(
		observation, samples
	)
	outcome.ranged_source_engagement_progress = _ranged_source_engagement_progress(
		observation, action
	)
	outcome.targets_in_weapon_range = _targets_in_weapon_range(observation, action)

	var final_displacement: Vector2 = samples.back().displacement
	var roaming_distance: float = _movement_geometry.derive(observation).roaming_distance
	outcome.roaming_progress = clamp(final_displacement.length() / roaming_distance, 0.0, 1.0)
	if action.movement == Vector2.ZERO:
		outcome.standing_seconds = action.forecast_seconds
	else:
		outcome.moving_seconds = action.forecast_seconds
	if previous_movement.length_squared() > 0.0 and action.movement.length_squared() > 0.0:
		outcome.heading_continuity = previous_movement.normalized().dot(action.movement)


func _material_acquisition_value(entities: Array, samples: Array, pickup: Dictionary) -> float:
	var value := 0.0
	for entity in entities:
		var initial_distance: float = entity.relative_position.length()
		var closest_distance := initial_distance
		for sample in samples:
			closest_distance = min(
				closest_distance, (entity.relative_position - sample.displacement).length()
			)
		if closest_distance <= pickup.collection_radius:
			value += 1.0
		elif closest_distance <= pickup.attraction_radius:
			value += 0.7
		else:
			# The local predictor owns visible pickups outside attraction range as
			# normalized progress toward the attraction boundary.
			var approach_distance := max(1.0, initial_distance - pickup.attraction_radius)
			value += (
				clamp((initial_distance - closest_distance) / approach_distance, 0.0, 1.0)
				* 0.7
			)
	return value


func _recovery_approach_progress(observation: Dictionary, samples: Array) -> float:
	var progress := 0.0
	var pickup: Dictionary = observation.player_state.pickup
	var missing_health_ratio: float = 1.0 - observation.player_state.health.ratio
	for consumable in observation.visible_world.consumables:
		var recovery: float = _rule_projector.project_recovery(
			observation.player_state.effect_rules,
			"consumable_pickup",
			consumable.get("pickup_profile", {}).get("base_recovery", 0.0)
		)
		recovery = _rule_projector.project_recovery(
			observation.player_state.effect_rules, "healing", recovery
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
			* missing_health_ratio
		)
	return progress


func _tree_opportunity_progress(observation: Dictionary, action: Dictionary) -> float:
	var maximum_range: float = _usable_weapon_range(
		observation.player_state.weapons, action.movement != Vector2.ZERO
	)
	if maximum_range <= 0.0:
		return 0.0
	var interaction := 0.0
	for tree in observation.visible_world.trees:
		var initial_distance: float = tree.relative_position.length()
		var closest_distance: float = initial_distance
		for sample in action.samples:
			closest_distance = min(
				closest_distance, (tree.relative_position - sample.displacement).length()
			)
		if closest_distance <= maximum_range:
			interaction += _opportunity_valuation.tree_reward_value(observation, tree)
		else:
			# Normalize progress to the remaining gap to attack range. Approaching
			# a tree is one continuous opportunity, not a weak unrelated bonus.
			var initial_gap := max(1.0, initial_distance - maximum_range)
			var closest_gap := max(0.0, closest_distance - maximum_range)
			interaction += (
				clamp((initial_gap - closest_gap) / initial_gap, 0.0, 1.0)
				* _opportunity_valuation.tree_reward_value(observation, tree)
			)
	return interaction


func _bonus_kill_reward_approach_progress(observation: Dictionary, samples: Array) -> float:
	var progress := 0.0
	var final_displacement: Vector2 = samples.back().displacement
	for track in observation.enemy_tracks:
		if not track.behavior_profile.strategic_roles.bonus_reward_target:
			continue
		var initial_distance: float = track.relative_position.length()
		if initial_distance <= 0.0:
			continue
		var predicted_position := _predict_track_position(track, samples.back().time)
		var final_distance: float = (predicted_position - final_displacement).length()
		progress += (
			clamp((initial_distance - final_distance) / initial_distance, -1.0, 1.0)
			* track.recency_confidence
			* _opportunity_valuation.bonus_kill_reward_value(observation, track)
			* _opportunity_valuation.enemy_kill_feasibility(observation, track)
		)
	return progress


func _target_approach_progress(tracks: Array, samples: Array, role: String) -> float:
	var progress := 0.0
	var final_displacement: Vector2 = samples.back().displacement
	for track in tracks:
		if not track.behavior_profile.strategic_roles[role]:
			continue
		var initial_distance: float = track.relative_position.length()
		if initial_distance <= 0.0:
			continue
		var predicted_position := _predict_track_position(track, samples.back().time)
		var final_distance: float = (predicted_position - final_displacement).length()
		progress += (
			clamp((initial_distance - final_distance) / initial_distance, -1.0, 1.0)
			* track.recency_confidence
		)
	return progress


func _ranged_source_engagement_progress(observation: Dictionary, action: Dictionary) -> float:
	# Movement can prepare a later stationary attack, so this strategic screening
	# estimate considers owned weapon reach even when movement suppresses attacks.
	var maximum_range: float = _maximum_weapon_range(observation.player_state.weapons)
	if maximum_range <= 0.0:
		return 0.0
	var final_sample: Dictionary = action.samples.back()
	var progress := 0.0
	for track in observation.enemy_tracks:
		if not track.behavior_profile.strategic_roles.ranged_pressure_source:
			continue
		var attack_range: float = maximum_range + track.last_measurement.visual_radius
		var initial_distance: float = track.relative_position.length()
		var initial_gap: float = max(0.0, initial_distance - attack_range)
		if initial_gap <= 0.0:
			continue
		var predicted_position: Vector2 = _predict_track_position(track, final_sample.time)
		var final_distance: float = (predicted_position - final_sample.displacement).length()
		var final_gap: float = max(0.0, final_distance - attack_range)
		progress += (
			clamp((initial_gap - final_gap) / initial_distance, -1.0, 1.0)
			* track.recency_confidence
			* track.behavior_profile.attack_behavior.confidence
			* track.behavior_profile.attack_behavior.pressure_intensity
		)
	return progress


func _targets_in_weapon_range(observation: Dictionary, action: Dictionary) -> float:
	var maximum_range := _usable_weapon_range(
		observation.player_state.weapons, action.movement != Vector2.ZERO
	)
	if maximum_range <= 0.0:
		return 0.0
	var final_sample: Dictionary = action.samples.back()
	var opportunity := 0.0
	for track in observation.enemy_tracks:
		var position: Vector2 = (
			_predict_track_position(track, final_sample.time)
			- final_sample.displacement
		)
		if position.length() <= maximum_range + track.last_measurement.visual_radius:
			opportunity += track.recency_confidence
	return opportunity


func _predict_track_position(track: Dictionary, time: float) -> Vector2:
	return _motion_predictor.predict_position(
		track.relative_position,
		track.estimated_velocity,
		track.estimated_acceleration,
		track.motion_confidence,
		time
	)


func _usable_weapon_range(weapons: Array, is_moving: bool) -> float:
	var result := 0.0
	for weapon in weapons:
		if is_moving and not weapon.attack_model.timing.permitted_while_moving:
			continue
		result = max(result, float(weapon.attack_model.delivery.maximum_range))
	return result


func _maximum_weapon_range(weapons: Array) -> float:
	var result := 0.0
	for weapon in weapons:
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
