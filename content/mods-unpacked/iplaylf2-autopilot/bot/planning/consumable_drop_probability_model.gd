extends Reference

# Projects stable drop inputs into current consumable and item-box probabilities.
# Knowledge modules own the target-version fields; this model uniquely owns their
# state-dependent composition with current luck.


func any_consumable_drop_chance(observation: Dictionary, rewards: Dictionary) -> float:
	if rewards.get("guaranteed_consumable", false):
		return 1.0
	return clamp(
		rewards.get("base_consumable_drop_chance", 0.0) * _luck_multiplier(observation), 0.0, 1.0
	)


func item_box_drop_chance(observation: Dictionary, rewards: Dictionary) -> float:
	var conditional_chance: float = clamp(
		rewards.get("item_box_conditional_chance", 0.0) * _luck_multiplier(observation), 0.0, 1.0
	)
	return any_consumable_drop_chance(observation, rewards) * conditional_chance


func _luck_multiplier(observation: Dictionary) -> float:
	return max(0.0, 1.0 + observation.player_state.effective_stats.luck / 100.0)
