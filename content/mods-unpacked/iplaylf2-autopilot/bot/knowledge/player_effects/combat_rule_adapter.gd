extends Reference

# Adapts stable player-effect fields that modify combat outcomes or rewards.
# Current target state and completion evidence remain in observation and planning.


func adapt(effects: Dictionary) -> Array:
	var rules := []
	_append_enemy_material_distance_rules(rules, effects[Keys.scale_materials_with_distance_hash])
	var bonus_key: int = Keys.bonus_non_elemental_damage_against_burning_targets_hash
	var burning_target_bonus: float = effects[bonus_key]
	if burning_target_bonus != 0.0:
		rules.push_back(
			{
				"event": "damage_dealt",
				"condition":
				{
					"target_has_status": "burning",
					"damage_kind_is_not": "damage_over_time",
				},
				"consequences":
				[
					{
						"target": "dealt_damage",
						"operation": "multiply",
						"value": 1.0 + burning_target_bonus / 100.0,
					}
				],
			}
		)
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


func _append_enemy_material_distance_rules(rules: Array, scaling_effects: Array) -> void:
	for effect in scaling_effects:
		if effect == null or effect.max_range <= 0:
			continue
		rules.push_back(
			{
				"event": "enemy_death",
				"condition": {"killed_by_player": true},
				"consequences":
				[
					{
						"target": "enemy_material_reward",
						"operation": "multiply_by_distance_curve",
						"curve":
						{
							"kind": "clamped_linear_percentage",
							"minimum_percentage": float(effect.min_value),
							"maximum_percentage": float(effect.value),
							"range": float(effect.max_range),
							"buffer": float(effect.buffer),
							"inverted": bool(effect.invert_scaling),
						},
					}
				],
			}
		)
