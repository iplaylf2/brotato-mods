extends Reference

# Observes attack time windows of an already-visible enemy. Deterministic
# cooldown state is exact. A resolved random cooldown remains opaque until
# visible behavior reveals its timing.


func observe_projectile_volley_window(enemy: Node) -> Dictionary:
	if (
		not "_current_attack_behavior" in enemy
		or not enemy._current_attack_behavior is ShootingAttackBehavior
	):
		return _unknown_window()
	var behavior: ShootingAttackBehavior = enemy._current_attack_behavior
	if behavior._current_initial_cooldown > 0:
		var initial_seconds: float = behavior._current_initial_cooldown / 60.0
		return _exact_window(initial_seconds)
	return _observe_cooldown_window(behavior)


func observe_charge_attack_window(enemy: Node) -> Dictionary:
	if (
		not "_current_attack_behavior" in enemy
		or not enemy._current_attack_behavior is ChargingAttackBehavior
	):
		return _unknown_window()
	return _observe_cooldown_window(enemy._current_attack_behavior)


func _observe_cooldown_window(behavior: Node) -> Dictionary:
	if behavior.max_cd_randomization <= 0 and behavior._current_cd > 0:
		return _exact_window(behavior._current_cd / 60.0)
	# The current random cooldown roll is intentionally opaque. Once cooldown
	# reaches zero, the visible attack animation still makes realization nonzero;
	# without compiling that animation track, retain the stable interval.
	return {
		"is_exact": false,
		"earliest_seconds": 0.0,
		"latest_seconds": (behavior.cooldown + behavior.max_cd_randomization) / 60.0,
	}


func _exact_window(seconds: float) -> Dictionary:
	return {
		"is_exact": true,
		"earliest_seconds": seconds,
		"latest_seconds": seconds,
	}


func _unknown_window() -> Dictionary:
	return {
		"is_exact": false,
		"earliest_seconds": 0.0,
		"latest_seconds": INF,
	}
