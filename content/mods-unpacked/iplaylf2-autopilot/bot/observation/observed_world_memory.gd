extends Reference

# Ephemeral memory of the world observed by one player in one battle. Hidden
# enemies are never refreshed from game state: estimates age and expire.

const TRACK_MEMORY_SECONDS := 4.0
const BASE_UNCERTAINTY := 24.0
const UNCERTAINTY_PER_SECOND := 80.0
const VELOCITY_UNCERTAINTY_FACTOR := 0.35
const REACQUISITION_MARGIN := 72.0
const VISUAL_RADIUS_REACQUISITION_TOLERANCE := 12.0
const EnemyBehaviorProfiler := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/enemy_behavior_profiler.gd"
)

var _elapsed_seconds := 0.0
var _next_track_id := 1
var _odometry_position := Vector2.ZERO
var _observed_edge_coordinates := {"left": null, "right": null, "top": null, "bottom": null}
var _tracks := {}
var _visible_source_track_ids := {}
var _enemy_profiler: Reference = EnemyBehaviorProfiler.new()


func update(
	delta_seconds: float, position_delta: Vector2, visible_edges: Dictionary, visible_enemies: Array
) -> void:
	_elapsed_seconds += delta_seconds
	_odometry_position += position_delta
	_record_visible_edges(visible_edges)
	_update_enemy_tracks(visible_enemies)


func get_localization_state() -> Dictionary:
	var map_x = _get_map_x()
	var map_y = _get_map_y()
	return {
		"odometry_position": _odometry_position,
		"map_x": map_x,
		"map_y": map_y,
		"map_position": null if map_x == null or map_y == null else Vector2(map_x, map_y),
		"map_bounds": _get_map_bounds(),
	}


func get_enemy_tracks() -> Array:
	var result := []
	for track_id in _tracks:
		var track: Dictionary = _tracks[track_id]
		var seconds_since_seen: float = _elapsed_seconds - track.last_seen_at_seconds
		var estimated_odometry_position: Vector2 = track.last_seen_odometry_position
		var uncertainty := 0.0
		if not track.visible:
			estimated_odometry_position += track.last_observed_velocity * seconds_since_seen
			uncertainty = (
				BASE_UNCERTAINTY
				+ UNCERTAINTY_PER_SECOND * seconds_since_seen
				+ (
					track.last_observed_velocity.length()
					* VELOCITY_UNCERTAINTY_FACTOR
					* seconds_since_seen
				)
			)
		result.push_back(
			{
				# This is a memory handle created by the bot, not a game content ID.
				"track_id": track_id,
				"visible": track.visible,
				"relative_position": estimated_odometry_position - _odometry_position,
				"last_observed_velocity": track.last_observed_velocity,
				"seconds_since_seen": seconds_since_seen,
				"uncertainty_radius": uncertainty,
				"recency_confidence": max(0.0, 1.0 - seconds_since_seen / TRACK_MEMORY_SECONDS),
				"behavior_profile": track.behavior_profile.duplicate(true),
				# Latest measurement; stale while the enemy is outside the visible world.
				"last_measurement": track.last_measurement.duplicate(true),
				# Evidence accumulated during this battle, never across runs.
				"behavior_evidence": track.evidence.duplicate(true),
			}
		)
	return result


func _record_visible_edges(visible_edges: Dictionary) -> void:
	for edge in visible_edges:
		if _observed_edge_coordinates[edge] != null:
			continue
		if edge == "left" or edge == "right":
			_observed_edge_coordinates[edge] = _odometry_position.x + visible_edges[edge]
		else:
			_observed_edge_coordinates[edge] = _odometry_position.y + visible_edges[edge]


func _update_enemy_tracks(visible_enemies: Array) -> void:
	for track in _tracks.values():
		track.visible = false

	var observed_track_ids := {}
	var next_visible_source_track_ids := {}
	for observation in visible_enemies:
		var source = observation._source
		var track_id = _visible_source_track_ids.get(source)
		if track_id == null or not _tracks.has(track_id):
			track_id = _find_reacquisition(observation, observed_track_ids)
		if track_id == null:
			track_id = _create_track()

		_update_track(_tracks[track_id], observation)
		observed_track_ids[track_id] = true
		next_visible_source_track_ids[source] = track_id

	_visible_source_track_ids = next_visible_source_track_ids
	_expire_old_tracks()


func _find_reacquisition(observation: Dictionary, observed_track_ids: Dictionary):
	var observed_odometry_position: Vector2 = _odometry_position + observation.relative_position
	var best_track_id = null
	var best_distance := 1.0e20
	for track_id in _tracks:
		if observed_track_ids.has(track_id):
			continue
		var track: Dictionary = _tracks[track_id]
		var seconds_since_seen: float = _elapsed_seconds - track.last_seen_at_seconds
		if seconds_since_seen > TRACK_MEMORY_SECONDS:
			continue
		if (
			abs(track.last_measurement.visual_radius - observation.features.visual_radius)
			> VISUAL_RADIUS_REACQUISITION_TOLERANCE
		):
			continue
		var predicted_position: Vector2 = (
			track.last_seen_odometry_position
			+ track.last_observed_velocity * seconds_since_seen
		)
		var distance: float = predicted_position.distance_to(observed_odometry_position)
		var plausible_distance: float = (
			REACQUISITION_MARGIN
			+ UNCERTAINTY_PER_SECOND * seconds_since_seen
			+ track.last_observed_velocity.length() * seconds_since_seen
		)
		if distance <= plausible_distance and distance < best_distance:
			best_distance = distance
			best_track_id = track_id
	return best_track_id


func _create_track() -> int:
	var track_id := _next_track_id
	_next_track_id += 1
	_tracks[track_id] = {}
	return track_id


func _update_track(track: Dictionary, observation: Dictionary) -> void:
	track.visible = true
	track.last_seen_at_seconds = _elapsed_seconds
	track.last_seen_odometry_position = _odometry_position + observation.relative_position
	track.last_observed_velocity = observation.velocity
	track.last_measurement = observation.features.duplicate(true)
	var previous_evidence := track.evidence if track.has("evidence") else {}
	track.evidence = _enemy_profiler.accumulate_evidence(previous_evidence, track.last_measurement)
	track.behavior_profile = _enemy_profiler.build_profile(track.evidence)


func _expire_old_tracks() -> void:
	for track_id in _tracks.keys():
		if _elapsed_seconds - _tracks[track_id].last_seen_at_seconds > TRACK_MEMORY_SECONDS:
			_tracks.erase(track_id)


func _get_map_x():
	return (
		null
		if _observed_edge_coordinates.left == null
		else _odometry_position.x - _observed_edge_coordinates.left
	)


func _get_map_y():
	return (
		null
		if _observed_edge_coordinates.top == null
		else _odometry_position.y - _observed_edge_coordinates.top
	)


func _get_map_bounds() -> Dictionary:
	var bounds := {
		"seen_left": _observed_edge_coordinates.left != null,
		"seen_right": _observed_edge_coordinates.right != null,
		"seen_top": _observed_edge_coordinates.top != null,
		"seen_bottom": _observed_edge_coordinates.bottom != null,
		"distance_to_left": null,
		"distance_to_right": null,
		"distance_to_top": null,
		"distance_to_bottom": null,
		"known_width": null,
		"known_height": null,
	}

	if _observed_edge_coordinates.left != null:
		bounds.distance_to_left = _odometry_position.x - _observed_edge_coordinates.left
	if _observed_edge_coordinates.right != null:
		bounds.distance_to_right = _observed_edge_coordinates.right - _odometry_position.x
	if _observed_edge_coordinates.top != null:
		bounds.distance_to_top = _odometry_position.y - _observed_edge_coordinates.top
	if _observed_edge_coordinates.bottom != null:
		bounds.distance_to_bottom = _observed_edge_coordinates.bottom - _odometry_position.y
	if _observed_edge_coordinates.left != null and _observed_edge_coordinates.right != null:
		bounds.known_width = _observed_edge_coordinates.right - _observed_edge_coordinates.left
	if _observed_edge_coordinates.top != null and _observed_edge_coordinates.bottom != null:
		bounds.known_height = _observed_edge_coordinates.bottom - _observed_edge_coordinates.top
	return bounds
