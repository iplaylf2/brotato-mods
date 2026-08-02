extends Reference

# Discretizes the feasible movement-input space for the next control interval.
# Forecast duration follows observed encounter timing; it is not an execution
# commitment. Zero velocity is the origin of the same action space, not a mode.

const MIN_FORECAST_SECONDS := 0.18
const DEFAULT_FORECAST_SECONDS := 0.45
const MAX_FORECAST_SECONDS := 0.7
const ENCOUNTER_MARGIN := 120.0
const PLAYER_RADIUS := 24.0
const PlayerKinematicsModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_kinematics_model.gd"
)

var _player_kinematics: Reference = PlayerKinematicsModel.new()


func generate(
	observation: Dictionary, search_budget: Dictionary, navigation_graph: Dictionary
) -> Array:
	var forecast_seconds := _forecast_window(observation)
	var sample_count: int = search_budget.forecast_sample_count
	var directions := _candidate_directions(search_budget.direction_count, navigation_graph)
	var actions := [
		_make_action(observation, "no_movement_input", Vector2.ZERO, forecast_seconds, sample_count)
	]
	for direction_index in directions.size():
		actions.push_back(
			_make_action(
				observation,
				"movement_input_%s" % direction_index,
				directions[direction_index],
				forecast_seconds,
				sample_count
			)
		)
	return actions


func _make_action(
	observation: Dictionary,
	action_id: String,
	movement: Vector2,
	forecast_seconds: float,
	sample_count: int
) -> Dictionary:
	var samples := []
	for step in range(1, sample_count + 1):
		# Quadratic spacing is dense near the actually executed 0.1 s interval and
		# coarse at the speculative end of the forecast.
		var fraction: float = pow(float(step) / float(sample_count), 1.55)
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


func _candidate_directions(direction_count: int, navigation_graph: Dictionary) -> Array:
	var result := []
	for direction_index in direction_count:
		result.push_back(
			Vector2.RIGHT.rotated(TAU * float(direction_index) / float(direction_count))
		)
	for preferred in navigation_graph.preferred_directions:
		if not _has_similar_direction(result, preferred):
			result.push_back(preferred)
	return result


func _forecast_window(observation: Dictionary) -> float:
	var nearest_encounter := INF
	var player_velocity: Vector2 = observation.player_state.movement.velocity
	for track in observation.enemy_tracks:
		var relative_velocity: Vector2 = track.estimated_velocity - player_velocity
		nearest_encounter = min(
			nearest_encounter,
			_encounter_time(
				track.relative_position,
				relative_velocity,
				PLAYER_RADIUS + track.last_measurement.visual_radius + ENCOUNTER_MARGIN
			)
		)
	for projectile in observation.visible_world.enemy_projectiles:
		var relative_velocity: Vector2 = projectile.velocity - player_velocity
		nearest_encounter = min(
			nearest_encounter,
			_encounter_time(
				projectile.relative_position,
				relative_velocity,
				PLAYER_RADIUS + projectile.visual_radius + ENCOUNTER_MARGIN
			)
		)
	if nearest_encounter == INF:
		return DEFAULT_FORECAST_SECONDS
	return clamp(nearest_encounter + 0.12, MIN_FORECAST_SECONDS, MAX_FORECAST_SECONDS)


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
