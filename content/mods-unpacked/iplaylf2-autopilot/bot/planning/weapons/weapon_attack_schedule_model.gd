extends Reference

# Projects action-visible rule events into action-conditioned automatic-weapon
# attack counts. WeaponAttackCapacityModel owns the event-free baseline; this
# model owns cooldown-reset scheduling without depending on content IDs.

const WeaponAttackCapacityModel := preload("weapon_attack_capacity_model.gd")
const COOLDOWN_TARGET := "all_automatic_weapon_cooldowns"

var _attack_capacity_model: Reference = WeaponAttackCapacityModel.new()


func expected_attack_count(
	attack_model: Dictionary, horizon_seconds: float, effect_rules: Array, pickup_events: Dictionary
) -> float:
	var baseline_attack_count: float = _attack_capacity_model.expected_attack_count(
		attack_model, horizon_seconds
	)
	var reset_events: Array = _cooldown_reset_events(effect_rules, pickup_events, horizon_seconds)
	if reset_events.empty():
		return baseline_attack_count

	# Vanilla cooldowns form a renewal process. Certain events may be composed on
	# one schedule. Fractional weights are per-pickup existence confidence, not an
	# independence contract, so do not multiply them into an invented joint branch.
	# Use the strongest individually supported uncertain branch above the certain
	# schedule. This is monotone when another candidate pickup is discovered and
	# does not double-count correlated evidence.
	var certain_reset_events := []
	var uncertain_reset_events := []
	for event in reset_events:
		if is_equal_approx(event.existence_confidence, 1.0):
			certain_reset_events.push_back(event)
		else:
			uncertain_reset_events.push_back(event)
	var certain_reset_attack_count := max(
		baseline_attack_count,
		_attack_count_for_reset_schedule(attack_model, horizon_seconds, certain_reset_events)
	)
	var largest_supported_attack_increment := 0.0
	for event in uncertain_reset_events:
		var branch_events: Array = certain_reset_events.duplicate()
		branch_events.push_back(event)
		branch_events.sort_custom(self, "_earlier_event")
		var branch_attack_count := _attack_count_for_reset_schedule(
			attack_model, horizon_seconds, branch_events
		)
		largest_supported_attack_increment = max(
			largest_supported_attack_increment,
			event.existence_confidence * max(0.0, branch_attack_count - certain_reset_attack_count)
		)
	return certain_reset_attack_count + largest_supported_attack_increment


func _attack_count_for_reset_schedule(
	attack_model: Dictionary, horizon_seconds: float, reset_events: Array
) -> float:
	var interval: float = max(0.0001, float(attack_model.timing.expected_attack_interval_seconds))
	var next_readiness: float = max(0.0, float(attack_model.timing.seconds_until_next_attack))
	var initial_phase_end: float = max(
		0.0, float(attack_model.timing.get("seconds_until_attack_phase_complete", 0.0))
	)
	var result := 0.0
	for event in reset_events:
		var event_time: float = event.time
		while next_readiness < event_time:
			result += 1.0
			next_readiness += interval
		var reset_readiness := max(event_time, initial_phase_end)
		if reset_readiness < next_readiness:
			next_readiness = reset_readiness
	while next_readiness <= horizon_seconds:
		result += 1.0
		next_readiness += interval
	return result


func _cooldown_reset_events(
	effect_rules: Array, pickup_events: Dictionary, horizon_seconds: float
) -> Array:
	var has_material_reset_rule := false
	for rule in effect_rules:
		if rule.event != "material_pickup" or not rule.condition.empty():
			continue
		for consequence in rule.consequences:
			if (
				consequence.target == COOLDOWN_TARGET
				and consequence.operation == "set"
				and consequence.get("value", 0.0) <= 0.0
			):
				has_material_reset_rule = true
				break
		if has_material_reset_rule:
			break
	if not has_material_reset_rule:
		return []

	var result := []
	for event in pickup_events.get("material", []):
		var event_time: float = max(0.0, float(event.get("time", 0.0)))
		if event_time > horizon_seconds:
			continue
		result.push_back(
			{
				"time": event_time,
				"existence_confidence": clamp(event.get("event_weight", 1.0), 0.0, 1.0),
			}
		)
	result.sort_custom(self, "_earlier_event")
	return result


func _earlier_event(first: Dictionary, second: Dictionary) -> bool:
	return first.time < second.time
