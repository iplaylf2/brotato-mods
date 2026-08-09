extends Reference

# Derives shared movement geometry from observed player dimensions,
# candidate movement speed, and the movement timing model. This replaces
# nominal-player constants that were duplicated across predictors.

const PlanningTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/planning_timing_model.gd"
)
const PlayerKinematicsModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_kinematics_model.gd"
)

var _player_kinematics: Reference = PlayerKinematicsModel.new()
var _cached_physics_frame := -1
var _cached_geometry := {}


func derive(observation: Dictionary) -> Dictionary:
	var physics_frame: int = int(observation.get("physics_frame", -1))
	if physics_frame >= 0 and physics_frame == _cached_physics_frame:
		return _cached_geometry
	var player_radius: float = float(observation.player_state.collision_radius)
	var command_speed: float = max(1.0, _player_kinematics.predict_command_speed(observation, true))
	var timing: Dictionary = PlanningTimingModel.derive(observation)
	var control_distance: float = command_speed * timing.tactical_control_interval_seconds
	var near_term_distance: float = command_speed * timing.near_term_horizon_seconds
	var default_local_horizon_distance: float = command_speed * timing.default_local_horizon_seconds
	var direction_count: int = _direction_count(player_radius, control_distance)
	_cached_physics_frame = physics_frame
	_cached_geometry = {
		"player_radius": player_radius,
		"command_speed": command_speed,
		"control_distance": control_distance,
		"direction_count": direction_count,
		"near_term_distance": near_term_distance,
		"default_local_horizon_distance": default_local_horizon_distance,
		"enemy_pressure_distance": max(player_radius * 3.0, default_local_horizon_distance),
		"projectile_pressure_distance": max(player_radius * 2.0, near_term_distance),
		"encounter_margin": default_local_horizon_distance,
		# Reserve one default-local-horizon movement distance for turning near a boundary.
		"edge_margin": player_radius + default_local_horizon_distance,
		"ally_body_margin": player_radius + control_distance,
		"local_prediction_radius": command_speed * timing.effective_local_horizon_seconds,
		"opportunity_reach_distance":
		# Structural range for map discovery; unlike actionable opportunity reach,
		max(1.0, command_speed * timing.effective_navigation_horizon_seconds),
		# unknown map extent must not collapse as the wave clock expires.
		"roaming_distance": max(1.0, command_speed * timing.maximum_navigation_horizon_seconds),
	}
	return _cached_geometry


func _direction_count(player_radius: float, control_distance: float) -> int:
	# Adjacent commands may not end the committed control interval more than one
	# player radius apart. This converts collision geometry into angular fidelity.
	if control_distance <= player_radius * 0.5:
		return 4
	var half_angle := asin(clamp(player_radius / (2.0 * control_distance), 0.0, 1.0))
	var count := int(ceil(PI / max(0.01, half_angle)))
	return int(max(4, count + count % 2))
