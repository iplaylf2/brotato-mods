extends Reference

# Values a candidate observation pose by the staleness of the map area it can
# expose. No preferred direction, arena center, or patrol route is encoded;
# exploration and revisitation emerge from the age of legal sensor coverage.

var _coverage_physics_frame := -1
var _last_observed_ages := {}


func value_delta_along_path(observation: Dictionary, displacement: Vector2) -> float:
	var viewport_size: Vector2 = observation.visibility.viewport_size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return 0.0
	var origin_value := _observable_value(observation, Vector2.ZERO, viewport_size)
	var candidate_value := _observable_path_value(observation, displacement, viewport_size)
	return candidate_value - origin_value


func _observable_path_value(
	observation: Dictionary, displacement: Vector2, viewport_size: Vector2
) -> float:
	var cell_size: float = observation.localization.get("observation_grid_cell_size", 0.0)
	if cell_size <= 0.0 or displacement == Vector2.ZERO:
		return _observable_value(observation, displacement, viewport_size)
	_prepare_coverage_index(observation)
	var bounds: Dictionary = observation.localization.map_bounds
	var odometry_position: Vector2 = observation.localization.odometry_position
	var viewport_offset: Vector2 = observation.visibility.get(
		"viewport_offset_from_player", -viewport_size * 0.5
	)
	var sample_count := int(max(1.0, ceil(displacement.length() / cell_size)))
	var maximum_visible_area_by_cell := {}
	for sample_index in range(sample_count + 1):
		var fraction := float(sample_index) / float(sample_count)
		var sensor_rect := Rect2(
			odometry_position + displacement * fraction + viewport_offset, viewport_size
		)
		var first_x := int(floor(sensor_rect.position.x / cell_size))
		var last_x := int(floor((sensor_rect.end.x - 0.001) / cell_size))
		var first_y := int(floor(sensor_rect.position.y / cell_size))
		var last_y := int(floor((sensor_rect.end.y - 0.001) / cell_size))
		for grid_x in range(first_x, last_x + 1):
			for grid_y in range(first_y, last_y + 1):
				var cell_rect := Rect2(
					Vector2(grid_x * cell_size, grid_y * cell_size), Vector2(cell_size, cell_size)
				)
				var visible_area: float = _visible_cell_area(
					cell_rect, sensor_rect, odometry_position, bounds
				)
				var key := _cell_key(grid_x, grid_y)
				maximum_visible_area_by_cell[key] = max(
					visible_area, maximum_visible_area_by_cell.get(key, 0.0)
				)
	var reobservation_horizon: float = max(0.01, observation.wave_state.duration_seconds)
	var observable_value := 0.0
	for key in maximum_visible_area_by_cell:
		var age: float = _last_observed_ages.get(key, INF)
		var observation_staleness := (
			1.0
			if age == INF
			else clamp(age / reobservation_horizon, 0.0, 1.0)
		)
		observable_value += maximum_visible_area_by_cell[key] * observation_staleness
	return observable_value / max(1.0, viewport_size.x * viewport_size.y)


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
	_prepare_coverage_index(observation)
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
			var age: float = _last_observed_ages.get(_cell_key(grid_x, grid_y), INF)
			var observation_staleness := (
				1.0
				if age == INF
				else clamp(age / reobservation_horizon, 0.0, 1.0)
			)
			observable_value += visible_area * observation_staleness
	return observable_value / viewport_area


func _prepare_coverage_index(observation: Dictionary) -> void:
	var physics_frame: int = observation.get("physics_frame", -1)
	if physics_frame >= 0 and physics_frame == _coverage_physics_frame:
		return
	_coverage_physics_frame = physics_frame
	_last_observed_ages = {}
	for cell in observation.localization.get("observation_cells", []):
		_last_observed_ages[_cell_key(cell.grid_x, cell.grid_y)] = cell.seconds_since_observed


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
