extends Reference

# Predicts the outcome of one feasible movement vector over a threat-timed
# forecast. Every scored consequence uses that same forecast; the shorter
# control interval is retained only as an execution diagnostic for the input
# that will actually be submitted before replanning.

const WeaponOutcomeForecastModel := preload("engagement/weapon_outcome_forecast_model.gd")
const BattlefieldInfluenceModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/battlefield_influence_model.gd"
)
const VelocityObstacleCollisionModel := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/collision/"
		+ "velocity_obstacle_collision_model.gd"
	)
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
const OpportunityPricingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_pricing_model.gd"
)
const CollisionHealthImpactModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/health/collision_health_impact_model.gd"
)
const PickupCollectionProjector := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/pickups/"
		+ "pickup_collection_projector.gd"
	)
)

var _weapon_outcome_forecast_model: Reference = WeaponOutcomeForecastModel.new()
var _battlefield_influence_model: Reference = BattlefieldInfluenceModel.new()
var _velocity_obstacle_collision_model: Reference = VelocityObstacleCollisionModel.new()
var _player_rule_outcome_predictor: Reference = PlayerRuleOutcomePredictor.new()
var _movement_state_projector: Reference = PlayerMovementStateProjector.new()
var _rule_projector: Reference = PlayerRuleProjector.new()
var _player_kinematics_model: Reference = PlayerKinematicsModel.new()
var _opportunity_pricing_model: Reference = OpportunityPricingModel.new()
var _collision_health_impact_model: Reference = CollisionHealthImpactModel.new()
var _pickup_collection_projector: Reference = PickupCollectionProjector.new()


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_weapon_outcome_forecast_model.set_enemy_motion_predictor(predictor)
	_battlefield_influence_model.set_enemy_motion_predictor(predictor)
	_velocity_obstacle_collision_model.set_enemy_motion_predictor(predictor)
	_player_rule_outcome_predictor.set_enemy_motion_predictor(predictor)


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
		"pickup_events": _pickup_collection_projector.project(observation, action.samples),
		"forecast_seconds": action.forecast_seconds,
		"material_acquisition_value": 0.0,
		"wasted_consumable_recovery": 0.0,
		"consumed_consumable_recovery_supply": 0.0,
		"consumed_single_use_support_supply": 0.0,
		"expected_weapon_damage": 0.0,
		"expected_allied_completion_value": 0.0,
		"expected_enemy_completion_equivalents": 0.0,
		"expected_enemy_reward_delta_value": 0.0,
		"expected_enemy_burden_relief_value": 0.0,
		"expected_enemy_death_consequence_value": 0.0,
		"expected_tree_completion_value": 0.0,
		"standing_seconds": 0.0,
		"moving_seconds": 0.0,
		"navigation_trajectory_value_gain": 0.0,
		"expected_attack_hits": 0.0,
		"expected_enemy_hits": 0.0,
		"expected_rule_completion_value": 0.0,
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
		"forecast_consumable_health_loss": 0.0,
		"committed_consumable_health_loss": 0.0,
		"terminal_consumable_risk": 0.0,
		"terminal_health_risk": 0.0,
	}
	var battlefield_outcome: Dictionary = _battlefield_influence_model.predict(
		observation,
		action,
		planning_context.environmental_pressure_weights,
		planning_context.control_interval_seconds,
		planning_context.enemy_completion_value_ledger
	)
	outcome.merge(battlefield_outcome, true)
	outcome.merge(
		_velocity_obstacle_collision_model.evaluate(
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
	outcome.merge(
		_collision_health_impact_model.evaluate(
			observation,
			committed_action,
			_committed_collision_evidence(outcome),
			planning_context.state_factors.positive_damage_is_terminal_rule
		),
		true
	)
	var forecast_impact: Dictionary = _collision_health_impact_model.evaluate(
		observation,
		action,
		_forecast_collision_evidence(outcome),
		planning_context.state_factors.positive_damage_is_terminal_rule
	)
	outcome.forecast_expected_health_loss = forecast_impact.expected_health_loss
	outcome.forecast_terminal_collision_risk = forecast_impact.terminal_collision_risk
	var forecast_resolution_count: float = forecast_impact.expected_contact_resolution_count
	outcome.forecast_expected_contact_resolution_count = forecast_resolution_count
	outcome.committed_contact_opportunity_count = outcome.committed_contact_opportunities.size()
	outcome.forecast_contact_opportunity_count = outcome.contact_opportunities.size()
	var forecast_maximum_adjusted_hit_damage: float = forecast_impact.maximum_armor_adjusted_hit_damage
	outcome.forecast_maximum_armor_adjusted_hit_damage = forecast_maximum_adjusted_hit_damage
	outcome.movement_damage_exposure_reduction = (
		_movement_damage_exposure_reduction(observation, action)
		* outcome.collision_risk
	)
	# Navigation is a consequence of sustaining the candidate over the same
	# forecast used by exposure, collision, pickups, rules, and weapon outcomes.
	# The controller still commits only one control interval before replanning;
	# shortening this field alone made local combat receive several times the
	# horizon of strategic movement in the same utility comparison.
	outcome.navigation_trajectory_value_gain = _navigation_trajectory_progress(
		observation, action, planning_context
	)
	return outcome


func _committed_collision_evidence(outcome: Dictionary) -> Dictionary:
	return {
		"path_collision_risk": outcome.committed_peak_path_collision_risk,
		"path_contact_evidence_seconds": outcome.committed_path_contact_evidence_seconds,
		"path_raw_damage_evidence_seconds": outcome.committed_path_raw_damage_evidence_seconds,
		"maximum_path_raw_damage": outcome.committed_maximum_path_collision_raw_damage,
		"velocity_collision_risk": outcome.committed_hostile_velocity_obstacle_risk,
		"velocity_contact_evidence_sum":
		outcome.committed_hostile_velocity_obstacle_contact_evidence_sum,
		"velocity_raw_damage_evidence_sum":
		outcome.committed_hostile_velocity_obstacle_raw_damage_evidence_sum,
		"maximum_velocity_raw_damage": outcome.committed_maximum_velocity_obstacle_raw_damage,
		"contact_opportunities": outcome.committed_contact_opportunities,
	}


func _forecast_collision_evidence(outcome: Dictionary) -> Dictionary:
	return {
		"path_collision_risk": outcome.peak_path_collision_risk,
		"path_contact_evidence_seconds": outcome.path_contact_evidence_seconds,
		"path_raw_damage_evidence_seconds": outcome.path_raw_damage_evidence_seconds,
		"maximum_path_raw_damage": outcome.maximum_path_collision_raw_damage,
		"velocity_collision_risk": outcome.forecast_hostile_velocity_obstacle_risk,
		"velocity_contact_evidence_sum":
		outcome.forecast_hostile_velocity_obstacle_contact_evidence_sum,
		"velocity_raw_damage_evidence_sum":
		outcome.forecast_hostile_velocity_obstacle_raw_damage_evidence_sum,
		"maximum_velocity_raw_damage": outcome.forecast_maximum_velocity_obstacle_raw_damage,
		"contact_opportunities": outcome.contact_opportunities,
	}


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
	outcome.terminal_health_risk = outcome.terminal_collision_risk
	_weapon_outcome_forecast_model.accumulate_outcome(
		observation, action, outcome, planning_context
	)
	_player_rule_outcome_predictor.accumulate_outcome(
		observation, action, outcome, planning_context
	)
	return outcome


func _predict_action_outcomes(
	observation: Dictionary, action: Dictionary, outcome: Dictionary
) -> void:
	var samples: Array = action.samples
	assert(not samples.empty())
	outcome.material_acquisition_value = _material_acquisition_value(
		observation, outcome.pickup_events.material
	)

	if action.movement == Vector2.ZERO:
		outcome.standing_seconds = action.forecast_seconds
	else:
		outcome.moving_seconds = action.forecast_seconds


func _material_acquisition_value(observation: Dictionary, events: Array) -> float:
	var value := 0.0
	for event in events:
		value += (
			_opportunity_pricing_model.material_collection_value(observation, event.entity)
			* event.event_weight
		)
	return value


func _navigation_trajectory_progress(
	observation: Dictionary, action: Dictionary, planning_context: Dictionary
) -> float:
	# Realize the trajectory value field at this action's direction using only the
	# displacement caused by the candidate movement input.
	var terminal_sample: Dictionary = action.samples.back()
	var terminal_displacement: Vector2 = terminal_sample.displacement
	var zero_input_displacement: Vector2 = _player_kinematics_model.predict_displacement(
		observation, Vector2.ZERO, terminal_sample.time
	)
	var controlled_displacement: Vector2 = terminal_displacement - zero_input_displacement
	if controlled_displacement.length_squared() <= 0.0:
		return 0.0
	var directional_samples: Array = planning_context.navigation_trajectory_value_samples
	if directional_samples.empty():
		return 0.0
	var value_rate: float = _interpolated_navigation_value_rate(
		controlled_displacement.normalized(), directional_samples
	)
	return controlled_displacement.length() * value_rate


func _interpolated_navigation_value_rate(direction: Vector2, directional_samples: Array) -> float:
	var direction_angle: float = fposmod(direction.angle(), TAU)
	var before: Dictionary = directional_samples[0]
	var after: Dictionary = directional_samples[0]
	var before_distance := INF
	var after_distance := INF
	for sample in directional_samples:
		var sample_angle: float = fposmod(sample.direction.angle(), TAU)
		var clockwise_distance: float = fposmod(direction_angle - sample_angle, TAU)
		var counterclockwise_distance: float = fposmod(sample_angle - direction_angle, TAU)
		if clockwise_distance < before_distance:
			before_distance = clockwise_distance
			before = sample
		if counterclockwise_distance < after_distance:
			after_distance = counterclockwise_distance
			after = sample
	var before_rate: float = before.value_rate
	if before_distance <= 0.000001:
		return before_rate
	var after_rate: float = after.value_rate
	var angular_span: float = before_distance + after_distance
	return lerp(before_rate, after_rate, before_distance / angular_span)


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
