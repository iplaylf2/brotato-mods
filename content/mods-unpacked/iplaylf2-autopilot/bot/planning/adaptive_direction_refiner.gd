extends Reference

# Proposes angular midpoints around promising evaluated movement directions.
# Callers own candidate construction, evaluation, and stopping policy.

const MIN_REFINEMENT_ANGLE_RADIANS := 0.002


func propose_direction(direction_scores: Array) -> Vector2:
	var moving_direction_scores := []
	for direction_score in direction_scores:
		if direction_score.movement.length_squared() <= 0.0:
			continue
		moving_direction_scores.push_back(direction_score)
	if moving_direction_scores.size() < 2:
		return Vector2.ZERO

	var best_interval := {}
	for left in moving_direction_scores:
		var left_angle: float = wrapf(left.movement.angle(), 0.0, TAU)
		var nearest_clockwise := {}
		var nearest_delta := TAU
		for right in moving_direction_scores:
			if right == left:
				continue
			var right_angle: float = wrapf(right.movement.angle(), 0.0, TAU)
			var delta: float = wrapf(right_angle - left_angle, 0.0, TAU)
			if delta > 0.0 and delta < nearest_delta:
				nearest_delta = delta
				nearest_clockwise = right
		if nearest_clockwise.empty() or nearest_delta <= MIN_REFINEMENT_ANGLE_RADIANS:
			continue
		var interval_priority: float = max(left.score, nearest_clockwise.score)
		if (
			best_interval.empty()
			or interval_priority > best_interval.priority
			or (
				is_equal_approx(interval_priority, best_interval.priority)
				and nearest_delta > best_interval.width
			)
		):
			best_interval = {
				"angle": left_angle + nearest_delta * 0.5,
				"priority": interval_priority,
				"width": nearest_delta,
			}
	return Vector2.ZERO if best_interval.empty() else Vector2.RIGHT.rotated(best_interval.angle)
