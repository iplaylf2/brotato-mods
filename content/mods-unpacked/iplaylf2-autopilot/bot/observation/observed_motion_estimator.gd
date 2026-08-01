extends Reference

# Derives motion from successive visible positions. Source nodes are used only
# as private continuity tokens and are never copied into the public observation.

const MAX_SAMPLE_GAP_SECONDS := 0.2
const MAX_ACCELERATION := 1800.0
const ACCELERATION_SMOOTHING := 0.3
const FORGET_AFTER_SECONDS := 1.0

var _elapsed_seconds := 0.0
var _samples := {}


func update(observations: Array, delta_seconds: float) -> void:
	_elapsed_seconds += max(0.0, delta_seconds)
	for observation in observations:
		_update_observation(observation)
	_forget_stale_samples()


func _update_observation(observation: Dictionary) -> void:
	var source = observation._source
	var position: Vector2 = observation._world_position
	var velocity: Vector2 = observation.velocity
	var acceleration := Vector2.ZERO
	var sample_count := 1
	var previous = _samples.get(source)
	if previous != null:
		var elapsed: float = _elapsed_seconds - previous.observed_at_seconds
		if elapsed > 0.0 and elapsed <= MAX_SAMPLE_GAP_SECONDS:
			velocity = (position - previous.position) / elapsed
			var measured_acceleration: Vector2 = (velocity - previous.velocity) / elapsed
			acceleration = previous.acceleration.linear_interpolate(
				measured_acceleration, ACCELERATION_SMOOTHING
			)
			acceleration = acceleration.clamped(MAX_ACCELERATION)
			sample_count = previous.sample_count + 1

	observation.velocity = velocity
	observation.acceleration = acceleration
	observation.motion_confidence = clamp(float(sample_count - 1) / 3.0, 0.0, 1.0)
	_samples[source] = {
		"position": position,
		"velocity": velocity,
		"acceleration": acceleration,
		"sample_count": sample_count,
		"observed_at_seconds": _elapsed_seconds,
	}


func _forget_stale_samples() -> void:
	for source in _samples.keys():
		if (
			not is_instance_valid(source)
			or _elapsed_seconds - _samples[source].observed_at_seconds > FORGET_AFTER_SECONDS
		):
			_samples.erase(source)
