extends Reference

# Battle-local memory of the world observed by one player. Hidden enemy positions
# are short-lived motion estimates; persistent health observations may preserve
# life and existence without refreshing position. Remembered entities are permanent
# observation records; only belief in their current existence may change.

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
const VisibilityCoverageModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/observation/visibility_coverage_model.gd"
)
const EnemyDeathProductMatcher := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/observation/enemy_death_product_matcher.gd"
)

var _elapsed_seconds := 0.0
var _next_track_id := 1
var _next_memory_record_id := 1
var _odometry_position := Vector2.ZERO
var _observed_edge_coordinates := {"left": null, "right": null, "top": null, "bottom": null}
var _observation_cell_size := 0.0
var _observation_cell_last_seen := {}
var _tracks := {}
var _visible_source_track_ids := {}
var _persistent_health_source_track_ids := {}
var _remembered_entities := {}
var _source_memory_record_ids := {}
var _enemy_profiler: Reference = EnemyBehaviorProfiler.new()
var _entity_existence_estimator: Reference = RememberedEntityExistenceEstimator.new()
var _visibility_coverage_model: Reference = VisibilityCoverageModel.new()
var _enemy_death_product_matcher: Reference = EnemyDeathProductMatcher.new()


func update(
	delta_seconds: float,
	position_delta: Vector2,
	visible_edges: Dictionary,
	memory_inputs: Dictionary,
	party_state: Dictionary,
	visible_allied_agents: Array,
	player_pickup: Dictionary,
	visibility: Dictionary
) -> void:
	_elapsed_seconds += delta_seconds
	_odometry_position += position_delta
	_record_visible_edges(visible_edges)
	_update_observation_coverage(visibility.viewport_size, visibility.viewport_offset_from_player)
	_entity_existence_estimator.update(delta_seconds, position_delta, visible_allied_agents)
	var death_product_observations: Array = _update_remembered_entities(
		delta_seconds, memory_inputs.entity_observations, party_state, player_pickup, visibility
	)
	_update_enemy_tracks(
		memory_inputs.enemy_observations,
		memory_inputs.persistent_enemy_health_observations,
		memory_inputs.persistent_enemy_health_snapshot_complete,
		death_product_observations,
		visibility
	)


func get_localization_state() -> Dictionary:
	var map_x_known: bool = _observed_edge_coordinates.left != null
	var map_y_known: bool = _observed_edge_coordinates.top != null
	var map_x: float = (
		_odometry_position.x - float(_observed_edge_coordinates.left)
		if map_x_known
		else 0.0
	)
	var map_y: float = (
		_odometry_position.y - float(_observed_edge_coordinates.top)
		if map_y_known
		else 0.0
	)
	return {
		"odometry_position": _odometry_position,
		"map_x": map_x if map_x_known else null,
		"map_y": map_y if map_y_known else null,
		"map_position": Vector2(map_x, map_y) if map_x_known and map_y_known else null,
		"map_bounds": _get_map_bounds(),
		"observation_grid_cell_size": _observation_cell_size,
		"observation_cells": _get_observation_cells(),
	}


func _update_observation_coverage(
	viewport_size: Vector2, viewport_offset_from_player: Vector2
) -> void:
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	if _observation_cell_size <= 0.0:
		# A quarter of the short viewport keeps the complete arena state small while
		# avoiding the old aliasing failure where touching one edge of a half-view
		# cell marked hundreds of unseen pixels as fresh. Navigation can now observe
		# a value gradient before it has travelled an entire viewport radius.
		_observation_cell_size = max(1.0, min(viewport_size.x, viewport_size.y) * 0.25)
	var visible_rect := Rect2(_odometry_position + viewport_offset_from_player, viewport_size)
	var first_x := int(floor(visible_rect.position.x / _observation_cell_size))
	var last_x := int(floor((visible_rect.end.x - 0.001) / _observation_cell_size))
	var first_y := int(floor(visible_rect.position.y / _observation_cell_size))
	var last_y := int(floor((visible_rect.end.y - 0.001) / _observation_cell_size))
	for grid_x in range(first_x, last_x + 1):
		for grid_y in range(first_y, last_y + 1):
			_observation_cell_last_seen[_observation_cell_key(grid_x, grid_y)] = {
				"grid_x": grid_x,
				"grid_y": grid_y,
				"last_seen_at_seconds": _elapsed_seconds,
			}


func _get_observation_cells() -> Array:
	var result := []
	for cell in _observation_cell_last_seen.values():
		result.push_back(
			{
				"grid_x": cell.grid_x,
				"grid_y": cell.grid_y,
				"seconds_since_observed": _elapsed_seconds - cell.last_seen_at_seconds,
			}
		)
	return result


func _observation_cell_key(grid_x: int, grid_y: int) -> String:
	return "%s:%s" % [grid_x, grid_y]


func get_enemy_tracks() -> Array:
	return _materialize_enemy_tracks(false)


func get_planning_enemy_tracks() -> Array:
	return _materialize_enemy_tracks(true)


func _materialize_enemy_tracks(planning_view: bool) -> Array:
	var result := []
	for track_id in _tracks:
		var track: Dictionary = _tracks[track_id]
		var seconds_since_seen: float = _elapsed_seconds - track.last_seen_at_seconds
		var visual_recency_confidence := max(0.0, 1.0 - seconds_since_seen / TRACK_MEMORY_SECONDS)
		var existence_confidence := (
			1.0
			if track.persistent_health_observation_active
			else visual_recency_confidence
		)
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
		var observation := {
			# This is a memory handle created by the bot, not a game content ID.
			"track_id": track_id,
			"visible": track.visible,
			"relative_position": estimated_odometry_position - _odometry_position,
			"last_observed_velocity": track.last_observed_velocity,
			"last_observed_acceleration": track.last_observed_acceleration,
			"estimated_velocity": estimated_velocity,
			"estimated_acceleration": estimated_acceleration,
			"motion_confidence": track.motion_confidence * visual_recency_confidence,
			"seconds_since_seen": seconds_since_seen,
			"uncertainty_radius": uncertainty,
			# Existence and position evidence are deliberately separate. A persistent
			# health bar proves that the target is alive and exposes current health,
			# but it does not refresh the last visually measured position.
			"existence_confidence": existence_confidence,
			"recency_confidence": visual_recency_confidence,
			"persistent_health_observation_active": track.persistent_health_observation_active,
			"behavior_profile": track.behavior_profile.duplicate(not planning_view),
			# Latest measurement; stale while the enemy is outside the visible world.
			"last_measurement": track.last_measurement.duplicate(not planning_view),
		}
		if not planning_view:
			# Inputs retained for the public diagnostic contract. Planning consumes the
			# compiled behavior profile and must not carry this duplicate evidence graph.
			observation.behavior_evidence = track.evidence.duplicate(true)
		result.push_back(observation)
	return result


func get_remembered_entities() -> Array:
	return _materialize_remembered_entities(false)


func get_planning_remembered_entities() -> Array:
	# Confirmed-absent records remain part of the public historical observation
	# contract, but cannot affect planning. Keeping them out of the hot snapshot
	# prevents battle-long pickup history from growing every navigation query and
	# telemetry sample without bound.
	return _materialize_remembered_entities(true, true)


func _materialize_remembered_entities(
	planning_view: bool, omit_confirmed_absent: bool = false
) -> Array:
	var result := []
	for memory_record_id in _remembered_entities:
		var memory_record: Dictionary = _remembered_entities[memory_record_id]
		if (
			omit_confirmed_absent
			and (
				memory_record.get("absence_confirmed", false)
				or memory_record.get("existence_confidence", 0.0) <= 0.0
			)
		):
			continue
		var seconds_since_seen: float = _elapsed_seconds - memory_record.last_seen_at_seconds
		var confidence: float = memory_record.existence_confidence
		var observation: Dictionary = memory_record.observation.duplicate(not planning_view)
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


func _update_enemy_tracks(
	visible_enemies: Array,
	persistent_health_observations: Array,
	persistent_health_snapshot_complete: bool,
	death_product_observations: Array,
	visibility: Dictionary
) -> void:
	for track in _tracks.values():
		track.visible = false
		track.persistent_health_observation_active = false

	var observed_track_ids := {}
	var next_visible_source_track_ids := {}
	for observation in visible_enemies:
		var source: Object = observation._source
		var source_id: int = source.get_instance_id()
		var track_id := -1
		if observation.features.persistent_health_observation:
			track_id = _persistent_health_source_track_ids.get(source_id, -1)
		if track_id < 0:
			track_id = _visible_source_track_ids.get(source_id, -1)
		if track_id < 0 or not _tracks.has(track_id):
			track_id = _find_reacquisition(observation, observed_track_ids)
		if track_id < 0:
			track_id = _create_track()

		_update_track(_tracks[track_id], observation)
		observed_track_ids[track_id] = true
		next_visible_source_track_ids[source_id] = track_id
		if observation.features.persistent_health_observation:
			_persistent_health_source_track_ids[source_id] = track_id
	_visible_source_track_ids = next_visible_source_track_ids

	_apply_persistent_enemy_health_snapshot(
		persistent_health_observations, persistent_health_snapshot_complete
	)
	_retire_tracks_from_death_products(death_product_observations)
	_remove_tracks_confirmed_absent(visibility)
	_expire_old_tracks()
	_prune_persistent_health_source_track_ids()


func _apply_persistent_enemy_health_snapshot(
	health_observations: Array, snapshot_complete: bool
) -> void:
	if not snapshot_complete:
		return
	var observed_track_ids := {}
	for observation in health_observations:
		var source: Object = observation._source
		var track_id: int = _persistent_health_source_track_ids.get(source.get_instance_id(), -1)
		if track_id < 0 or not _tracks.has(track_id):
			continue
		if not observation.alive or observation.health.current <= 0.0:
			_tracks.erase(track_id)
			continue
		var track: Dictionary = _tracks[track_id]
		track.persistent_health_observation_active = true
		track.persistent_health_observation_correlated = true
		track.last_measurement.health = observation.health.duplicate(true)
		observed_track_ids[track_id] = true
	for track_id in _tracks.keys():
		var track: Dictionary = _tracks[track_id]
		if track.persistent_health_observation_correlated and not observed_track_ids.has(track_id):
			# The complete persistent-bar snapshot no longer contains this correlated
			# target, so it is no longer an active enemy. The cause is not inferred.
			_tracks.erase(track_id)


func _retire_tracks_from_death_products(observations: Array) -> void:
	if observations.empty():
		return
	var candidates := []
	for track_id in _tracks:
		var track: Dictionary = _tracks[track_id]
		if track.visible or track.persistent_health_observation_active:
			continue
		var products: Array = track.behavior_profile.kill_rewards.guaranteed_death_products
		if products.empty():
			continue
		var seconds_since_seen: float = _elapsed_seconds - track.last_seen_at_seconds
		var maximum_speed: float = max(
			max(
				track.last_observed_velocity.length(),
				track.behavior_profile.get("target_position_response", {}).get(
					"movement_speed", 0.0
				)
			),
			track.behavior_profile.get("charge_attack", {}).get("maximum_charge_speed", 0.0)
		)
		candidates.push_back(
			{
				"track_id": track_id,
				"products": products,
				"relative_position": track.last_seen_odometry_position - _odometry_position,
				"position_uncertainty_radius": maximum_speed * max(0.0, seconds_since_seen),
			}
		)
	for track_id in _enemy_death_product_matcher.match_track_ids(candidates, observations):
		_tracks.erase(track_id)


func _prune_persistent_health_source_track_ids() -> void:
	for source_id in _persistent_health_source_track_ids.keys():
		if not _tracks.has(_persistent_health_source_track_ids[source_id]):
			_persistent_health_source_track_ids.erase(source_id)


func _remove_tracks_confirmed_absent(visibility: Dictionary) -> void:
	for track_id in _tracks.keys():
		var track: Dictionary = _tracks[track_id]
		if track.visible or track.persistent_health_observation_active:
			continue
		var seconds_since_seen: float = _elapsed_seconds - track.last_seen_at_seconds
		var maximum_speed: float = max(
			max(
				track.last_observed_velocity.length(),
				track.behavior_profile.get("target_position_response", {}).get(
					"movement_speed", 0.0
				)
			),
			track.behavior_profile.get("charge_attack", {}).get("maximum_charge_speed", 0.0)
		)
		var last_relative_position: Vector2 = track.last_seen_odometry_position - _odometry_position
		var visual_radius: float = max(0.0, track.last_measurement.get("visual_radius", 0.0))
		if _visibility_coverage_model.covers_reachable_circle(
			last_relative_position,
			visual_radius,
			maximum_speed * max(0.0, seconds_since_seen),
			visibility
		):
			_tracks.erase(track_id)


func _update_remembered_entities(
	delta_seconds: float,
	visible_entities: Array,
	party_state: Dictionary,
	player_pickup: Dictionary,
	visibility: Dictionary
) -> Array:
	var new_death_product_observations := []
	for memory_record_id in _remembered_entities:
		var memory_record: Dictionary = _remembered_entities[memory_record_id]
		memory_record.visible = false
		_remembered_entities[memory_record_id] = memory_record
	for observation in visible_entities:
		var source: Object = observation._source
		var source_id: int = source.get_instance_id()
		var memory_record_id: int = _source_memory_record_ids.get(source_id, -1)
		if memory_record_id < 0 or _source_reused_for_new_entity(memory_record_id, observation):
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
			for trait in observation.get("pickup_profile", {}).get("traits", []):
				new_death_product_observations.push_back(
					{"kind": trait, "relative_position": observation.relative_position}
				)
		else:
			# Visible pickups move while dropping and while being attracted. Refreshing
			# the existing record keeps navigation aimed at their current position and
			# prevents ordinary motion from being mistaken for pooled-node reuse.
			var memory_record: Dictionary = _remembered_entities[memory_record_id]
			memory_record.visible = true
			memory_record.last_seen_at_seconds = _elapsed_seconds
			memory_record.odometry_position = _odometry_position + observation.relative_position
			memory_record.observation = observation.duplicate(true)
			memory_record.existence_confidence = 1.0
			memory_record.disappearance_hazard_per_second = 0.0
			memory_record.absence_confirmed = false
			_remembered_entities[memory_record_id] = memory_record
	# Evaluate negative evidence only after current visible observations have been
	# reconciled. This prevents an entity that is present this frame from briefly
	# confirming its own absence, while a pooled source moved to a new entity leaves
	# the old record available for legitimate visibility confirmation.
	for memory_record_id in _remembered_entities:
		var memory_record: Dictionary = _remembered_entities[memory_record_id]
		if memory_record.visible:
			continue
		var existence_estimate: Dictionary = _entity_existence_estimator.estimate(
			memory_record, party_state, player_pickup, visibility
		)
		var disappearance_hazard: float = existence_estimate.disappearance_hazard_per_second
		memory_record.absence_confirmed = existence_estimate.absence_confirmed
		memory_record.disappearance_hazard_per_second = disappearance_hazard
		memory_record.existence_confidence = (
			0.0
			if existence_estimate.absence_confirmed
			else (memory_record.existence_confidence * exp(-disappearance_hazard * delta_seconds))
		)
		_remembered_entities[memory_record_id] = memory_record
	return new_death_product_observations


func _source_reused_for_new_entity(memory_record_id: int, observation: Dictionary) -> bool:
	if not _remembered_entities.has(memory_record_id):
		return true
	var memory_record: Dictionary = _remembered_entities[memory_record_id]
	if memory_record.visible:
		return false
	if memory_record.absence_confirmed:
		return true
	var observed_position: Vector2 = _odometry_position + observation.relative_position
	var seconds_since_seen: float = _elapsed_seconds - memory_record.last_seen_at_seconds
	var remembered_velocity: Vector2 = memory_record.observation.get("velocity", Vector2.ZERO)
	var plausible_position: Vector2 = (
		memory_record.odometry_position
		+ remembered_velocity * seconds_since_seen
	)
	var plausible_distance: float = (
		ENTITY_MEMORY_REACQUISITION_MARGIN
		+ remembered_velocity.length() * seconds_since_seen * 0.5
		+ memory_record.observation.get("visual_radius", 0.0)
	)
	return plausible_position.distance_to(observed_position) > plausible_distance


func _find_reacquisition(observation: Dictionary, observed_track_ids: Dictionary) -> int:
	var observed_odometry_position: Vector2 = _odometry_position + observation.relative_position
	var best_track_id := -1
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
	var features: Dictionary = observation.features
	track.last_measurement = features.duplicate(true)
	track.persistent_health_observation_correlated = features.persistent_health_observation
	track.persistent_health_observation_active = features.persistent_health_observation
	var previous_evidence: Dictionary = track.evidence if track.has("evidence") else {}
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
		if _tracks[track_id].persistent_health_observation_active:
			continue
		if _elapsed_seconds - _tracks[track_id].last_seen_at_seconds > TRACK_MEMORY_SECONDS:
			_tracks.erase(track_id)


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
