extends Reference

# Defines stat names shared by mechanic rules and player-owned weapon observations.


func get_name(stat_hash: int) -> String:
	var names := {
		Keys.stat_max_hp_hash: "max_health",
		Keys.stat_damage_hash: "percent_damage",
		Keys.stat_armor_hash: "armor",
		Keys.stat_crit_chance_hash: "critical_chance",
		Keys.stat_luck_hash: "luck",
		Keys.stat_attack_speed_hash: "attack_speed",
		Keys.stat_elemental_damage_hash: "elemental_damage",
		Keys.stat_hp_regeneration_hash: "health_regeneration",
		Keys.stat_lifesteal_hash: "lifesteal",
		Keys.stat_melee_damage_hash: "melee_damage",
		Keys.stat_dodge_hash: "dodge",
		Keys.stat_engineering_hash: "engineering",
		Keys.stat_range_hash: "range",
		Keys.stat_ranged_damage_hash: "ranged_damage",
		Keys.stat_speed_hash: "speed",
		Keys.stat_harvesting_hash: "harvesting",
		Keys.stat_curse_hash: "curse",
	}
	return names.get(stat_hash, "")
