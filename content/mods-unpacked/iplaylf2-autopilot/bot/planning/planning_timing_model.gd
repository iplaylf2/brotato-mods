extends Reference

# Planning cadence and prediction horizons are derived from the physics clock and
# the distance the current player can traverse relative to their collision
# diameter. The only scheduling choice is an integer number of physics ticks;
# all prediction horizons follow from the rolling-control contract rather than
# independent wall-clock constants.

const TACTICAL_CONTROL_PHYSICS_TICKS := 3
const STRATEGIC_NAVIGATION_GUIDANCE_TACTICAL_CONTROL_STEPS := 4
const STRATEGIC_NAVIGATION_GUIDANCE_MAX_AGE_INTERVALS := 2
const NEAR_TERM_HORIZON_TACTICAL_CONTROL_STEPS := 4
const DEFAULT_LOCAL_HORIZON_TACTICAL_CONTROL_STEPS := 8
const LOCAL_HORIZON_EXTENSION_TACTICAL_CONTROL_STEPS := 6
const NAVIGATION_HORIZON_EXTENSION_TACTICAL_CONTROL_STEPS := 10
const DEFAULT_LOCAL_HORIZON_COLLISION_DIAMETERS := 2.0


static func tactical_control_interval_seconds() -> float:
	return float(TACTICAL_CONTROL_PHYSICS_TICKS) / max(1.0, float(Engine.iterations_per_second))


static func strategic_guidance_interval_seconds() -> float:
	return (
		tactical_control_interval_seconds()
		* STRATEGIC_NAVIGATION_GUIDANCE_TACTICAL_CONTROL_STEPS
	)


static func strategic_guidance_interval_physics_ticks() -> int:
	return TACTICAL_CONTROL_PHYSICS_TICKS * STRATEGIC_NAVIGATION_GUIDANCE_TACTICAL_CONTROL_STEPS


static func strategic_guidance_max_age_physics_ticks() -> int:
	return (
		strategic_guidance_interval_physics_ticks()
		* STRATEGIC_NAVIGATION_GUIDANCE_MAX_AGE_INTERVALS
	)


static func clip_to_wave_remaining(observation: Dictionary, horizon_seconds: float) -> float:
	return min(max(0.0, horizon_seconds), max(0.0, float(observation.wave_state.seconds_remaining)))


static func derive(observation: Dictionary) -> Dictionary:
	var tactical_control_interval: float = tactical_control_interval_seconds()
	var player_radius: float = observation.player_state.collision_radius
	var command_speed: float = max(1.0, observation.player_state.runtime_stats.move_speed)
	# A useful local horizon must contain several future control corrections and
	# enough travel to clear more than one body width at the current speed.
	var collision_traversal_seconds: float = (
		DEFAULT_LOCAL_HORIZON_COLLISION_DIAMETERS
		* (2.0 * player_radius)
		/ command_speed
	)
	var default_local_horizon: float = max(
		DEFAULT_LOCAL_HORIZON_TACTICAL_CONTROL_STEPS * tactical_control_interval,
		collision_traversal_seconds
	)
	var maximum_local_horizon: float = (
		default_local_horizon
		+ LOCAL_HORIZON_EXTENSION_TACTICAL_CONTROL_STEPS * tactical_control_interval
	)
	var maximum_navigation_horizon: float = (
		maximum_local_horizon
		+ NAVIGATION_HORIZON_EXTENSION_TACTICAL_CONTROL_STEPS * tactical_control_interval
	)
	return {
		"tactical_control_interval_seconds": tactical_control_interval,
		"near_term_horizon_seconds":
		NEAR_TERM_HORIZON_TACTICAL_CONTROL_STEPS * tactical_control_interval,
		"default_local_horizon_seconds": default_local_horizon,
		"maximum_local_horizon_seconds": maximum_local_horizon,
		"maximum_navigation_horizon_seconds": maximum_navigation_horizon,
		"effective_local_horizon_seconds":
		clip_to_wave_remaining(observation, maximum_local_horizon),
		"effective_navigation_horizon_seconds":
		clip_to_wave_remaining(observation, maximum_navigation_horizon),
	}
