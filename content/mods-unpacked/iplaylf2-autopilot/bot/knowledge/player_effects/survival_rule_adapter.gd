extends Reference

# Adapts health and incoming-attack events from the target player-effect schema.

const StatMetadata := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/stats/stat_metadata.gd"
)

var _stat_metadata: Reference = StatMetadata.new()


func adapt(effects: Dictionary, player_index: int) -> Array:
	var rules := []
	_append_stat_damage_rules(rules, effects[Keys.dmg_when_heal_hash], "healing", player_index)
	_append_damage_explosion_rules(rules, effects[Keys.explode_on_hit_hash], player_index)
	_append_temporary_stat_rules(rules, effects[Keys.temp_stats_on_hit_hash], "damage_taken")
	_append_temporary_stat_rules(rules, effects[Keys.temp_stats_on_dodge_hash], "attack_dodged")
	_append_stat_damage_rules(rules, effects[Keys.dmg_on_dodge_hash], "attack_dodged", player_index)
	_append_dodge_healing_rules(rules, effects[Keys.heal_on_dodge_hash])
	_append_recovery_constraint(rules, effects)
	_append_fatal_damage_rule(rules, effects)
	_append_passive_health_loss_rule(rules, effects)
	return rules


func _append_dodge_healing_rules(rules: Array, entries: Array) -> void:
	for entry in entries:
		if entry.size() < 3:
			continue
		rules.push_back(
			{
				"event": "attack_dodged",
				"condition": {},
				"consequences":
				[
					{
						"target": "health_recovery",
						"operation": "add",
						"value": entry[1],
						"probability": entry[2] / 100.0,
					}
				],
			}
		)


func _append_stat_damage_rules(
	rules: Array, entries: Array, event: String, player_index: int
) -> void:
	for entry in entries:
		if entry.size() < 3:
			continue
		var damage := _stat_damage_value(entry, player_index)
		rules.push_back(
			{
				"event": event,
				"condition": {},
				"consequences":
				[
					{
						"target": "enemy_health",
						"operation": "deal_damage",
						"amount": _damage_amount(damage),
						"delivery": _enemy_delivery(INF, 1.0),
						"probability": entry[2] / 100.0,
					}
				],
			}
		)


func _append_damage_explosion_rules(rules: Array, effects: Array, player_index: int) -> void:
	for effect in effects:
		if effect == null or effect.stats == null:
			continue
		var damage: float = (
			WeaponService.get_explosion_damage(effect.stats, player_index)
			+ effect.get_additional_scaling_damage(player_index)
		)
		var size_bonus: float = Utils.get_stat(Keys.explosion_size_hash, player_index) / 100.0
		var radius: float = max(
			1.0, effect.stats.max_range * effect.scale * max(0.1, 1.0 + size_bonus)
		)
		rules.push_back(
			{
				"event": "damage_taken",
				"condition": {},
				"consequences":
				[
					{
						"target": "enemy_health",
						"operation": "deal_damage",
						"amount": _damage_amount(damage),
						"delivery": _enemy_delivery(radius, INF),
						"probability": effect.chance,
					}
				],
			}
		)


func _append_temporary_stat_rules(rules: Array, entries: Array, event: String) -> void:
	for entry in entries:
		if entry.size() < 2:
			continue
		var stat_name: String = _stat_metadata.get_stat_name(entry[0])
		if stat_name.empty():
			continue
		rules.push_back(
			{
				"event": event,
				"condition": {},
				"consequences":
				[
					{
						"target": stat_name,
						"operation": "add",
						"value": entry[1],
					}
				],
			}
		)


func _append_recovery_constraint(rules: Array, effects: Dictionary) -> void:
	var torture_recovery: float = effects[Keys.torture_hash]
	if effects[Keys.no_heal_hash] > 0 or torture_recovery > 0.0:
		rules.push_back(
			{
				"event": "healing",
				"condition": {},
				"consequences":
				[{"target": "health_recovery", "operation": "multiply", "value": 0.0}],
			}
		)
	if torture_recovery > 0.0:
		rules.push_back(
			{
				"event": "time_elapsed",
				"condition": {},
				"consequences":
				[
					{
						"target": "health_recovery",
						"operation": "add",
						"rate_per_second": torture_recovery,
					}
				],
			}
		)


func _append_fatal_damage_rule(rules: Array, effects: Dictionary) -> void:
	if effects[Keys.die_in_one_hit_hash] <= 0:
		return
	rules.push_back(
		{
			"event": "damage_taken",
			"condition": {"value_is_positive": true},
			"consequences": [{"target": "health", "operation": "set", "value": 0}],
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


func _enemy_delivery(radius: float, capacity: float) -> Dictionary:
	return {
		"reuse_event_targets": false,
		"exclude_event_targets": false,
		"anchor_on_event_entity": false,
		"radius": radius,
		"capacity_per_event": capacity,
	}


func _append_passive_health_loss_rule(rules: Array, effects: Dictionary) -> void:
	var health_loss_per_second: float = effects[Keys.lose_hp_per_second_hash]
	if health_loss_per_second <= 0.0:
		return
	rules.push_back(
		{
			"event": "time_elapsed",
			"condition": {},
			"consequences":
			[
				{
					"target": "health",
					"operation": "add",
					"rate_per_second": -health_loss_per_second,
				}
			],
		}
	)
