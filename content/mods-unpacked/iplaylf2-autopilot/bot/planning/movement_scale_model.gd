extends Reference

# Derives shared spatial and collision horizons from observed player geometry,
# candidate movement speed, and the planning timing contract. This replaces
# nominal-player constants that were duplicated across predictors.

const MovementPlanningTiming := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_planning_timing.gd"
)
const PlayerKinematicsModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_kinematics_model.gd"
)

var _player_kinematics: Reference = PlayerKinematicsModel.new()
var _cached_physics_frame := -1
var _cached_scale := {}


func derive(observation: Dictionary) -> Dictionary:
	var physics_frame: int = int(observation.get("physics_frame", -1))
	if physics_frame >= 0 and physics_frame == _cached_physics_frame:
		return _cached_scale
	var player_radius: float = max(1.0, float(observation.player_state.collision_radius))
	var command_speed: float = max(1.0, _player_kinematics.predict_command_speed(observation, true))
	var control_distance := command_speed * MovementPlanningTiming.CONTROL_INTERVAL_SECONDS
	var minimum_reaction_distance := (
		command_speed
		* MovementPlanningTiming.LOCAL_FORECAST_MIN_SECONDS
	)
	var default_reaction_distance := (
		command_speed
		* MovementPlanningTiming.LOCAL_FORECAST_DEFAULT_SECONDS
	)
	_cached_physics_frame = physics_frame
	_cached_scale = {
		"player_radius": player_radius,
		"command_speed": command_speed,
		"control_distance": control_distance,
		"minimum_reaction_distance": minimum_reaction_distance,
		"default_reaction_distance": default_reaction_distance,
		"enemy_pressure_distance": max(player_radius * 3.0, default_reaction_distance),
		"projectile_pressure_distance": max(player_radius * 2.0, minimum_reaction_distance),
		"encounter_margin": default_reaction_distance,
		"edge_margin": player_radius + control_distance,
		"ally_body_margin": player_radius + control_distance,
		"roaming_distance":
		max(1.0, command_speed * MovementPlanningTiming.NAVIGATION_FORECAST_MAX_SECONDS),
		"ttc_risk_seconds": MovementPlanningTiming.LOCAL_FORECAST_MAX_SECONDS,
		"maximum_collision_seconds": MovementPlanningTiming.NAVIGATION_FORECAST_MAX_SECONDS,
	}
	return _cached_scale
