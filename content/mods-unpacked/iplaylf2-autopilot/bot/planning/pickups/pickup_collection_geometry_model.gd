extends Reference

# Resolves continuous collection geometry between player and pickup paths,
# including pickups already moving after entering the attraction area. Both
# sampled action paths and straight navigation paths use this boundary.


func first_collection(pickup: Dictionary, samples: Array, collection_radius: float) -> Dictionary:
	var previous_time := 0.0
	var previous_player_displacement := Vector2.ZERO
	var previous_relative_position: Vector2 = pickup.relative_position
	if previous_relative_position.length() <= collection_radius:
		return {
			"entity": pickup,
			"time": 0.0,
			"player_displacement": Vector2.ZERO,
		}
	for sample in samples:
		var time: float = max(previous_time, float(sample.time))
		var player_displacement: Vector2 = sample.displacement
		var relative_position: Vector2 = (
			_predict_pickup_displacement(pickup, time)
			- player_displacement
		)
		var segment_fraction: float = _first_circle_intersection_fraction(
			previous_relative_position, relative_position, collection_radius
		)
		if segment_fraction >= 0.0:
			return {
				"entity": pickup,
				"time": lerp(previous_time, time, segment_fraction),
				"player_displacement":
				previous_player_displacement.linear_interpolate(
					player_displacement, segment_fraction
				),
			}
		previous_time = time
		previous_player_displacement = player_displacement
		previous_relative_position = relative_position
	return {}


func initial_collection_gap(pickup: Dictionary, collection_radius: float) -> float:
	return max(0.0, pickup.relative_position.length() - collection_radius)


func collection_gap_at(
	pickup: Dictionary,
	player_displacement: Vector2,
	forecast_seconds: float,
	collection_radius: float
) -> float:
	return max(
		0.0,
		(
			(_predict_pickup_displacement(pickup, forecast_seconds) - player_displacement).length()
			- collection_radius
		)
	)


func _predict_pickup_displacement(pickup: Dictionary, time: float) -> Vector2:
	var confidence: float = clamp(pickup.get("motion_confidence", 1.0), 0.0, 1.0)
	return pickup.relative_position + pickup.get("velocity", Vector2.ZERO) * confidence * time


func _first_circle_intersection_fraction(start: Vector2, finish: Vector2, radius: float) -> float:
	var segment: Vector2 = finish - start
	var a: float = segment.length_squared()
	var radius_squared: float = radius * radius
	if start.length_squared() <= radius_squared:
		return 0.0
	if a <= 0.000001:
		return -1.0
	var b: float = 2.0 * start.dot(segment)
	var c: float = start.length_squared() - radius_squared
	var discriminant: float = b * b - 4.0 * a * c
	if discriminant < 0.0:
		return -1.0
	var root: float = (-b - sqrt(discriminant)) / (2.0 * a)
	return root if root >= 0.0 and root <= 1.0 else -1.0
