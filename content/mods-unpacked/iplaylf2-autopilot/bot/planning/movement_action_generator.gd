extends Reference

# Discretizes the feasible movement-input space for the next control interval.
# Forecast duration follows observed encounter timing; it is not an execution
# commitment. Zero velocity is the origin of the same action space, not a mode.

const MovementTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_timing_model.gd"
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

const BASELINE_DIRECTION_COUNT := 8
const MAX_PROJECTILE_PHASE_STEP := PI / 2.0

var _player_kinematics: Reference = PlayerKinematicsModel.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _projectile_motion_predictor: Reference = ProjectileMotionPredictor.new()


func generate(observation: Dictionary, navigation_intent: Dictionary) -> Array:
	var timing: Dictionary = MovementTimingModel.derive(observation)
	var forecast_seconds := _forecast_window(observation, timing)
	var sample_count := _forecast_sample_count(observation, forecast_seconds, timing)
	var direction_count: int = _movement_geometry.derive(observation).direction_count
	var directions := _candidate_directions(direction_count, navigation_intent)
	var actions := [
		_make_action(
			observation, "no_movement_input", Vector2.ZERO, forecast_seconds, sample_count, true
		)
	]
	for direction_index in directions.size():
		var direction: Vector2 = directions[direction_index]
		actions.push_back(
			_make_action(
				observation,
				"movement_input_%s" % direction_index,
				direction,
				forecast_seconds,
				sample_count,
				_is_baseline_direction(direction, navigation_intent)
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
		forecast_template.samples.size(),
		false
	)


func _make_action(
	observation: Dictionary,
	action_id: String,
	movement: Vector2,
	forecast_seconds: float,
	sample_count: int,
	is_baseline_candidate: bool
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
		"is_baseline_candidate": is_baseline_candidate,
	}


func _candidate_directions(direction_count: int, navigation_intent: Dictionary) -> Array:
	var result := []
	for direction_index in direction_count:
		result.push_back(
			Vector2.RIGHT.rotated(TAU * float(direction_index) / float(direction_count))
		)
	# The geometry-derived lattice owns escape resolution. The octants own smooth
	# baseline comparison and are added independently when the two grids do not
	# share an angle.
	for baseline_index in BASELINE_DIRECTION_COUNT:
		var baseline_direction := Vector2.RIGHT.rotated(
			TAU * float(baseline_index) / float(BASELINE_DIRECTION_COUNT)
		)
		if not _has_similar_direction(result, baseline_direction):
			result.push_back(baseline_direction)
	var movement_preference: Vector2 = navigation_intent.movement_preference
	if movement_preference != Vector2.ZERO:
		var preferred_direction := movement_preference.normalized()
		if not _has_similar_direction(result, preferred_direction):
			result.push_back(preferred_direction)
	return result


func _forecast_window(observation: Dictionary, timing: Dictionary) -> float:
	var nearest_encounter := INF
	var player_velocity: Vector2 = _player_kinematics.predict_average_velocity(
		observation,
		observation.player_state.movement.input_vector,
		timing.near_term_horizon_seconds
	)
	var geometry: Dictionary = _movement_geometry.derive(observation)
	for track in observation.enemy_tracks:
		var relative_velocity: Vector2 = track.estimated_velocity - player_velocity
		nearest_encounter = min(
			nearest_encounter,
			_encounter_time(
				track.relative_position,
				relative_velocity,
				(
					geometry.player_radius
					+ track.last_measurement.visual_radius
					+ geometry.encounter_margin
				)
			)
		)
	for projectile in observation.visible_world.enemy_projectiles:
		var projectile_displacement: Vector2 = (
			_projectile_motion_predictor.predict_position(
				projectile, timing.default_local_horizon_seconds
			)
			- projectile.relative_position
		)
		var relative_velocity: Vector2 = (
			projectile_displacement / timing.default_local_horizon_seconds
			- player_velocity
		)
		nearest_encounter = min(
			nearest_encounter,
			_encounter_time(
				projectile.relative_position,
				relative_velocity,
				geometry.player_radius + projectile.visual_radius + geometry.encounter_margin
			)
		)
	if nearest_encounter == INF:
		return timing.default_local_horizon_seconds
	return clamp(
		nearest_encounter + timing.control_interval_seconds,
		timing.default_local_horizon_seconds,
		timing.maximum_local_horizon_seconds
	)


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
	var control_samples := int(ceil(forecast_seconds / timing.control_interval_seconds))
	return int(max(max(1, spatial_samples), max(phase_samples, control_samples)))


func _is_baseline_direction(direction: Vector2, navigation_intent: Dictionary) -> bool:
	var baseline_step := TAU / float(BASELINE_DIRECTION_COUNT)
	var nearest_baseline_angle := round(direction.angle() / baseline_step) * baseline_step
	if abs(wrapf(direction.angle() - nearest_baseline_angle, -PI, PI)) <= 0.001:
		return true
	var preference: Vector2 = navigation_intent.movement_preference
	return preference != Vector2.ZERO and direction.dot(preference.normalized()) > 0.999


func _encounter_time(position: Vector2, velocity: Vector2, threat_radius: float) -> float:
	var speed_squared := velocity.length_squared()
	if speed_squared <= 1.0:
		return 0.0 if position.length() <= threat_radius else INF
	var closest_time := max(0.0, -position.dot(velocity) / speed_squared)
	var closest_distance := (position + velocity * closest_time).length()
	return closest_time if closest_distance <= threat_radius else INF


func _has_similar_direction(directions: Array, candidate: Vector2) -> bool:
	for direction in directions:
		if direction.dot(candidate) > 0.97:
			return true
	return false
