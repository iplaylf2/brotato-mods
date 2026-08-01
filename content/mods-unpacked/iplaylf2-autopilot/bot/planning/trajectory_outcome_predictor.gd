extends Reference

# Predicts an interpretable outcome vector. Coarse prediction covers movement,
# collection, and hazards; full prediction additionally estimates automatic
# weapon geometry for the shortlisted trajectories.

const WeaponAttackPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapon_attack_predictor.gd"
)
const MotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion_predictor.gd"
)

const PLAYER_RADIUS := 24.0
const HAZARD_DISTANCE := 150.0
const PROJECTILE_HAZARD_DISTANCE := 100.0
const RANGED_SOURCE_PRESSURE_DISTANCE := 650.0
const EDGE_MARGIN := 56.0
const ROAMING_DISTANCE := 600.0

var _weapon_attack_predictor: Reference = WeaponAttackPredictor.new()
var _motion_predictor: Reference = MotionPredictor.new()


func predict(
	observation: Dictionary,
	trajectory: Dictionary,
	previous_movement: Vector2,
	include_weapon_attacks: bool
) -> Dictionary:
	var outcome := {
		"material_pickup_value": 0.0,
		"healing_pickup_value": 0.0,
		"expected_enemy_damage": 0.0,
		"expected_producer_damage": 0.0,
		"expected_loot_target_damage": 0.0,
		"ranged_source_suppression_value": 0.0,
		"producer_approach_progress": 0.0,
		"loot_target_approach_progress": 0.0,
		"ranged_source_engagement_progress": 0.0,
		"targets_in_weapon_range": 0.0,
		"tree_attack_opportunity": 0.0,
		"hazard_exposure": 0.0,
		"contact_pressure": 0.0,
		"ranged_source_pressure": 0.0,
		"roaming_progress": 0.0,
		"standing_seconds": 0.0,
		"moving_seconds": 0.0,
		"heading_continuity": 0.0,
		"expected_attack_hits": 0.0,
	}
	_predict_trajectory_outcomes(observation, trajectory, previous_movement, outcome)
	if include_weapon_attacks:
		_weapon_attack_predictor.accumulate_outcome(observation, trajectory, outcome)
	return outcome


func _predict_trajectory_outcomes(
	observation: Dictionary, trajectory: Dictionary, previous_movement: Vector2, outcome: Dictionary
) -> void:
	var samples: Array = trajectory.samples
	assert(not samples.empty())
	var step_seconds: float = trajectory.horizon_seconds / float(samples.size())
	for sample in samples:
		_predict_sample_hazards(observation, sample, step_seconds, outcome)
	_predict_projectile_hazards(observation, samples, step_seconds, outcome)

	outcome.material_pickup_value = _collection_value(
		observation.visible_world.materials, samples, observation.player_state.pickup
	)
	outcome.healing_pickup_value = (
		_collection_value(
			observation.visible_world.consumables, samples, observation.player_state.pickup
		)
		* (1.0 - observation.player_state.health.ratio)
	)
	outcome.tree_attack_opportunity = _tree_attack_opportunity(observation, trajectory)
	outcome.producer_approach_progress = _target_approach_progress(
		observation.enemy_tracks, samples, "enemy_producer"
	)
	outcome.loot_target_approach_progress = _target_approach_progress(
		observation.enemy_tracks, samples, "loot_reward_target"
	)
	outcome.ranged_source_engagement_progress = _ranged_source_engagement_progress(
		observation, trajectory
	)
	outcome.targets_in_weapon_range = _targets_in_weapon_range(observation, trajectory)

	var final_displacement: Vector2 = samples.back().displacement
	outcome.roaming_progress = clamp(final_displacement.length() / ROAMING_DISTANCE, 0.0, 1.0)
	if trajectory.movement == Vector2.ZERO:
		outcome.standing_seconds = trajectory.horizon_seconds
	else:
		outcome.moving_seconds = trajectory.horizon_seconds
	if previous_movement.length_squared() > 0.0 and trajectory.movement.length_squared() > 0.0:
		outcome.heading_continuity = previous_movement.normalized().dot(trajectory.movement)


func _predict_sample_hazards(
	observation: Dictionary, sample: Dictionary, step_seconds: float, outcome: Dictionary
) -> void:
	for track in observation.enemy_tracks:
		var position := _predict_track_position(track, sample.time) - sample.displacement
		var radius: float = (
			PLAYER_RADIUS
			+ track.last_measurement.visual_radius
			+ track.uncertainty_radius
		)
		_accumulate_hazard(position.length() - radius, HAZARD_DISTANCE, step_seconds, outcome)

	for warning in observation.visible_world.spawn_warnings:
		if warning.disposition != "hostile":
			continue
		var clearance := (warning.relative_position - sample.displacement).length() - PLAYER_RADIUS
		_accumulate_hazard(clearance, HAZARD_DISTANCE, step_seconds, outcome)

	_accumulate_edge_hazard(
		observation.localization.map_bounds, sample.displacement, step_seconds, outcome
	)
	_accumulate_ranged_source_pressure(observation.enemy_tracks, sample, step_seconds, outcome)


# Uses the closest point on every predicted projectile segment. Fast Brotato
# projectiles can cross hundreds of pixels between trajectory samples, so
# endpoint-only proximity checks would miss direct intersections.
func _predict_projectile_hazards(
	observation: Dictionary, samples: Array, step_seconds: float, outcome: Dictionary
) -> void:
	for projectile in observation.visible_world.enemy_projectiles:
		var previous_position: Vector2 = projectile.relative_position
		for sample in samples:
			var position: Vector2 = _motion_predictor.predict_position(
				projectile.relative_position,
				projectile.velocity,
				projectile.acceleration,
				projectile.motion_confidence,
				sample.time
			)
			position -= sample.displacement
			var closest_position := _closest_point_to_origin(previous_position, position)
			var clearance := closest_position.length() - PLAYER_RADIUS - projectile.visual_radius
			_accumulate_hazard(clearance, PROJECTILE_HAZARD_DISTANCE, step_seconds, outcome)
			previous_position = position


func _closest_point_to_origin(segment_start: Vector2, segment_end: Vector2) -> Vector2:
	var segment := segment_end - segment_start
	var length_squared := segment.length_squared()
	if length_squared <= 0.0:
		return segment_start
	var fraction := clamp(-segment_start.dot(segment) / length_squared, 0.0, 1.0)
	return segment_start + segment * fraction


func _accumulate_ranged_source_pressure(
	tracks: Array, sample: Dictionary, step_seconds: float, outcome: Dictionary
) -> void:
	for track in tracks:
		if not track.behavior_profile.strategic_roles.ranged_pressure_source:
			continue
		var position := _predict_track_position(track, sample.time) - sample.displacement
		var pressure_distance: float = track.behavior_profile.attack_behavior.get(
			"maximum_range", RANGED_SOURCE_PRESSURE_DISTANCE
		)
		pressure_distance = max(1.0, pressure_distance)
		var minimum_pressure_distance: float = track.behavior_profile.attack_behavior.get(
			"minimum_range", 0.0
		)
		var clearance: float = (
			position.length()
			- track.last_measurement.visual_radius
			- track.uncertainty_radius
		)
		var proximity := clamp((pressure_distance - clearance) / pressure_distance, 0.0, 1.0)
		if minimum_pressure_distance > 0.0:
			proximity *= clamp(position.length() / minimum_pressure_distance, 0.0, 1.0)
		outcome.ranged_source_pressure += (
			proximity
			* proximity
			* step_seconds
			* track.recency_confidence
			* track.behavior_profile.attack_behavior.confidence
			* track.behavior_profile.attack_behavior.pressure_intensity
		)


func _accumulate_hazard(
	clearance: float, danger_distance: float, step_seconds: float, outcome: Dictionary
) -> void:
	var proximity := clamp((danger_distance - clearance) / danger_distance, 0.0, 1.0)
	outcome.hazard_exposure += proximity * proximity * step_seconds
	var contact_pressure := clamp((PLAYER_RADIUS - clearance) / PLAYER_RADIUS, 0.0, 1.0)
	outcome.contact_pressure = max(outcome.contact_pressure, contact_pressure)


func _accumulate_edge_hazard(
	bounds: Dictionary, displacement: Vector2, step_seconds: float, outcome: Dictionary
) -> void:
	var future_distances := [
		_add_if_known(bounds.distance_to_left, displacement.x),
		_add_if_known(bounds.distance_to_right, -displacement.x),
		_add_if_known(bounds.distance_to_top, displacement.y),
		_add_if_known(bounds.distance_to_bottom, -displacement.y),
	]
	for distance in future_distances:
		if distance == null:
			continue
		if distance < EDGE_MARGIN:
			var proximity := clamp((EDGE_MARGIN - distance) / EDGE_MARGIN, 0.0, 1.0)
			outcome.hazard_exposure += proximity * proximity * step_seconds


func _collection_value(entities: Array, samples: Array, pickup: Dictionary) -> float:
	var value := 0.0
	for entity in entities:
		var closest_distance := entity.relative_position.length()
		for sample in samples:
			closest_distance = min(
				closest_distance, (entity.relative_position - sample.displacement).length()
			)
		if closest_distance <= pickup.collection_radius:
			value += 1.0
		elif closest_distance <= pickup.attraction_radius:
			value += 0.7
		else:
			value += max(0.0, 1.0 - closest_distance / 500.0) * 0.15
	return value


func _tree_attack_opportunity(observation: Dictionary, trajectory: Dictionary) -> float:
	var maximum_range := _usable_weapon_range(
		observation.player_state.weapons, trajectory.movement != Vector2.ZERO
	)
	if maximum_range <= 0.0:
		return 0.0
	var interaction := 0.0
	for tree in observation.visible_world.trees:
		var initial_distance := tree.relative_position.length()
		var closest_distance := initial_distance
		for sample in trajectory.samples:
			closest_distance = min(
				closest_distance, (tree.relative_position - sample.displacement).length()
			)
		if closest_distance <= maximum_range:
			interaction += 1.0
		elif initial_distance > 0.0:
			interaction += max(0.0, initial_distance - closest_distance) / initial_distance * 0.3
	return interaction


func _target_approach_progress(tracks: Array, samples: Array, role: String) -> float:
	var progress := 0.0
	var final_displacement: Vector2 = samples.back().displacement
	for track in tracks:
		if not track.behavior_profile.strategic_roles[role]:
			continue
		var initial_distance: float = track.relative_position.length()
		if initial_distance <= 0.0:
			continue
		var predicted_position := _predict_track_position(track, samples.back().time)
		var final_distance: float = (predicted_position - final_displacement).length()
		progress += (
			clamp((initial_distance - final_distance) / initial_distance, -1.0, 1.0)
			* track.recency_confidence
		)
	return progress


func _ranged_source_engagement_progress(observation: Dictionary, trajectory: Dictionary) -> float:
	# Movement can prepare a later stationary attack, so this strategic coarse
	# estimate considers owned weapon reach even when movement suppresses attacks.
	var maximum_range := _maximum_weapon_range(observation.player_state.weapons)
	if maximum_range <= 0.0:
		return 0.0
	var final_sample: Dictionary = trajectory.samples.back()
	var progress := 0.0
	for track in observation.enemy_tracks:
		if not track.behavior_profile.strategic_roles.ranged_pressure_source:
			continue
		var attack_range := maximum_range + track.last_measurement.visual_radius
		var initial_distance: float = track.relative_position.length()
		var initial_gap := max(0.0, initial_distance - attack_range)
		if initial_gap <= 0.0:
			continue
		var predicted_position := _predict_track_position(track, final_sample.time)
		var final_distance: float = (predicted_position - final_sample.displacement).length()
		var final_gap := max(0.0, final_distance - attack_range)
		progress += (
			clamp((initial_gap - final_gap) / initial_distance, -1.0, 1.0)
			* track.recency_confidence
			* track.behavior_profile.attack_behavior.confidence
			* track.behavior_profile.attack_behavior.pressure_intensity
		)
	return progress


func _targets_in_weapon_range(observation: Dictionary, trajectory: Dictionary) -> float:
	var maximum_range := _usable_weapon_range(
		observation.player_state.weapons, trajectory.movement != Vector2.ZERO
	)
	if maximum_range <= 0.0:
		return 0.0
	var final_sample: Dictionary = trajectory.samples.back()
	var opportunity := 0.0
	for track in observation.enemy_tracks:
		var position := (
			_predict_track_position(track, final_sample.time)
			- final_sample.displacement
		)
		if position.length() <= maximum_range + track.last_measurement.visual_radius:
			opportunity += track.recency_confidence
	return opportunity


func _predict_track_position(track: Dictionary, time: float) -> Vector2:
	return _motion_predictor.predict_position(
		track.relative_position,
		track.estimated_velocity,
		track.estimated_acceleration,
		track.motion_confidence,
		time
	)


func _usable_weapon_range(weapons: Array, is_moving: bool) -> float:
	var result := 0.0
	for weapon in weapons:
		if is_moving and not weapon.automatic_attacks_allowed_while_moving:
			continue
		result = max(result, float(weapon.maximum_range))
	return result


func _maximum_weapon_range(weapons: Array) -> float:
	var result := 0.0
	for weapon in weapons:
		result = max(result, float(weapon.maximum_range))
	return result


func _add_if_known(value, addition: float):
	return null if value == null else value + addition
