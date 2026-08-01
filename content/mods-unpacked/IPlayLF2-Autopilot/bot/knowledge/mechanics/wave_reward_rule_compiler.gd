extends Reference


func compile(effects: Dictionary) -> Array:
	var rules := []
	var held_material_percent: float = effects[Keys.gain_pct_gold_start_wave_hash]
	if held_material_percent != 0.0:
		_append_scalar_rule(
			rules, "wave_start", "materials", "add_percent_of_current", held_material_percent
		)

	var living_enemy_percent: float = effects[Keys.pacifist_hash]
	if living_enemy_percent != 0.0:
		_append_scalar_rule(
			rules,
			"wave_end",
			"materials_and_experience_per_living_enemy",
			"add_percent_of_enemy_material_value",
			living_enemy_percent
		)

	var materials_per_enemy: float = effects[Keys.materials_per_living_enemy_hash]
	if materials_per_enemy != 0.0:
		_append_scalar_rule(
			rules,
			"wave_end",
			"materials_and_experience_per_living_enemy",
			"add",
			materials_per_enemy
		)

	var materials_per_tree: float = effects[Keys.cryptid_hash]
	if materials_per_tree != 0.0:
		_append_scalar_rule(
			rules, "wave_end", "materials_and_experience_per_living_tree", "add", materials_per_tree
		)
	return rules


func _append_scalar_rule(
	rules: Array, event: String, target: String, operation: String, value: float
) -> void:
	rules.push_back(
		{
			"event": event,
			"condition": {},
			"consequences":
			[
				{
					"target": target,
					"operation": operation,
					"value": value,
				}
			],
		}
	)
