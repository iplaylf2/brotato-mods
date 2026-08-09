extends Reference

# Owns target-specific automatic-attack intervals and their distance geometry.
# Health targets weight intervals by primary damage rate; hit-limited neutrals
# use primary hit rate. This model does not value targets or select movement.

const WeaponAttackCapacityModel := preload("weapon_attack_capacity_model.gd")

var _capacity_model: Reference = WeaponAttackCapacityModel.new()


func normalized_intervals(weapons: Array, target: Dictionary) -> Array:
	var intervals := []
	var total_capacity := 0.0
	var uses_hit_capacity: bool = (
		float(target.get("weapon_response", {}).get("hit_limit_progress_per_hit", 0.0))
		> 0.0
	)
	for observed_weapon in weapons:
		var attack_model: Dictionary = observed_weapon.attack_model
		var capacity: float = (
			_capacity_model.expected_primary_hit_rate_for_attack_model(attack_model)
			if uses_hit_capacity
			else _capacity_model.expected_primary_damage_rate_for_attack_model(attack_model)
		)
		if capacity <= 0.0:
			continue
		var minimum_distance := max(0.0, float(attack_model.delivery.minimum_targeting_distance))
		var maximum_distance := max(
			minimum_distance, float(attack_model.delivery.maximum_targeting_distance)
		)
		_merge_interval(intervals, minimum_distance, maximum_distance, capacity)
		total_capacity += capacity
	if total_capacity <= 0.0:
		return []
	for interval in intervals:
		interval.capacity_share /= total_capacity
	return intervals


func distance_gap(distance: float, interval: Dictionary) -> float:
	var bounded_distance := max(0.0, distance)
	if bounded_distance < interval.minimum_distance:
		return interval.minimum_distance - bounded_distance
	if bounded_distance > interval.maximum_distance:
		return bounded_distance - interval.maximum_distance
	return 0.0


func access_direction(relative_position: Vector2, interval: Dictionary) -> Vector2:
	if relative_position.length_squared() <= 0.0:
		return Vector2.ZERO
	var distance := relative_position.length()
	if distance < interval.minimum_distance:
		return -relative_position
	if distance > interval.maximum_distance:
		return relative_position
	return Vector2.ZERO


func _merge_interval(
	intervals: Array, minimum_distance: float, maximum_distance: float, capacity: float
) -> void:
	for interval in intervals:
		if (
			is_equal_approx(interval.minimum_distance, minimum_distance)
			and is_equal_approx(interval.maximum_distance, maximum_distance)
		):
			interval.capacity_share += capacity
			return
	intervals.push_back(
		{
			"minimum_distance": minimum_distance,
			"maximum_distance": maximum_distance,
			"capacity_share": capacity,
		}
	)
