extends Reference

# Owns target-independent automatic-weapon capacity: expected attack cadence,
# damage per delivered hit, and primary-path hit, damage, and lifesteal rates.
# Spatial delivery belongs to WeaponOutcomeFieldModel.


func expected_damage_per_hit(attack_model: Dictionary) -> float:
	return attack_model.impact.damage * _critical_damage_multiplier(attack_model)


func expected_primary_damage_rate(weapons: Array, is_moving: bool = false) -> float:
	var result := 0.0
	for observed_weapon in weapons:
		var attack_model: Dictionary = observed_weapon.attack_model
		if is_moving and not attack_model.timing.permitted_while_moving:
			continue
		result += (
			expected_damage_per_hit(attack_model)
			* _expected_primary_hits_per_attack(attack_model)
			/ max(0.05, attack_model.timing.expected_attack_interval_seconds)
		)
	return result


func expected_primary_hit_rate(weapons: Array, is_moving: bool = false) -> float:
	var result := 0.0
	for observed_weapon in weapons:
		var attack_model: Dictionary = observed_weapon.attack_model
		if is_moving and not attack_model.timing.permitted_while_moving:
			continue
		result += (
			_expected_primary_hits_per_attack(attack_model)
			/ max(0.05, attack_model.timing.expected_attack_interval_seconds)
		)
	return result


func expected_primary_lifesteal_rate(weapons: Array, is_moving: bool = false) -> float:
	var result := 0.0
	for observed_weapon in weapons:
		var attack_model: Dictionary = observed_weapon.attack_model
		if is_moving and not attack_model.timing.permitted_while_moving:
			continue
		result += (
			_expected_primary_hits_per_attack(attack_model)
			* clamp(attack_model.impact.lifesteal, 0.0, 1.0)
			/ max(0.05, attack_model.timing.expected_attack_interval_seconds)
		)
	return result


func _critical_damage_multiplier(attack_model: Dictionary) -> float:
	var chance: float = clamp(attack_model.impact.critical_chance, 0.0, 1.0)
	return 1.0 + chance * max(0.0, attack_model.impact.critical_damage_multiplier - 1.0)


func _expected_primary_hits_per_attack(attack_model: Dictionary) -> float:
	return (
		max(1.0, float(attack_model.delivery.paths.count))
		* clamp(attack_model.delivery.paths.primary_probability_floor, 0.05, 1.0)
	)
