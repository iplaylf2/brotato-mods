extends Reference

# Predicts the outcome of one feasible movement vector over a threat-timed
# forecast. Every scored consequence uses that same forecast; the shorter
# control interval is retained only as an execution diagnostic and as the
# fraction of a longer navigation plan that this input can actually realize.

const WeaponOutcomeFieldModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapon_outcome_field_model.gd"
)
const BattlefieldInfluenceModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/battlefield_influence_model.gd"
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
const PlayerKinematicsModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_kinematics_model.gd"
)
const OpportunityValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_value_model.gd"
)
const CollisionHealthImpactModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/collision_health_impact_model.gd"
)

var _weapon_outcome_field_model: Reference = WeaponOutcomeFieldModel.new()
var _battlefield_influence_model: Reference = BattlefieldInfluenceModel.new()
var _velocity_obstacle_risk_model: Reference = VelocityObstacleRiskModel.new()
var _player_rule_outcome_predictor: Reference = PlayerRuleOutcomePredictor.new()
var _movement_state_projector: Reference = PlayerMovementStateProjector.new()
var _rule_projector: Reference = PlayerRuleProjector.new()
var _player_kinematics_model: Reference = PlayerKinematicsModel.new()
var _opportunity_value_model: Reference = OpportunityValueModel.new()
var _collision_health_impact_model: Reference = CollisionHealthImpactModel.new()


func predict(
	observation: Dictionary, action: Dictionary, planning_context: Dictionary
) -> Dictionary:
	var base_outcome: Dictionary = predict_base(observation, action, planning_context)
	return complete_prediction(observation, action, base_outcome, planning_context)


# The expensive movement, battlefield, and collision projection is independent
# of weapon prediction. Full weapon prediction reuses this immutable base.
func predict_base(
	observation: Dictionary, action: Dictionary, planning_context: Dictionary
) -> Dictionary:
	var outcome := {
		"material_acquisition_value": 0.0,
		"wasted_consumable_recovery": 0.0,
		"consumed_consumable_recovery_supply": 0.0,
		"consumed_single_use_support_supply": 0.0,
		"expected_weapon_damage": 0.0,
		"expected_allied_damage": 0.0,
		"expected_enemy_removal_value_progress": 0.0,
		"expected_tree_harvest_value_progress": 0.0,
		"standing_seconds": 0.0,
		"moving_seconds": 0.0,
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
		"forecast_expected_health_loss": 0.0,
		"forecast_terminal_collision_risk": 0.0,
	}
	var battlefield_outcome: Dictionary = _battlefield_influence_model.predict(
		observation,
		action,
		planning_context.environmental_pressure_weights,
		planning_context.control_interval_seconds
	)
	outcome.merge(battlefield_outcome, true)
	outcome.merge(
		_velocity_obstacle_risk_model.evaluate(
			observation, action, planning_context.control_interval_seconds
		),
		true
	)
	var committed_action: Dictionary = _committed_action(
		observation, action, planning_context.control_interval_seconds
	)
	_predict_action_outcomes(observation, action, outcome)
	outcome.collision_risk = max(outcome.peak_path_collision_risk, outcome.velocity_obstacle_risk)
	outcome.hostile_collision_risk = max(
		outcome.peak_path_collision_risk, outcome.hostile_velocity_obstacle_risk
	)
	var committed_collision_risk: float = max(
		outcome.committed_peak_path_collision_risk, outcome.committed_hostile_velocity_obstacle_risk
	)
	var committed_hit_damage: float = max(
		outcome.committed_maximum_path_collision_damage,
		outcome.committed_maximum_velocity_obstacle_damage
	)
	outcome.merge(
		_collision_health_impact_model.evaluate(
			observation,
			committed_action,
			committed_collision_risk,
			outcome.committed_integrated_hostile_collision_risk,
			committed_hit_damage,
			planning_context.state_factors.positive_damage_is_terminal_rule
		),
		true
	)
	var forecast_collision_risk: float = max(
		outcome.peak_path_collision_risk, outcome.forecast_hostile_velocity_obstacle_risk
	)
	var forecast_hit_damage: float = max(
		outcome.maximum_path_collision_damage, outcome.forecast_maximum_velocity_obstacle_damage
	)
	var forecast_impact: Dictionary = _collision_health_impact_model.evaluate(
		observation,
		action,
		forecast_collision_risk,
		outcome.integrated_hostile_collision_risk,
		forecast_hit_damage,
		planning_context.state_factors.positive_damage_is_terminal_rule
	)
	outcome.forecast_expected_health_loss = forecast_impact.expected_health_loss
	outcome.forecast_terminal_collision_risk = forecast_impact.terminal_collision_risk
	outcome.forecast_expected_collision_hit_count = forecast_impact.expected_collision_hit_count
	var forecast_adjusted_hit_damage: float = forecast_impact.maximum_armor_adjusted_hit_damage
	outcome.forecast_maximum_armor_adjusted_hit_damage = forecast_adjusted_hit_damage
	outcome.movement_damage_exposure_reduction = (
		_movement_damage_exposure_reduction(observation, action)
		* outcome.collision_risk
	)
	outcome.navigation_terminal_value_gain = _navigation_terminal_value_progress(
		observation, committed_action, planning_context
	)
	return outcome


func complete_prediction(
	observation: Dictionary,
	action: Dictionary,
	base_outcome: Dictionary,
	planning_context: Dictionary
) -> Dictionary:
	# Completion only updates scalar outcome fields. Keep immutable arrays and
	# dictionaries shared instead of recursively copying the whole forecast for
	# the base forecast and its semantic completion.
	var outcome: Dictionary = base_outcome.duplicate(false)
	_weapon_outcome_field_model.accumulate_outcome(observation, action, outcome, planning_context)
	_player_rule_outcome_predictor.accumulate_outcome(observation, action, outcome)
	return outcome


func _predict_action_outcomes(
	observation: Dictionary, action: Dictionary, outcome: Dictionary
) -> void:
	var samples: Array = action.samples
	assert(not samples.empty())
	outcome.material_acquisition_value = _material_acquisition_value(observation, samples)

	if action.movement == Vector2.ZERO:
		outcome.standing_seconds = action.forecast_seconds
	else:
		outcome.moving_seconds = action.forecast_seconds


func _material_acquisition_value(observation: Dictionary, samples: Array) -> float:
	var value := 0.0
	for entity in observation.visible_world.materials:
		var closest_distance: float = entity.relative_position.length()
		for sample in samples:
			closest_distance = min(
				closest_distance, (entity.relative_position - sample.displacement).length()
			)
		if closest_distance <= observation.player_state.pickup.collection_radius:
			value += _opportunity_value_model.material_collection_value(observation, entity)
	return value


func _navigation_terminal_value_progress(
	observation: Dictionary, action: Dictionary, planning_context: Dictionary
) -> float:
	# A terminal plan contributes only the fraction caused by this committed
	# input. Subtracting the zero-input path prevents knockback from earning it.
	var terminal_distance: float = planning_context.get("navigation_terminal_distance", 0.0)
	var movement_preference: Vector2 = planning_context.navigation_movement_preference
	if terminal_distance <= 0.0 or movement_preference == Vector2.ZERO:
		return 0.0
	var committed_sample: Dictionary = action.samples.back()
	var committed_displacement: Vector2 = committed_sample.displacement
	var zero_input_displacement: Vector2 = _player_kinematics_model.predict_displacement(
		observation, Vector2.ZERO, committed_sample.time
	)
	var controlled_displacement: Vector2 = committed_displacement - zero_input_displacement
	var terminal_progress: float = clamp(
		controlled_displacement.dot(movement_preference) / terminal_distance, -1.0, 1.0
	)
	return terminal_progress * planning_context.navigation_terminal_value_gain


func _committed_action(
	observation: Dictionary, action: Dictionary, control_interval_seconds: float
) -> Dictionary:
	var committed_seconds: float = min(action.forecast_seconds, control_interval_seconds)
	var committed_samples := []
	for sample in action.samples:
		if sample.time > committed_seconds + 0.0001:
			break
		committed_samples.push_back(sample)
	if committed_samples.empty() or committed_samples.back().time < committed_seconds - 0.0001:
		committed_samples.push_back(
			{
				"time": committed_seconds,
				"displacement":
				_player_kinematics_model.predict_displacement(
					observation, action.movement, committed_seconds
				),
				"movement": action.movement,
			}
		)
	var result: Dictionary = action.duplicate(false)
	result.forecast_seconds = committed_seconds
	result.samples = committed_samples
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
