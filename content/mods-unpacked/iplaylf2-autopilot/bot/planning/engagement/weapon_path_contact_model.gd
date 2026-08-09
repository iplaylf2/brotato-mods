extends Reference

# Separates automatic target eligibility from physical weapon-path contact.
# Vanilla may start an attack inside its targeting allowance even when the
# delivered melee path cannot reach the selected target.


func primary_contact_fraction(
	attack_model: Dictionary,
	target_position: Vector2,
	target_radius: float,
	lateral_transition_width: float
) -> float:
	if target_position.length_squared() <= 0.0:
		return 1.0
	var paths: Dictionary = attack_model.delivery.paths
	var path_count := max(0, int(paths.count))
	if path_count <= 0:
		return 0.0
	if float(paths.angular_half_extent) > 0.0:
		return _swept_sector_contact(
			paths, target_position, target_position, max(0.0, target_radius)
		)
	var contact_sum := 0.0
	for path_index in path_count:
		contact_sum += _path_contact(
			paths,
			target_position,
			target_position,
			max(0.0, target_radius),
			max(1.0, lateral_transition_width),
			path_index,
			path_count
		)
	return contact_sum / float(path_count)


func additional_contact_fraction(
	attack_model: Dictionary,
	aim_position: Vector2,
	target_position: Vector2,
	target_radius: float,
	lateral_transition_width: float
) -> float:
	if aim_position.length_squared() <= 0.0:
		return 0.0
	var paths: Dictionary = attack_model.delivery.paths
	var path_count := max(0, int(paths.count))
	if path_count <= 0:
		return 0.0
	if float(paths.angular_half_extent) > 0.0:
		return _swept_sector_contact(paths, aim_position, target_position, max(0.0, target_radius))
	var best_contact := 0.0
	for path_index in path_count:
		best_contact = max(
			best_contact,
			_path_contact(
				paths,
				aim_position,
				target_position,
				max(0.0, target_radius),
				max(1.0, lateral_transition_width),
				path_index,
				path_count
			)
		)
	return best_contact


func _swept_sector_contact(
	paths: Dictionary, aim_position: Vector2, target_position: Vector2, target_radius: float
) -> float:
	# A sweep is represented by its occupied sector at contact, not by an invented
	# frame-by-frame blade trajectory or an uncertainty band around the boundary.
	var distance: float = target_position.length()
	if distance <= target_radius:
		return 1.0
	var maximum_distance := max(0.0, float(paths.maximum_travel_distance))
	if distance > maximum_distance + target_radius:
		return 0.0
	var angle_delta: float = abs(
		fposmod(target_position.angle() - aim_position.angle() + PI, TAU) - PI
	)
	var angular_half_extent := max(0.0, float(paths.angular_half_extent))
	var angular_clearance: float = max(0.0, angle_delta - angular_half_extent) * distance
	return 1.0 if angular_clearance <= target_radius else 0.0


func _path_contact(
	paths: Dictionary,
	aim_position: Vector2,
	target_position: Vector2,
	target_radius: float,
	lateral_transition_width: float,
	path_index: int,
	path_count: int
) -> float:
	var path_angle := 0.0
	if path_count > 1:
		path_angle = lerp(
			-float(paths.angular_half_extent),
			float(paths.angular_half_extent),
			float(path_index) / float(path_count - 1)
		)
	var direction: Vector2 = aim_position.normalized().rotated(path_angle)
	var forward_distance: float = target_position.dot(direction)
	var maximum_distance := max(0.0, float(paths.maximum_travel_distance))
	if forward_distance < -target_radius or forward_distance > maximum_distance + target_radius:
		return 0.0
	var lateral_distance: float = abs(target_position.cross(direction))
	var clearance: float = lateral_distance - float(paths.corridor_half_width) - target_radius
	return clamp(1.0 - clearance / lateral_transition_width, 0.0, 1.0)
