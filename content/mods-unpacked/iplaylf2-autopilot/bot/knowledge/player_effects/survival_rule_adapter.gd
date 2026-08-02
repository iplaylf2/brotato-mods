extends Reference

# Adapts health and incoming-attack events from the target player-effect schema.

const StatVocabulary := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/stat_vocabulary.gd"
)

var _stat_vocabulary: Reference = StatVocabulary.new()


func adapt(effects: Dictionary, player_index: int) -> Array:
	var rules := []
	_append_stat_damage_rules(rules, effects[Keys.dmg_when_heal_hash], "healing")
	_append_damage_explosion_rules(rules, effects[Keys.explode_on_hit_hash], player_index)
	_append_temporary_stat_rules(rules, effects[Keys.temp_stats_on_hit_hash], "damage_taken")
	_append_temporary_stat_rules(rules, effects[Keys.temp_stats_on_dodge_hash], "attack_dodged")
	_append_recovery_constraint(rules, effects)
	_append_fatal_damage_rule(rules, effects)
	_append_passive_health_loss_rule(rules, effects)
	return rules


func _append_stat_damage_rules(rules: Array, entries: Array, event: String) -> void:
	for entry in entries:
		if entry.size() < 3:
			continue
		var stat_name := _stat_vocabulary.get_name(entry[0])
		if stat_name.empty():
			continue
		rules.push_back(
			{
				"event": event,
				"condition": {},
				"consequences":
				[
					{
						"target": "random_enemy",
						"operation": "deal_scaled_damage",
						"scaling_stat": stat_name,
						"scaling_percent": entry[1],
						"chance_percent": entry[2],
						"outcome_channels": {"enemy_damage": 1.0},
					}
				],
			}
		)


func _append_damage_explosion_rules(rules: Array, effects: Array, player_index: int) -> void:
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
				"event": "damage_taken",
				"condition": {},
				"consequences":
				[
					{
						"target": "enemies_in_radius",
						"operation": "deal_area_damage",
						"damage": damage,
						"radius": radius,
						"chance_percent": effect.chance * 100.0,
						"center": "player",
						"outcome_channels": {"enemy_damage": 1.0},
					}
				],
			}
		)


func _append_temporary_stat_rules(rules: Array, entries: Array, event: String) -> void:
	for entry in entries:
		if entry.size() < 2:
			continue
		var stat_name := _stat_vocabulary.get_name(entry[0])
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
						"operation": "add_temporarily",
						"value": entry[1],
						"outcome_channels": {"player_growth": 0.6},
					}
				],
			}
		)


func _append_recovery_constraint(rules: Array, effects: Dictionary) -> void:
	if effects[Keys.no_heal_hash] > 0:
		rules.push_back(
			{
				"event": "healing",
				"condition": {},
				"consequences":
				[{"target": "health_recovery", "operation": "multiply", "value": 0.0}],
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
					"operation": "add_rate",
					"value": -health_loss_per_second,
				}
			],
		}
	)
