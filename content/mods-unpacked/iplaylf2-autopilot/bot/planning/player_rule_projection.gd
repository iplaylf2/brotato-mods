extends Reference

# Projects normalized effect rules onto the few player-level dimensions used to
# shape a plan. Vanilla storage keys and content identities must not enter here.


func project(observation: Dictionary) -> Dictionary:
	var rules: Array = observation.player_state.effect_rules
	var event_outcome_channels := {}
	for rule in rules:
		var event: String = rule.event
		if not event_outcome_channels.has(event):
			event_outcome_channels[event] = {}
		for consequence in rule.consequences:
			var probability := clamp(consequence.get("chance_percent", 100.0) / 100.0, 0.0, 1.0)
			for channel in consequence.get("outcome_channels", {}):
				event_outcome_channels[event][channel] = (
					event_outcome_channels[event].get(channel, 0.0)
					+ consequence.outcome_channels[channel] * probability
				)

	var maximum_consumable_recovery := 0.0
	for entity in observation.get("remembered_entities", []):
		if entity.kind != "consumable":
			continue
		maximum_consumable_recovery = max(
			maximum_consumable_recovery,
			_project_recovery(
				rules,
				"consumable_pickup",
				entity.get("pickup_profile", {}).get("base_recovery", 0.0)
			)
		)
	if maximum_consumable_recovery <= 0.0:
		maximum_consumable_recovery = _project_recovery(rules, "consumable_pickup", 3.0)
	maximum_consumable_recovery = _project_recovery(rules, "healing", maximum_consumable_recovery)

	return {
		"event_outcome_channels": event_outcome_channels,
		"movement_state_value_rates": _movement_state_value_rates(rules, observation),
		"recovery":
		{
			"available": _project_recovery(rules, "healing", 1.0) > 0.0,
			"consumable_available": maximum_consumable_recovery > 0.0,
		},
		"survival":
		{
			"health_rate": _health_rate(rules),
			"terminal_on_positive_damage": _terminal_on_positive_damage(rules),
		},
	}


func project_recovery(rules: Array, event: String, base_value: float) -> float:
	return _project_recovery(rules, event, base_value)


func _project_recovery(rules: Array, event: String, base_value: float) -> float:
	var result := base_value
	for rule in rules:
		if rule.event != event or not rule.condition.empty():
			continue
		for consequence in rule.consequences:
			if consequence.target != "health_recovery":
				continue
			match consequence.operation:
				"add":
					result += consequence.get("value", 0.0)
				"multiply":
					result *= consequence.get("value", 1.0)
				"set":
					result = consequence.get("value", result)
	return max(0.0, result)


func _movement_state_value_rates(rules: Array, observation: Dictionary) -> Dictionary:
	var result := {"standing": 0.0, "moving": 0.0}
	for rule in rules:
		if rule.event != "movement_state" or not rule.condition.has("is_moving"):
			continue
		var value := 0.0
		for consequence in rule.consequences:
			if consequence.target == "materials":
				var percent: float = consequence.get("percent", 0.0) / 100.0
				value += max(1.0, observation.player_state.resources.materials * percent)
			elif consequence.operation == "add":
				value += max(0.0, consequence.get("value", 0.0)) * 0.04
		if rule.condition.is_moving:
			result.moving += value
		else:
			result.standing += value
	return result


func _health_rate(rules: Array) -> float:
	var result := 0.0
	for rule in rules:
		if rule.event != "time_elapsed":
			continue
		for consequence in rule.consequences:
			if consequence.target == "health" and consequence.operation == "add_rate":
				result += consequence.get("value", 0.0)
	return result


func _terminal_on_positive_damage(rules: Array) -> bool:
	for rule in rules:
		if rule.event != "damage_taken" or not rule.condition.get("value_is_positive", false):
			continue
		for consequence in rule.consequences:
			if (
				consequence.target == "health"
				and consequence.operation == "set"
				and consequence.get("value", 1.0) <= 0.0
			):
				return true
	return false
