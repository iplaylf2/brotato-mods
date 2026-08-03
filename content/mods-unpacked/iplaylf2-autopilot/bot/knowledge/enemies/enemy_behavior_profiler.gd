extends Reference

# Combines versioned enemy mechanics with battle-local observed evidence. Stable
# content identity stays inside the compiler cache and never enters this profile.


func accumulate_evidence(previous: Dictionary, measurement: Dictionary) -> Dictionary:
	if previous.empty():
		return {
			"stable_mechanic_profile": measurement.stable_mechanic_profile.duplicate(true),
			"ranged_attack_inferred": measurement.ranged_attack_inferred,
			"visible_removable_projectile_damage": measurement.visible_removable_projectile_damage,
			"next_volley_window": measurement.next_volley_window.duplicate(true),
			"next_charge_attack_window": measurement.next_charge_attack_window.duplicate(true),
		}
	return {
		"stable_mechanic_profile": measurement.stable_mechanic_profile.duplicate(true),
		"ranged_attack_inferred":
		previous.ranged_attack_inferred or measurement.ranged_attack_inferred,
		"visible_removable_projectile_damage": measurement.visible_removable_projectile_damage,
		"next_volley_window": measurement.next_volley_window.duplicate(true),
		"next_charge_attack_window": measurement.next_charge_attack_window.duplicate(true),
	}


func build_profile(evidence: Dictionary) -> Dictionary:
	var projectile_attack: Dictionary = evidence.stable_mechanic_profile.projectile_attack.duplicate(
		true
	)
	if projectile_attack.kind == "unconfirmed" and evidence.ranged_attack_inferred:
		projectile_attack = {
			"kind": "ranged_projectile_inferred",
			"confidence": 0.9,
			"knowledge_source": "observed_emission",
			"creates_projectile_pressure": true,
			"maximum_range": 650.0,
			"pressure_intensity": 1.0,
			"delivery_modes": ["observed_projectile"],
		}
	return {
		"projectile_attack": projectile_attack,
		"charge_attack": evidence.stable_mechanic_profile.charge_attack.duplicate(true),
		"material_assimilation":
		evidence.stable_mechanic_profile.material_assimilation.duplicate(true),
		"target_position_response":
		evidence.stable_mechanic_profile.target_position_response.duplicate(true),
		"next_volley_window": evidence.next_volley_window.duplicate(true),
		"next_charge_attack_window": evidence.next_charge_attack_window.duplicate(true),
		"durability": evidence.stable_mechanic_profile.durability.duplicate(true),
		"contact_damage": evidence.stable_mechanic_profile.contact_damage,
		"contact_radius": evidence.stable_mechanic_profile.contact_radius,
		"kill_rewards": evidence.stable_mechanic_profile.kill_rewards.duplicate(true),
		"battlefield_effects": evidence.stable_mechanic_profile.battlefield_effects.duplicate(true),
		"removal_effects":
		{"visible_projectile_damage": evidence.visible_removable_projectile_damage},
	}
