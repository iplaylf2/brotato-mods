extends Reference

# Combines versioned enemy mechanics with battle-local observed evidence. Stable
# content identity stays inside the compiler cache and never enters this profile.

const STATIONARY_SPEED := 5.0
const FAST_CLOSING_SPEED := 90.0


func accumulate_evidence(previous: Dictionary, measurement: Dictionary) -> Dictionary:
	if previous.empty():
		return {
			"peak_observed_speed": measurement.observed_speed,
			"peak_closing_speed": measurement.closing_speed,
			"stable_mechanic_profile": measurement.stable_mechanic_profile.duplicate(true),
			"ranged_attack_inferred": measurement.ranged_attack_inferred,
			"loot_reward_known": measurement.loot_reward_known,
			"enemy_production_known": measurement.enemy_production_known,
		}
	return {
		"peak_observed_speed": max(previous.peak_observed_speed, measurement.observed_speed),
		"peak_closing_speed": max(previous.peak_closing_speed, measurement.closing_speed),
		"stable_mechanic_profile": measurement.stable_mechanic_profile.duplicate(true),
		"ranged_attack_inferred":
		previous.ranged_attack_inferred or measurement.ranged_attack_inferred,
		"loot_reward_known": previous.loot_reward_known or measurement.loot_reward_known,
		"enemy_production_known":
		previous.enemy_production_known or measurement.enemy_production_known,
	}


func build_profile(evidence: Dictionary) -> Dictionary:
	var attack_behavior: Dictionary = evidence.stable_mechanic_profile.attack_behavior.duplicate(
		true
	)
	if attack_behavior.kind == "unconfirmed" and evidence.ranged_attack_inferred:
		attack_behavior = {
			"kind": "ranged_projectile_inferred",
			"confidence": 0.9,
			"knowledge_source": "observed_emission",
			"creates_projectile_pressure": true,
			"maximum_range": 650.0,
			"pressure_intensity": 1.0,
			"delivery_modes": ["observed_projectile"],
		}
	var is_ranged_source: bool = attack_behavior.get("creates_projectile_pressure", false)
	return {
		"attack_behavior": attack_behavior,
		"durability": evidence.stable_mechanic_profile.durability.duplicate(true),
		"movement_behavior": _classify_movement(evidence),
		"strategic_roles":
		{
			"loot_reward_target": evidence.loot_reward_known,
			"enemy_producer": evidence.enemy_production_known,
			"ranged_pressure_source": is_ranged_source,
		},
	}


func _classify_movement(evidence: Dictionary) -> Dictionary:
	if evidence.peak_observed_speed < STATIONARY_SPEED:
		return {"kind": "stationary_observed", "confidence": 0.9}
	if evidence.peak_closing_speed >= FAST_CLOSING_SPEED:
		return {"kind": "fast_closing_observed", "confidence": 0.75}
	return {"kind": "mobile_observed", "confidence": 0.55}
