extends Reference

# Derives a resolution window from stable full duration and per-player visible
# history. It does not read the per-instance private countdown.

var _elapsed_seconds := 0.0
var _sightings := {}


func advance_time(delta_seconds: float) -> void:
	_elapsed_seconds += max(0.0, delta_seconds)


func estimate(
	warning_key: int, world_position: Vector2, full_duration_seconds: float
) -> Dictionary:
	var sighting: Dictionary = _sightings.get(warning_key, {})
	if sighting.empty() or sighting.world_position != world_position:
		sighting = {
			"first_observed_at_seconds": _elapsed_seconds,
			"world_position": world_position,
		}
		_sightings[warning_key] = sighting
	var observed_age: float = max(0.0, _elapsed_seconds - sighting.first_observed_at_seconds)
	var latest_seconds := max(0.0, full_duration_seconds - observed_age)
	return {
		"is_exact": latest_seconds == 0.0,
		"earliest_seconds": 0.0,
		"latest_seconds": latest_seconds,
	}


func retain_sightings(live_warning_keys: Dictionary) -> void:
	for warning_key in _sightings.keys():
		if not live_warning_keys.has(warning_key):
			_sightings.erase(warning_key)
