extends Reference

# Owner-level contracts for attacks already committed before candidate movement.
# They compare scored outcomes without prescribing a movement mode or policy.

const PLANNING_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/planning/"

var _failed := false
var _fixtures: Reference


func run(fixtures: Reference) -> bool:
	_fixtures = fixtures
	_check_moving_committed_melee_contact()
	_check_sweep_positioning_quality()
	return not _failed


func _check_moving_committed_melee_contact() -> void:
	var forecast_script: Script = load(
		PLANNING_PATH + "engagement/weapon_outcome_forecast_model.gd"
	)
	var forecast: Reference = forecast_script.new()
	var enemy: Dictionary = _fixtures.enemy_track(Vector2(80.0, 0.0), Vector2.ZERO, false)
	enemy.last_measurement.health = {"current": 20.0, "maximum": 20.0, "ratio": 1.0}
	enemy.behavior_profile.durability = {"maximum_health": 20.0}
	var observation: Dictionary = _fixtures.planning_observation([enemy])
	observation.player_state.health = {"current": 10.0, "maximum": 10.0, "ratio": 1.0}
	observation.player_state.effective_stats.percent_damage = 0.0
	observation.player_state.effective_stats.attack_speed = 0.0
	var attack_model: Dictionary = _fixtures.weapon_attack_model()
	attack_model.timing.attack_in_progress = true
	attack_model.timing.seconds_until_next_attack = 10.0
	attack_model.timing.seconds_until_attack_phase_complete = 0.8
	attack_model.timing.committed_contact_pending = true
	attack_model.timing.seconds_until_committed_contact = 0.4
	attack_model.timing.seconds_until_committed_contact_expires = 0.6
	attack_model.timing.permitted_while_moving = false
	attack_model.delivery.paths.maximum_travel_distance = 100.0
	observation.player_state.weapons = [{"slot": 0, "attack_model": attack_model}]
	var utility: Reference = load(PLANNING_PATH + "movement_utility_model.gd").new()
	var context: Dictionary = utility.build_context(observation)
	context.tactical_control_interval_seconds = 0.1
	var keep_contact_action := _action(Vector2.RIGHT, Vector2(80.0, 0.0))
	var abandon_contact_action := _action(Vector2.LEFT, Vector2(-80.0, 0.0))
	var keep_contact_outcome := _empty_outcome(forecast_script.OUTCOME_FIELDS)
	var abandon_contact_outcome := _empty_outcome(forecast_script.OUTCOME_FIELDS)
	forecast.accumulate_outcome(observation, keep_contact_action, keep_contact_outcome, context)
	forecast.accumulate_outcome(
		observation, abandon_contact_action, abandon_contact_outcome, context
	)
	var keep_contact_score: Dictionary = utility.evaluate(keep_contact_outcome, context)
	var abandon_contact_score: Dictionary = utility.evaluate(abandon_contact_outcome, context)
	var unsupported_completion_context := context.duplicate(true)
	var wave_forecast: Dictionary = unsupported_completion_context.wave_completion_forecast
	var completion_fractions: Dictionary = wave_forecast.completion_fraction_by_target_id
	completion_fractions["enemy:1"] = 0.0
	var unsupported_completion_outcome := _empty_outcome(forecast_script.OUTCOME_FIELDS)
	forecast.accumulate_outcome(
		observation,
		keep_contact_action,
		unsupported_completion_outcome,
		unsupported_completion_context
	)
	var unsupported_completion_score: Dictionary = utility.evaluate(
		unsupported_completion_outcome, unsupported_completion_context
	)
	_expect(
		(
			keep_contact_outcome.expected_weapon_damage > 0.0
			and is_equal_approx(abandon_contact_outcome.expected_weapon_damage, 0.0)
		),
		"the committed-contact scenario must distinguish a preserved hit from an empty swing"
	)
	_expect(
		keep_contact_score.score > abandon_contact_score.score,
		(
			"a moving action that preserves feasible committed melee work must retain more "
			+ "utility than an otherwise equivalent action that abandons it"
		)
	)
	_expect(
		is_equal_approx(unsupported_completion_score.score, abandon_contact_score.score),
		(
			"committed partial damage must not prepay target value when the shared wave "
			+ "forecast does not support eventual completion"
		)
	)


func _check_sweep_positioning_quality() -> void:
	var forecast_script: Script = load(
		PLANNING_PATH + "engagement/weapon_outcome_forecast_model.gd"
	)
	var forecast: Reference = forecast_script.new()
	var primary: Dictionary = _fixtures.enemy_track(Vector2(80.0, 0.0), Vector2.ZERO, false)
	primary.last_measurement.health = {"current": 20.0, "maximum": 20.0, "ratio": 1.0}
	primary.behavior_profile.durability = {"maximum_health": 20.0}
	var secondary: Dictionary = _fixtures.enemy_track(Vector2(80.0, 120.0), Vector2.ZERO, false)
	secondary.track_id = 2
	secondary.last_measurement.health = {"current": 20.0, "maximum": 20.0, "ratio": 1.0}
	secondary.behavior_profile.durability = {"maximum_health": 20.0}
	var observation: Dictionary = _fixtures.planning_observation([primary, secondary])
	observation.player_state.health = {"current": 10.0, "maximum": 10.0, "ratio": 1.0}
	observation.player_state.effective_stats.percent_damage = 0.0
	observation.player_state.effective_stats.attack_speed = 0.0
	var attack_model: Dictionary = _fixtures.weapon_attack_model()
	attack_model.timing.attack_in_progress = true
	attack_model.timing.seconds_until_next_attack = 10.0
	attack_model.timing.committed_contact_pending = true
	attack_model.timing.seconds_until_committed_contact = 0.4
	attack_model.timing.seconds_until_committed_contact_expires = 0.6
	attack_model.timing.permitted_while_moving = false
	attack_model.delivery.paths.angular_half_extent = 0.9 * PI
	attack_model.delivery.paths.corridor_half_width = 0.0
	attack_model.delivery.paths.hit_capacity = INF
	attack_model.delivery.paths.maximum_travel_distance = 100.0
	observation.player_state.weapons = [{"slot": 0, "attack_model": attack_model}]
	var utility: Reference = load(PLANNING_PATH + "movement_utility_model.gd").new()
	var context: Dictionary = utility.build_context(observation)
	context.tactical_control_interval_seconds = 0.1
	var improve_coverage_outcome := _empty_outcome(forecast_script.OUTCOME_FIELDS)
	var lose_coverage_outcome := _empty_outcome(forecast_script.OUTCOME_FIELDS)
	forecast.accumulate_outcome(
		observation, _action(Vector2.DOWN, Vector2(0.0, 80.0)), improve_coverage_outcome, context
	)
	forecast.accumulate_outcome(
		observation, _action(Vector2.UP, Vector2(0.0, -80.0)), lose_coverage_outcome, context
	)
	var improve_coverage_score: Dictionary = utility.evaluate(improve_coverage_outcome, context)
	var lose_coverage_score: Dictionary = utility.evaluate(lose_coverage_outcome, context)
	_expect(
		(
			lose_coverage_outcome.expected_weapon_damage > 0.0
			and (
				improve_coverage_outcome.expected_weapon_damage
				> lose_coverage_outcome.expected_weapon_damage
			)
		),
		"the sweep scenario must preserve its primary hit while exposing another target"
	)
	_expect(
		improve_coverage_score.score > lose_coverage_score.score,
		(
			"positioning that adds feasible sweep coverage must retain more utility than "
			+ "an otherwise equivalent path that hits only the primary target"
		)
	)


func _action(movement: Vector2, displacement: Vector2) -> Dictionary:
	return {
		"movement": movement,
		"forecast_seconds": 0.5,
		"samples": [{"time": 0.5, "displacement": displacement, "movement": movement}],
	}


func _empty_outcome(field_names: Array) -> Dictionary:
	var outcome := {}
	for field_name in field_names:
		outcome[field_name] = 0.0
	outcome.expected_recovery = 0.0
	outcome.expected_recovery_events = 0.0
	outcome.forecast_expected_health_loss = 0.0
	outcome.forecast_terminal_health_risk = 0.0
	outcome.forecast_seconds = 0.5
	return outcome


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot committed attack contract failed: %s" % message)
