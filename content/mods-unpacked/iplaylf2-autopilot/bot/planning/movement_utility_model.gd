extends Reference

# Converts predicted state deltas into a material-equivalent utility ledger.

const PlayerRuleProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_rule_projector.gd"
)
const HealthInventoryValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/health/health_inventory_value_model.gd"
)
const OpportunityPricingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_pricing_model.gd"
)
const TargetCompletionAllocationModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/target_completion_allocation_model.gd"
)

var _rule_projector: Reference = PlayerRuleProjector.new()
var _health_inventory_value_model: Reference = HealthInventoryValueModel.new()
var _opportunity_pricing_model: Reference = OpportunityPricingModel.new()
var _target_completion_allocation_model: Reference = TargetCompletionAllocationModel.new()
var _scoring_schema_validated := false


func build_context(observation: Dictionary) -> Dictionary:
	var health_ratio: float = observation.player_state.health.ratio
	var duration: float = max(0.01, observation.wave_state.duration_seconds)
	var wave_time_remaining_ratio: float = clamp(
		observation.wave_state.seconds_remaining / duration, 0.0, 1.0
	)
	var player_rule_projection: Dictionary = _rule_projector.project(observation)
	var recovery_profile: Dictionary = player_rule_projection.recovery
	var completion_ledger: Dictionary = _target_completion_allocation_model.allocate(observation)
	var health_inventory_value: Dictionary = _health_inventory_value_model.estimate(
		observation, player_rule_projection, completion_ledger
	)
	var marginal_health_unit_value: float = health_inventory_value.marginal_health_unit_value
	var terminal_health_loss_unit_value: float = health_inventory_value.terminal_health_loss_unit_value
	var movement_state_economy_rates: Dictionary = player_rule_projection.movement_state_economy_rates
	var damage_is_terminal_rule: bool = player_rule_projection.survival.terminal_on_positive_damage
	var current_unprotected_damage_is_terminal: bool = (
		damage_is_terminal_rule
		and observation.player_state.runtime_stats.hit_protection <= 0
	)
	var removal_value_ledger: Dictionary = _opportunity_pricing_model.build_enemy_removal_value_ledger(
		observation, marginal_health_unit_value
	)
	var information_value_per_viewport := _information_value_per_viewport(
		observation, removal_value_ledger, health_inventory_value, wave_time_remaining_ratio
	)
	var context := {
		"objective_weights":
		{
			"survival":
			{
				"integrated_environmental_exposure": -marginal_health_unit_value,
				"forecast_terminal_collision_risk":
				(
					-terminal_health_loss_unit_value
					* max(1.0, health_inventory_value.immediate_hit_reserve)
				),
				"forecast_health_inventory_loss_value": -1.0,
				"movement_damage_exposure_reduction": marginal_health_unit_value,
			},
			"recovery":
			# Recovery first becomes liquid health. A consumable pickup also spends
			# replenishment supply below, so the two entries together equal the
			# liquidity-conversion value. Pricing recovery at that net value here
			{
				# would charge the consumed supply twice.
				"expected_recovery": health_inventory_value.terminal_health_loss_unit_value,
				# Replacement supply lowers the shadow price of taking damage. Charging
				# that same price when a pickup is consumed puts insurance and consumption
				# on one ledger instead of letting the same reserve be valued twice.
				"consumed_consumable_recovery_supply":
				-health_inventory_value.replenishment_unit_value,
				"consumed_single_use_support_supply": -marginal_health_unit_value,
				"integrated_allied_healing_support":
				(
					health_inventory_value.recovery_conversion_unit_value
					if recovery_profile.available
					else 0.0
				),
			},
			"economy":
			{
				"material_acquisition_value": 1.0,
				"expected_stat_upgrade_equivalents": 1.0,
				"expected_stat_opportunity_value": 1.0,
				"expected_material_gain": 1.0,
				"expected_tree_harvest_value_progress": 1.0,
				"standing_seconds": movement_state_economy_rates.standing,
				"moving_seconds": movement_state_economy_rates.moving,
			},
			"combat":
			{
				"expected_enemy_removal_value_progress": 1.0,
				"expected_rule_damage": removal_value_ledger.mean_removal_value_per_enemy_health,
				"expected_allied_damage": removal_value_ledger.mean_removal_value_per_enemy_health,
			},
			"navigation": {"navigation_terminal_value_gain": 1.0},
		},
		"environmental_pressure_weights":
		{
			"enemy_proximity": 1.0,
			"enemy_contact": 1.0,
			"projectile_contact": 1.0,
			"spawn_warning": 1.0,
			"ranged_attack": 1.0,
			"map_edge": 1.0,
			"allied_body_proximity": 1.0,
			"allied_pressure_relief": 1.0,
			"projectile_interception_relief": 1.0,
		},
		"state_factors":
		{
			"health_ratio": health_ratio,
			"wave_time_remaining_ratio": wave_time_remaining_ratio,
			"positive_damage_is_terminal_rule": damage_is_terminal_rule,
			"current_unprotected_damage_is_terminal": current_unprotected_damage_is_terminal,
			"recovery_profile": recovery_profile,
			"health_inventory_value": health_inventory_value,
			"mean_removal_value_per_enemy_health":
			removal_value_ledger.mean_removal_value_per_enemy_health,
			"living_enemy_preservation_value": removal_value_ledger.living_enemy_preservation_value,
			"information_value_per_viewport": information_value_per_viewport,
			"environmental_exposure_value": marginal_health_unit_value,
		},
		"enemy_removal_value_ledger": removal_value_ledger,
		"target_completion_ledger": completion_ledger,
	}
	if OS.is_debug_build() and not _scoring_schema_validated:
		_assert_valid_scoring_schema(context)
		_scoring_schema_validated = true
	return context


func evaluate(outcome: Dictionary, context: Dictionary) -> Dictionary:
	var scored_outcome := outcome.duplicate(false)
	var health_inventory_value: Dictionary = context.state_factors.health_inventory_value
	var health_inventory_loss_value: float = _health_inventory_value_model.health_loss_value(
		outcome.forecast_expected_health_loss, health_inventory_value
	)
	scored_outcome.forecast_health_inventory_loss_value = health_inventory_loss_value
	var field_utility_breakdown := {}
	var objective_utility_breakdown := {}
	var score := 0.0
	for objective_name in context.objective_weights:
		var objective_score := 0.0
		for name in context.objective_weights[objective_name]:
			var contribution: float = (
				scored_outcome.get(name, 0.0)
				* context.objective_weights[objective_name][name]
			)
			field_utility_breakdown[name] = contribution
			objective_score += contribution
			objective_utility_breakdown[objective_name] = objective_score
			score += contribution
	return {
		"score": score,
		"field_utility_breakdown": field_utility_breakdown,
		"objective_utility_breakdown": objective_utility_breakdown,
	}


func _assert_valid_scoring_schema(context: Dictionary) -> void:
	var field_owners := {}
	for objective_name in context.objective_weights:
		for field_name in context.objective_weights[objective_name]:
			assert(not field_owners.has(field_name))
			field_owners[field_name] = objective_name


func _information_value_per_viewport(
	observation: Dictionary,
	removal_value_ledger: Dictionary,
	health_inventory_value: Dictionary,
	remaining_ratio: float
) -> float:
	var observed_value := 0.0
	for material in observation.visible_world.materials:
		observed_value += _opportunity_pricing_model.material_collection_value(
			observation, material
		)
	var observation_count: int = observation.visible_world.materials.size()
	for consumable in observation.visible_world.consumables:
		observed_value += (
			_opportunity_pricing_model.consumable_recovery_value(observation, consumable)
			* health_inventory_value.recovery_conversion_unit_value
		)
		observation_count += 1
	for tree in observation.visible_world.trees:
		observed_value += _opportunity_pricing_model.tree_destruction_value(
			observation, tree, health_inventory_value
		)
		observation_count += 1
	if not observation.enemy_tracks.empty():
		observed_value += (
			removal_value_ledger.mean_absolute_removal_value
			* observation.enemy_tracks.size()
		)
		observation_count += observation.enemy_tracks.size()
	var empirical_opportunity_value: float = observed_value / max(1, observation_count)
	return max(1.0, empirical_opportunity_value) * remaining_ratio
