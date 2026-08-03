extends Reference

# Values a candidate observation pose by the staleness of the map area it can
# expose. No preferred direction, arena center, or patrol route is encoded;
# exploration and revisitation emerge from the age of legal sensor coverage.


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
	var viewport_area := max(1.0, viewport_size.x * viewport_size.y)
	var viewport_offset: Vector2 = observation.visibility.get(
		"viewport_offset_from_player", -viewport_size * 0.5
	)
	var cell_size: float = observation.localization.get("observation_grid_cell_size", 0.0)
	if cell_size <= 0.0:
		return (
			_known_map_intersection_area(
				Rect2(displacement + viewport_offset, viewport_size), bounds
			)
			/ viewport_area
		)
	var last_observed_ages := {}
	for cell in observation.localization.get("observation_cells", []):
		last_observed_ages[_cell_key(cell.grid_x, cell.grid_y)] = cell.seconds_since_observed
	var odometry_position: Vector2 = observation.localization.odometry_position
	var sensor_rect := Rect2(odometry_position + displacement + viewport_offset, viewport_size)
	var first_x := int(floor(sensor_rect.position.x / cell_size))
	var last_x := int(floor((sensor_rect.end.x - 0.001) / cell_size))
	var first_y := int(floor(sensor_rect.position.y / cell_size))
	var last_y := int(floor((sensor_rect.end.y - 0.001) / cell_size))
	var reobservation_horizon: float = max(0.01, observation.wave_state.duration_seconds)
	var observable_value := 0.0
	for grid_x in range(first_x, last_x + 1):
		for grid_y in range(first_y, last_y + 1):
			var cell_rect := Rect2(
				Vector2(grid_x * cell_size, grid_y * cell_size), Vector2(cell_size, cell_size)
			)
			var visible_area: float = _visible_cell_area(
				cell_rect, sensor_rect, odometry_position, bounds
			)
			if visible_area <= 0.0:
				continue
			var age: float = last_observed_ages.get(_cell_key(grid_x, grid_y), INF)
			var observation_staleness := (
				1.0
				if age == INF
				else clamp(age / reobservation_horizon, 0.0, 1.0)
			)
			observable_value += visible_area * observation_staleness
	return observable_value / viewport_area


func _visible_cell_area(
	cell_rect: Rect2, sensor_rect: Rect2, odometry_position: Vector2, bounds: Dictionary
) -> float:
	var left: float = (
		odometry_position.x - bounds.distance_to_left
		if bounds.seen_left
		else sensor_rect.position.x
	)
	var right: float = (
		odometry_position.x + bounds.distance_to_right
		if bounds.seen_right
		else sensor_rect.end.x
	)
	var top: float = (
		odometry_position.y - bounds.distance_to_top
		if bounds.seen_top
		else sensor_rect.position.y
	)
	var bottom: float = (
		odometry_position.y + bounds.distance_to_bottom
		if bounds.seen_bottom
		else sensor_rect.end.y
	)
	var width := max(
		0.0,
		(
			min(min(cell_rect.end.x, sensor_rect.end.x), right)
			- max(max(cell_rect.position.x, sensor_rect.position.x), left)
		)
	)
	var height := max(
		0.0,
		(
			min(min(cell_rect.end.y, sensor_rect.end.y), bottom)
			- max(max(cell_rect.position.y, sensor_rect.position.y), top)
		)
	)
	return width * height


func _known_map_intersection_area(sensor_rect: Rect2, bounds: Dictionary) -> float:
	var left: float = -bounds.distance_to_left if bounds.seen_left else sensor_rect.position.x
	var right: float = bounds.distance_to_right if bounds.seen_right else sensor_rect.end.x
	var top: float = -bounds.distance_to_top if bounds.seen_top else sensor_rect.position.y
	var bottom: float = bounds.distance_to_bottom if bounds.seen_bottom else sensor_rect.end.y
	var width := max(0.0, min(sensor_rect.end.x, right) - max(sensor_rect.position.x, left))
	var height := max(0.0, min(sensor_rect.end.y, bottom) - max(sensor_rect.position.y, top))
	return width * height


func _cell_key(grid_x: int, grid_y: int) -> String:
	return "%s:%s" % [grid_x, grid_y]
