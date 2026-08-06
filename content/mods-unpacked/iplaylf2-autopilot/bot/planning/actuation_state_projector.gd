extends Reference

# Advances a detached observation to the estimated instant when a background
# plan can reach the movement actuator. This is a causal state projection, not
# a gameplay policy: every candidate is evaluated from the same future instant
# under the movement input that remains active while planning runs.

const PlayerKinematicsModel := preload("player_kinematics_model.gd")
const ObservedMotionPredictor := preload("motion/observed_motion_predictor.gd")
const EnemyMotionPredictor := preload("motion/enemy_motion_predictor.gd")
const ProjectileMotionPredictor := preload("motion/projectile_motion_predictor.gd")

var _player_kinematics: Reference = PlayerKinematicsModel.new()
var _observed_motion_predictor: Reference = ObservedMotionPredictor.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _projectile_motion_predictor: Reference = ProjectileMotionPredictor.new()


func project(observation: Dictionary, active_movement: Vector2, delay_seconds: float) -> Dictionary:
	var delay := max(0.0, delay_seconds)
	var projected: Dictionary = observation.duplicate(true)
	if delay <= 0.0:
		return {
			"observation": projected,
			"delay_seconds": 0.0,
			"player_displacement": Vector2.ZERO,
		}

	var player_displacement: Vector2 = _player_kinematics.predict_displacement(
		observation, active_movement, delay
	)
	_project_wave_state(projected.wave_state, delay)
	_project_player_state(projected, active_movement, delay)
	_project_localization(projected.localization, player_displacement, delay)
	_project_enemy_tracks(projected.enemy_tracks, player_displacement, delay)
	_project_visible_world(projected.visible_world, player_displacement, delay)
	_project_remembered_entities(projected.remembered_entities, player_displacement, delay)
	return {
		"observation": projected,
		"delay_seconds": delay,
		"player_displacement": player_displacement,
	}


func _project_wave_state(wave_state: Dictionary, delay: float) -> void:
	wave_state.seconds_remaining = max(0.0, float(wave_state.seconds_remaining) - delay)


func _project_player_state(observation: Dictionary, active_movement: Vector2, delay: float) -> void:
	var player_state: Dictionary = observation.player_state
	var runtime_stats: Dictionary = player_state.runtime_stats
	runtime_stats.invincibility_seconds_remaining = max(
		0.0, float(runtime_stats.invincibility_seconds_remaining) - delay
	)
	for weapon in player_state.weapons:
		var timing: Dictionary = weapon.attack_model.timing
		timing.current_cooldown_seconds = max(0.0, float(timing.current_cooldown_seconds) - delay)
		timing.seconds_until_next_attack = max(0.0, float(timing.seconds_until_next_attack) - delay)
	var movement: Dictionary = player_state.movement
	movement.input_vector = active_movement
	movement.is_moving = active_movement != Vector2.ZERO
	movement.knockback_velocity = _player_kinematics.predict_knockback_velocity(observation, delay)
	var command_velocity := Vector2.ZERO
	if active_movement != Vector2.ZERO:
		command_velocity = active_movement.normalized() * float(runtime_stats.move_speed)
	movement.velocity = command_velocity + movement.knockback_velocity


func _project_localization(
	localization: Dictionary, player_displacement: Vector2, delay: float
) -> void:
	localization.odometry_position += player_displacement
	if localization.map_position != null:
		localization.map_position += player_displacement
	var bounds: Dictionary = localization.map_bounds
	if bounds.seen_left:
		bounds.distance_to_left = max(0.0, float(bounds.distance_to_left) + player_displacement.x)
	if bounds.seen_right:
		bounds.distance_to_right = max(0.0, float(bounds.distance_to_right) - player_displacement.x)
	if bounds.seen_top:
		bounds.distance_to_top = max(0.0, float(bounds.distance_to_top) + player_displacement.y)
	if bounds.seen_bottom:
		bounds.distance_to_bottom = max(
			0.0, float(bounds.distance_to_bottom) - player_displacement.y
		)
	for cell in localization.observation_cells:
		cell.seconds_since_observed += delay


func _project_enemy_tracks(tracks: Array, player_displacement: Vector2, delay: float) -> void:
	for track in tracks:
		var target_response: Dictionary = track.behavior_profile.get("target_position_response", {})
		track.relative_position = (
			_enemy_motion_predictor.predict_position(track, delay, player_displacement)
			- player_displacement
		)
		if not target_response.get("responds_to_target_position", false):
			track.estimated_velocity = _observed_motion_predictor.predict_velocity(
				track.estimated_velocity,
				track.estimated_acceleration,
				track.motion_confidence,
				delay
			)
			track.estimated_acceleration = _observed_motion_predictor.predict_acceleration(
				track.estimated_acceleration, delay
			)
		track.seconds_since_seen += delay
		_shift_window(track.behavior_profile.get("next_volley_window", {}), delay)
		_shift_window(track.behavior_profile.get("next_charge_attack_window", {}), delay)


func _project_visible_world(
	visible_world: Dictionary, player_displacement: Vector2, delay: float
) -> void:
	for key in ["trees", "allied_agents", "structures", "materials", "consumables"]:
		for entity in visible_world.get(key, []):
			_project_entity(entity, player_displacement, delay)
	for projectile in visible_world.enemy_projectiles:
		projectile.relative_position = (
			_projectile_motion_predictor.predict_position(projectile, delay)
			- player_displacement
		)
		projectile.velocity = _observed_motion_predictor.predict_velocity(
			projectile.velocity, projectile.acceleration, projectile.motion_confidence, delay
		)
		projectile.acceleration = _observed_motion_predictor.predict_acceleration(
			projectile.acceleration, delay
		)
		var motion_model: Dictionary = projectile.get("motion_model", {})
		if motion_model.get("kind", "linear") == "sinusoidal_velocity":
			motion_model.phase += motion_model.angular_velocity * delay
	for warning in visible_world.spawn_warnings:
		warning.relative_position -= player_displacement
		_shift_window(warning.get("resolution_window", {}), delay)


func _project_remembered_entities(
	entities: Array, player_displacement: Vector2, delay: float
) -> void:
	for entity in entities:
		_project_entity(entity, player_displacement, delay)
		if entity.has("last_observed_relative_position"):
			entity.last_observed_relative_position -= player_displacement
		entity.seconds_since_seen += delay


func _project_entity(entity: Dictionary, player_displacement: Vector2, delay: float) -> void:
	entity.relative_position = (
		_observed_motion_predictor.predict_position(
			entity.relative_position,
			entity.get("velocity", Vector2.ZERO),
			entity.get("acceleration", Vector2.ZERO),
			entity.get("motion_confidence", 0.0),
			delay
		)
		- player_displacement
	)
	if entity.has("velocity"):
		entity.velocity = _observed_motion_predictor.predict_velocity(
			entity.velocity,
			entity.get("acceleration", Vector2.ZERO),
			entity.get("motion_confidence", 0.0),
			delay
		)
	if entity.has("acceleration"):
		entity.acceleration = _observed_motion_predictor.predict_acceleration(
			entity.acceleration, delay
		)


func _shift_window(window: Dictionary, delay: float) -> void:
	if window.empty():
		return
	window.earliest_seconds = max(0.0, float(window.get("earliest_seconds", 0.0)) - delay)
	var latest = window.get("latest_seconds", INF)
	if latest != INF:
		window.latest_seconds = max(0.0, float(latest) - delay)
