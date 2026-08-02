extends Reference

# Predicts the outcome of one feasible movement vector over a threat-timed
# forecast. The screening pass covers exposure and goals; shortlisted actions
# also receive automatic-weapon prediction. Scoring belongs to MovementUtilityModel.

const WeaponAttackPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapon_attack_predictor.gd"
)
const ObservedMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/observed_motion_predictor.gd"
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

const ROAMING_DISTANCE := 600.0

var _weapon_attack_predictor: Reference = WeaponAttackPredictor.new()
var _motion_predictor: Reference = ObservedMotionPredictor.new()
var _battlefield_exposure_model: Reference = BattlefieldExposureModel.new()
var _velocity_obstacle_risk_model: Reference = VelocityObstacleRiskModel.new()
var _player_rule_outcome_predictor: Reference = PlayerRuleOutcomePredictor.new()
var _movement_state_projector: Reference = PlayerMovementStateProjector.new()
var _rule_projector: Reference = PlayerRuleProjector.new()


func predict(
	observation: Dictionary,
	action: Dictionary,
	previous_movement: Vector2,
	include_weapon_prediction: bool,
	planning_context: Dictionary
) -> Dictionary:
	var outcome := {
		"weapon_prediction_included": include_weapon_prediction,
		"material_acquisition_value": 0.0,
		"recovery_approach_progress": 0.0,
		"expected_weapon_damage": 0.0,
		"expected_producer_damage": 0.0,
		"expected_loot_target_damage": 0.0,
		"ranged_source_suppression_value": 0.0,
		"producer_approach_progress": 0.0,
		"loot_target_approach_progress": 0.0,
		"ranged_source_engagement_progress": 0.0,
		"targets_in_weapon_range": 0.0,
		"tree_attack_opportunity": 0.0,
		"roaming_progress": 0.0,
		"standing_seconds": 0.0,
		"moving_seconds": 0.0,
		"heading_continuity": 0.0,
		"navigation_guidance_alignment": 0.0,
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
	}
	var battlefield_outcome: Dictionary = _battlefield_exposure_model.predict(
		observation, action, planning_context.exposure_policy
	)
	outcome.merge(battlefield_outcome, true)
	outcome.merge(_velocity_obstacle_risk_model.evaluate(observation, action), true)
	_predict_action_outcomes(observation, action, previous_movement, outcome)
	if planning_context.navigation_guidance != Vector2.ZERO:
		# Roaming is an uninformed exploration fallback, not a second reward for
		# following an already-valued navigation terminal.
		outcome.roaming_progress = 0.0
	outcome.collision_risk = max(outcome.peak_path_collision_risk, outcome.velocity_obstacle_risk)
	outcome.movement_damage_exposure_reduction = (
		_movement_damage_exposure_reduction(observation, action)
		* outcome.collision_risk
	)
	outcome.navigation_guidance_alignment = action.movement.dot(
		planning_context.navigation_guidance
	)
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
	outcome.tree_attack_opportunity = _tree_attack_opportunity(observation, action)
	outcome.producer_approach_progress = _target_approach_progress(
		observation.enemy_tracks, samples, "enemy_producer"
	)
	outcome.loot_target_approach_progress = _target_approach_progress(
		observation.enemy_tracks, samples, "loot_reward_target"
	)
	outcome.ranged_source_engagement_progress = _ranged_source_engagement_progress(
		observation, action
	)
	outcome.targets_in_weapon_range = _targets_in_weapon_range(observation, action)

	var final_displacement: Vector2 = samples.back().displacement
	outcome.roaming_progress = clamp(final_displacement.length() / ROAMING_DISTANCE, 0.0, 1.0)
	if action.movement == Vector2.ZERO:
		outcome.standing_seconds = action.forecast_seconds
	else:
		outcome.moving_seconds = action.forecast_seconds
	if previous_movement.length_squared() > 0.0 and action.movement.length_squared() > 0.0:
		outcome.heading_continuity = previous_movement.normalized().dot(action.movement)


func _material_acquisition_value(entities: Array, samples: Array, pickup: Dictionary) -> float:
	var value := 0.0
	for entity in entities:
		var closest_distance := entity.relative_position.length()
		for sample in samples:
			closest_distance = min(
				closest_distance, (entity.relative_position - sample.displacement).length()
			)
		if closest_distance <= pickup.collection_radius:
			value += 1.0
		elif closest_distance <= pickup.attraction_radius:
			value += 0.7
		else:
			value += max(0.0, 1.0 - closest_distance / 500.0) * 0.15
	return value


func _recovery_approach_progress(observation: Dictionary, samples: Array) -> float:
	var progress := 0.0
	var pickup: Dictionary = observation.player_state.pickup
	var missing_health_ratio := 1.0 - observation.player_state.health.ratio
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


func _tree_attack_opportunity(observation: Dictionary, action: Dictionary) -> float:
	var maximum_range := _usable_weapon_range(
		observation.player_state.weapons, action.movement != Vector2.ZERO
	)
	if maximum_range <= 0.0:
		return 0.0
	var interaction := 0.0
	for tree in observation.visible_world.trees:
		var initial_distance := tree.relative_position.length()
		var closest_distance := initial_distance
		for sample in action.samples:
			closest_distance = min(
				closest_distance, (tree.relative_position - sample.displacement).length()
			)
		if closest_distance <= maximum_range:
			interaction += 1.0
		elif initial_distance > 0.0:
			interaction += max(0.0, initial_distance - closest_distance) / initial_distance * 0.3
	return interaction


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
	var maximum_range := _maximum_weapon_range(observation.player_state.weapons)
	if maximum_range <= 0.0:
		return 0.0
	var final_sample: Dictionary = action.samples.back()
	var progress := 0.0
	for track in observation.enemy_tracks:
		if not track.behavior_profile.strategic_roles.ranged_pressure_source:
			continue
		var attack_range := maximum_range + track.last_measurement.visual_radius
		var initial_distance: float = track.relative_position.length()
		var initial_gap := max(0.0, initial_distance - attack_range)
		if initial_gap <= 0.0:
			continue
		var predicted_position := _predict_track_position(track, final_sample.time)
		var final_distance: float = (predicted_position - final_sample.displacement).length()
		var final_gap := max(0.0, final_distance - attack_range)
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
		var position := (
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
	var current_damage_exposure := (
		_armor_damage_multiplier(current.armor)
		* (1.0 - current.dodge_chance)
	)
	var projected_damage_exposure := (
		_armor_damage_multiplier(projected.armor)
		* (1.0 - projected.dodge_chance)
	)
	return (current_damage_exposure - projected_damage_exposure) * action.forecast_seconds


func _armor_damage_multiplier(armor: float) -> float:
	if armor >= 0.0:
		return 1.0 / (1.0 + armor / 15.0)
	return 2.0 - 1.0 / (1.0 - armor / 15.0)
