extends Reference

const PLANNING_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/planning/"

var _failed := false
var _fixtures: Reference


func run(fixtures: Reference) -> bool:
	_fixtures = fixtures
	_check_status_followup_value()
	_check_material_reset_attack_output()
	return not _failed


func _check_status_followup_value() -> void:
	var model: Reference = _model()
	var observation: Dictionary = _observation(
		_fixtures.enemy_track(Vector2(100.0, 0.0), Vector2.ZERO, false)
	)
	var event: Dictionary = _event()
	var ledger: Dictionary = _ledger()
	var damage_over_time_only: float = model.realized_value(
		observation, "consumable_pickup", event, ledger
	)
	observation.player_state.effect_rules.push_back(
		{
			"event": "damage_dealt",
			"condition":
			{
				"target_has_status": "burning",
				"damage_kind_is_not": "damage_over_time",
			},
			"consequences": [{"target": "dealt_damage", "operation": "multiply", "value": 3.0}],
		}
	)
	var status_synergy: float = model.realized_value(
		observation, "consumable_pickup", event, ledger
	)
	_expect(
		status_synergy > damage_over_time_only,
		"a status event must include marginal follow-up damage enabled during its lifetime"
	)
	observation.player_state.weapons[0].attack_model.timing.seconds_until_next_attack = 10.0
	var unavailable_followup: float = model.realized_value(
		observation, "consumable_pickup", event, ledger
	)
	_expect(
		is_equal_approx(unavailable_followup, damage_over_time_only),
		"follow-up damage must not be prepaid when no attack is available during the status"
	)


func _check_material_reset_attack_output() -> void:
	var field_script: Script = load(PLANNING_PATH + "engagement/weapon_outcome_forecast_model.gd")
	var field: Reference = field_script.new()
	var weapon: Dictionary = _fixtures.weapon_attack_model()
	weapon.timing.seconds_until_next_attack = 1.0
	var observation := {
		"physics_frame": 11,
		"player_state":
		{
			"collision_radius": 10.0,
			"health": {"current": 10.0, "maximum": 10.0},
			"runtime_stats": {"move_speed": 100.0},
			"effective_stats": {"percent_damage": 0.0, "attack_speed": 0.0},
			"effect_rules": [],
			"movement": {"knockback_velocity": Vector2.ZERO},
			"weapons": [{"slot": 0, "attack_model": weapon}],
		},
		"enemy_tracks": [_fixtures.enemy_track(Vector2(100.0, 0.0), Vector2.ZERO, false)],
		"visible_world": {"trees": []},
		"localization": {"map_bounds": _fixtures.unknown_bounds()},
	}
	var action := {
		"movement": Vector2.ZERO,
		"forecast_seconds": 0.5,
		"samples": [{"time": 0.5, "displacement": Vector2.ZERO}],
	}
	var context := {
		"tactical_control_interval_seconds": 0.1,
		"enemy_completion_value_ledger": _ledger(),
		"state_factors": {"health_inventory_value": {}},
		"wave_completion_forecast": _fixtures.wave_completion_forecast({1: 0.0}),
	}
	var events := {"material": [{"time": 0.25, "event_weight": 0.8}], "consumable": []}
	var baseline: float = _weapon_damage(field_script, field, observation, action, context, events)
	observation.player_state.effect_rules = [_material_reset_rule()]
	var reset: float = _weapon_damage(field_script, field, observation, action, context, events)
	_expect(reset > baseline, "a reachable material reset must expose same-action weapon output")
	var two_events := events.duplicate(true)
	two_events.material.push_back({"time": 0.2, "event_weight": 0.8})
	_expect(
		_weapon_damage(field_script, field, observation, action, context, two_events) >= reset,
		"another uncertain reset candidate must not reduce supported weapon output"
	)
	observation.player_state.weapons[0].attack_model.timing.seconds_until_attack_phase_complete = 1.0
	observation.physics_frame += 1
	_expect(
		is_equal_approx(
			_weapon_damage(field_script, field, observation, action, context, events), 0.0
		),
		"a material reset must preserve an attack phase already visible in player state"
	)


func _weapon_damage(
	field_script: Script,
	field: Reference,
	observation: Dictionary,
	action: Dictionary,
	context: Dictionary,
	pickup_events: Dictionary
) -> float:
	var outcome := {"expected_recovery": 0.0, "expected_recovery_events": 0.0}
	for field_name in field_script.OUTCOME_FIELDS:
		outcome[field_name] = 0.0
	outcome.pickup_events = pickup_events
	field.accumulate_outcome(observation, action, outcome, context)
	return outcome.expected_weapon_damage


func _material_reset_rule() -> Dictionary:
	return {
		"event": "material_pickup",
		"condition": {},
		"consequences":
		[
			{
				"target": "all_automatic_weapon_cooldowns",
				"operation": "set",
				"value": 0,
			}
		],
	}


func _model() -> Reference:
	var model: Reference = load(PLANNING_PATH + "engagement/rule_event_value_model.gd").new()
	model.set_enemy_motion_predictor(load(PLANNING_PATH + "motion/enemy_motion_predictor.gd").new())
	return model


func _observation(enemy: Dictionary) -> Dictionary:
	var status_consequence := {
		"target": "enemy_status",
		"operation": "apply",
		"status": "burning",
		"duration_seconds": 5.0,
		"damage_over_time": {"constant": 1.0, "minimum": 0.0},
		"delivery":
		{
			"anchor_on_event_entity": true,
			"radius": 30.0,
			"capacity_per_event": INF,
		},
	}
	return {
		"physics_frame": 7,
		"wave_state": {"seconds_remaining": 20.0},
		"player_state":
		{
			"health": {"ratio": 1.0},
			"weapons": [{"slot": 0, "attack_model": _fixtures.weapon_attack_model()}],
			"effect_rules":
			[
				{
					"event": "consumable_pickup",
					"condition": {},
					"consequences": [status_consequence],
				},
			],
		},
		"enemy_tracks": [enemy],
	}


func _event() -> Dictionary:
	return {
		"entity": {"relative_position": Vector2(100.0, 0.0)},
		"time": 0.0,
		"player_displacement": Vector2.ZERO,
	}


func _ledger() -> Dictionary:
	return {
		"entries_by_track_id":
		{
			1:
			{
				"reward_delta_value": 10.0,
				"burden_relief_value": 0.0,
				"death_consequence_value": 0.0,
				"net_completion_value": 10.0,
				"remaining_health": 10.0,
			}
		},
		"mean_net_completion_value": 0.0,
		"mean_absolute_net_completion_value": 0.0,
		"mean_burden_relief_value": 0.0,
	}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot rule-event contract failed: %s" % message)
