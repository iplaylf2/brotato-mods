extends Reference

# Converts predicted outcomes into a common utility ledger. Weights are rebuilt
# from the current state every replan. Geometric contact is a soft tail-risk
# cost until observations can support calibrated damage or death probabilities.

const PlayerRuleProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_rule_projector.gd"
)

var _rule_projector: Reference = PlayerRuleProjector.new()


func build_context(observation: Dictionary) -> Dictionary:
	var health_ratio: float = observation.player_state.health.ratio
	var duration: float = max(0.01, observation.wave_state.duration_seconds)
	var wave_time_remaining_ratio: float = clamp(
		observation.wave_state.seconds_remaining / duration, 0.0, 1.0
	)
	var wave_progress := 1.0 - wave_time_remaining_ratio
	var bonus_reward_target_count := _count_role(observation.enemy_tracks, "bonus_reward_target")
	var enemy_producer_count := _count_role(observation.enemy_tracks, "enemy_producer")
	var ranged_source_count := _count_role(observation.enemy_tracks, "ranged_pressure_source")
	var producer_multiplier := 1.0 + 0.35 * min(3, max(0, enemy_producer_count - 1))
	var ranged_source_multiplier := 1.0 + 0.2 * min(5, max(0, ranged_source_count - 1))
	var player_rule_projection: Dictionary = _rule_projector.project(observation)
	var survivability_credit := _survivability_credit(observation)
	var risk_tolerance := clamp((health_ratio - 0.25) / 0.75 + survivability_credit, 0.0, 1.0)
	var passive_health_loss_rate: float = max(0.0, -player_rule_projection.survival.health_rate)
	var passive_recovery_rate: float = max(0.0, player_rule_projection.survival.recovery_rate)
	risk_tolerance = clamp(
		(
			risk_tolerance
			- passive_health_loss_rate / max(1.0, observation.player_state.health.maximum)
			+ passive_recovery_rate / max(1.0, observation.player_state.health.maximum)
		),
		0.0,
		1.0
	)
	var projectile_density := clamp(
		observation.visible_world.enemy_projectiles.size() / 12.0, 0.0, 1.0
	)
	var ranged_engagement_appetite: float = (
		lerp(0.25, 1.0, risk_tolerance)
		* lerp(1.0, 0.35, projectile_density)
	)
	var movement_state_economy_rates: Dictionary = player_rule_projection.movement_state_economy_rates
	var damage_is_terminal_rule: bool = player_rule_projection.survival.terminal_on_positive_damage
	var current_unprotected_damage_is_terminal: bool = (
		damage_is_terminal_rule
		and observation.player_state.runtime_stats.hit_protection <= 0
	)
	var incoming_attack_value := {
		"enemy_damage":
		max(
			_event_value(player_rule_projection, "damage_taken", "enemy_damage"),
			_event_value(player_rule_projection, "attack_dodged", "enemy_damage")
		),
		"player_growth":
		max(
			_event_value(player_rule_projection, "damage_taken", "player_growth"),
			_event_value(player_rule_projection, "attack_dodged", "player_growth")
		),
	}
	var recovery_profile: Dictionary = player_rule_projection.recovery
	if current_unprotected_damage_is_terminal:
		risk_tolerance = 0.0
	var contact_combat_appetite := clamp(
		(
			max(incoming_attack_value.enemy_damage, incoming_attack_value.player_growth)
			* risk_tolerance
		),
		0.0,
		1.0
	)
	var environmental_exposure_cost: float = lerp(
		20.0, 5.0 - 2.0 * contact_combat_appetite, risk_tolerance
	)
	var health_replacement_cost := (
		1.0
		/ max(1.0, float(recovery_profile.maximum_consumable_recovery))
	)
	var context := {
		"objective_weights":
		{
			"survival":
			{
				"integrated_environmental_exposure": -environmental_exposure_cost,
				"terminal_collision_risk":
				(
					-(
						160.0
						if current_unprotected_damage_is_terminal
						else lerp(70.0, 28.0, risk_tolerance)
					)
					* lerp(1.0, 0.45, contact_combat_appetite)
				),
				# Ordinary contact spends replaceable health. One full survival reserve
				# is an additional unit of option value; only terminal contact keeps the
				# hard run-ending price above.
				"expected_health_loss": -health_replacement_cost,
				"expendable_health_consumption_ratio": -1.0,
				"movement_damage_exposure_reduction": 20.0,
			},
			"recovery":
			{
				"recovery_approach_progress":
				lerp(10.0, 0.8, health_ratio) if recovery_profile.consumable_available else 0.0,
				"expected_recovery": lerp(3.0, 0.15, health_ratio),
				"integrated_allied_healing_support":
				lerp(14.0, 1.5, health_ratio) if recovery_profile.available else 0.0,
			},
			"economy":
			{
				"material_acquisition_value": 1.0 + 1.6 * wave_progress,
				"expected_stat_change_value": 0.8,
				"expected_material_gain": 1.0 + 1.6 * wave_progress,
				"tree_opportunity_progress": 1.0 + 1.6 * wave_progress,
				"expected_bonus_kill_reward_progress": 1.0 + 1.6 * wave_progress,
				"bonus_kill_reward_approach_progress": 0.8,
				"standing_seconds": movement_state_economy_rates.standing,
				"moving_seconds": movement_state_economy_rates.moving,
			},
			"combat":
			{
				"expected_weapon_damage":
				0.018 * _enemy_damage_multiplier(player_rule_projection, wave_progress),
				"expected_effect_damage":
				0.018 * _enemy_damage_multiplier(player_rule_projection, wave_progress),
				"expected_producer_damage": 0.045 * wave_time_remaining_ratio * producer_multiplier,
				"ranged_source_suppression_value":
				10.0 * wave_time_remaining_ratio * ranged_source_multiplier,
				"producer_approach_progress": 5.0 * wave_time_remaining_ratio * producer_multiplier,
				"ranged_source_engagement_progress":
				(
					6.0
					* wave_time_remaining_ratio
					* ranged_source_multiplier
					* ranged_engagement_appetite
				),
			},
			# Exploration remains useful when no observed goal owns navigation;
			# local exposure still suppresses it in an uncontrolled battlefield.
			"navigation":
			{
				"roaming_progress": 0.35 * risk_tolerance + 0.85 * wave_time_remaining_ratio,
				"navigation_preference_alignment": 4.0,
			},
			"control_stability": {"heading_continuity": 0.25},
		},
		# Screening proxies stand in for outcomes omitted before weapon prediction.
		# They are not additional utility once that prediction supplies them.
		"screening_proxy_weights": {"combat": {"targets_in_weapon_range": 0.15}},
		"selection_temperature":
		lerp(0.03, 0.12, risk_tolerance) * lerp(0.7, 1.2, wave_time_remaining_ratio),
		"exposure_policy":
		{
			"enemy_proximity": 0.7,
			"enemy_contact": 2.2,
			"projectile_contact": 1.4,
			"spawn_warning": 0.8,
			"ranged_source": 0.6 * lerp(1.0, 1.5, projectile_density) * ranged_source_multiplier,
			"map_edge": 1.2,
			"allied_body_proximity": 0.8,
			"allied_pressure_relief": 0.8,
			"projectile_interception_relief": 1.4,
		},
		"navigation_policy":
		{
			"material": 0.35 + 0.55 * wave_progress,
			"recovery_pickup":
			(1.2 * (1.0 - health_ratio)) if recovery_profile.consumable_available else 0.0,
			"healing_support": lerp(0.9, 0.1, health_ratio) if recovery_profile.available else 0.0,
			"tree": 0.35,
			"enemy_producer": 0.45 * wave_time_remaining_ratio * producer_multiplier,
			"bonus_reward_target": 0.35,
			"ranged_source":
			0.5 * wave_time_remaining_ratio * ranged_source_multiplier * ranged_engagement_appetite,
			"rising_pressure": 0.22,
			# Navigation shares local scoring's state-dependent risk price, normalized
			# to the low-health endpoint.
			"environmental_exposure_cost": environmental_exposure_cost / 20.0,
			"travel_cost": 0.08,
			"contact_combat": 0.65 * contact_combat_appetite,
		},
		"state_factors":
		{
			"health_ratio": health_ratio,
			"wave_time_remaining_ratio": wave_time_remaining_ratio,
			"wave_progress": wave_progress,
			"risk_tolerance": risk_tolerance,
			"bonus_reward_target_count": bonus_reward_target_count,
			"enemy_producer_count": enemy_producer_count,
			"ranged_source_count": ranged_source_count,
			"producer_multiplier": producer_multiplier,
			"ranged_source_multiplier": ranged_source_multiplier,
			"projectile_density": projectile_density,
			"ranged_engagement_appetite": ranged_engagement_appetite,
			"positive_damage_is_terminal_rule": damage_is_terminal_rule,
			"current_unprotected_damage_is_terminal": current_unprotected_damage_is_terminal,
			"incoming_attack_value": incoming_attack_value,
			"recovery_profile": recovery_profile,
			"contact_combat_appetite": contact_combat_appetite,
			"passive_health_loss_rate": passive_health_loss_rate,
			"passive_recovery_rate": passive_recovery_rate,
			"health_replacement_cost": health_replacement_cost,
		},
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
		score += objective_score
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


func _survivability_credit(observation: Dictionary) -> float:
	var credit := 0.0
	credit += clamp(observation.player_state.runtime_stats.armor / 100.0, -0.1, 0.15)
	credit += clamp(observation.player_state.runtime_stats.dodge_chance * 0.15, 0.0, 0.1)
	credit += clamp(observation.player_state.effective_stats.health_regeneration / 100.0, 0.0, 0.1)
	credit += clamp(observation.player_state.effective_stats.lifesteal / 1000.0, 0.0, 0.1)
	return credit


func _count_role(tracks: Array, role: String) -> int:
	var result := 0
	for track in tracks:
		if track.behavior_profile.strategic_roles[role]:
			result += 1
	return result


func _enemy_damage_multiplier(rule_projection: Dictionary, wave_progress: float) -> float:
	if _event_value(rule_projection, "wave_end", "enemy_preservation") > 0.0:
		return lerp(0.7, -0.5, wave_progress)
	return 1.0


func _event_value(rule_projection: Dictionary, event: String, channel: String) -> float:
	return rule_projection.event_outcome_channels.get(event, {}).get(channel, 0.0)
