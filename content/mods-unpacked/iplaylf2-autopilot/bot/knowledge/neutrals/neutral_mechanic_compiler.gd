extends Reference

# Compiles a visible neutral's stable completion mechanics and reward inputs.
# Planning owns the state-dependent valuation of these raw mechanics.


func compile(neutral: Node) -> Dictionary:
	var result := {
		"destruction":
		{
			"hit_limit": 1.0,
			"maximum_health": max(1.0, float(neutral.max_stats.health)),
		},
		"kill_rewards":
		{
			"base_materials": 0.0,
			"base_consumable_drop_chance": 0.0,
			"item_box_conditional_chance": 0.0,
			"guaranteed_consumable": false,
		},
	}
	if "number_of_hits_before_dying" in neutral:
		result.destruction.hit_limit = max(1.0, float(neutral.number_of_hits_before_dying))
	if not "stats" in neutral or neutral.stats == null:
		return result
	var stats: Resource = neutral.stats
	result.kill_rewards.base_materials = max(0.0, float(stats.value))
	result.kill_rewards.base_consumable_drop_chance = clamp(float(stats.base_drop_chance), 0.0, 1.0)
	result.kill_rewards.item_box_conditional_chance = clamp(float(stats.item_drop_chance), 0.0, 1.0)
	result.kill_rewards.guaranteed_consumable = bool(stats.always_drop_consumables)
	return result
