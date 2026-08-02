extends Reference

# Predicts resolved projectile motion from the public trajectory contract. The
# sinusoidal branch is the analytic integral of vanilla's velocity offset, so it
# neither estimates phase from recent samples nor turns known curvature into an
# ever-growing collision radius.

const ObservedMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/observed_motion_predictor.gd"
)

var _observed_motion_predictor: Reference = ObservedMotionPredictor.new()


func predict_position(projectile: Dictionary, time: float) -> Vector2:
	var safe_time := max(0.0, time)
	var model: Dictionary = projectile.get("motion_model", {"kind": "linear"})
	if model.kind != "sinusoidal_velocity":
		return _observed_motion_predictor.predict_position(
			projectile.relative_position,
			projectile.velocity,
			projectile.acceleration,
			projectile.motion_confidence,
			safe_time
		)
	return (
		projectile.relative_position
		+ projectile.velocity * safe_time
		+ _sinusoidal_displacement(model, safe_time)
	)


func maximum_angular_velocity(projectile: Dictionary) -> float:
	var model: Dictionary = projectile.get("motion_model", {"kind": "linear"})
	if model.kind != "sinusoidal_velocity":
		return 0.0
	var angular_velocity: Vector2 = model.angular_velocity
	return max(abs(angular_velocity.x), abs(angular_velocity.y))


func _sinusoidal_displacement(model: Dictionary, time: float) -> Vector2:
	var phase: Vector2 = model.phase
	var angular_velocity: Vector2 = model.angular_velocity
	var amplitude: Vector2 = model.velocity_amplitude
	return Vector2(
		_integrated_axis(amplitude.x, angular_velocity.x, phase.x, time),
		_integrated_axis(amplitude.y, angular_velocity.y, phase.y, time)
	)


func _integrated_axis(
	amplitude: float, angular_velocity: float, phase: float, time: float
) -> float:
	if abs(angular_velocity) <= 0.0001:
		return amplitude * sin(phase) * time
	return amplitude * (cos(phase) - cos(phase + angular_velocity * time)) / angular_velocity
