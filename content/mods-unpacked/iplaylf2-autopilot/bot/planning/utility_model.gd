extends Reference

# Converts predicted outcomes into a common utility ledger. Weights are rebuilt
# from the current state every replan. Geometric contact is a soft tail-risk
# cost until observations can support calibrated damage or death probabilities.


func build_context(observation: Dictionary) -> Dictionary:
	var health_ratio: float = observation.player_state.health.ratio
	var duration: float = max(0.01, observation.wave_state.duration_seconds)
	var wave_time_remaining_ratio: float = clamp(
		observation.wave_state.seconds_remaining / duration, 0.0, 1.0
	)
	var wave_progress := 1.0 - wave_time_remaining_ratio
	var loot_target_count := _count_role(observation.enemy_tracks, "loot_reward_target")
	var enemy_producer_count := _count_role(observation.enemy_tracks, "enemy_producer")
	var loot_target_multiplier := 1.0 + 0.15 * min(3, max(0, loot_target_count - 1))
	var producer_multiplier := 1.0 + 0.35 * min(3, max(0, enemy_producer_count - 1))
	var survivability_credit := _survivability_credit(observation)
	var risk_tolerance := clamp((health_ratio - 0.25) / 0.75 + survivability_credit, 0.0, 1.0)
	var mechanic_weights := _mechanic_weights(observation)

	return {
		"weights":
		{
			"material_pickup_value": 1.0 + 1.6 * wave_progress,
			"healing_pickup_value": lerp(10.0, 0.8, health_ratio),
			"expected_enemy_damage": 0.018 * _enemy_damage_multiplier(observation, wave_progress),
			"expected_producer_damage": 0.045 * wave_time_remaining_ratio * producer_multiplier,
			"expected_loot_target_damage": 0.055 * (1.0 + wave_progress) * loot_target_multiplier,
			"producer_approach_progress": 5.0 * wave_time_remaining_ratio * producer_multiplier,
			"loot_target_approach_progress": 4.0 * (1.0 + wave_progress) * loot_target_multiplier,
			"targets_in_weapon_range": 0.15,
			"tree_attack_opportunity": _tree_weight(observation, wave_progress),
			"hazard_exposure": -lerp(30.0, 6.0, risk_tolerance) * lerp(1.0, 0.65, wave_progress),
			"contact_pressure": -lerp(120.0, 35.0, risk_tolerance) * lerp(1.0, 0.65, wave_progress),
			"roaming_progress": 1.2 * wave_time_remaining_ratio,
			"standing_seconds": mechanic_weights.standing,
			"moving_seconds": mechanic_weights.moving,
			"heading_continuity": 0.25,
		},
		"selection_temperature":
		lerp(0.03, 0.12, risk_tolerance) * lerp(0.7, 1.2, wave_time_remaining_ratio),
		"state_factors":
		{
			"health_ratio": health_ratio,
			"wave_time_remaining_ratio": wave_time_remaining_ratio,
			"wave_progress": wave_progress,
			"risk_tolerance": risk_tolerance,
			"loot_target_count": loot_target_count,
			"enemy_producer_count": enemy_producer_count,
			"loot_target_multiplier": loot_target_multiplier,
			"producer_multiplier": producer_multiplier,
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
	return credit


func _count_role(tracks: Array, role: String) -> int:
	var result := 0
	for track in tracks:
		if track.behavior_profile.strategic_roles[role]:
			result += 1
	return result


func _enemy_damage_multiplier(observation: Dictionary, wave_progress: float) -> float:
	if _has_positive_wave_reward(observation, "materials_and_experience_per_living_enemy"):
		return lerp(0.7, -0.5, wave_progress)
	return 1.0


func _tree_weight(observation: Dictionary, wave_progress: float) -> float:
	if _has_positive_wave_reward(observation, "materials_and_experience_per_living_tree"):
		return lerp(-0.4, -2.0, wave_progress)
	return 0.5 + 0.5 * wave_progress


func _mechanic_weights(observation: Dictionary) -> Dictionary:
	var result := {"standing": 0.0, "moving": 0.0}
	for rule in observation.player_state.mechanic_rules:
		if rule.event != "movement_state" or not rule.condition.has("is_moving"):
			continue
		var value := _consequence_value(rule.consequences, observation)
		if rule.condition.is_moving:
			result.moving += value
		else:
			result.standing += value
	return result


func _consequence_value(consequences: Array, observation: Dictionary) -> float:
	var result := 0.0
	for consequence in consequences:
		if consequence.target == "materials":
			var percent: float = consequence.get("percent", 0.0) / 100.0
			result += max(1.0, observation.player_state.resources.materials * percent)
		elif consequence.operation == "add":
			result += max(0.0, consequence.get("value", 0.0)) * 0.04
	return result


func _has_positive_wave_reward(observation: Dictionary, target: String) -> bool:
	for rule in observation.player_state.mechanic_rules:
		if rule.event != "wave_end":
			continue
		for consequence in rule.consequences:
			if consequence.target == target and consequence.get("value", 0.0) > 0.0:
				return true
	return false
