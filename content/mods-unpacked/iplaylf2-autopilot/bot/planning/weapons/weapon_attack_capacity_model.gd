extends Reference

# Owns target-independent automatic-weapon capacity: expected attack cadence,
# damage per delivered hit, and primary-path hit, damage, and lifesteal rates.
# It does not own targeting intervals or action-conditioned spatial delivery.


func expected_damage_per_hit(attack_model: Dictionary) -> float:
	return attack_model.impact.damage * _critical_damage_multiplier(attack_model)


func expected_attack_count(
	attack_model: Dictionary, horizon_seconds: float, elapsed_seconds: float = 0.0
) -> float:
	var timing: Dictionary = attack_model.timing
	var interval_seconds: float = timing.expected_attack_interval_seconds
	var horizon := max(0.0, horizon_seconds)
	var seconds_until_ready := max(
		0.0, float(timing.seconds_until_next_attack) - max(0.0, elapsed_seconds)
	)
	if seconds_until_ready > horizon:
		return 0.0
	# The compiled current cooldown and visible animation phase fix the first
	# opportunity. Later random cooldowns remain an expectation at the long-run rate.
	return 1.0 + max(0.0, horizon - seconds_until_ready) / interval_seconds


func expected_primary_damage_rate(weapons: Array, is_moving: bool = false) -> float:
	var result := 0.0
	for observed_weapon in weapons:
		result += expected_primary_damage_rate_for_attack_model(
			observed_weapon.attack_model, is_moving
		)
	return result


func expected_primary_hit_rate(weapons: Array, is_moving: bool = false) -> float:
	var result := 0.0
	for observed_weapon in weapons:
		result += expected_primary_hit_rate_for_attack_model(
			observed_weapon.attack_model, is_moving
		)
	return result


func expected_primary_damage_rate_for_attack_model(
	attack_model: Dictionary, is_moving: bool = false
) -> float:
	return (
		expected_damage_per_hit(attack_model)
		* expected_primary_hit_rate_for_attack_model(attack_model, is_moving)
	)


func expected_primary_hit_rate_for_attack_model(
	attack_model: Dictionary, is_moving: bool = false
) -> float:
	if is_moving and not attack_model.timing.permitted_while_moving:
		return 0.0
	return (
		_expected_primary_hits_per_attack(attack_model)
		/ attack_model.timing.expected_attack_interval_seconds
	)


func expected_primary_lifesteal_rate(weapons: Array, is_moving: bool = false) -> float:
	var result := 0.0
	for observed_weapon in weapons:
		var attack_model: Dictionary = observed_weapon.attack_model
		if is_moving and not attack_model.timing.permitted_while_moving:
			continue
		result += (
			_expected_primary_hits_per_attack(attack_model)
			* clamp(attack_model.impact.lifesteal, 0.0, 1.0)
			/ attack_model.timing.expected_attack_interval_seconds
		)
	return result


func _critical_damage_multiplier(attack_model: Dictionary) -> float:
	var chance: float = clamp(attack_model.impact.critical_chance, 0.0, 1.0)
	return 1.0 + chance * max(0.0, attack_model.impact.critical_damage_multiplier - 1.0)


func _expected_primary_hits_per_attack(attack_model: Dictionary) -> float:
	return (
		float(attack_model.delivery.paths.count)
		* float(attack_model.delivery.paths.primary_probability_floor)
	)
