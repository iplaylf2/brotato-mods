extends Reference

# Read-only first-order model derived from vanilla Unit.get_next_velocity():
# normalized movement input at move speed plus exponentially decaying knockback.

# Vanilla applies linear_interpolate(Vector2.ZERO, 0.1) once per 60 Hz tick:
# -60 * ln(0.9) = 6.32163094 per second.
const KNOCKBACK_DECAY_RATE := 6.32163094


func predict_displacement(
	observation: Dictionary, movement: Vector2, time_seconds: float
) -> Vector2:
	var command_velocity := _command_velocity(observation, movement)
	var disturbance := _observed_disturbance(observation)
	var disturbance_integral := (
		(1.0 - exp(-KNOCKBACK_DECAY_RATE * time_seconds))
		/ KNOCKBACK_DECAY_RATE
	)
	return command_velocity * time_seconds + disturbance * disturbance_integral


func predict_average_velocity(
	observation: Dictionary, movement: Vector2, time_seconds: float
) -> Vector2:
	return predict_displacement(observation, movement, time_seconds) / max(0.01, time_seconds)


func _command_velocity(observation: Dictionary, movement: Vector2) -> Vector2:
	if movement == Vector2.ZERO:
		return Vector2.ZERO
	return movement.normalized() * observation.player_state.runtime_stats.move_speed


func _observed_disturbance(observation: Dictionary) -> Vector2:
	var current_input: Vector2 = observation.player_state.movement.input_vector
	var current_command := _command_velocity(observation, current_input)
	return observation.player_state.movement.velocity - current_command
