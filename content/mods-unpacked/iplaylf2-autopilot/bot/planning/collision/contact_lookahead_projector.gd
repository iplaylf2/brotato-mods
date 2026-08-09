extends Reference

# Extends only geometric contact evidence beyond the detailed action forecast.
# Tactical rewards, weapon outcomes, rules, and environmental channels retain
# the shorter controllability window; this projector supplies the lookahead
# contact cost needed to avoid entering a path that cannot clear one local body
# traversal before the next observations arrive.

const PlanningTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/planning_timing_model.gd"
)
const PlayerKinematicsModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_kinematics_model.gd"
)
const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)
const ProjectileMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/projectile_motion_predictor.gd"
)
const ContactOpportunityProjector := preload("contact_opportunity_projector.gd")

const MAX_PROJECTILE_PHASE_STEP := PI / 2.0

var _player_kinematics: Reference = PlayerKinematicsModel.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _projectile_motion_predictor: Reference = ProjectileMotionPredictor.new()
var _contact_opportunity_projector: Reference = ContactOpportunityProjector.new()


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_enemy_motion_predictor = predictor


func project(observation: Dictionary, action: Dictionary) -> Dictionary:
	_enemy_motion_predictor.begin_physics_frame(observation.get("physics_frame", -1))
	var start_seconds: float = max(0.0, action.forecast_seconds)
	var horizon_seconds: float = max(
		start_seconds, action.get("contact_forecast_seconds", start_seconds)
	)
	var result := _empty_result(horizon_seconds)
	if horizon_seconds <= start_seconds + 0.0001:
		return result

	var timing: Dictionary = PlanningTimingModel.derive(observation)
	var step_count := int(
		max(
			1,
			ceil(
				(
					(horizon_seconds - start_seconds)
					/ max(0.001, timing.tactical_control_interval_seconds)
				)
			)
		)
	)
	# Preserve the same curved-projectile resolution contract as the detailed
	# action lattice. A cheap extension is still a continuous geometry forecast,
	# not a chord approximation across an arbitrary amount of trajectory phase.
	for projectile in observation.visible_world.enemy_projectiles:
		step_count = max(
			step_count,
			int(
				ceil(
					(
						_projectile_motion_predictor.maximum_angular_velocity(projectile)
						* (horizon_seconds - start_seconds)
						/ MAX_PROJECTILE_PHASE_STEP
					)
				)
			)
		)
	var previous_time := start_seconds
	var previous_player_displacement: Vector2 = _player_kinematics.predict_displacement(
		observation, action.movement, start_seconds
	)
	var previous_enemy_positions := []
	for track in observation.enemy_tracks:
		previous_enemy_positions.push_back(
			(
				_enemy_motion_predictor.predict_position(
					track, start_seconds, previous_player_displacement
				)
				- previous_player_displacement
			)
		)
	var projectiles: Array = observation.visible_world.enemy_projectiles
	var previous_projectile_positions := []
	for projectile in projectiles:
		previous_projectile_positions.push_back(
			(
				_projectile_motion_predictor.predict_position(projectile, start_seconds)
				- previous_player_displacement
			)
		)

	for step in range(1, step_count + 1):
		var fraction := float(step) / float(step_count)
		var time: float = lerp(start_seconds, horizon_seconds, fraction)
		var player_displacement: Vector2 = _player_kinematics.predict_displacement(
			observation, action.movement, time
		)
		var step_seconds: float = time - previous_time
		_project_enemy_contacts(
			observation, time, step_seconds, player_displacement, previous_enemy_positions, result
		)
		_project_projectile_contacts(
			observation,
			time,
			step_seconds,
			player_displacement,
			previous_projectile_positions,
			result
		)
		previous_time = time
	return result


func _project_enemy_contacts(
	observation: Dictionary,
	time: float,
	step_seconds: float,
	player_displacement: Vector2,
	previous_positions: Array,
	result: Dictionary
) -> void:
	var player_radius: float = observation.player_state.collision_radius
	for track_index in observation.enemy_tracks.size():
		var track: Dictionary = observation.enemy_tracks[track_index]
		var current_position: Vector2 = (
			_enemy_motion_predictor.predict_position(track, time, player_displacement)
			- player_displacement
		)
		var combined_radius: float = player_radius + track.behavior_profile.contact_radius
		var intersection_fraction := _first_circle_intersection_fraction(
			previous_positions[track_index], current_position, combined_radius
		)
		previous_positions[track_index] = current_position
		if intersection_fraction < 0.0:
			continue
		var realization_probability: float = clamp(track.recency_confidence, 0.0, 1.0)
		var contact_time := time - step_seconds * (1.0 - intersection_fraction)
		result.contact_opportunities.push_back(
			_contact_opportunity_projector.project_enemy_contact(
				contact_time, track, realization_probability
			)
		)
		_accumulate_evidence(
			result, realization_probability, track.behavior_profile.contact_damage, step_seconds
		)


func _project_projectile_contacts(
	observation: Dictionary,
	time: float,
	step_seconds: float,
	player_displacement: Vector2,
	previous_positions: Array,
	result: Dictionary
) -> void:
	var player_radius: float = observation.player_state.collision_radius
	var projectiles: Array = observation.visible_world.enemy_projectiles
	for projectile_index in projectiles.size():
		var projectile: Dictionary = projectiles[projectile_index]
		var current_position: Vector2 = (
			_projectile_motion_predictor.predict_position(projectile, time)
			- player_displacement
		)
		var combined_radius: float = player_radius + projectile.contact_radius
		var intersection_fraction := _first_circle_intersection_fraction(
			previous_positions[projectile_index], current_position, combined_radius
		)
		previous_positions[projectile_index] = current_position
		if intersection_fraction < 0.0:
			continue
		var contact_time := time - step_seconds * (1.0 - intersection_fraction)
		result.contact_opportunities.push_back(
			_contact_opportunity_projector.project_projectile_contact(
				contact_time, projectile_index, projectile, 1.0
			)
		)
		_accumulate_evidence(result, 1.0, projectile.contact_damage, step_seconds)


func _accumulate_evidence(
	result: Dictionary, realization_probability: float, raw_damage: float, step_seconds: float
) -> void:
	result.peak_collision_risk = max(result.peak_collision_risk, realization_probability)
	result.contact_evidence_seconds += realization_probability * step_seconds
	result.raw_damage_evidence_seconds += (
		realization_probability
		* max(0.0, raw_damage)
		* step_seconds
	)
	result.maximum_raw_damage = max(result.maximum_raw_damage, raw_damage)


func _first_circle_intersection_fraction(start: Vector2, finish: Vector2, radius: float) -> float:
	# When the extension starts inside an overlap, emit the next sampled contact
	# rather than duplicating the detailed window's terminal opportunity. Repeated
	# samples remain useful because the health state model owns invulnerability.
	if start.length_squared() <= radius * radius:
		return 1.0
	var segment: Vector2 = finish - start
	var a: float = segment.length_squared()
	if a <= 0.000001:
		return -1.0
	var b: float = 2.0 * start.dot(segment)
	var c: float = start.length_squared() - radius * radius
	var discriminant: float = b * b - 4.0 * a * c
	if discriminant < 0.0:
		return -1.0
	var root: float = (-b - sqrt(discriminant)) / (2.0 * a)
	return root if root >= 0.0 and root <= 1.0 else -1.0


func _empty_result(horizon_seconds: float) -> Dictionary:
	return {
		"horizon_seconds": horizon_seconds,
		"peak_collision_risk": 0.0,
		"contact_evidence_seconds": 0.0,
		"raw_damage_evidence_seconds": 0.0,
		"maximum_raw_damage": 0.0,
		"contact_opportunities": [],
	}
