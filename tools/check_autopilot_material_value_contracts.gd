extends Reference

# Focused contracts for confirmed material quantities and their pickup value.

const PLANNING_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/planning/"

var _failed := false
var _fixtures: Reference


func run(fixtures: Reference) -> bool:
	_fixtures = fixtures
	_check_confirmed_material_quantity_pricing()
	_check_material_pickup_multiplier_quantity()
	_check_recovery_supply_pricing()
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


func _check_recovery_supply_pricing() -> void:
	var utility: Reference = load(PLANNING_PATH + "movement_utility_model.gd").new()
	var observation: Dictionary = _fixtures.planning_observation([])
	observation.player_state.health = {"current": 4.0, "maximum": 20.0, "ratio": 0.2}
	observation.player_state.resources = {"materials": 0.0}
	var fruit := {
		"kind": "consumable",
		"relative_position": Vector2(10.0, 0.0),
		"visual_radius": 10.0,
		"existence_confidence": 1.0,
		"pickup_profile": {"base_recovery": 3.0, "traits": ["fruit"]},
	}
	observation.remembered_entities = [fruit]
	observation.visible_world.consumables = [fruit]
	var context: Dictionary = utility.build_context(observation)
	var pickup_utility: Dictionary = utility.evaluate(
		{
			"forecast_expected_health_loss": 0.0,
			"expected_recovery": 3.0,
			"consumed_consumable_recovery_supply": 3.0,
		},
		context
	)
	_expect(
		pickup_utility.objective_utility_breakdown.recovery > 0.0,
		"collecting reachable healing supply must produce recovery value"
	)
	var tree := {
		"destructible_profile":
		{
			"death_rewards":
			{
				"material_quantity": 0.0,
				"material_drop_guaranteed": true,
				"base_consumable_drop_chance": 1.0,
				"item_box_conditional_chance": 0.0,
				"consumable_drop_guaranteed": true,
			}
		}
	}
	var opportunity: Reference = load(PLANNING_PATH + "opportunity_pricing_model.gd").new()
	var no_drop_tree: Dictionary = tree.duplicate(true)
	no_drop_tree.destructible_profile.death_rewards.base_consumable_drop_chance = 0.0
	no_drop_tree.destructible_profile.death_rewards.consumable_drop_guaranteed = false
	_expect(
		(
			opportunity.tree_destruction_value(
				observation, tree, context.state_factors.health_inventory_value
			)
			> opportunity.tree_destruction_value(
				observation, no_drop_tree, context.state_factors.health_inventory_value
			)
		),
		"a tree that creates reachable healing supply must retain inventory value"
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot material-value contract failed: %s" % message)
