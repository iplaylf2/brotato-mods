extends Reference

# Adapts rewards caused by combat outcomes. Current target state and completion
# evidence remain in observation and planning; this adapter only translates the
# player's stable on-kill rules.


func adapt(effects: Dictionary) -> Array:
	var rules := []
	for entry in effects[Keys.gold_on_crit_kill_hash]:
		if entry.size() < 2:
			continue
		rules.push_back(
			{
				"event": "critical_kill",
				"condition": {},
				"consequences":
				[
					{
						"target": "materials",
						"operation": "add",
						"value": 1,
						"probability": entry[1] / 100.0,
					}
				],
			}
		)

	var critical_heal_chance: float = effects[Keys.heal_on_crit_kill_hash]
	if critical_heal_chance > 0.0:
		rules.push_back(
			{
				"event": "critical_kill",
				"condition": {},
				"consequences":
				[
					{
						"target": "health_recovery",
						"operation": "add",
						"value": 1,
						"probability": critical_heal_chance / 100.0,
					}
				],
			}
		)
	return rules
