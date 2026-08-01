extends Reference

const StatVocabulary := preload(
	"res://mods-unpacked/IPlayLF2-Autopilot/bot/knowledge/stat_vocabulary.gd"
)

var _stat_vocabulary: Reference = StatVocabulary.new()


func compile(effects: Dictionary) -> Array:
	var rules := []
	_append_material_rules(rules, effects)
	_append_consumable_rules(rules, effects)
	return rules


func _append_material_rules(rules: Array, effects: Dictionary) -> void:
	var value_bonus: float = effects[Keys.increase_material_value_hash]
	if value_bonus != 0.0:
		rules.push_back(
			{
				"event": "material_pickup",
				"condition": {},
				"consequences":
				[
					{
						"target": "picked_material_value",
						"operation": "add_percent",
						"value": value_bonus,
					}
				],
			}
		)

	var double_chance: float = effects[Keys.chance_double_gold_hash]
	if double_chance != 0.0:
		rules.push_back(
			{
				"event": "material_pickup",
				"condition": {},
				"consequences":
				[
					{
						"target": "picked_material_value",
						"operation": "multiply",
						"value": 2,
						"chance_percent": double_chance,
					}
				],
			}
		)

	var heal_chance: float = effects[Keys.heal_when_pickup_gold_hash]
	if heal_chance != 0.0:
		rules.push_back(
			{
				"event": "material_pickup",
				"condition": {},
				"consequences":
				[
					{
						"target": "health",
						"operation": "heal",
						"value": 1,
						"chance_percent": heal_chance,
					}
				],
			}
		)

	if bool(effects[Keys.reload_when_pickup_gold_hash]):
		rules.push_back(
			{
				"event": "material_pickup",
				"condition": {},
				"consequences":
				[
					{
						"target": "all_automatic_weapon_cooldowns",
						"operation": "set",
						"value": 0,
					}
				],
			}
		)

	for stat_damage in effects[Keys.dmg_when_pickup_gold_hash]:
		if stat_damage.size() < 3:
			continue
		var stat_name := _stat_vocabulary.get_name(stat_damage[0])
		if stat_name.empty():
			continue
		rules.push_back(
			{
				"event": "material_pickup",
				"condition": {},
				"consequences":
				[
					{
						"target": "random_enemy",
						"operation": "deal_scaled_damage",
						"scaling_stat": stat_name,
						"scaling_percent": stat_damage[1],
						"chance_percent": stat_damage[2],
					}
				],
			}
		)


func _append_consumable_rules(rules: Array, effects: Dictionary) -> void:
	for entry in effects[Keys.consumable_stats_while_max_hash]:
		_append_consumable_stat_rule(rules, entry, "add_permanently")

	for entry in effects[Keys.temp_consumable_stats_while_max_hash]:
		_append_consumable_stat_rule(rules, entry, "add_temporarily")

	for entry in effects[Keys.decaying_stats_on_consumable_hash]:
		if entry.size() < 3:
			continue
		var stat_name := _stat_vocabulary.get_name(entry[0])
		if stat_name.empty():
			continue
		rules.push_back(
			{
				"event": "consumable_pickup",
				"condition": {},
				"consequences":
				[
					{
						"target": stat_name,
						"operation": "add_temporarily",
						"value": entry[1],
						"duration_seconds": entry[2],
					}
				],
			}
		)


func _append_consumable_stat_rule(rules: Array, entry: Array, operation: String) -> void:
	if entry.size() < 2:
		return
	var stat_name := _stat_vocabulary.get_name(entry[0])
	if stat_name.empty():
		return
	rules.push_back(
		{
			"event": "consumable_pickup",
			"condition": {"health_is_full": true},
			"consequences":
			[
				{
					"target": stat_name,
					"operation": operation,
					"value": entry[1],
					"per_wave_cap": entry[2] if entry.size() >= 3 else null,
				}
			],
		}
	)
