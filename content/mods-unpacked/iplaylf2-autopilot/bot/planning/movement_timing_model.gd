extends Reference

# Control cadence and prediction horizons are derived from the physics clock and
# the distance the current player can traverse relative to their collision
# diameter. The only scheduling choice is an integer number of physics ticks;
# all prediction horizons follow from the rolling-control contract rather than
# independent wall-clock constants.

const REPLAN_PHYSICS_TICKS := 6
const NEAR_TERM_HORIZON_CONTROL_STEPS := 2
const DEFAULT_LOCAL_HORIZON_CONTROL_STEPS := 4
const LOCAL_HORIZON_EXTENSION_CONTROL_STEPS := 3
const NAVIGATION_HORIZON_EXTENSION_CONTROL_STEPS := 5
const DEFAULT_LOCAL_HORIZON_COLLISION_DIAMETERS := 2.0


static func control_interval_seconds() -> float:
	return float(REPLAN_PHYSICS_TICKS) / max(1.0, float(Engine.iterations_per_second))


static func clip_to_wave_remaining(observation: Dictionary, horizon_seconds: float) -> float:
	return min(max(0.0, horizon_seconds), max(0.0, float(observation.wave_state.seconds_remaining)))


static func derive(observation: Dictionary) -> Dictionary:
	var control_interval: float = control_interval_seconds()
	var player_radius: float = max(1.0, observation.player_state.collision_radius)
	var command_speed: float = max(1.0, observation.player_state.runtime_stats.move_speed)
	# A useful local horizon must contain several future control corrections and
	# enough travel to clear more than one body width at the current speed.
	var collision_traversal_seconds: float = (
		DEFAULT_LOCAL_HORIZON_COLLISION_DIAMETERS
		* (2.0 * player_radius)
		/ command_speed
	)
	var default_local_horizon: float = max(
		DEFAULT_LOCAL_HORIZON_CONTROL_STEPS * control_interval, collision_traversal_seconds
	)
	var maximum_local_horizon: float = (
		default_local_horizon
		+ LOCAL_HORIZON_EXTENSION_CONTROL_STEPS * control_interval
	)
	var maximum_navigation_horizon: float = (
		maximum_local_horizon
		+ NAVIGATION_HORIZON_EXTENSION_CONTROL_STEPS * control_interval
	)
	return {
		"control_interval_seconds": control_interval,
		"near_term_horizon_seconds": NEAR_TERM_HORIZON_CONTROL_STEPS * control_interval,
		"default_local_horizon_seconds": default_local_horizon,
		"maximum_local_horizon_seconds": maximum_local_horizon,
		"maximum_navigation_horizon_seconds": maximum_navigation_horizon,
		"effective_local_horizon_seconds":
		clip_to_wave_remaining(observation, maximum_local_horizon),
		"effective_navigation_horizon_seconds":
		clip_to_wave_remaining(observation, maximum_navigation_horizon),
	}
