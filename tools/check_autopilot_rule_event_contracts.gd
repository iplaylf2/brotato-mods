extends Reference

const PLANNING_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/planning/"

var _failed := false
var _fixtures: Reference


func run(fixtures: Reference) -> bool:
	_fixtures = fixtures
	_check_status_followup_value()
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
				"net_completion_value": 10.0,
				"remaining_health": 10.0,
			}
		}
	}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot rule-event contract failed: %s" % message)
