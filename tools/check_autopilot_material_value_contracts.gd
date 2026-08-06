extends Reference

# Focused contracts for confirmed material quantities and their pickup value.

const PLANNING_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/planning/"

var _failed := false
var _fixtures: Reference


func run(fixtures: Reference) -> bool:
	_fixtures = fixtures
	_check_confirmed_material_quantity_pricing()
	_check_material_pickup_multiplier_quantity()
	_check_remembered_consumable_collection()
	_check_crossed_pickup_opportunity()
	_check_recovery_supply_pricing()
	_check_damaging_consumable_pricing()
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
		"existence_confidence": 0.5,
	}
	var observation: Dictionary = _fixtures.planning_observation([])
	observation.remembered_entities = [material]
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
		"pickup_events":
		load(PLANNING_PATH + "pickups/pickup_collection_projector.gd").new().project(
			observation, action.samples
		),
		"expected_recovery": 0.0,
		"expected_recovery_events": 0.0,
		"expected_critical_kill_weight": 0.0,
		"material_acquisition_value": 4.0,
	}
	predictor.accumulate_outcome(
		observation, action, outcome, {"enemy_completion_value_ledger": {}}
	)
	_expect(
		is_equal_approx(outcome.material_acquisition_value, 6.0),
		(
			"pickup multipliers must scale remembered material quantity and current "
			+ "existence confidence rather than the node count"
		)
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


func _check_damaging_consumable_pricing() -> void:
	var predictor: Reference = load(PLANNING_PATH + "player_rule_outcome_predictor.gd").new()
	var utility: Reference = load(PLANNING_PATH + "movement_utility_model.gd").new()
	var opportunity: Reference = load(PLANNING_PATH + "opportunity_pricing_model.gd").new()
	var observation: Dictionary = _fixtures.planning_observation([])
	observation.player_state.health = {"current": 4.0, "maximum": 20.0, "ratio": 0.2}
	observation.player_state.effect_rules = [
		{
			"event": "consumable_pickup",
			"condition": {},
			"consequences":
			[
				{
					"target": "consumable_health_effect",
					"operation": "add",
					"value": 1.0,
				}
			],
		}
	]
	var poisoned_fruit := {
		"kind": "consumable",
		"relative_position": Vector2(10.0, 0.0),
		"visual_radius": 10.0,
		"existence_confidence": 1.0,
		"pickup_profile": {"base_recovery": 0.0, "base_health_damage": 3.0, "traits": ["fruit"]},
	}
	observation.remembered_entities = [poisoned_fruit]
	observation.visible_world.consumables = [poisoned_fruit]
	var action := {
		"forecast_seconds": 0.1,
		"samples": [{"time": 0.1, "displacement": Vector2.ZERO}],
	}
	var outcome_template := {
		"pickup_events":
		load(PLANNING_PATH + "pickups/pickup_collection_projector.gd").new().project(
			observation, action.samples
		),
		"expected_recovery": 0.0,
		"expected_recovery_events": 0.0,
		"expected_critical_kill_weight": 0.0,
		"consumed_consumable_recovery_supply": 0.0,
		"wasted_consumable_recovery": 0.0,
		"forecast_consumable_health_loss": 0.0,
		"committed_consumable_health_loss": 0.0,
		"forecast_expected_health_loss": 0.0,
		"committed_expected_health_loss": 0.0,
		"forecast_terminal_consumable_risk": 0.0,
		"committed_terminal_consumable_risk": 0.0,
		"forecast_terminal_health_risk": 0.0,
		"committed_terminal_health_risk": 0.0,
	}
	var outcome: Dictionary = outcome_template.duplicate(true)
	predictor.accumulate_outcome(
		observation,
		action,
		outcome,
		{"enemy_completion_value_ledger": {}, "control_interval_seconds": 0.1}
	)
	_expect(
		(
			is_equal_approx(outcome.forecast_consumable_health_loss, 4.0)
			and is_equal_approx(outcome.committed_consumable_health_loss, 4.0)
			and is_equal_approx(outcome.forecast_terminal_health_risk, 1.0)
			and is_equal_approx(outcome.committed_terminal_health_risk, 1.0)
			and is_equal_approx(outcome.expected_recovery, 0.0)
		),
		(
			"a damaging consumable must apply the shared consumable modifier to damage, "
			+ "enter both health-loss horizons, and remain distinct from recovery"
		)
	)
	var delayed_outcome: Dictionary = outcome_template.duplicate(true)
	delayed_outcome.pickup_events = {
		"material": [],
		"consumable": [{"entity": poisoned_fruit, "time": 0.4, "event_weight": 1.0}],
	}
	action.forecast_seconds = 0.4
	predictor.accumulate_outcome(
		observation,
		action,
		delayed_outcome,
		{"enemy_completion_value_ledger": {}, "control_interval_seconds": 0.1}
	)
	_expect(
		(
			is_equal_approx(delayed_outcome.forecast_terminal_health_risk, 1.0)
			and is_equal_approx(delayed_outcome.committed_terminal_health_risk, 0.0)
		),
		"a lethal pickup beyond the committed prefix must remain terminal in forecast value"
	)
	var context: Dictionary = utility.build_context(observation)
	_expect(
		(
			opportunity.consumable_pickup_value(
				observation,
				poisoned_fruit,
				context.state_factors.health_inventory_value,
				context.state_factors.run_continuation_value
			)
			< 0.0
		),
		"a damaging consumable must form negative navigation value without an identity policy"
	)
	var distant_poisoned_fruit: Dictionary = poisoned_fruit.duplicate(true)
	distant_poisoned_fruit.relative_position = Vector2(300.0, 0.0)
	observation.remembered_entities = [distant_poisoned_fruit]
	observation.visible_world.consumables = [distant_poisoned_fruit]
	var spatial_script: Script = load(PLANNING_PATH + "spatial_opportunity_value_model.gd")
	var toward_poison: Dictionary = spatial_script.new().point_value_delta(
		observation, context, Vector2(100.0, 0.0), 1.0
	)
	var away_from_poison: Dictionary = spatial_script.new().point_value_delta(
		observation, context, Vector2(-100.0, 0.0), 1.0
	)
	_expect(
		(
			is_zero_approx(toward_poison.recovery_opportunity)
			and is_zero_approx(away_from_poison.recovery_opportunity)
		),
		(
			"a harmful optional pickup must stay out of the navigation field in both "
			+ "directions instead of driving retreat into a boundary"
		)
	)


func _check_remembered_consumable_collection() -> void:
	var projector: Reference = load(PLANNING_PATH + "pickups/pickup_collection_projector.gd").new()
	var predictor: Reference = load(PLANNING_PATH + "player_rule_outcome_predictor.gd").new()
	var observation: Dictionary = _fixtures.planning_observation([])
	observation.player_state.health = {"current": 5.0, "maximum": 20.0, "ratio": 0.25}
	observation.remembered_entities = [
		{
			"kind": "consumable",
			"relative_position": Vector2(60.0, 0.0),
			"existence_confidence": 0.5,
			"pickup_profile": {"base_recovery": 3.0, "traits": ["fruit"]},
		}
	]
	var action := {
		"forecast_seconds": 1.0,
		"samples": [{"time": 1.0, "displacement": Vector2(100.0, 0.0)}],
	}
	var outcome := {
		"pickup_events": projector.project(observation, action.samples),
		"expected_recovery": 0.0,
		"expected_recovery_events": 0.0,
		"expected_critical_kill_weight": 0.0,
		"consumed_consumable_recovery_supply": 0.0,
		"wasted_consumable_recovery": 0.0,
	}
	predictor.accumulate_outcome(
		observation, action, outcome, {"enemy_completion_value_ledger": {}}
	)
	_expect(
		(
			is_equal_approx(outcome.expected_recovery, 1.5)
			and is_equal_approx(outcome.consumed_consumable_recovery_supply, 1.5)
		),
		(
			"an off-screen remembered consumable crossed by the action path must enter "
			+ "recovery and supply ledgers at its existence confidence"
		)
	)


func _check_crossed_pickup_opportunity() -> void:
	var spatial: Reference = load(PLANNING_PATH + "spatial_opportunity_value_model.gd").new()
	var observation: Dictionary = _fixtures.planning_observation([])
	observation.remembered_entities = [
		{
			"kind": "material",
			"relative_position": Vector2(60.0, 0.0),
			"existence_confidence": 1.0,
			"material_quantity": 1.0,
		}
	]
	var context := {
		"state_factors": {"health_inventory_value": {}},
		"enemy_completion_value_ledger": {},
		"wave_completion_forecast": _fixtures.wave_completion_forecast({}),
	}
	var crossed_value: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(100.0, 0.0), 1.0
	)
	_expect(
		crossed_value.material_opportunity > 0.0,
		(
			"a navigation path must retain an absorbing pickup reward after crossing "
			+ "the collection circle instead of losing it after overshoot"
		)
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot material-value contract failed: %s" % message)
