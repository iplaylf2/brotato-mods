extends Reference

# Projects movement-conditioned player rules from the observed active state to
# a candidate movement state. It never mutates the player or observed weapons.


func project_weapon(weapon: Dictionary, observation: Dictionary, is_moving: bool) -> Dictionary:
	var projected: Dictionary = weapon.duplicate(true)
	var stat_deltas := _movement_stat_deltas(observation.player_state.effect_rules, is_moving)
	var effective_stats: Dictionary = observation.player_state.effective_stats
	var percent_damage_delta: float = stat_deltas.get("percent_damage", 0.0)
	var current_percent_damage: float = effective_stats.percent_damage
	var current_damage_multiplier := max(0.01, 1.0 + current_percent_damage / 100.0)
	var projected_damage_multiplier := max(
		0.01, 1.0 + (current_percent_damage + percent_damage_delta) / 100.0
	)

	var direct_damage_delta := 0.0
	for scaling in projected.scaling:
		direct_damage_delta += (
			stat_deltas.get(scaling.stat, 0.0)
			* scaling.coefficient
			* projected_damage_multiplier
		)
	projected.damage = max(
		1.0,
		(
			projected.damage * projected_damage_multiplier / current_damage_multiplier
			+ direct_damage_delta
		)
	)

	var attack_speed_delta: float = stat_deltas.get("attack_speed", 0.0)
	var current_attack_speed: float = effective_stats.attack_speed
	projected.nominal_attack_cycle_seconds = max(
		0.05,
		(
			projected.nominal_attack_cycle_seconds
			* _attack_speed_cooldown_factor(current_attack_speed + attack_speed_delta)
			/ _attack_speed_cooldown_factor(current_attack_speed)
		)
	)
	projected.critical_chance = clamp(
		projected.critical_chance + stat_deltas.get("critical_chance", 0.0) / 100.0, 0.0, 1.0
	)
	var range_delta: float = stat_deltas.get("range", 0.0)
	projected.minimum_range = max(0.0, projected.minimum_range + range_delta)
	projected.maximum_range = max(projected.minimum_range, projected.maximum_range + range_delta)
	return projected


func project_runtime_stats(observation: Dictionary, is_moving: bool) -> Dictionary:
	var projected: Dictionary = observation.player_state.runtime_stats.duplicate(true)
	var stat_deltas := _movement_stat_deltas(observation.player_state.effect_rules, is_moving)
	projected.armor += stat_deltas.get("armor", 0.0)
	projected.dodge_chance = clamp(
		projected.dodge_chance + stat_deltas.get("dodge", 0.0) / 100.0, 0.0, 1.0
	)
	return projected


func _attack_speed_cooldown_factor(attack_speed: float) -> float:
	var ratio := attack_speed / 100.0
	return 1.0 + abs(ratio) if ratio < 0.0 else 1.0 / (1.0 + ratio)


func _movement_stat_deltas(rules: Array, is_moving: bool) -> Dictionary:
	var result := {}
	for rule in rules:
		if rule.event != "movement_state" or not rule.condition.has("is_moving"):
			continue
		var active_now: bool = rule.get("active", false)
		var active_for_candidate: bool = rule.condition.is_moving == is_moving
		if active_now == active_for_candidate:
			continue
		var direction := 1.0 if active_for_candidate else -1.0
		for consequence in rule.consequences:
			if consequence.operation != "add":
				continue
			result[consequence.target] = (
				result.get(consequence.target, 0.0)
				+ direction * consequence.value
			)
	return result
