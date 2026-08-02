extends Reference

# Adapts pickup-event fields from the target player-effect schema.

const StatVocabulary := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/stat_vocabulary.gd"
)

var _stat_vocabulary: Reference = StatVocabulary.new()


func adapt(effects: Dictionary, player_index: int) -> Array:
	var rules := []
	_append_material_rules(rules, effects)
	_append_consumable_rules(rules, effects, player_index)
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
						"target": "health_recovery",
						"operation": "add",
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
						"outcome_channels": {"enemy_damage": 1.0},
					}
				],
			}
		)


func _append_consumable_rules(rules: Array, effects: Dictionary, player_index: int) -> void:
	_append_consumable_explosion_rules(
		rules, effects[Keys.explode_on_consumable_hash], player_index
	)
	_append_trait_stat_rules(rules, effects[Keys.stats_on_fruit_hash], "fruit")
	_append_consumable_recovery_rule(rules, effects[Keys.consumable_heal_hash])
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
						"outcome_channels": {"player_growth": 0.6},
					}
				],
			}
		)


func _append_consumable_explosion_rules(rules: Array, effects: Array, player_index: int) -> void:
	for effect in effects:
		if effect == null or effect.stats == null:
			continue
		var damage := (
			WeaponService.get_explosion_damage(effect.stats, player_index)
			+ effect.get_additional_scaling_damage(player_index)
		)
		var size_bonus := Utils.get_stat(Keys.explosion_size_hash, player_index) / 100.0
		var radius := max(1.0, effect.stats.max_range * effect.scale * max(0.1, 1.0 + size_bonus))
		rules.push_back(
			{
				"event": "consumable_pickup",
				"condition": {},
				"consequences":
				[
					{
						"target": "enemies_in_radius",
						"operation": "deal_area_damage",
						"damage": damage,
						"radius": radius,
						"chance_percent": effect.chance * 100.0,
						"center": "pickup",
						"outcome_channels": {"enemy_damage": 1.0},
					}
				],
			}
		)


func _append_trait_stat_rules(rules: Array, entries: Array, trait: String) -> void:
	for entry in entries:
		if entry.size() < 3:
			continue
		var stat_name := _stat_vocabulary.get_name(entry[0])
		if stat_name.empty():
			continue
		rules.push_back(
			{
				"event": "consumable_pickup",
				"condition": {"entity_has_trait": trait},
				"consequences":
				[
					{
						"target": stat_name,
						"operation": "add_permanently",
						"value": entry[1],
						"chance_percent": entry[2],
						"outcome_channels": {"player_growth": 1.0},
					}
				],
			}
		)


func _append_consumable_recovery_rule(rules: Array, recovery_offset: float) -> void:
	if recovery_offset == 0.0:
		return
	rules.push_back(
		{
			"event": "consumable_pickup",
			"condition": {},
			"consequences":
			[{"target": "health_recovery", "operation": "add", "value": recovery_offset}],
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
					"outcome_channels": {"player_growth": 1.0},
				}
			],
		}
	)
