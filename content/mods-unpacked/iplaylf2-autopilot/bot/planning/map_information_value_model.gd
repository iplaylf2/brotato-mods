extends Reference

# Values a candidate observation pose by the map area it can keep visible and
# the new legally observable frontier it can expose. No preferred direction or
# arena center is encoded; those behaviors emerge from sensor/map geometry.


func value_delta(observation: Dictionary, displacement: Vector2) -> float:
	var viewport_size: Vector2 = observation.visibility.viewport_size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return 0.0
	var origin_value := _observable_value(observation, Vector2.ZERO, viewport_size)
	var candidate_value := _observable_value(observation, displacement, viewport_size)
	return candidate_value - origin_value


func _observable_value(
	observation: Dictionary, displacement: Vector2, viewport_size: Vector2
) -> float:
	var bounds: Dictionary = observation.localization.map_bounds
	var half_size := viewport_size * 0.5
	var sensor_rect := Rect2(displacement - half_size, viewport_size)
	var visible_known_area := _known_map_intersection_area(sensor_rect, bounds)
	var frontier_area := _frontier_extension_area(displacement, half_size, bounds)
	var viewport_area := max(1.0, viewport_size.x * viewport_size.y)
	return (visible_known_area + frontier_area) / viewport_area


func _known_map_intersection_area(sensor_rect: Rect2, bounds: Dictionary) -> float:
	var left: float = -bounds.distance_to_left if bounds.seen_left else sensor_rect.position.x
	var right: float = bounds.distance_to_right if bounds.seen_right else sensor_rect.end.x
	var top: float = -bounds.distance_to_top if bounds.seen_top else sensor_rect.position.y
	var bottom: float = bounds.distance_to_bottom if bounds.seen_bottom else sensor_rect.end.y
	var width := max(0.0, min(sensor_rect.end.x, right) - max(sensor_rect.position.x, left))
	var height := max(0.0, min(sensor_rect.end.y, bottom) - max(sensor_rect.position.y, top))
	return width * height


func _frontier_extension_area(
	displacement: Vector2, half_size: Vector2, bounds: Dictionary
) -> float:
	var result := 0.0
	if not bounds.seen_left:
		result += max(0.0, -displacement.x) * half_size.y * 2.0
	if not bounds.seen_right:
		result += max(0.0, displacement.x) * half_size.y * 2.0
	if not bounds.seen_top:
		result += max(0.0, -displacement.y) * half_size.x * 2.0
	if not bounds.seen_bottom:
		result += max(0.0, displacement.y) * half_size.x * 2.0
	return result
