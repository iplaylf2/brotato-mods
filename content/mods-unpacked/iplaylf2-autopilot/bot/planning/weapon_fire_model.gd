extends Reference

# Owns target-independent automatic-weapon firing mechanics: attack cadence,
# long-cycle timing and expected damage of one delivered hit. Target geometry
# and multi-target delivery remain in WeaponAttackPredictor.


func scheduled_attack_times(
	weapon: Dictionary, arrival_seconds: float, horizon_seconds: float, cooldown_reset_times := []
) -> Array:
	var result := []
	var attack_time: float = weapon.timing.cooldown_remaining_seconds
	var end_time := arrival_seconds + horizon_seconds
	var cycle_seconds: float = max(0.05, weapon.timing.cycle_seconds)
	var attacks_until_reload: int = weapon.timing.attacks_until_long_cycle
	var reload_every: int = weapon.timing.long_cycle_every_attacks
	var reload_cycle_seconds: float = max(cycle_seconds, weapon.timing.long_cycle_seconds)
	var reset_index := 0
	while attack_time <= end_time:
		while (
			reset_index < cooldown_reset_times.size()
			and cooldown_reset_times[reset_index] <= attack_time
		):
			attack_time = float(cooldown_reset_times[reset_index])
			reset_index += 1
		if attack_time >= arrival_seconds:
			result.push_back(attack_time)
		var next_cycle := cycle_seconds
		if attacks_until_reload > 0:
			attacks_until_reload -= 1
			if attacks_until_reload == 0:
				next_cycle = reload_cycle_seconds
				attacks_until_reload = reload_every
		attack_time += next_cycle
	return result


func expected_damage_per_hit(weapon: Dictionary) -> float:
	return weapon.impact.damage * _critical_damage_multiplier(weapon)


func rule_delta(rules: Array, event: String, target: String) -> float:
	var result := 0.0
	for rule in rules:
		if rule.event != event or not rule.condition.empty():
			continue
		for consequence in rule.consequences:
			if consequence.target == target and consequence.operation == "add":
				result += consequence.get("value", 0.0)
	return result


func _critical_damage_multiplier(weapon: Dictionary) -> float:
	var chance: float = clamp(weapon.impact.critical_chance, 0.0, 1.0)
	return 1.0 + chance * max(0.0, weapon.impact.critical_damage_multiplier - 1.0)
