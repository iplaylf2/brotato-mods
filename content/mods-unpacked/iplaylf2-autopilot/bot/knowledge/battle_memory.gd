extends Reference

# Ephemeral memory for one player in one battle. Hidden enemies are never refreshed
# from game state: their estimates age, become less certain, and expire.

const TRACK_MEMORY_SECONDS := 4.0
const BASE_UNCERTAINTY := 24.0
const UNCERTAINTY_PER_SECOND := 80.0
const VELOCITY_UNCERTAINTY_FACTOR := 0.35
const REACQUISITION_MARGIN := 72.0
const FOOTPRINT_REACQUISITION_TOLERANCE := 12.0
const EnemyBehaviorClassifier := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/enemy_behavior_classifier.gd"
)

var _elapsed := 0.0
var _next_track_id := 1
var _local_position := Vector2.ZERO
var _landmarks := {"left": null, "right": null, "top": null, "bottom": null}
var _tracks := {}
var _continuous_visible_sources := {}
var _enemy_classifier: Reference = EnemyBehaviorClassifier.new()


func update(
	delta: float, motion_delta: Vector2, visible_edges: Dictionary, visible_enemies: Array
) -> void:
	_elapsed += delta
	_local_position += motion_delta
	_remember_edges(visible_edges)
	_update_enemy_tracks(visible_enemies)


func get_localization_state() -> Dictionary:
	var map_x = _get_map_x()
	var map_y = _get_map_y()
	return {
		"odometry_position": _local_position,
		"map_x": map_x,
		"map_y": map_y,
		"map_position": null if map_x == null or map_y == null else Vector2(map_x, map_y),
		"map_bounds": _get_map_bounds(),
	}


func get_enemy_tracks() -> Array:
	var result := []
	for track_id in _tracks:
		var track: Dictionary = _tracks[track_id]
		var age: float = _elapsed - track.last_seen_at
		var estimated_local_position: Vector2 = track.last_seen_local_position
		var uncertainty := 0.0
		if not track.visible:
			estimated_local_position += track.velocity * age
			uncertainty = (
				BASE_UNCERTAINTY
				+ UNCERTAINTY_PER_SECOND * age
				+ track.velocity.length() * VELOCITY_UNCERTAINTY_FACTOR * age
			)
		result.push_back(
			{
				# This is a memory handle created by the bot, not a game content ID.
				"track_id": track_id,
				"visible": track.visible,
				"relative_position": estimated_local_position - _local_position,
				"last_observed_velocity": track.velocity,
				"seconds_since_seen": age,
				"uncertainty_radius": uncertainty,
				"recency_confidence": max(0.0, 1.0 - age / TRACK_MEMORY_SECONDS),
				"behavior_classification": track.behavior_classification.duplicate(true),
				# Exact values from the latest observation; stale when visible is false.
				"last_measurement": track.last_measurement.duplicate(true),
				# Evidence accumulated during this battle, never across runs.
				"battle_evidence": track.evidence.duplicate(true),
			}
		)
	return result


func _remember_edges(visible_edges: Dictionary) -> void:
	for edge in visible_edges:
		if _landmarks[edge] != null:
			continue
		if edge == "left" or edge == "right":
			_landmarks[edge] = _local_position.x + visible_edges[edge]
		else:
			_landmarks[edge] = _local_position.y + visible_edges[edge]


func _update_enemy_tracks(visible_enemies: Array) -> void:
	for track in _tracks.values():
		track.visible = false

	var observed_track_ids := {}
	var next_visible_sources := {}
	for observation in visible_enemies:
		var source = observation._source
		var track_id = _continuous_visible_sources.get(source)
		if track_id == null or not _tracks.has(track_id):
			track_id = _find_reacquisition(observation, observed_track_ids)
		if track_id == null:
			track_id = _create_track()

		_update_track(_tracks[track_id], observation)
		observed_track_ids[track_id] = true
		next_visible_sources[source] = track_id

	_continuous_visible_sources = next_visible_sources
	_expire_old_tracks()


func _find_reacquisition(observation: Dictionary, observed_track_ids: Dictionary):
	var observed_local_position: Vector2 = _local_position + observation.relative_position
	var best_track_id = null
	var best_distance := 1.0e20
	for track_id in _tracks:
		if observed_track_ids.has(track_id):
			continue
		var track: Dictionary = _tracks[track_id]
		var age: float = _elapsed - track.last_seen_at
		if age > TRACK_MEMORY_SECONDS:
			continue
		if (
			abs(track.last_measurement.footprint_radius - observation.features.footprint_radius)
			> FOOTPRINT_REACQUISITION_TOLERANCE
		):
			continue
		var predicted_position: Vector2 = track.last_seen_local_position + track.velocity * age
		var distance: float = predicted_position.distance_to(observed_local_position)
		var plausible_distance: float = (
			REACQUISITION_MARGIN
			+ UNCERTAINTY_PER_SECOND * age
			+ track.velocity.length() * age
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
	track.last_seen_at = _elapsed
	track.last_seen_local_position = _local_position + observation.relative_position
	track.velocity = observation.velocity
	track.last_measurement = observation.features.duplicate(true)
	var previous_evidence := track.evidence if track.has("evidence") else {}
	track.evidence = _enemy_classifier.accumulate_evidence(
		previous_evidence, track.last_measurement
	)
	track.behavior_classification = _enemy_classifier.classify(track.evidence)


func _expire_old_tracks() -> void:
	for track_id in _tracks.keys():
		if _elapsed - _tracks[track_id].last_seen_at > TRACK_MEMORY_SECONDS:
			_tracks.erase(track_id)


func _get_map_x():
	return null if _landmarks.left == null else _local_position.x - _landmarks.left


func _get_map_y():
	return null if _landmarks.top == null else _local_position.y - _landmarks.top


func _get_map_bounds() -> Dictionary:
	var bounds := {
		"seen_left": _landmarks.left != null,
		"seen_right": _landmarks.right != null,
		"seen_top": _landmarks.top != null,
		"seen_bottom": _landmarks.bottom != null,
		"distance_to_left": null,
		"distance_to_right": null,
		"distance_to_top": null,
		"distance_to_bottom": null,
		"known_width": null,
		"known_height": null,
	}

	if _landmarks.left != null:
		bounds.distance_to_left = _local_position.x - _landmarks.left
	if _landmarks.right != null:
		bounds.distance_to_right = _landmarks.right - _local_position.x
	if _landmarks.top != null:
		bounds.distance_to_top = _local_position.y - _landmarks.top
	if _landmarks.bottom != null:
		bounds.distance_to_bottom = _landmarks.bottom - _local_position.y
	if _landmarks.left != null and _landmarks.right != null:
		bounds.known_width = _landmarks.right - _landmarks.left
	if _landmarks.top != null and _landmarks.bottom != null:
		bounds.known_height = _landmarks.bottom - _landmarks.top
	return bounds
