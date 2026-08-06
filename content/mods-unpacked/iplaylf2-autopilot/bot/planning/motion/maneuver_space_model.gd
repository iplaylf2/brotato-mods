extends Reference

# Measures how much of the next control interval's angular movement space is
# blocked by a reachable enemy disk. It neither chooses a route nor prices the
# constraint; those responsibilities remain with navigation and battlefield models.


func enemy_constraint(track: Dictionary, relative_position: Vector2, geometry: Dictionary) -> float:
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
		return 0.0
	# Contact is priced by collision evidence. This channel only measures how much
	# directional choice the reachable disk removes, so it stays continuous at the
	# contact boundary instead of adding a second all-or-nothing collision penalty.
	var angular_fraction: float = (
		asin(clamp(support_radius / max(distance, support_radius), 0.0, 1.0))
		/ PI
	)
	var reach_weight: float = clamp((reach_margin - distance) / geometry.encounter_margin, 0.0, 1.0)
	return angular_fraction * reach_weight * track.recency_confidence
