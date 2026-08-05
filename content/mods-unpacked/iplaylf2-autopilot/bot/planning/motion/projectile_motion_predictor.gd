extends Reference

# Owns resolved projectile motion and its conservative displacement bound from
# the public trajectory contract. The sinusoidal branch analytically integrates
# vanilla's velocity offset; reachability consumers share its bounded excursion
# instead of independently inflating known curvature.

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


func maximum_displacement(projectile: Dictionary, time: float) -> float:
	var safe_time := max(0.0, time)
	var result: float = (
		projectile.velocity.length() * safe_time
		+ 0.5 * projectile.acceleration.length() * safe_time * safe_time
	)
	var model: Dictionary = projectile.get("motion_model", {"kind": "linear"})
	if model.kind != "sinusoidal_velocity":
		return result
	var amplitude: Vector2 = model.velocity_amplitude
	var angular_velocity: Vector2 = model.angular_velocity
	return (
		result
		+ _maximum_integrated_axis_excursion(amplitude.x, angular_velocity.x, safe_time)
		+ _maximum_integrated_axis_excursion(amplitude.y, angular_velocity.y, safe_time)
	)


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


func _maximum_integrated_axis_excursion(
	amplitude: float, angular_velocity: float, time: float
) -> float:
	if abs(angular_velocity) <= 0.0001:
		return abs(amplitude) * time
	return min(abs(amplitude) * time, 2.0 * abs(amplitude / angular_velocity))
