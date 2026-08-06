extends Reference

# Read-only first-order model derived from vanilla Unit.get_next_velocity():
# normalized movement input at move speed plus exponentially decaying knockback.

# Vanilla applies linear_interpolate(Vector2.ZERO, 0.1) once per 60 Hz tick:
# -60 * ln(0.9) = 6.32163094 per second.
const KNOCKBACK_DECAY_RATE := 6.32163094
const PlayerMovementStateProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_movement_state_projector.gd"
)

var _movement_state_projector: Reference = PlayerMovementStateProjector.new()


func predict_displacement(
	observation: Dictionary, movement: Vector2, time_seconds: float
) -> Vector2:
	var command_velocity := _command_velocity(observation, movement)
	var disturbance := _observed_disturbance(observation)
	var disturbance_integral := (
		(1.0 - exp(-KNOCKBACK_DECAY_RATE * time_seconds))
		/ KNOCKBACK_DECAY_RATE
	)
	var unconstrained_displacement := (
		command_velocity * time_seconds
		+ disturbance * disturbance_integral
	)
	return _clamp_to_observed_zone(observation, unconstrained_displacement)


func predict_average_velocity(
	observation: Dictionary, movement: Vector2, time_seconds: float
) -> Vector2:
	return predict_displacement(observation, movement, time_seconds) / max(0.01, time_seconds)


func predict_knockback_velocity(observation: Dictionary, time_seconds: float) -> Vector2:
	return _observed_disturbance(observation) * exp(-KNOCKBACK_DECAY_RATE * max(0.0, time_seconds))


func predict_command_speed(observation: Dictionary, is_moving: bool) -> float:
	if not is_moving:
		return 0.0
	var projected: Dictionary = _movement_state_projector.project_runtime_stats(observation, true)
	return projected.move_speed


func _command_velocity(observation: Dictionary, movement: Vector2) -> Vector2:
	if movement == Vector2.ZERO:
		return Vector2.ZERO
	return movement.normalized() * predict_command_speed(observation, true)


func _observed_disturbance(observation: Dictionary) -> Vector2:
	return observation.player_state.movement.knockback_velocity


func _clamp_to_observed_zone(observation: Dictionary, displacement: Vector2) -> Vector2:
	# Vanilla Unit clamps the next body origin to the zone rectangle on each
	# physics tick. A known boundary therefore removes displacement; it is not an
	# obstacle that a utility penalty may choose to cross. Unknown boundaries stay
	# unconstrained until the player has legally observed them.
	var bounds: Dictionary = observation.localization.map_bounds
	var result := displacement
	if bounds.seen_left:
		result.x = max(result.x, -float(bounds.distance_to_left))
	if bounds.seen_right:
		result.x = min(result.x, float(bounds.distance_to_right))
	if bounds.seen_top:
		result.y = max(result.y, -float(bounds.distance_to_top))
	if bounds.seen_bottom:
		result.y = min(result.y, float(bounds.distance_to_bottom))
	return result
