extends Reference

# Projects raw death-reward inputs into current material and consumable
# probabilities. Knowledge owns the detached profile; this model owns its
# composition with wave rules and current luck.


func material_drop_probability(observation: Dictionary, death_rewards: Dictionary) -> float:
	if death_rewards.get("material_drop_guaranteed", false):
		return 1.0
	var wave_number: float = max(1.0, observation.wave_state.number)
	var chance := 1.0 if wave_number < 5.0 else max(0.5, 1.0 - wave_number * 0.015)
	if observation.wave_state.get("is_horde", false):
		chance *= 0.65
	return clamp(chance, 0.0, 1.0)


func any_consumable_drop_probability(observation: Dictionary, death_rewards: Dictionary) -> float:
	if death_rewards.get("consumable_drop_guaranteed", false):
		return 1.0
	return clamp(
		death_rewards.get("base_consumable_drop_chance", 0.0) * _luck_multiplier(observation),
		0.0,
		1.0
	)


func item_box_drop_probability(observation: Dictionary, death_rewards: Dictionary) -> float:
	var conditional_chance: float = clamp(
		death_rewards.get("item_box_conditional_chance", 0.0) * _luck_multiplier(observation),
		0.0,
		1.0
	)
	return any_consumable_drop_probability(observation, death_rewards) * conditional_chance


func _luck_multiplier(observation: Dictionary) -> float:
	return max(0.0, 1.0 + observation.player_state.effective_stats.luck / 100.0)
