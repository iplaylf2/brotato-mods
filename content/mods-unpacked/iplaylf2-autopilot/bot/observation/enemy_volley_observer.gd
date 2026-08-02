extends Reference

# Observes the next-volley time window of an already-visible enemy. Deterministic
# cooldown state is exact. A resolved random cooldown remains opaque until visible
# behavior reveals its timing.


func observe(enemy: Node) -> Dictionary:
	if (
		not "_current_attack_behavior" in enemy
		or not enemy._current_attack_behavior is ShootingAttackBehavior
	):
		return _unknown_window()
	var behavior: ShootingAttackBehavior = enemy._current_attack_behavior
	if behavior._current_initial_cooldown > 0:
		var initial_seconds: float = behavior._current_initial_cooldown / 60.0
		return {
			"is_exact": true,
			"earliest_seconds": initial_seconds,
			"latest_seconds": initial_seconds,
		}
	if behavior.max_cd_randomization <= 0 and behavior._current_cd > 0:
		var remaining_seconds: float = behavior._current_cd / 60.0
		return {
			"is_exact": true,
			"earliest_seconds": remaining_seconds,
			"latest_seconds": remaining_seconds,
		}
	# The current random cooldown roll is intentionally opaque. Once cooldown
	# reaches zero, the visible attack animation also makes spawn time nonzero;
	# without compiling that animation track, keep the next-volley time as an interval.
	return {
		"is_exact": false,
		"earliest_seconds": 0.0,
		"latest_seconds": (behavior.cooldown + behavior.max_cd_randomization) / 60.0,
	}


func _unknown_window() -> Dictionary:
	return {
		"is_exact": false,
		"earliest_seconds": 0.0,
		"latest_seconds": INF,
	}
