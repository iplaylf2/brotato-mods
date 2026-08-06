extends Reference

# Measures the union of headings blocked during the next control interval by
# reachable enemy disks and known map boundaries. Overlapping obstacles consume
# one angular region instead of being counted repeatedly, so clustered enemies
# block fewer distinct headings than obstacles distributed around the player.


func constraint_profile(
	tracks: Array,
	relative_positions: Array,
	bounds: Dictionary,
	player_displacement: Vector2,
	geometry: Dictionary
) -> Dictionary:
	assert(tracks.size() == relative_positions.size())
	var enemy_intervals := []
	for track_index in tracks.size():
		_append_enemy_interval(
			enemy_intervals, tracks[track_index], relative_positions[track_index], geometry
		)
	var boundary_intervals := _boundary_intervals(bounds, player_displacement, geometry)
	var combined_intervals: Array = enemy_intervals.duplicate()
	combined_intervals.append_array(boundary_intervals)
	return {
		"enemy": _covered_fraction(enemy_intervals),
		"boundary": _covered_fraction(boundary_intervals),
		"combined": _covered_fraction(combined_intervals),
	}


func _append_enemy_interval(
	intervals: Array, track: Dictionary, relative_position: Vector2, geometry: Dictionary
) -> void:
	var distance: float = relative_position.length()
	var target_response: Dictionary = track.behavior_profile.get("target_position_response", {})
	var enemy_control_reach: float = (
		max(track.estimated_velocity.length(), target_response.get("movement_speed", 0.0))
		* geometry.control_distance
		/ geometry.command_speed
	)
	var support_radius: float = (
		geometry.player_radius
		+ track.behavior_profile.contact_radius
		+ enemy_control_reach
	)
	var reach_margin: float = geometry.encounter_margin + support_radius
	if distance >= reach_margin:
		return
	var half_width: float = asin(clamp(support_radius / max(distance, support_radius), 0.0, 1.0))
	var reach_weight: float = clamp((reach_margin - distance) / geometry.encounter_margin, 0.0, 1.0)
	# Contract confidence and reach into angular support before the union. This
	# preserves the former single-obstacle contribution while preventing overlap
	# from manufacturing extra confinement.
	half_width *= reach_weight * track.recency_confidence
	_append_wrapped_interval(intervals, relative_position.angle(), half_width)


func _boundary_intervals(bounds: Dictionary, displacement: Vector2, geometry: Dictionary) -> Array:
	var result := []
	var future_distances := [
		_add_if_known(bounds.distance_to_right, -displacement.x),
		_add_if_known(bounds.distance_to_bottom, -displacement.y),
		_add_if_known(bounds.distance_to_left, displacement.x),
		_add_if_known(bounds.distance_to_top, displacement.y),
	]
	var outward_angles := [0.0, PI * 0.5, PI, PI * 1.5]
	var control_reach: float = max(1.0, geometry.control_distance)
	for side_index in future_distances.size():
		var distance = future_distances[side_index]
		if distance == null:
			continue
		var clearance: float = max(0.0, float(distance) - geometry.player_radius)
		if clearance >= control_reach:
			continue
		var half_width: float = acos(clamp(clearance / control_reach, 0.0, 1.0))
		_append_wrapped_interval(result, outward_angles[side_index], half_width)
	return result


func _append_wrapped_interval(intervals: Array, center: float, half_width: float) -> void:
	if half_width <= 0.0:
		return
	var start: float = fposmod(center - half_width, TAU)
	var finish: float = fposmod(center + half_width, TAU)
	if start <= finish:
		intervals.push_back(Vector2(start, finish))
	else:
		intervals.push_back(Vector2(0.0, finish))
		intervals.push_back(Vector2(start, TAU))


func _covered_fraction(intervals: Array) -> float:
	if intervals.empty():
		return 0.0
	intervals.sort_custom(self, "_interval_starts_before")
	var covered := 0.0
	var current_start: float = intervals[0].x
	var current_finish: float = intervals[0].y
	for interval_index in range(1, intervals.size()):
		var interval: Vector2 = intervals[interval_index]
		if interval.x <= current_finish:
			current_finish = max(current_finish, interval.y)
		else:
			covered += current_finish - current_start
			current_start = interval.x
			current_finish = interval.y
	covered += current_finish - current_start
	return clamp(covered / TAU, 0.0, 1.0)


func _interval_starts_before(left: Vector2, right: Vector2) -> bool:
	return left.x < right.x


func _add_if_known(value, addition: float):
	return null if value == null else float(value) + addition
