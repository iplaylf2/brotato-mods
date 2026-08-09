extends Reference

# Discretizes the feasible movement-input space for the next control interval.
# All candidates share one comparison horizon, extended when local player and
# threat reach domains can overlap. It is not an execution commitment. Zero
# velocity is the origin of the same action space, not a mode.

const PlanningTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/planning_timing_model.gd"
)
const PlayerKinematicsModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_kinematics_model.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const ProjectileMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/projectile_motion_predictor.gd"
)

const MAX_PROJECTILE_PHASE_STEP := PI / 2.0

var _player_kinematics: Reference = PlayerKinematicsModel.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _projectile_motion_predictor: Reference = ProjectileMotionPredictor.new()


func generate(observation: Dictionary, navigation_intent: Dictionary) -> Array:
	var timing: Dictionary = PlanningTimingModel.derive(observation)
	var forecast_seconds := _forecast_window(observation, timing)
	var sample_count := _forecast_sample_count(observation, forecast_seconds, timing)
	var direction_count: int = _movement_geometry.derive(observation).direction_count
	var directions := _candidate_directions(direction_count, navigation_intent)
	var actions := [
		_make_action(observation, "no_movement_input", Vector2.ZERO, forecast_seconds, sample_count)
	]
	for direction_index in directions.size():
		var direction: Vector2 = directions[direction_index]
		actions.push_back(
			_make_action(
				observation,
				"movement_input_%s" % direction_index,
				direction,
				forecast_seconds,
				sample_count
			)
		)
	return actions


func make_refined_action(
	observation: Dictionary,
	direction: Vector2,
	forecast_template: Dictionary,
	refined_action_index: int
) -> Dictionary:
	return _make_action(
		observation,
		"refined_movement_input_%s" % refined_action_index,
		direction.normalized(),
		forecast_template.forecast_seconds,
		forecast_template.samples.size()
	)


func _make_action(
	observation: Dictionary,
	action_id: String,
	movement: Vector2,
	forecast_seconds: float,
	sample_count: int
) -> Dictionary:
	var samples := []
	for step in range(1, sample_count + 1):
		# Equal spacing makes the maximum swept segment explicit: sample_count is
		# derived so neither player travel nor deterministic curve phase jumps over
		# its geometric resolution.
		var fraction: float = float(step) / float(sample_count)
		var time := forecast_seconds * fraction
		samples.push_back(
			{
				"time": time,
				"displacement":
				_player_kinematics.predict_displacement(observation, movement, time),
				"movement": movement,
			}
		)
	return {
		"action_id": action_id,
		"movement": movement,
		"forecast_seconds": forecast_seconds,
		"samples": samples,
	}


func _candidate_directions(direction_count: int, navigation_intent: Dictionary) -> Array:
	var result := []
	# Physical influence time and collision geometry derive the uniform lattice.
	# Every heading receives the unchanged swept-collision sampling contract.
	for direction_index in direction_count:
		result.push_back(
			Vector2.RIGHT.rotated(TAU * float(direction_index) / float(direction_count))
		)
	# A navigation direction reaches the executable set only after the trajectory
	# field has scored it. Uniform actions remain the geometry-owned baseline.
	var movement_preference: Vector2 = navigation_intent.movement_preference
	if movement_preference != Vector2.ZERO:
		var preferred_direction := movement_preference.normalized()
		if not _has_similar_direction(result, preferred_direction):
			result.push_back(preferred_direction)
	return result


func _forecast_window(observation: Dictionary, timing: Dictionary) -> float:
	# Detailed collision, pickup, rule, and weapon projection has sharply
	# diminishing value beyond the near-term controllability horizon: only the first
	# control interval is committed before replanning, and the strategic value field
	# already owns longer consequences. Keeping one invariant window also prevents
	# enemy density from increasing both per-action cost and search-space starvation.
	return PlanningTimingModel.clip_to_wave_remaining(observation, timing.near_term_horizon_seconds)


func _forecast_sample_count(
	observation: Dictionary, forecast_seconds: float, timing: Dictionary
) -> int:
	var geometry: Dictionary = _movement_geometry.derive(observation)
	var collision_diameter: float = max(1.0, geometry.player_radius * 2.0)
	var spatial_samples := int(ceil(geometry.command_speed * forecast_seconds / collision_diameter))
	var phase_samples := 1
	for projectile in observation.visible_world.enemy_projectiles:
		phase_samples = max(
			phase_samples,
			int(
				ceil(
					(
						_projectile_motion_predictor.maximum_angular_velocity(projectile)
						* forecast_seconds
						/ MAX_PROJECTILE_PHASE_STEP
					)
				)
			)
		)
	# At least one sample per future control commitment keeps temporal events and
	# spatial sweeps on the same resolution contract.
	var control_samples := int(ceil(forecast_seconds / timing.tactical_control_interval_seconds))
	return int(max(max(1, spatial_samples), max(phase_samples, control_samples)))


func _has_similar_direction(directions: Array, candidate: Vector2) -> bool:
	for direction in directions:
		if direction.dot(candidate) > 0.97:
			return true
	return false
