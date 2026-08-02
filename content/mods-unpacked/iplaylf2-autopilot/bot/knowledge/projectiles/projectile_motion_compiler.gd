extends Reference

# Compiles the resolved motion law of an already-visible projectile. Random
# launch direction, spread, and speed have already become observable velocity;
# deterministic phase is transparent, while future unresolved random rolls are
# never read here.


func compile(projectile: Node) -> Dictionary:
	var result := {"kind": "linear"}
	if "sinusoidal_motion" in projectile:
		var sinusoidal_motion: Vector2 = projectile.sinusoidal_motion
		if sinusoidal_motion != Vector2.ZERO:
			result = {
				"kind": "sinusoidal_velocity",
				"velocity_amplitude": sinusoidal_motion * 0.5,
				"angular_velocity": projectile.sinusoidal_motion_speed,
				"phase": projectile.sinusoidal_time,
			}
	return result
