extends Reference

# Battle-local memory of the world observed by one player. Hidden enemies are
# short-lived motion estimates. Remembered entities are permanent observation
# records; only the belief that an unobserved entity still exists may change.

const TRACK_MEMORY_SECONDS := 4.0
const BASE_UNCERTAINTY := 24.0
const UNCERTAINTY_PER_SECOND := 80.0
const VELOCITY_UNCERTAINTY_FACTOR := 0.35
const REACQUISITION_MARGIN := 72.0
const VISUAL_RADIUS_REACQUISITION_TOLERANCE := 12.0
const ACCELERATION_DECAY_SECONDS := 0.18
const ENTITY_MEMORY_UNCERTAINTY_PER_SECOND := 24.0
const ENTITY_MEMORY_REACQUISITION_MARGIN := 72.0
const EnemyBehaviorProfiler := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/enemies/enemy_behavior_profiler.gd"
)
const RememberedEntityExistenceEstimator := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/observation/remembered_entity_existence_estimator.gd"
)

var _elapsed_seconds := 0.0
var _next_track_id := 1
var _next_memory_record_id := 1
var _odometry_position := Vector2.ZERO
var _observed_edge_coordinates := {"left": null, "right": null, "top": null, "bottom": null}
var _tracks := {}
var _visible_source_track_ids := {}
var _remembered_entities := {}
var _source_memory_record_ids := {}
var _enemy_profiler: Reference = EnemyBehaviorProfiler.new()
var _entity_existence_estimator: Reference = RememberedEntityExistenceEstimator.new()


func update(
	delta_seconds: float,
	position_delta: Vector2,
	visible_edges: Dictionary,
	visible_enemies: Array,
	visible_entities: Array,
	party_state: Dictionary,
	visible_allied_agents: Array,
	player_pickup: Dictionary
) -> void:
	_elapsed_seconds += delta_seconds
	_odometry_position += position_delta
	_record_visible_edges(visible_edges)
	_update_enemy_tracks(visible_enemies)
	_entity_existence_estimator.update(delta_seconds, position_delta, visible_allied_agents)
	_update_remembered_entities(delta_seconds, visible_entities, party_state, player_pickup)


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
		var acceleration_decay := exp(-seconds_since_seen / ACCELERATION_DECAY_SECONDS)
		var estimated_velocity: Vector2 = (
			track.last_observed_velocity
			+ (
				track.last_observed_acceleration
				* track.motion_confidence
				* ACCELERATION_DECAY_SECONDS
				* (1.0 - acceleration_decay)
			)
		)
		var estimated_acceleration: Vector2 = track.last_observed_acceleration * acceleration_decay
		var uncertainty := 0.0
		if not track.visible:
			estimated_odometry_position = _predict_observed_position(
				estimated_odometry_position,
				track.last_observed_velocity,
				track.last_observed_acceleration,
				track.motion_confidence,
				seconds_since_seen
			)
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
				"last_observed_acceleration": track.last_observed_acceleration,
				"estimated_velocity": estimated_velocity,
				"estimated_acceleration": estimated_acceleration,
				"motion_confidence":
				track.motion_confidence * max(0.0, 1.0 - seconds_since_seen / TRACK_MEMORY_SECONDS),
				"seconds_since_seen": seconds_since_seen,
				"uncertainty_radius": uncertainty,
				"recency_confidence": max(0.0, 1.0 - seconds_since_seen / TRACK_MEMORY_SECONDS),
				"behavior_profile": track.behavior_profile.duplicate(true),
				# Latest measurement; stale while the enemy is outside the visible world.
				"last_measurement": track.last_measurement.duplicate(true),
				# Inputs retained for this track: stable mechanics plus battle-local evidence.
				"behavior_evidence": track.evidence.duplicate(true),
			}
		)
	return result


func get_remembered_entities() -> Array:
	var result := []
	for memory_record_id in _remembered_entities:
		var memory_record: Dictionary = _remembered_entities[memory_record_id]
		var seconds_since_seen: float = _elapsed_seconds - memory_record.last_seen_at_seconds
		var confidence: float = memory_record.existence_confidence
		var observation: Dictionary = memory_record.observation.duplicate(true)
		observation.erase("_source")
		observation.erase("_world_position")
		observation.memory_record_id = memory_record.memory_record_id
		var remembered_velocity: Vector2 = observation.get("velocity", Vector2.ZERO)
		var remembered_motion_confidence: float = clamp(
			observation.get("motion_confidence", 0.0), 0.0, 1.0
		)
		observation.relative_position = (
			memory_record.odometry_position
			+ remembered_velocity * remembered_motion_confidence * seconds_since_seen
			- _odometry_position
		)
		observation.last_observed_relative_position = (
			memory_record.odometry_position
			- _odometry_position
		)
		observation.motion_confidence = remembered_motion_confidence * confidence
		observation.visible = memory_record.visible
		observation.seconds_since_seen = seconds_since_seen
		# The permanent record proves that the observation happened. This confidence
		# describes the uncertain present existence and is what planning must use.
		observation.existence_confidence = confidence
		observation.disappearance_hazard_per_second = memory_record.get(
			"disappearance_hazard_per_second", 0.0
		)
		observation.absence_confirmed = memory_record.get("absence_confirmed", false)
		observation.uncertainty_radius = (
			0.0
			if memory_record.visible
			else (
				ENTITY_MEMORY_UNCERTAINTY_PER_SECOND
				* seconds_since_seen
				* clamp(observation.get("motion_confidence", 0.0), 0.0, 1.0)
			)
		)
		result.push_back(observation)
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


func _update_remembered_entities(
	delta_seconds: float,
	visible_entities: Array,
	party_state: Dictionary,
	player_pickup: Dictionary
) -> void:
	for memory_record in _remembered_entities.values():
		memory_record.visible = false
		var existence_estimate: Dictionary = _entity_existence_estimator.estimate(
			memory_record, party_state, player_pickup
		)
		var disappearance_hazard: float = existence_estimate.disappearance_hazard_per_second
		memory_record.absence_confirmed = existence_estimate.absence_confirmed
		memory_record.disappearance_hazard_per_second = disappearance_hazard
		memory_record.existence_confidence = (
			0.0
			if existence_estimate.absence_confirmed
			else (memory_record.existence_confidence * exp(-disappearance_hazard * delta_seconds))
		)
	for observation in visible_entities:
		var source = observation._source
		var source_id: int = source.get_instance_id()
		var memory_record_id = _source_memory_record_ids.get(source_id)
		if memory_record_id == null or _source_reused_for_new_entity(memory_record_id, observation):
			memory_record_id = _next_memory_record_id
			_next_memory_record_id += 1
			_source_memory_record_ids[source_id] = memory_record_id
		_remembered_entities[memory_record_id] = {
			"memory_record_id": memory_record_id,
			"source_id": source_id,
			"visible": true,
			"last_seen_at_seconds": _elapsed_seconds,
			"odometry_position": _odometry_position + observation.relative_position,
			"observation": observation.duplicate(true),
			"existence_confidence": 1.0,
			"disappearance_hazard_per_second": 0.0,
			"absence_confirmed": false,
		}


func _source_reused_for_new_entity(memory_record_id: int, observation: Dictionary) -> bool:
	if not _remembered_entities.has(memory_record_id):
		return true
	var memory_record: Dictionary = _remembered_entities[memory_record_id]
	if memory_record.visible:
		return false
	var observed_position: Vector2 = _odometry_position + observation.relative_position
	var seconds_since_seen: float = _elapsed_seconds - memory_record.last_seen_at_seconds
	var remembered_velocity: Vector2 = memory_record.observation.get("velocity", Vector2.ZERO)
	var plausible_position: Vector2 = (
		memory_record.odometry_position
		+ remembered_velocity * seconds_since_seen
	)
	var plausible_distance := (
		ENTITY_MEMORY_REACQUISITION_MARGIN
		+ remembered_velocity.length() * seconds_since_seen * 0.5
		+ memory_record.observation.get("visual_radius", 0.0)
	)
	return plausible_position.distance_to(observed_position) > plausible_distance


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
		var predicted_position: Vector2 = _predict_observed_position(
			track.last_seen_odometry_position,
			track.last_observed_velocity,
			track.last_observed_acceleration,
			track.motion_confidence,
			seconds_since_seen
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
	track.last_observed_acceleration = observation.acceleration
	track.motion_confidence = observation.motion_confidence
	track.last_measurement = observation.features.duplicate(true)
	var previous_evidence := track.evidence if track.has("evidence") else {}
	track.evidence = _enemy_profiler.accumulate_evidence(previous_evidence, track.last_measurement)
	track.behavior_profile = _enemy_profiler.build_profile(track.evidence)


func _predict_observed_position(
	position: Vector2,
	velocity: Vector2,
	acceleration: Vector2,
	motion_confidence: float,
	time: float
) -> Vector2:
	var decay := ACCELERATION_DECAY_SECONDS
	var acceleration_displacement := (
		acceleration
		* clamp(motion_confidence, 0.0, 1.0)
		* decay
		* (time - decay * (1.0 - exp(-time / decay)))
	)
	return position + velocity * time + acceleration_displacement


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
