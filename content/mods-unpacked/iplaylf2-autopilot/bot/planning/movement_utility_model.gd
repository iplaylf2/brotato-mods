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
	var loot_target_count := _count_role(observation.enemy_tracks, "loot_reward_target")
	var enemy_producer_count := _count_role(observation.enemy_tracks, "enemy_producer")
	var ranged_source_count := _count_role(observation.enemy_tracks, "ranged_pressure_source")
	var loot_target_multiplier := 1.0 + 0.15 * min(3, max(0, loot_target_count - 1))
	var producer_multiplier := 1.0 + 0.35 * min(3, max(0, enemy_producer_count - 1))
	var ranged_source_multiplier := 1.0 + 0.2 * min(5, max(0, ranged_source_count - 1))
	var player_rule_projection: Dictionary = _rule_projector.project(observation)
	var survivability_credit := _survivability_credit(observation)
	var risk_tolerance := clamp((health_ratio - 0.25) / 0.75 + survivability_credit, 0.0, 1.0)
	var passive_health_loss_rate: float = max(0.0, -player_rule_projection.survival.health_rate)
	risk_tolerance = clamp(
		(
			risk_tolerance
			- passive_health_loss_rate / max(1.0, observation.player_state.health.maximum)
		),
		0.0,
		1.0
	)
	var projectile_density := clamp(
		observation.visible_world.enemy_projectiles.size() / 12.0, 0.0, 1.0
	)
	var ranged_engagement_appetite := (
		lerp(0.25, 1.0, risk_tolerance)
		* lerp(1.0, 0.35, projectile_density)
	)
	var movement_state_value_rates: Dictionary = player_rule_projection.movement_state_value_rates
	var fatal_on_unprotected_hit := (
		player_rule_projection.survival.terminal_on_positive_damage
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
	if fatal_on_unprotected_hit:
		risk_tolerance = 0.0
	var contact_combat_appetite := clamp(
		(
			max(incoming_attack_value.enemy_damage, incoming_attack_value.player_growth)
			* risk_tolerance
		),
		0.0,
		1.0
	)

	return {
		"weights":
		{
			"material_pickup_value": 1.0 + 1.6 * wave_progress,
			"recovery_pickup_value":
			lerp(10.0, 0.8, health_ratio) if recovery_profile.consumable_available else 0.0,
			"expected_weapon_damage":
			0.018 * _enemy_damage_multiplier(player_rule_projection, wave_progress),
			"expected_effect_damage":
			0.018 * _enemy_damage_multiplier(player_rule_projection, wave_progress),
			"expected_recovery": lerp(3.0, 0.15, health_ratio),
			"expected_stat_gain_value": 0.8,
			"expected_material_gain": 1.0 + 1.6 * wave_progress,
			"movement_survivability_delta": 20.0,
			"expected_producer_damage": 0.045 * wave_time_remaining_ratio * producer_multiplier,
			"expected_loot_target_damage": 0.055 * (1.0 + wave_progress) * loot_target_multiplier,
			"ranged_source_suppression_value":
			10.0 * wave_time_remaining_ratio * ranged_source_multiplier,
			"producer_approach_progress": 5.0 * wave_time_remaining_ratio * producer_multiplier,
			"loot_target_approach_progress": 4.0 * (1.0 + wave_progress) * loot_target_multiplier,
			"ranged_source_engagement_progress":
			6.0 * wave_time_remaining_ratio * ranged_source_multiplier * ranged_engagement_appetite,
			"targets_in_weapon_range": 0.15,
			"tree_attack_opportunity": _tree_weight(player_rule_projection, wave_progress),
			"integrated_survival_pressure":
			(
				-lerp(20.0, 5.0 - 2.0 * contact_combat_appetite, risk_tolerance)
				* lerp(1.0, 0.65, wave_progress)
			),
			"mean_pressure_material_derivative": -lerp(5.0, 1.5, risk_tolerance),
			"velocity_obstacle_risk":
			(
				-(160.0 if fatal_on_unprotected_hit else lerp(70.0, 28.0, risk_tolerance))
				* lerp(1.0, 0.45, contact_combat_appetite)
				* lerp(1.0, 0.75, wave_progress)
			),
			"allied_zone_healing_support":
			lerp(14.0, 1.5, health_ratio) if recovery_profile.available else 0.0,
			"roaming_progress": 1.2 * wave_time_remaining_ratio,
			"standing_seconds": movement_state_value_rates.standing,
			"moving_seconds": movement_state_value_rates.moving,
			"heading_continuity": 0.25,
			"navigation_guidance_alignment": 4.0,
		},
		"selection_temperature":
		lerp(0.03, 0.12, risk_tolerance) * lerp(0.7, 1.2, wave_time_remaining_ratio),
		"pressure_policy":
		{
			"enemy_proximity": 0.7,
			"contact": 2.2,
			"projectile": 1.4,
			"spawn": 0.8,
			"ranged": 0.6 * lerp(1.0, 1.5, projectile_density) * ranged_source_multiplier,
			"edge": 1.2,
			"ally_body": 0.8,
			"allied_suppression": 0.8,
			"projectile_interception": 1.4,
		},
		"navigation_policy":
		{
			"material": 0.35 + 0.55 * wave_progress,
			"recovery_pickup":
			lerp(1.2, 0.1, health_ratio) if recovery_profile.consumable_available else 0.0,
			"consumable_event_value":
			clamp(
				max(
					_event_value(player_rule_projection, "consumable_pickup", "enemy_damage"),
					_event_value(player_rule_projection, "consumable_pickup", "player_growth")
				),
				0.0,
				1.0
			),
			"healing_support": lerp(0.9, 0.1, health_ratio) if recovery_profile.available else 0.0,
			"tree": _tree_weight(player_rule_projection, wave_progress) * 0.35,
			"enemy_producer": 0.45 * wave_time_remaining_ratio * producer_multiplier,
			"loot_target": 0.35 * (1.0 + wave_progress) * loot_target_multiplier,
			"ranged_source":
			0.5 * wave_time_remaining_ratio * ranged_source_multiplier * ranged_engagement_appetite,
			"rising_pressure": 0.22,
			"travel_cost": 0.08,
			"contact_combat": 0.65 * contact_combat_appetite,
		},
		"state_factors":
		{
			"health_ratio": health_ratio,
			"wave_time_remaining_ratio": wave_time_remaining_ratio,
			"wave_progress": wave_progress,
			"risk_tolerance": risk_tolerance,
			"loot_target_count": loot_target_count,
			"enemy_producer_count": enemy_producer_count,
			"ranged_source_count": ranged_source_count,
			"loot_target_multiplier": loot_target_multiplier,
			"producer_multiplier": producer_multiplier,
			"ranged_source_multiplier": ranged_source_multiplier,
			"projectile_density": projectile_density,
			"ranged_engagement_appetite": ranged_engagement_appetite,
			"fatal_on_unprotected_hit": fatal_on_unprotected_hit,
			"incoming_attack_value": incoming_attack_value,
			"recovery_profile": recovery_profile,
			"contact_combat_appetite": contact_combat_appetite,
			"passive_health_loss_rate": passive_health_loss_rate,
		},
	}


func evaluate(outcome: Dictionary, context: Dictionary) -> Dictionary:
	var breakdown := {}
	var score := 0.0
	for name in context.weights:
		var contribution: float = outcome.get(name, 0.0) * context.weights[name]
		breakdown[name] = contribution
		score += contribution
	return {
		"score": score,
		"breakdown": breakdown,
	}


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


func _tree_weight(rule_projection: Dictionary, wave_progress: float) -> float:
	if _event_value(rule_projection, "wave_end", "tree_preservation") > 0.0:
		return lerp(-0.4, -2.0, wave_progress)
	return 0.5 + 0.5 * wave_progress


func _event_value(rule_projection: Dictionary, event: String, channel: String) -> float:
	return rule_projection.event_outcome_channels.get(event, {}).get(channel, 0.0)
