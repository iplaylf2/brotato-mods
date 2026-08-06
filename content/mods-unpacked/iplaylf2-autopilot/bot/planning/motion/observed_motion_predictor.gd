extends Reference

# Extrapolates only observed motion. Acceleration decays quickly so a recent
# visible turn can inform the plan without assuming that intent persists.

const ACCELERATION_DECAY_SECONDS := 0.18


func predict_position(
	position: Vector2,
	velocity: Vector2,
	acceleration: Vector2,
	motion_confidence: float,
	time: float
) -> Vector2:
	var safe_time := max(0.0, time)
	var decay := ACCELERATION_DECAY_SECONDS
	var acceleration_displacement := (
		acceleration
		* clamp(motion_confidence, 0.0, 1.0)
		* decay
		* (safe_time - decay * (1.0 - exp(-safe_time / decay)))
	)
	return position + velocity * safe_time + acceleration_displacement


func predict_velocity(
	velocity: Vector2, acceleration: Vector2, motion_confidence: float, time: float
) -> Vector2:
	var safe_time := max(0.0, time)
	return (
		velocity
		+ (
			acceleration
			* clamp(motion_confidence, 0.0, 1.0)
			* ACCELERATION_DECAY_SECONDS
			* (1.0 - exp(-safe_time / ACCELERATION_DECAY_SECONDS))
		)
	)


func predict_acceleration(acceleration: Vector2, time: float) -> Vector2:
	return acceleration * exp(-max(0.0, time) / ACCELERATION_DECAY_SECONDS)
