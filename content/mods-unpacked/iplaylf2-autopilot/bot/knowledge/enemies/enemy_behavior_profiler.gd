extends Reference

# Combines versioned enemy mechanics with battle-local observed evidence. Stable
# content identity stays inside the compiler cache and never enters this profile.


func accumulate_evidence(previous: Dictionary, measurement: Dictionary) -> Dictionary:
	if previous.empty():
		return {
			"stable_mechanic_profile": measurement.stable_mechanic_profile.duplicate(true),
			"ranged_attack_inferred": measurement.ranged_attack_inferred,
			"next_volley_window": measurement.next_volley_window.duplicate(true),
		}
	return {
		"stable_mechanic_profile": measurement.stable_mechanic_profile.duplicate(true),
		"ranged_attack_inferred":
		previous.ranged_attack_inferred or measurement.ranged_attack_inferred,
		"next_volley_window": measurement.next_volley_window.duplicate(true),
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
	return {
		"attack_behavior": attack_behavior,
		"next_volley_window": evidence.next_volley_window.duplicate(true),
		"durability": evidence.stable_mechanic_profile.durability.duplicate(true),
		"contact_damage": evidence.stable_mechanic_profile.contact_damage,
		"kill_rewards": evidence.stable_mechanic_profile.kill_rewards.duplicate(true),
		"battlefield_effects": evidence.stable_mechanic_profile.battlefield_effects.duplicate(true),
	}
