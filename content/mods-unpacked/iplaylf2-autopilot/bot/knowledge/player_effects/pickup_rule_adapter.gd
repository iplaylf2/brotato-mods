extends Reference

# Adapts pickup-event fields from the target player-effect schema.

const StatMetadata := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/stats/stat_metadata.gd"
)

var _stat_metadata: Reference = StatMetadata.new()


func adapt(effects: Dictionary, player_index: int) -> Array:
	var rules := []
	_append_material_rules(rules, effects, player_index)
	_append_consumable_rules(rules, effects, player_index)
	return rules


func _append_material_rules(rules: Array, effects: Dictionary, player_index: int) -> void:
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
						"operation": "multiply",
						"value": 1.0 + value_bonus / 100.0,
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
						"probability": double_chance / 100.0,
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
						"probability": heal_chance / 100.0,
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
		var damage := _stat_damage_value(stat_damage, player_index)
		rules.push_back(
			{
				"event": "material_pickup",
				"condition": {},
				"consequences":
				[
					{
						"target": "enemy_health",
						"operation": "deal_damage",
						"amount": _damage_amount(damage),
						"delivery": _enemy_delivery(false, INF, 1.0),
						"probability": stat_damage[2] / 100.0,
					}
				],
			}
		)


func _append_consumable_rules(rules: Array, effects: Dictionary, player_index: int) -> void:
	_append_explosion_event_rule(rules, effects[Keys.explode_on_consumable_hash], player_index)
	_append_explosion_event_rule(
		rules, effects[Keys.explode_on_consumable_burning_hash], player_index
	)
	_append_trait_stat_rules(rules, effects[Keys.stats_on_fruit_hash], "fruit")
	_append_consumable_recovery_rule(rules, effects[Keys.consumable_heal_hash])
	for entry in effects[Keys.consumable_stats_while_max_hash]:
		_append_consumable_stat_rule(rules, entry, INF)

	for entry in effects[Keys.temp_consumable_stats_while_max_hash]:
		_append_consumable_stat_rule(rules, entry, 0.0)

	for entry in effects[Keys.decaying_stats_on_consumable_hash]:
		if entry.size() < 3:
			continue
		var stat_name: String = _stat_metadata.get_stat_name(entry[0])
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
						"operation": "add",
						"value": entry[1],
						"duration_seconds": entry[2],
					}
				],
			}
		)


func _append_explosion_event_rule(rules: Array, effects: Array, player_index: int) -> void:
	var valid_effects := []
	for effect in effects:
		if effect != null and effect.stats != null:
			valid_effects.push_back(effect)
	if valid_effects.empty():
		return
	# Vanilla performs one chance roll from the sum, then one explosion whose
	# damage sums every effect and whose scene geometry comes from the first effect.
	# Independent rules would understate stacked damage and invent partial outcomes.
	var probability := 0.0
	var damage := 0.0
	for effect in valid_effects:
		probability += effect.chance
		damage += (
			WeaponService.get_explosion_damage(effect.stats, player_index)
			+ effect.get_additional_scaling_damage(player_index)
		)
	var first_effect: Resource = valid_effects[0]
	var size_bonus: float = Utils.get_stat(Keys.explosion_size_hash, player_index) / 100.0
	var radius: float = max(
		1.0, first_effect.stats.max_range * first_effect.scale * max(0.1, 1.0 + size_bonus)
	)
	var consequences := []
	if damage > 0.0:
		consequences.push_back(
			{
				"target": "enemy_health",
				"operation": "deal_damage",
				"amount": _damage_amount(damage),
				"delivery": _enemy_delivery(true, radius, INF),
				"probability": clamp(probability, 0.0, 1.0),
			}
		)
	var burning: Resource = first_effect.burning_data if "burning_data" in first_effect else null
	if burning != null and not burning.is_not_burning():
		var scaled_burning: Resource = WeaponService.init_burning_data(burning, player_index)
		consequences.push_back(
			{
				"target": "enemy_status",
				"operation": "apply",
				"status": "burning",
				"duration_seconds": max(0.0, float(scaled_burning.duration)),
				"damage_over_time":
				_damage_amount(max(0.0, float(scaled_burning.damage * scaled_burning.duration))),
				"delivery": _enemy_delivery(true, radius, INF),
				"probability":
				clamp(probability, 0.0, 1.0) * clamp(scaled_burning.chance, 0.0, 1.0),
			}
		)
	if consequences.empty():
		return
	rules.push_back(
		{
			"event": "consumable_pickup",
			"condition": {},
			"consequences": consequences,
		}
	)


func _append_trait_stat_rules(rules: Array, entries: Array, trait: String) -> void:
	for entry in entries:
		if entry.size() < 3:
			continue
		var stat_name: String = _stat_metadata.get_stat_name(entry[0])
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
						"operation": "add",
						"value": entry[1],
						"duration_seconds": INF,
						"probability": entry[2] / 100.0,
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


func _stat_damage_value(entry: Array, player_index: int) -> float:
	var base_damage: float = floor(
		max(1.0, entry[1] / 100.0 * Utils.get_stat(entry[0], player_index))
	)
	var percent_damage: float = (
		1.0
		+ Utils.get_stat(Keys.stat_percent_damage_hash, player_index) / 100.0
	)
	return round(base_damage * percent_damage)


func _damage_amount(constant: float) -> Dictionary:
	return {
		"constant": constant,
		"impact_coefficient": 0.0,
		"target_maximum_health_coefficient": 0.0,
		"minimum": 0.0,
	}


func _enemy_delivery(anchor_on_event_entity: bool, radius: float, capacity: float) -> Dictionary:
	return {
		"reuse_event_targets": false,
		"exclude_event_targets": false,
		"anchor_on_event_entity": anchor_on_event_entity,
		"radius": radius,
		"capacity_per_event": capacity,
	}


func _append_consumable_stat_rule(rules: Array, entry: Array, duration_seconds: float) -> void:
	if entry.size() < 2:
		return
	var stat_name: String = _stat_metadata.get_stat_name(entry[0])
	if stat_name.empty():
		return
	var consequence := {
		"target": stat_name,
		"operation": "add",
		"value": entry[1],
		"per_wave_cap": entry[2] if entry.size() >= 3 else null,
	}
	if duration_seconds > 0.0:
		consequence.duration_seconds = duration_seconds
	rules.push_back(
		{
			"event": "consumable_pickup",
			"condition": {"health_is_full": true},
			"consequences": [consequence],
		}
	)
