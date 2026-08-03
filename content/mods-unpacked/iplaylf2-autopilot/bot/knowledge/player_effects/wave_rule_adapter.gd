extends Reference

# Adapts wave-boundary fields from the target player-effect schema.


func adapt(effects: Dictionary) -> Array:
	var rules := []
	var held_material_percent: float = effects[Keys.gain_pct_gold_start_wave_hash]
	if held_material_percent != 0.0:
		_append_scalar_rule(rules, "wave_start", "materials", 0.0, held_material_percent / 100.0)

	var living_enemy_percent: float = effects[Keys.pacifist_hash]
	if living_enemy_percent != 0.0:
		_append_scalar_rule(
			rules,
			"wave_end",
			"materials_and_experience_per_living_enemy",
			0.0,
			0.0,
			living_enemy_percent / 100.0
		)

	var materials_per_enemy: float = effects[Keys.materials_per_living_enemy_hash]
	if materials_per_enemy != 0.0:
		_append_scalar_rule(
			rules, "wave_end", "materials_and_experience_per_living_enemy", materials_per_enemy
		)

	var materials_per_tree: float = effects[Keys.cryptid_hash]
	if materials_per_tree != 0.0:
		_append_scalar_rule(
			rules, "wave_end", "materials_and_experience_per_living_tree", materials_per_tree
		)
	return rules


func _append_scalar_rule(
	rules: Array,
	event: String,
	target: String,
	value: float,
	target_coefficient := 0.0,
	event_value_coefficient := 0.0
) -> void:
	rules.push_back(
		{
			"event": event,
			"condition": {},
			"consequences":
			[
				{
					"target": target,
					"operation": "add",
					"value": value,
					"target_coefficient": target_coefficient,
					"event_value_coefficient": event_value_coefficient,
				}
			],
		}
	)
