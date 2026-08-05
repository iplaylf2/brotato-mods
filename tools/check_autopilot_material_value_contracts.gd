extends Reference

# Focused contracts for confirmed material quantities and their pickup value.

const PLANNING_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/planning/"

var _failed := false
var _fixtures: Reference


func run(fixtures: Reference) -> bool:
	_fixtures = fixtures
	_check_confirmed_material_quantity_pricing()
	_check_material_pickup_multiplier_quantity()
	return not _failed


func _check_confirmed_material_quantity_pricing() -> void:
	var pricing: Reference = load(PLANNING_PATH + "opportunity_pricing_model.gd").new()
	var observation := {
		"wave_state": {"duration_seconds": 20.0, "seconds_remaining": 20.0},
	}
	_expect(
		is_equal_approx(
			pricing.material_collection_value(observation, {"material_quantity": 17.0}), 17.0
		),
		"material pricing must preserve the exact quantity used by vanilla settlement"
	)


func _check_material_pickup_multiplier_quantity() -> void:
	var predictor: Reference = load(PLANNING_PATH + "player_rule_outcome_predictor.gd").new()
	var material := {
		"kind": "material",
		"relative_position": Vector2(10.0, 0.0),
		"material_quantity": 8.0,
	}
	var observation: Dictionary = _fixtures.planning_observation([])
	observation.visible_world.materials = [material]
	observation.player_state.effect_rules = [
		{
			"event": "material_pickup",
			"condition": {},
			"consequences":
			[
				{
					"target": "picked_material_value",
					"operation": "multiply",
					"value": 1.5,
				}
			],
		}
	]
	var action := {
		"forecast_seconds": 0.1,
		"samples": [{"time": 0.1, "displacement": Vector2.ZERO}],
	}
	var outcome := {
		"expected_recovery": 0.0,
		"expected_recovery_events": 0.0,
		"expected_critical_kill_weight": 0.0,
		"material_acquisition_value": 8.0,
	}
	predictor.accumulate_outcome(
		observation, action, outcome, {"enemy_completion_value_ledger": {}}
	)
	_expect(
		is_equal_approx(outcome.material_acquisition_value, 12.0),
		"pickup multipliers must scale the confirmed quantity rather than the node count"
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot material-value contract failed: %s" % message)
