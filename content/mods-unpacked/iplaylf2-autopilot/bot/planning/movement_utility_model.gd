extends Reference

# Converts predicted state deltas into one material-equivalent utility ledger.
# Mechanics may create different consequences, but entity categories do not own
# policy weights or target-selection priority.

const PlayerRuleProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_rule_projector.gd"
)
const HealthResourceValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/health_resource_value_model.gd"
)
const OpportunityValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_value_model.gd"
)

var _rule_projector: Reference = PlayerRuleProjector.new()
var _health_resource_value_model: Reference = HealthResourceValueModel.new()
var _opportunity_value_model: Reference = OpportunityValueModel.new()


func build_context(observation: Dictionary) -> Dictionary:
	var health_ratio: float = observation.player_state.health.ratio
	var duration: float = max(0.01, observation.wave_state.duration_seconds)
	var wave_time_remaining_ratio: float = clamp(
		observation.wave_state.seconds_remaining / duration, 0.0, 1.0
	)
	var player_rule_projection: Dictionary = _rule_projector.project(observation)
	var recovery_profile: Dictionary = player_rule_projection.recovery
	var health_value: Dictionary = _health_resource_value_model.estimate(
		observation, player_rule_projection
	)
	var health_price: float = health_value.marginal_health_value
	var movement_state_economy_rates: Dictionary = player_rule_projection.movement_state_economy_rates
	var damage_is_terminal_rule: bool = player_rule_projection.survival.terminal_on_positive_damage
	var current_unprotected_damage_is_terminal: bool = (
		damage_is_terminal_rule
		and observation.player_state.runtime_stats.hit_protection <= 0
	)
	var removal_value_ledger: Dictionary = _opportunity_value_model.build_enemy_removal_value_ledger(
		observation, health_price
	)
	var information_value_per_viewport := _information_value_per_viewport(
		observation, removal_value_ledger, health_value, wave_time_remaining_ratio
	)
	var context := {
		"objective_weights":
		{
			"survival":
			{
				"integrated_environmental_exposure": -health_price,
				"terminal_collision_risk":
				-health_price * max(1.0, health_value.observed_hit_reserve),
				"expected_health_loss": -health_price,
				"movement_damage_exposure_reduction": health_price,
			},
			"recovery":
			{
				"consumable_recovery_approach_progress":
				(
					health_value.recovery_conversion_value
					if recovery_profile.consumable_available
					else 0.0
				),
				"expected_recovery": health_price,
				"consumed_consumable_recovery_supply": -health_value.recovery_supply_value,
				"integrated_allied_healing_support":
				health_value.recovery_conversion_value if recovery_profile.available else 0.0,
			},
			"economy":
			{
				"material_acquisition_value": 1.0,
				"material_approach_progress": 1.0,
				"expected_stat_upgrade_equivalents": 1.0,
				"expected_material_gain": 1.0,
				"tree_opportunity_progress": 1.0,
				"standing_seconds": movement_state_economy_rates.standing,
				"moving_seconds": movement_state_economy_rates.moving,
			},
			"combat":
			{
				"expected_enemy_removal_value_progress": 1.0,
				"enemy_removal_value_approach_progress": 1.0,
				"expected_rule_damage": removal_value_ledger.mean_value_per_health,
			},
			"navigation": {"navigation_terminal_value_gain": 1.0},
			# This is a switching cost, not a goal preference.
			"control_stability": {"heading_continuity": 0.1},
		},
		# The proxy estimates the same enemy removal value before exact weapon
		# geometry is available; it disappears from fully evaluated actions.
		"screening_proxy_weights": {"combat": {"enemy_removal_value_in_range": 1.0}},
		"exposure_policy":
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
			"health_resource_value": health_value,
			"mean_enemy_removal_value_per_health": removal_value_ledger.mean_value_per_health,
			"living_enemy_preservation_value": removal_value_ledger.living_enemy_preservation_value,
			"information_value_per_viewport": information_value_per_viewport,
			"environmental_exposure_value": health_price,
		},
		"enemy_removal_value_ledger": removal_value_ledger,
	}
	if OS.is_debug_build():
		_assert_valid_scoring_schema(context)
	return context


func evaluate(outcome: Dictionary, context: Dictionary) -> Dictionary:
	var field_utility_breakdown := {}
	var objective_utility_breakdown := {}
	var score := 0.0
	for objective_name in context.objective_weights:
		var objective_score := 0.0
		for name in context.objective_weights[objective_name]:
			var contribution: float = (
				outcome.get(name, 0.0)
				* context.objective_weights[objective_name][name]
			)
			field_utility_breakdown[name] = contribution
			objective_score += contribution
			objective_utility_breakdown[objective_name] = objective_score
			score += contribution
	if not outcome.weapon_prediction_included:
		for objective_name in context.screening_proxy_weights:
			for name in context.screening_proxy_weights[objective_name]:
				var contribution: float = (
					outcome.get(name, 0.0)
					* context.screening_proxy_weights[objective_name][name]
				)
				field_utility_breakdown[name] = contribution
				objective_utility_breakdown[objective_name] += contribution
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
	for objective_name in context.screening_proxy_weights:
		assert(context.objective_weights.has(objective_name))
		for field_name in context.screening_proxy_weights[objective_name]:
			assert(not field_owners.has(field_name))
			field_owners[field_name] = objective_name


func _information_value_per_viewport(
	observation: Dictionary,
	removal_value_ledger: Dictionary,
	health_value: Dictionary,
	remaining_ratio: float
) -> float:
	var observed_value: float = float(observation.visible_world.materials.size())
	var observation_count: int = observation.visible_world.materials.size()
	for consumable in observation.visible_world.consumables:
		observed_value += (
			_opportunity_value_model.consumable_recovery_value(observation, consumable)
			* health_value.recovery_conversion_value
		)
		observation_count += 1
	for tree in observation.visible_world.trees:
		observed_value += _opportunity_value_model.tree_reward_value(observation, tree)
		observation_count += 1
	if not observation.enemy_tracks.empty():
		observed_value += (
			removal_value_ledger.mean_absolute_value
			* observation.enemy_tracks.size()
		)
		observation_count += observation.enemy_tracks.size()
	var empirical_opportunity_value: float = observed_value / max(1, observation_count)
	return max(1.0, empirical_opportunity_value) * remaining_ratio
