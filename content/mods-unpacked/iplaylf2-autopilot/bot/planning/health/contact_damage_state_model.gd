extends Reference

# Propagates timestamped contact opportunities through vanilla's
# damage order: active iframes, dodge, hit protection, armor, then new iframes.
# Geometry owns whether and when contact occurs; this model owns health state.


func evaluate(
	observation: Dictionary,
	runtime_stats: Dictionary,
	contact_opportunities: Array,
	positive_damage_is_terminal_rule: bool
) -> Dictionary:
	var opportunities := _normalize_opportunities(contact_opportunities)
	if opportunities.empty():
		return _empty_result()
	var initial_health: int = int(round(max(0.0, observation.player_state.health.current)))
	var states := [
		{
			"health": initial_health,
			"hit_protection": int(max(0, runtime_stats.hit_protection)),
			"damageable_at_seconds":
			max(0.0, runtime_stats.get("invincibility_seconds_remaining", 0.0)),
			"weighted_resolved_contact_count": 0.0,
			"terminal": initial_health <= 0,
			"terminal_time_seconds": 0.0 if initial_health <= 0 else null,
			"probability": 1.0,
		}
	]
	var armor_multiplier := _armor_damage_multiplier(runtime_stats.armor)
	var dodge_probability: float = clamp(runtime_stats.dodge_chance, 0.0, 1.0)
	var minimum_invincibility_seconds: float = max(
		0.001, runtime_stats.minimum_invincibility_seconds
	)
	var maximum_invincibility_seconds: float = max(
		minimum_invincibility_seconds,
		runtime_stats.get("maximum_invincibility_seconds", minimum_invincibility_seconds * 2.0)
	)
	var maximum_armor_adjusted_damage := 0.0
	for opportunity in opportunities:
		var damage := _armor_adjusted_damage(opportunity.raw_damage, armor_multiplier)
		maximum_armor_adjusted_damage = max(maximum_armor_adjusted_damage, damage)
		states = _advance_opportunity(
			states,
			opportunity,
			damage,
			dodge_probability,
			minimum_invincibility_seconds,
			maximum_invincibility_seconds,
			max(1.0, observation.player_state.health.maximum),
			positive_damage_is_terminal_rule
		)
	var expected_remaining_health := 0.0
	var expected_contact_resolution_count := 0.0
	var terminal_probability := 0.0
	var probability_weighted_terminal_time := 0.0
	for state in states:
		expected_remaining_health += state.probability * state.health
		expected_contact_resolution_count += state.weighted_resolved_contact_count
		if state.terminal:
			terminal_probability += state.probability
			probability_weighted_terminal_time += (
				state.probability
				* float(state.terminal_time_seconds)
			)
	return {
		"maximum_armor_adjusted_hit_damage": maximum_armor_adjusted_damage,
		"expected_contact_resolution_count": expected_contact_resolution_count,
		"expected_health_loss": max(0.0, initial_health - expected_remaining_health),
		"terminal_collision_risk": clamp(terminal_probability, 0.0, 1.0),
		"expected_terminal_time_seconds":
		(
			probability_weighted_terminal_time / terminal_probability
			if terminal_probability > 0.0
			else null
		),
	}


func _advance_opportunity(
	states: Array,
	opportunity: Dictionary,
	damage: float,
	dodge_probability: float,
	minimum_invincibility_seconds: float,
	maximum_invincibility_seconds: float,
	maximum_health: float,
	positive_damage_is_terminal_rule: bool
) -> Array:
	var next_by_key := {}
	var realization_probability: float = clamp(opportunity.realization_probability, 0.0, 1.0)
	for state in states:
		if state.terminal or opportunity.time_seconds + 0.0001 < state.damageable_at_seconds:
			_add_state(next_by_key, state, state.probability, state.weighted_resolved_contact_count)
			continue
		_add_state(
			next_by_key,
			state,
			state.probability * (1.0 - realization_probability),
			state.weighted_resolved_contact_count * (1.0 - realization_probability)
		)
		var realized_probability_mass: float = state.probability * realization_probability
		if realized_probability_mass <= 0.0:
			continue
		var weighted_resolved_contact_count: float = (
			state.weighted_resolved_contact_count * realization_probability
			+ realized_probability_mass
		)
		var resolved: Dictionary = state.duplicate(false)
		resolved.damageable_at_seconds = (opportunity.time_seconds + minimum_invincibility_seconds)
		_add_state(
			next_by_key,
			resolved,
			realized_probability_mass * dodge_probability,
			weighted_resolved_contact_count * dodge_probability
		)
		var undodged_probability_mass := realized_probability_mass * (1.0 - dodge_probability)
		if resolved.hit_protection > 0:
			var protected: Dictionary = resolved.duplicate(false)
			protected.hit_protection -= 1
			_add_state(
				next_by_key,
				protected,
				undodged_probability_mass,
				weighted_resolved_contact_count * (1.0 - dodge_probability)
			)
		else:
			var damaged: Dictionary = resolved.duplicate(false)
			damaged.health = max(0, damaged.health - int(damage))
			damaged.damageable_at_seconds = (
				opportunity.time_seconds
				+ _invincibility_duration_seconds(
					damage,
					maximum_health,
					minimum_invincibility_seconds,
					maximum_invincibility_seconds
				)
			)
			damaged.terminal = (
				damaged.health <= 0
				or (positive_damage_is_terminal_rule and damage > 0.0)
			)
			if damaged.terminal:
				damaged.terminal_time_seconds = opportunity.time_seconds
			_add_state(
				next_by_key,
				damaged,
				undodged_probability_mass,
				weighted_resolved_contact_count * (1.0 - dodge_probability)
			)
	return next_by_key.values()


func _add_state(
	states_by_key: Dictionary,
	state: Dictionary,
	probability: float,
	weighted_resolved_contact_count: float
) -> void:
	if probability <= 0.0000001:
		return
	var key := (
		"%s|%s|%s|%s|%s"
		% [
			state.health,
			state.hit_protection,
			int(round(state.damageable_at_seconds * 10000.0)),
			int(state.terminal),
			(
				int(round(float(state.terminal_time_seconds) * 10000.0))
				if state.terminal_time_seconds != null
				else -1
			),
		]
	)
	if states_by_key.has(key):
		states_by_key[key].probability += probability
		states_by_key[key].weighted_resolved_contact_count += weighted_resolved_contact_count
		return
	var stored: Dictionary = state.duplicate(false)
	stored.probability = probability
	stored.weighted_resolved_contact_count = weighted_resolved_contact_count
	states_by_key[key] = stored


func _normalize_opportunities(contact_opportunities: Array) -> Array:
	var result := []
	var earliest_consuming_opportunity_by_source_id := {}
	for opportunity in contact_opportunities:
		if opportunity.get("source_consumed_on_contact", false):
			var source_id: String = opportunity.source_id
			if (
				earliest_consuming_opportunity_by_source_id.has(source_id)
				and (
					earliest_consuming_opportunity_by_source_id[source_id].time_seconds
					<= opportunity.time_seconds
				)
			):
				continue
			earliest_consuming_opportunity_by_source_id[source_id] = opportunity
		else:
			result.push_back(opportunity)
	for opportunity in earliest_consuming_opportunity_by_source_id.values():
		result.push_back(opportunity)
	result.sort_custom(self, "_opportunity_precedes")
	return result


func _opportunity_precedes(left: Dictionary, right: Dictionary) -> bool:
	return left.time_seconds < right.time_seconds


func _invincibility_duration_seconds(
	damage: float,
	maximum_health: float,
	minimum_invincibility_seconds: float,
	maximum_invincibility_seconds: float
) -> float:
	var health_fraction := damage / max(1.0, maximum_health)
	return clamp(
		(health_fraction * maximum_invincibility_seconds) / 0.15,
		minimum_invincibility_seconds,
		maximum_invincibility_seconds
	)


func _armor_adjusted_damage(raw_damage: float, armor_multiplier: float) -> float:
	if raw_damage <= 0.0:
		return 0.0
	return max(1.0, round(raw_damage * armor_multiplier))


func _armor_damage_multiplier(armor: float) -> float:
	if armor >= 0.0:
		return 1.0 / (1.0 + armor / 15.0)
	return 2.0 - 1.0 / (1.0 - armor / 15.0)


func _empty_result() -> Dictionary:
	return {
		"maximum_armor_adjusted_hit_damage": 0.0,
		"expected_contact_resolution_count": 0.0,
		"expected_health_loss": 0.0,
		"terminal_collision_risk": 0.0,
		"expected_terminal_time_seconds": null,
	}
