extends Reference

# Evaluates environmental exposure and position-domain collision evidence along
# a candidate path. Allied suppression can reduce eligible exposure, while
# collision evidence is unified with velocity-space risk by
# MovementOutcomePredictor.

const ObservedMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/observed_motion_predictor.gd"
)
const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const ProjectileMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/projectile_motion_predictor.gd"
)

const RANGED_SOURCE_PRESSURE_DISTANCE := 650.0

var _observed_motion_predictor: Reference = ObservedMotionPredictor.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _projectile_motion_predictor: Reference = ProjectileMotionPredictor.new()


func predict(
	observation: Dictionary, action_forecast: Dictionary, exposure_policy: Dictionary
) -> Dictionary:
	var result := _empty_result()
	var initial: Dictionary = sample_point(observation, Vector2.ZERO, 0.0, exposure_policy)
	result.initial_environmental_pressure = initial.environmental_pressure
	var samples: Array = action_forecast.samples
	assert(not samples.empty())
	var sources := _get_influence_sources(observation)
	var geometry: Dictionary = _movement_geometry.derive(observation)
	var consumed_single_use_sources := {}
	var interception_samples := _find_projectile_interception_samples(
		observation, samples, geometry
	)
	var previous_projectile_positions := []
	for projectile in observation.visible_world.enemy_projectiles:
		previous_projectile_positions.push_back(projectile.relative_position)

	var previous_time := 0.0
	for sample_index in samples.size():
		var sample: Dictionary = samples[sample_index]
		var step_seconds: float = max(0.0, sample.time - previous_time)
		var channels := _sample_channels(
			observation,
			sample,
			sample_index,
			sources,
			consumed_single_use_sources,
			interception_samples,
			previous_projectile_positions,
			geometry
		)
		var exposure := _evaluate_channels(channels, exposure_policy)
		_accumulate_result(result, channels, exposure, step_seconds)
		previous_time = sample.time
	var final_sample: Dictionary = samples.back()
	var terminal: Dictionary = sample_point(
		observation, final_sample.displacement, final_sample.time, exposure_policy
	)
	result.terminal_environmental_pressure = terminal.environmental_pressure
	# This endpoint quotient is the mean material derivative of P(x(t), t)
	# along the candidate velocity, not the Eulerian change at a fixed point.
	result.mean_environmental_pressure_derivative = (
		(result.terminal_environmental_pressure - result.initial_environmental_pressure)
		/ max(0.01, action_forecast.forecast_seconds)
	)
	return result


# The collision-outcome pass must retain angular coverage under load without paying for
# economy, allied influence, healing, or ambient-pressure interactions.
func predict_collision(
	observation: Dictionary, action_forecast: Dictionary, exposure_policy: Dictionary
) -> Dictionary:
	var peak_path_collision_risk := 0.0
	var integrated_hostile_collision_risk := 0.0
	var maximum_path_collision_damage := 0.0
	var samples: Array = action_forecast.samples
	var geometry: Dictionary = _movement_geometry.derive(observation)
	var previous_projectile_positions := []
	for projectile in observation.visible_world.enemy_projectiles:
		previous_projectile_positions.push_back(projectile.relative_position)
	var previous_time := 0.0
	for sample_index in samples.size():
		var sample: Dictionary = samples[sample_index]
		var step_seconds: float = max(0.0, sample.time - previous_time)
		var channels := _empty_channels()
		_sample_enemy_pressure(observation.enemy_tracks, sample, channels, geometry)
		_sample_projectile_pressure(
			observation.visible_world.enemy_projectiles,
			sample,
			sample_index,
			{},
			previous_projectile_positions,
			channels,
			geometry
		)
		var exposure: Dictionary = _evaluate_channels(channels, exposure_policy)
		peak_path_collision_risk = max(peak_path_collision_risk, exposure.path_collision_risk)
		integrated_hostile_collision_risk += exposure.path_collision_risk * step_seconds
		maximum_path_collision_damage = max(maximum_path_collision_damage, channels.contact_damage)
		previous_time = sample.time
	return {
		"peak_path_collision_risk": peak_path_collision_risk,
		"integrated_hostile_collision_risk": integrated_hostile_collision_risk,
		"maximum_path_collision_damage": maximum_path_collision_damage,
	}


# Point queries support navigation terminal estimates. They describe exposure at
# (position, time), while predict() retains swept-path handling for a forecast.
func sample_point(
	observation: Dictionary, displacement: Vector2, time: float, exposure_policy: Dictionary
) -> Dictionary:
	var sample := {"time": time, "displacement": displacement, "movement": Vector2.ZERO}
	var channels := _empty_channels()
	var geometry: Dictionary = _movement_geometry.derive(observation)
	_sample_enemy_pressure(observation.enemy_tracks, sample, channels, geometry)
	_sample_spawn_pressure(observation.visible_world.spawn_warnings, sample, channels, geometry)
	_sample_edge_pressure(observation.localization.map_bounds, displacement, channels, geometry)
	_sample_allied_pressure(
		observation, _get_influence_sources(observation), sample, 0, {}, channels, geometry
	)
	_sample_projectile_point_pressure(
		observation.visible_world.enemy_projectiles, sample, channels, geometry
	)
	_saturate_channels(channels)
	var exposure := _evaluate_channels(channels, exposure_policy)
	return {
		"hostile_exposure": exposure.hostile_exposure,
		"exposure_relief": exposure.exposure_relief,
		"environmental_pressure": exposure.environmental_pressure,
		"path_collision_risk": exposure.path_collision_risk,
		"healing_support": channels.healing_support,
		"channels": channels,
	}


func _sample_channels(
	observation: Dictionary,
	sample: Dictionary,
	sample_index: int,
	sources: Array,
	consumed_single_use_sources: Dictionary,
	interception_samples: Dictionary,
	previous_projectile_positions: Array,
	geometry: Dictionary
) -> Dictionary:
	var channels := _empty_channels()
	_sample_enemy_pressure(observation.enemy_tracks, sample, channels, geometry)
	_sample_spawn_pressure(observation.visible_world.spawn_warnings, sample, channels, geometry)
	_sample_edge_pressure(
		observation.localization.map_bounds, sample.displacement, channels, geometry
	)
	_sample_allied_pressure(
		observation, sources, sample, sample_index, consumed_single_use_sources, channels, geometry
	)
	_sample_projectile_pressure(
		observation.visible_world.enemy_projectiles,
		sample,
		sample_index,
		interception_samples,
		previous_projectile_positions,
		channels,
		geometry
	)
	_saturate_channels(channels)
	return channels


func _sample_enemy_pressure(
	tracks: Array, sample: Dictionary, channels: Dictionary, geometry: Dictionary
) -> void:
	for track in tracks:
		var position: Vector2 = (
			_predict_enemy_position(track, sample.time, sample.displacement)
			- sample.displacement
		)
		var uncertain_clearance: float = (
			position.length()
			- geometry.player_radius
			- track.last_measurement.visual_radius
			- track.uncertainty_radius
		)
		var proximity := clamp(
			(
				(geometry.enemy_pressure_distance - uncertain_clearance)
				/ geometry.enemy_pressure_distance
			),
			0.0,
			1.0
		)
		channels.enemy_proximity += proximity * proximity * track.recency_confidence

		var physical_clearance: float = (
			position.length()
			- geometry.player_radius
			- track.last_measurement.visual_radius
		)
		var contact := clamp(-physical_clearance / geometry.player_radius, 0.0, 1.0)
		channels.contact = max(channels.contact, contact * track.recency_confidence)
		if contact > 0.0:
			channels.contact_damage = max(
				channels.contact_damage, track.behavior_profile.get("contact_damage", 1.0)
			)
		_accumulate_ranged_pressure(track, position, sample.time, channels)
		_accumulate_charge_pressure(track, position, sample.time, channels, geometry)


func _accumulate_charge_pressure(
	track: Dictionary,
	position: Vector2,
	sample_time: float,
	channels: Dictionary,
	geometry: Dictionary
) -> void:
	var charge_attack: Dictionary = track.behavior_profile.get("charge_attack", {})
	if not charge_attack.get("active", false):
		return
	var charge_window: Dictionary = track.behavior_profile.get("next_charge_attack_window", {})
	var readiness := 1.0
	if charge_window.get("is_exact", false):
		readiness = 0.0 if sample_time < charge_window.earliest_seconds else 1.0
	elif charge_window.get("latest_seconds", INF) != INF:
		readiness = clamp(
			(
				(sample_time - charge_window.get("earliest_seconds", 0.0))
				/ max(
					0.01, charge_window.latest_seconds - charge_window.get("earliest_seconds", 0.0)
				)
			),
			0.0,
			1.0
		)
	if readiness <= 0.0:
		return
	var physical_clearance: float = (
		position.length()
		- geometry.player_radius
		- track.last_measurement.visual_radius
	)
	var pressure_distance: float = min(
		max(0.0, charge_attack.get("maximum_range", 0.0)),
		max(0.0, charge_attack.get("maximum_travel_distance", 0.0))
	)
	if pressure_distance <= 0.0:
		return
	var reach: float = clamp((pressure_distance - physical_clearance) / pressure_distance, 0.0, 1.0)
	channels.enemy_proximity += (
		reach
		* reach
		* readiness
		* track.recency_confidence
		* clamp(charge_attack.get("confidence", 0.0), 0.0, 1.0)
	)


func _accumulate_ranged_pressure(
	track: Dictionary, position: Vector2, sample_time: float, channels: Dictionary
) -> void:
	var projectile_attack: Dictionary = track.behavior_profile.projectile_attack
	if not projectile_attack.get("creates_projectile_pressure", false):
		return
	var pressure_distance: float = max(
		1.0, float(projectile_attack.get("maximum_range", RANGED_SOURCE_PRESSURE_DISTANCE))
	)
	var minimum_distance: float = projectile_attack.get("minimum_range", 0.0)
	var clearance: float = (
		position.length()
		- track.last_measurement.visual_radius
		- track.uncertainty_radius
	)
	var proximity := clamp((pressure_distance - clearance) / pressure_distance, 0.0, 1.0)
	if minimum_distance > 0.0:
		proximity *= clamp(position.length() / minimum_distance, 0.0, 1.0)
	var volley_pressure_factor := 1.0
	var volley_window: Dictionary = track.behavior_profile.get("next_volley_window", {})
	if volley_window.get("is_exact", false):
		volley_pressure_factor = (0.0 if sample_time < volley_window.earliest_seconds else 1.0)
	channels.ranged += (
		proximity
		* proximity
		* track.recency_confidence
		* projectile_attack.confidence
		* projectile_attack.pressure_intensity
		* volley_pressure_factor
	)


func _sample_spawn_pressure(
	warnings: Array, sample: Dictionary, channels: Dictionary, geometry: Dictionary
) -> void:
	for warning in warnings:
		if warning.disposition != "hostile":
			continue
		var clearance: float = (
			(warning.relative_position - sample.displacement).length()
			- geometry.player_radius
		)
		var proximity := clamp(
			(geometry.enemy_pressure_distance - clearance) / geometry.enemy_pressure_distance,
			0.0,
			1.0
		)
		channels.spawn += proximity * proximity


func _sample_edge_pressure(
	bounds: Dictionary, displacement: Vector2, channels: Dictionary, geometry: Dictionary
) -> void:
	var future_distances := [
		_add_if_known(bounds.distance_to_left, displacement.x),
		_add_if_known(bounds.distance_to_right, -displacement.x),
		_add_if_known(bounds.distance_to_top, displacement.y),
		_add_if_known(bounds.distance_to_bottom, -displacement.y),
	]
	for distance in future_distances:
		if distance == null or distance >= geometry.edge_margin:
			continue
		var proximity := clamp((geometry.edge_margin - distance) / geometry.edge_margin, 0.0, 1.0)
		channels.edge += proximity * proximity


func _sample_allied_pressure(
	observation: Dictionary,
	sources: Array,
	sample: Dictionary,
	sample_index: int,
	consumed_single_use_sources: Dictionary,
	channels: Dictionary,
	geometry: Dictionary
) -> void:
	for source_index in sources.size():
		var source: Dictionary = sources[source_index]
		var relief: Dictionary = source.influence.pressure_relief
		if relief.active and relief.radius > 0.0:
			if not relief.single_use:
				channels.allied_suppression += _source_suppression(
					observation.enemy_tracks, source, relief, sample, geometry
				)
			elif (
				not consumed_single_use_sources.has(source_index)
				and _has_single_use_trigger(observation.enemy_tracks, source, relief, sample)
			):
				channels.allied_suppression += _source_suppression(
					observation.enemy_tracks, source, relief, sample, geometry, true
				)
				consumed_single_use_sources[source_index] = sample_index

		var healing: Dictionary = source.influence.healing_support
		if healing.active and healing.radius > 0.0:
			channels.healing_support += _source_healing_support(
				observation, source, healing, sample
			)

		if source.kind == "player":
			channels.ally_body += _ally_body_pressure(source, sample, geometry)


func _source_suppression(
	tracks: Array,
	source: Dictionary,
	relief: Dictionary,
	sample: Dictionary,
	geometry: Dictionary,
	require_visible_targets := false
) -> float:
	var source_position := _predict_source_position(source, sample.time)
	var player_activation_radius: float = relief.get("player_activation_radius", 0.0)
	if (
		player_activation_radius > 0.0
		and (source_position - sample.displacement).length() > player_activation_radius
	):
		return 0.0
	var covered_pressure := 0.0
	var strongest_relief := 0.0
	for track in tracks:
		if require_visible_targets and not track.visible:
			continue
		var enemy_position: Vector2 = _predict_enemy_position(
			track, sample.time, sample.displacement
		)
		var support_distance: float = (enemy_position - source_position).length()
		if support_distance > relief.radius + track.last_measurement.visual_radius:
			continue
		var player_distance: float = (enemy_position - sample.displacement).length()
		var pressure: float = clamp(
			(
				(geometry.enemy_pressure_distance * 2.0 - player_distance)
				/ (geometry.enemy_pressure_distance * 2.0)
			),
			0.0,
			1.0
		)
		var coverage := clamp(1.25 - support_distance / relief.radius, 0.25, 1.0)
		var relieved_pressure: float = pressure * coverage * track.recency_confidence
		covered_pressure += relieved_pressure
		strongest_relief = max(strongest_relief, relieved_pressure)
	var target_capacity: float = max(0.0, relief.get("simultaneous_target_capacity", INF))
	if target_capacity <= 1.0:
		covered_pressure = strongest_relief * target_capacity
	else:
		covered_pressure = min(covered_pressure, target_capacity)
	return min(2.0, covered_pressure) * relief.intensity * source.get("existence_confidence", 1.0)


func _has_single_use_trigger(
	tracks: Array, source: Dictionary, relief: Dictionary, sample: Dictionary
) -> bool:
	var source_position := _predict_source_position(source, sample.time)
	for track in tracks:
		# A remembered trajectory is useful ambient pressure evidence, but cannot
		# claim that an irreversible trigger will actually be consumed.
		if not track.visible:
			continue
		var enemy_position := _predict_enemy_position(track, sample.time, sample.displacement)
		var trigger_radius: float = relief.activation_radius + track.last_measurement.visual_radius
		if (enemy_position - source_position).length() <= trigger_radius:
			return true
	return false


func _source_healing_support(
	observation: Dictionary, source: Dictionary, healing: Dictionary, sample: Dictionary
) -> float:
	var source_position: Vector2 = _predict_source_position(source, sample.time)
	var distance: float = (source_position - sample.displacement).length()
	var coverage: float = clamp((healing.radius - distance) / healing.radius, 0.0, 1.0)
	var opportunity := 1.0
	if healing.get("requires_recovery_opportunity", false):
		var effective_stats: Dictionary = observation.player_state.effective_stats
		opportunity = clamp(
			(effective_stats.health_regeneration + effective_stats.lifesteal) / 20.0, 0.0, 1.0
		)
	return coverage * healing.intensity * opportunity * source.get("existence_confidence", 1.0)


func _ally_body_pressure(ally: Dictionary, sample: Dictionary, geometry: Dictionary) -> float:
	var ally_position: Vector2 = _predict_source_position(ally, sample.time)
	var clearance: float = (
		(ally_position - sample.displacement).length()
		- geometry.player_radius
		- ally.visual_radius
	)
	var proximity: float = clamp(
		(geometry.ally_body_margin - clearance) / geometry.ally_body_margin, 0.0, 1.0
	)
	return proximity * proximity


func _sample_projectile_pressure(
	projectiles: Array,
	sample: Dictionary,
	sample_index: int,
	interception_samples: Dictionary,
	previous_positions: Array,
	channels: Dictionary,
	geometry: Dictionary
) -> void:
	for projectile_index in projectiles.size():
		var projectile: Dictionary = projectiles[projectile_index]
		var position: Vector2 = (
			_predict_projectile_position(projectile, sample.time)
			- sample.displacement
		)
		var interception_sample: int = interception_samples.get(projectile_index, -1)
		var closest_position: Vector2 = _closest_point_to_origin(
			previous_positions[projectile_index], position
		)
		var clearance: float = (
			closest_position.length()
			- geometry.player_radius
			- projectile.visual_radius
		)
		var proximity: float = clamp(
			(
				(geometry.projectile_pressure_distance - clearance)
				/ geometry.projectile_pressure_distance
			),
			0.0,
			1.0
		)
		var projectile_pressure: float = proximity * proximity
		channels.projectile += projectile_pressure
		channels.projectile_contact = max(
			channels.projectile_contact, clamp(-clearance / geometry.player_radius, 0.0, 1.0)
		)
		if clearance < 0.0:
			channels.contact_damage = max(
				channels.contact_damage, projectile.get("contact_damage", 1.0)
			)
		if interception_sample >= 0 and sample_index >= interception_sample:
			channels.projectile_interception += projectile_pressure
			channels.projectile_contact_interception = max(
				channels.projectile_contact_interception, channels.projectile_contact
			)
		previous_positions[projectile_index] = position


func _sample_projectile_point_pressure(
	projectiles: Array, sample: Dictionary, channels: Dictionary, geometry: Dictionary
) -> void:
	for projectile in projectiles:
		var position: Vector2 = (
			_predict_projectile_position(projectile, sample.time)
			- sample.displacement
		)
		var clearance: float = position.length() - geometry.player_radius - projectile.visual_radius
		var proximity: float = clamp(
			(
				(geometry.projectile_pressure_distance - clearance)
				/ geometry.projectile_pressure_distance
			),
			0.0,
			1.0
		)
		channels.projectile += proximity * proximity
		channels.projectile_contact = max(
			channels.projectile_contact, clamp(-clearance / geometry.player_radius, 0.0, 1.0)
		)
		if clearance < 0.0:
			channels.contact_damage = max(
				channels.contact_damage, projectile.get("contact_damage", 1.0)
			)


func _find_projectile_interception_samples(
	observation: Dictionary, samples: Array, geometry: Dictionary
) -> Dictionary:
	var result := {}
	for projectile_index in observation.visible_world.enemy_projectiles.size():
		var projectile: Dictionary = observation.visible_world.enemy_projectiles[projectile_index]
		var earliest_sample := -1
		for ally in observation.visible_world.get("allied_agents", []):
			var interception: Dictionary = ally.influence.projectile_interception
			if not interception.active or interception.radius <= 0.0:
				continue
			var sample_index: int = _find_interception_sample(
				ally, interception, projectile, samples, geometry
			)
			if sample_index >= 0 and (earliest_sample < 0 or sample_index < earliest_sample):
				earliest_sample = sample_index
		if earliest_sample >= 0:
			result[projectile_index] = earliest_sample
	return result


func _find_interception_sample(
	ally: Dictionary,
	interception: Dictionary,
	projectile: Dictionary,
	samples: Array,
	geometry: Dictionary
) -> int:
	var previous_projectile: Vector2 = projectile.relative_position
	var previous_ally: Vector2 = ally.relative_position
	var previous_player_relative: Vector2 = projectile.relative_position
	for sample_index in samples.size():
		var sample: Dictionary = samples[sample_index]
		var projectile_position: Vector2 = _predict_projectile_position(projectile, sample.time)
		var ally_position: Vector2 = _predict_source_position(ally, sample.time)
		var player_relative: Vector2 = projectile_position - sample.displacement
		var shield_relative_start: Vector2 = previous_projectile - previous_ally
		var shield_relative_end: Vector2 = projectile_position - ally_position
		var shield_fraction: float = _closest_fraction_to_origin(
			shield_relative_start, shield_relative_end
		)
		var player_fraction: float = _closest_fraction_to_origin(
			previous_player_relative, player_relative
		)
		var crosses_shield: bool = (
			(shield_relative_start.linear_interpolate(shield_relative_end, shield_fraction)).length()
			<= interception.radius + projectile.visual_radius
		)
		var threatens_player: bool = (
			(previous_player_relative.linear_interpolate(player_relative, player_fraction)).length()
			<= (
				geometry.projectile_pressure_distance
				+ geometry.player_radius
				+ projectile.visual_radius
			)
		)
		if crosses_shield and threatens_player and shield_fraction <= player_fraction:
			return sample_index
		previous_projectile = projectile_position
		previous_ally = ally_position
		previous_player_relative = player_relative
	return -1


func _evaluate_channels(channels: Dictionary, policy: Dictionary) -> Dictionary:
	var collision_hostile: float = (
		channels.contact * policy.enemy_contact
		+ channels.projectile_contact * policy.projectile_contact
	)
	var suppressible_enemy_ambient: float = (
		channels.enemy_proximity * policy.enemy_proximity
		+ channels.ranged * policy.ranged_attack
	)
	var spawn_exposure: float = channels.spawn * policy.spawn_warning
	var positional: float = (
		channels.edge * policy.map_edge
		+ channels.ally_body * policy.allied_body_proximity
	)
	var ambient_relief: float = min(
		suppressible_enemy_ambient, channels.allied_suppression * policy.allied_pressure_relief
	)
	var interception_relief: float = min(
		channels.projectile_contact * policy.projectile_contact,
		channels.projectile_contact_interception * policy.projectile_interception_relief
	)
	var collision: float = _saturate(max(0.0, collision_hostile - interception_relief))
	var environmental: float = max(
		0.0, suppressible_enemy_ambient + spawn_exposure + positional - ambient_relief
	)
	var relief: float = ambient_relief + interception_relief
	var hostile: float = (
		collision_hostile
		+ suppressible_enemy_ambient
		+ spawn_exposure
		+ positional
	)
	return {
		"hostile_exposure": hostile,
		"exposure_relief": relief,
		"environmental_pressure": environmental,
		"path_collision_risk": collision,
	}


func _accumulate_result(
	result: Dictionary, channels: Dictionary, exposure: Dictionary, step_seconds: float
) -> void:
	result.integrated_enemy_proximity_pressure += channels.enemy_proximity * step_seconds
	result.integrated_projectile_proximity_pressure += channels.projectile * step_seconds
	result.peak_projectile_contact_risk = max(
		result.peak_projectile_contact_risk, channels.projectile_contact
	)
	result.integrated_spawn_pressure += channels.spawn * step_seconds
	result.integrated_ranged_attack_pressure += channels.ranged * step_seconds
	result.integrated_edge_pressure += channels.edge * step_seconds
	result.integrated_allied_body_pressure += channels.ally_body * step_seconds
	result.peak_enemy_contact_risk = max(result.peak_enemy_contact_risk, channels.contact)
	result.integrated_allied_pressure_relief += channels.allied_suppression * step_seconds
	result.integrated_allied_healing_support += channels.healing_support * step_seconds
	result.integrated_projectile_interception_relief += (
		channels.projectile_interception
		* step_seconds
	)
	result.integrated_hostile_exposure += exposure.hostile_exposure * step_seconds
	result.integrated_exposure_relief += exposure.exposure_relief * step_seconds
	result.integrated_environmental_exposure += exposure.environmental_pressure * step_seconds
	result.peak_environmental_pressure = max(
		result.peak_environmental_pressure, exposure.environmental_pressure
	)
	result.peak_path_collision_risk = max(
		result.peak_path_collision_risk, exposure.path_collision_risk
	)
	result.integrated_hostile_collision_risk += exposure.path_collision_risk * step_seconds
	result.maximum_path_collision_damage = max(
		result.maximum_path_collision_damage, channels.contact_damage
	)


func _get_influence_sources(observation: Dictionary) -> Array:
	var result: Array = observation.visible_world.get("structures", []).duplicate()
	result.append_array(observation.visible_world.get("allied_agents", []))
	for remembered_entity in observation.get("remembered_entities", []):
		if remembered_entity.kind == "structure" and not remembered_entity.visible:
			result.push_back(remembered_entity)
	return result


func _predict_projectile_position(projectile: Dictionary, time: float) -> Vector2:
	return _projectile_motion_predictor.predict_position(projectile, time)


func _predict_source_position(source: Dictionary, time: float) -> Vector2:
	return _observed_motion_predictor.predict_position(
		source.relative_position,
		source.velocity,
		source.acceleration,
		source.motion_confidence,
		time
	)


func _predict_enemy_position(
	track: Dictionary, time: float, player_displacement := Vector2.ZERO
) -> Vector2:
	return _enemy_motion_predictor.predict_position(track, time, player_displacement)


func _closest_point_to_origin(segment_start: Vector2, segment_end: Vector2) -> Vector2:
	var fraction := _closest_fraction_to_origin(segment_start, segment_end)
	return segment_start.linear_interpolate(segment_end, fraction)


func _closest_fraction_to_origin(segment_start: Vector2, segment_end: Vector2) -> float:
	var segment := segment_end - segment_start
	var length_squared := segment.length_squared()
	if length_squared <= 0.0:
		return 0.0
	return clamp(-segment_start.dot(segment) / length_squared, 0.0, 1.0)


func _saturate(value: float) -> float:
	return 1.0 - exp(-max(0.0, value))


func _saturate_channels(channels: Dictionary) -> void:
	for channel in [
		"enemy_proximity",
		"projectile",
		"projectile_interception",
		"spawn",
		"ranged",
		"ally_body",
	]:
		channels[channel] = _saturate(channels[channel])


func _add_if_known(value, addition: float):
	return null if value == null else value + addition


func _empty_result() -> Dictionary:
	return {
		"integrated_enemy_proximity_pressure": 0.0,
		"integrated_projectile_proximity_pressure": 0.0,
		"peak_projectile_contact_risk": 0.0,
		"integrated_spawn_pressure": 0.0,
		"integrated_ranged_attack_pressure": 0.0,
		"integrated_edge_pressure": 0.0,
		"peak_enemy_contact_risk": 0.0,
		"integrated_allied_body_pressure": 0.0,
		"integrated_allied_pressure_relief": 0.0,
		"integrated_allied_healing_support": 0.0,
		"integrated_projectile_interception_relief": 0.0,
		"integrated_hostile_exposure": 0.0,
		"integrated_exposure_relief": 0.0,
		"integrated_environmental_exposure": 0.0,
		"peak_environmental_pressure": 0.0,
		"peak_path_collision_risk": 0.0,
		"integrated_hostile_collision_risk": 0.0,
		"maximum_path_collision_damage": 0.0,
		"initial_environmental_pressure": 0.0,
		"terminal_environmental_pressure": 0.0,
		"mean_environmental_pressure_derivative": 0.0,
	}


func _empty_channels() -> Dictionary:
	return {
		"enemy_proximity": 0.0,
		"contact": 0.0,
		"projectile": 0.0,
		"projectile_contact": 0.0,
		"projectile_contact_interception": 0.0,
		"spawn": 0.0,
		"ranged": 0.0,
		"edge": 0.0,
		"ally_body": 0.0,
		"allied_suppression": 0.0,
		"healing_support": 0.0,
		"projectile_interception": 0.0,
		"contact_damage": 0.0,
	}
