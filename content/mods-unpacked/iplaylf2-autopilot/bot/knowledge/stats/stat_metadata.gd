extends Reference

# Defines normalized stat names and target-version tier-one upgrade increments.
# Raw stat deltas remain available to mechanic projectors; upgrade equivalence is
# attached at the version-knowledge boundary for material-equivalent valuation.

const TIER_ONE_UPGRADE_INCREMENTS := {
	"max_health": 3.0,
	"health_regeneration": 2.0,
	"lifesteal": 1.0,
	"percent_damage": 5.0,
	"melee_damage": 2.0,
	"ranged_damage": 1.0,
	"elemental_damage": 1.0,
	"attack_speed": 5.0,
	"critical_chance": 3.0,
	"engineering": 2.0,
	"range": 15.0,
	"armor": 1.0,
	"dodge": 3.0,
	"speed": 3.0,
	"luck": 5.0,
	"harvesting": 5.0,
}


func get_stat_name(stat_hash: int) -> String:
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


func upgrade_equivalent_value(stat_name: String, delta: float) -> float:
	var baseline_increment: float = TIER_ONE_UPGRADE_INCREMENTS.get(stat_name, 0.0)
	if baseline_increment <= 0.0:
		return 0.0
	return delta / baseline_increment
