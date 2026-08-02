extends Reference

# Evaluates a continuous spatiotemporal pressure field along a candidate path.
# Hostile channels are bounded before combination. Allied suppression can only
# cancel enemy-derived ambient pressure; it cannot erase contact, edges, body
# blocking, or a projectile that was not actually intercepted first.

const ObservedMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/observed_motion_predictor.gd"
)

const PLAYER_RADIUS := 24.0
const ENEMY_PRESSURE_DISTANCE := 150.0
const PROJECTILE_PRESSURE_DISTANCE := 100.0
const RANGED_SOURCE_PRESSURE_DISTANCE := 650.0
const EDGE_MARGIN := 56.0
const ALLY_BODY_MARGIN := 64.0

var _motion_predictor: Reference = ObservedMotionPredictor.new()


func predict(
	observation: Dictionary, action_forecast: Dictionary, pressure_policy: Dictionary
) -> Dictionary:
	var result := _empty_result()
	var initial: Dictionary = sample_point(observation, Vector2.ZERO, 0.0, pressure_policy)
	result.initial_survival_pressure = initial.net
	var samples: Array = action_forecast.samples
	assert(not samples.empty())
	var sources := _get_influence_sources(observation)
	var consumed_single_use_sources := {}
	var interception_samples := _find_projectile_interception_samples(observation, samples)
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
			previous_projectile_positions
		)
		var pressure := _combine_channels(channels, pressure_policy)
		_accumulate_result(result, channels, pressure, sample, step_seconds)
		previous_time = sample.time
	var final_sample: Dictionary = samples.back()
	var terminal: Dictionary = sample_point(
		observation, final_sample.displacement, final_sample.time, pressure_policy
	)
	result.terminal_survival_pressure = terminal.net
	# This endpoint quotient is the mean material derivative of P(x(t), t)
	# along the candidate velocity, not the Eulerian change at a fixed point.
	result.mean_pressure_material_derivative = (
		(result.terminal_survival_pressure - result.initial_survival_pressure)
		/ max(0.01, action_forecast.forecast_seconds)
	)
	return result


# Point queries build the adaptive map. They describe pressure at (position, time),
# while predict() retains swept-path handling for an action forecast.
func sample_point(
	observation: Dictionary, displacement: Vector2, time: float, pressure_policy: Dictionary
) -> Dictionary:
	var sample := {"time": time, "displacement": displacement, "movement": Vector2.ZERO}
	var channels := _empty_channels()
	_sample_enemy_pressure(observation.enemy_tracks, sample, channels)
	_sample_spawn_pressure(observation.visible_world.spawn_warnings, sample, channels)
	_sample_edge_pressure(observation.localization.map_bounds, displacement, channels)
	_sample_allied_pressure(
		observation, _get_influence_sources(observation), sample, 0, {}, channels
	)
	_sample_projectile_point_pressure(observation.visible_world.enemy_projectiles, sample, channels)
	_saturate_channels(channels)
	var pressure := _combine_channels(channels, pressure_policy)
	return {
		"hostile": pressure.hostile,
		"relief": pressure.relief,
		"net": pressure.net,
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
	previous_projectile_positions: Array
) -> Dictionary:
	var channels := _empty_channels()
	_sample_enemy_pressure(observation.enemy_tracks, sample, channels)
	_sample_spawn_pressure(observation.visible_world.spawn_warnings, sample, channels)
	_sample_edge_pressure(observation.localization.map_bounds, sample.displacement, channels)
	_sample_allied_pressure(
		observation, sources, sample, sample_index, consumed_single_use_sources, channels
	)
	_sample_projectile_pressure(
		observation.visible_world.enemy_projectiles,
		sample,
		sample_index,
		interception_samples,
		previous_projectile_positions,
		channels
	)
	_saturate_channels(channels)
	return channels


func _sample_enemy_pressure(tracks: Array, sample: Dictionary, channels: Dictionary) -> void:
	for track in tracks:
		var position := _predict_track_position(track, sample.time) - sample.displacement
		var uncertain_clearance: float = (
			position.length()
			- PLAYER_RADIUS
			- track.last_measurement.visual_radius
			- track.uncertainty_radius
		)
		var proximity := clamp(
			(ENEMY_PRESSURE_DISTANCE - uncertain_clearance) / ENEMY_PRESSURE_DISTANCE, 0.0, 1.0
		)
		channels.enemy_proximity += proximity * proximity * track.recency_confidence

		var physical_clearance: float = (
			position.length()
			- PLAYER_RADIUS
			- track.last_measurement.visual_radius
		)
		var contact := clamp(-physical_clearance / PLAYER_RADIUS, 0.0, 1.0)
		channels.contact = max(channels.contact, contact * track.recency_confidence)
		_accumulate_ranged_pressure(track, position, channels)


func _accumulate_ranged_pressure(
	track: Dictionary, position: Vector2, channels: Dictionary
) -> void:
	if not track.behavior_profile.strategic_roles.ranged_pressure_source:
		return
	var attack: Dictionary = track.behavior_profile.attack_behavior
	var pressure_distance: float = max(
		1.0, float(attack.get("maximum_range", RANGED_SOURCE_PRESSURE_DISTANCE))
	)
	var minimum_distance: float = attack.get("minimum_range", 0.0)
	var clearance: float = (
		position.length()
		- track.last_measurement.visual_radius
		- track.uncertainty_radius
	)
	var proximity := clamp((pressure_distance - clearance) / pressure_distance, 0.0, 1.0)
	if minimum_distance > 0.0:
		proximity *= clamp(position.length() / minimum_distance, 0.0, 1.0)
	channels.ranged += (
		proximity
		* proximity
		* track.recency_confidence
		* attack.confidence
		* attack.pressure_intensity
	)


func _sample_spawn_pressure(warnings: Array, sample: Dictionary, channels: Dictionary) -> void:
	for warning in warnings:
		if warning.disposition != "hostile":
			continue
		var clearance := (warning.relative_position - sample.displacement).length() - PLAYER_RADIUS
		var proximity := clamp(
			(ENEMY_PRESSURE_DISTANCE - clearance) / ENEMY_PRESSURE_DISTANCE, 0.0, 1.0
		)
		channels.spawn += proximity * proximity


func _sample_edge_pressure(bounds: Dictionary, displacement: Vector2, channels: Dictionary) -> void:
	var future_distances := [
		_add_if_known(bounds.distance_to_left, displacement.x),
		_add_if_known(bounds.distance_to_right, -displacement.x),
		_add_if_known(bounds.distance_to_top, displacement.y),
		_add_if_known(bounds.distance_to_bottom, -displacement.y),
	]
	for distance in future_distances:
		if distance == null or distance >= EDGE_MARGIN:
			continue
		var proximity := clamp((EDGE_MARGIN - distance) / EDGE_MARGIN, 0.0, 1.0)
		channels.edge += proximity * proximity


func _sample_allied_pressure(
	observation: Dictionary,
	sources: Array,
	sample: Dictionary,
	sample_index: int,
	consumed_single_use_sources: Dictionary,
	channels: Dictionary
) -> void:
	for source_index in sources.size():
		var source: Dictionary = sources[source_index]
		var relief: Dictionary = source.influence.pressure_relief
		if relief.active and relief.radius > 0.0:
			if not relief.single_use:
				channels.allied_suppression += _source_suppression(
					observation.enemy_tracks, source, relief, sample
				)
			elif (
				not consumed_single_use_sources.has(source_index)
				and _has_single_use_trigger(observation.enemy_tracks, source, relief, sample)
			):
				channels.allied_suppression += _source_suppression(
					observation.enemy_tracks, source, relief, sample
				)
				consumed_single_use_sources[source_index] = sample_index

		var healing: Dictionary = source.influence.healing_support
		if healing.active and healing.radius > 0.0:
			channels.healing_support += _source_healing_support(
				observation, source, healing, sample
			)

		if source.kind == "player":
			channels.ally_body += _ally_body_pressure(source, sample)


func _source_suppression(
	tracks: Array, source: Dictionary, relief: Dictionary, sample: Dictionary
) -> float:
	var source_position := _predict_source_position(source, sample.time)
	var player_activation_radius: float = relief.get("player_activation_radius", 0.0)
	if (
		player_activation_radius > 0.0
		and (source_position - sample.displacement).length() > player_activation_radius
	):
		return 0.0
	var covered_pressure := 0.0
	for track in tracks:
		var enemy_position := _predict_track_position(track, sample.time)
		var support_distance := (enemy_position - source_position).length()
		if support_distance > relief.radius + track.last_measurement.visual_radius:
			continue
		var player_distance := (enemy_position - sample.displacement).length()
		var pressure := clamp(
			(ENEMY_PRESSURE_DISTANCE * 2.0 - player_distance) / (ENEMY_PRESSURE_DISTANCE * 2.0),
			0.0,
			1.0
		)
		var coverage := clamp(1.25 - support_distance / relief.radius, 0.25, 1.0)
		var relieved_pressure: float = pressure * coverage * track.recency_confidence
		if relief.effect == "damage" and not relief.single_use:
			covered_pressure = max(covered_pressure, relieved_pressure)
		else:
			covered_pressure += relieved_pressure
	return min(2.0, covered_pressure) * relief.intensity * source.get("existence_confidence", 1.0)


func _has_single_use_trigger(
	tracks: Array, source: Dictionary, relief: Dictionary, sample: Dictionary
) -> bool:
	var source_position := _predict_source_position(source, sample.time)
	for track in tracks:
		var enemy_position := _predict_track_position(track, sample.time)
		var trigger_radius: float = relief.activation_radius + track.last_measurement.visual_radius
		if (enemy_position - source_position).length() <= trigger_radius:
			return true
	return false


func _source_healing_support(
	observation: Dictionary, source: Dictionary, healing: Dictionary, sample: Dictionary
) -> float:
	var source_position := _predict_source_position(source, sample.time)
	var distance := (source_position - sample.displacement).length()
	var coverage := clamp((healing.radius - distance) / healing.radius, 0.0, 1.0)
	var opportunity := 1.0
	if healing.effect == "healing_amplification":
		var effective_stats: Dictionary = observation.player_state.effective_stats
		opportunity = clamp(
			(effective_stats.health_regeneration + effective_stats.lifesteal) / 20.0, 0.0, 1.0
		)
	return coverage * healing.intensity * opportunity * source.get("existence_confidence", 1.0)


func _ally_body_pressure(ally: Dictionary, sample: Dictionary) -> float:
	var ally_position := _predict_source_position(ally, sample.time)
	var clearance := (
		(ally_position - sample.displacement).length()
		- PLAYER_RADIUS
		- ally.visual_radius
	)
	var proximity := clamp((ALLY_BODY_MARGIN - clearance) / ALLY_BODY_MARGIN, 0.0, 1.0)
	return proximity * proximity


func _sample_projectile_pressure(
	projectiles: Array,
	sample: Dictionary,
	sample_index: int,
	interception_samples: Dictionary,
	previous_positions: Array,
	channels: Dictionary
) -> void:
	for projectile_index in projectiles.size():
		var projectile: Dictionary = projectiles[projectile_index]
		var position := _predict_projectile_position(projectile, sample.time) - sample.displacement
		var interception_sample = interception_samples.get(projectile_index)
		var closest_position := _closest_point_to_origin(
			previous_positions[projectile_index], position
		)
		var clearance := closest_position.length() - PLAYER_RADIUS - projectile.visual_radius
		var proximity := clamp(
			(PROJECTILE_PRESSURE_DISTANCE - clearance) / PROJECTILE_PRESSURE_DISTANCE, 0.0, 1.0
		)
		var projectile_pressure := proximity * proximity
		channels.projectile += projectile_pressure
		if interception_sample != null and sample_index >= interception_sample:
			channels.projectile_interception += projectile_pressure
		previous_positions[projectile_index] = position


func _sample_projectile_point_pressure(
	projectiles: Array, sample: Dictionary, channels: Dictionary
) -> void:
	for projectile in projectiles:
		var position := _predict_projectile_position(projectile, sample.time) - sample.displacement
		var clearance := position.length() - PLAYER_RADIUS - projectile.visual_radius
		var proximity := clamp(
			(PROJECTILE_PRESSURE_DISTANCE - clearance) / PROJECTILE_PRESSURE_DISTANCE, 0.0, 1.0
		)
		channels.projectile += proximity * proximity


func _find_projectile_interception_samples(observation: Dictionary, samples: Array) -> Dictionary:
	var result := {}
	for projectile_index in observation.visible_world.enemy_projectiles.size():
		var projectile: Dictionary = observation.visible_world.enemy_projectiles[projectile_index]
		var earliest_sample = null
		for ally in observation.visible_world.get("allied_agents", []):
			var interception: Dictionary = ally.influence.projectile_interception
			if not interception.active or interception.radius <= 0.0:
				continue
			var sample_index := _find_interception_sample(ally, interception, projectile, samples)
			if sample_index != null and (earliest_sample == null or sample_index < earliest_sample):
				earliest_sample = sample_index
		if earliest_sample != null:
			result[projectile_index] = earliest_sample
	return result


func _find_interception_sample(
	ally: Dictionary, interception: Dictionary, projectile: Dictionary, samples: Array
):
	var previous_projectile: Vector2 = projectile.relative_position
	var previous_ally: Vector2 = ally.relative_position
	var previous_player_relative: Vector2 = projectile.relative_position
	for sample_index in samples.size():
		var sample: Dictionary = samples[sample_index]
		var projectile_position := _predict_projectile_position(projectile, sample.time)
		var ally_position := _predict_source_position(ally, sample.time)
		var player_relative: Vector2 = projectile_position - sample.displacement
		var shield_relative_start := previous_projectile - previous_ally
		var shield_relative_end := projectile_position - ally_position
		var shield_fraction := _closest_fraction_to_origin(
			shield_relative_start, shield_relative_end
		)
		var player_fraction := _closest_fraction_to_origin(
			previous_player_relative, player_relative
		)
		var crosses_shield := (
			(shield_relative_start.linear_interpolate(shield_relative_end, shield_fraction)).length()
			<= interception.radius + projectile.visual_radius
		)
		var threatens_player := (
			(previous_player_relative.linear_interpolate(player_relative, player_fraction)).length()
			<= PROJECTILE_PRESSURE_DISTANCE + PLAYER_RADIUS + projectile.visual_radius
		)
		if crosses_shield and threatens_player and shield_fraction <= player_fraction:
			return sample_index
		previous_projectile = projectile_position
		previous_ally = ally_position
		previous_player_relative = player_relative
	return null


func _combine_channels(channels: Dictionary, policy: Dictionary) -> Dictionary:
	var immediate := channels.contact * policy.contact + channels.projectile * policy.projectile
	var enemy_ambient := (
		channels.enemy_proximity * policy.enemy_proximity
		+ channels.spawn * policy.spawn
		+ channels.ranged * policy.ranged
	)
	var positional := channels.edge * policy.edge + channels.ally_body * policy.ally_body
	var ambient_relief := min(
		enemy_ambient, channels.allied_suppression * policy.allied_suppression
	)
	var interception_relief := min(
		channels.projectile * policy.projectile,
		channels.projectile_interception * policy.projectile_interception
	)
	var relief := ambient_relief + interception_relief
	var hostile := immediate + enemy_ambient + positional
	return {
		"hostile": hostile,
		"relief": relief,
		"net": max(0.0, hostile - relief),
	}


func _accumulate_result(
	result: Dictionary,
	channels: Dictionary,
	pressure: Dictionary,
	sample: Dictionary,
	step_seconds: float
) -> void:
	result.enemy_proximity_pressure += channels.enemy_proximity * step_seconds
	result.projectile_pressure += channels.projectile * step_seconds
	result.spawn_pressure += channels.spawn * step_seconds
	result.ranged_source_pressure += channels.ranged * step_seconds
	result.edge_pressure += channels.edge * step_seconds
	result.allied_body_pressure += channels.ally_body * step_seconds
	result.contact_pressure = max(result.contact_pressure, channels.contact)
	result.allied_zone_pressure_relief += channels.allied_suppression * step_seconds
	result.allied_zone_healing_support += channels.healing_support * step_seconds
	result.allied_projectile_interception += channels.projectile_interception * step_seconds
	result.integrated_hostile_pressure += pressure.hostile * step_seconds
	result.integrated_relief_pressure += pressure.relief * step_seconds
	result.integrated_survival_pressure += pressure.net * step_seconds
	result.peak_survival_pressure = max(result.peak_survival_pressure, pressure.net)
	result.pressure_trace.push_back(
		{
			"time": sample.time,
			"displacement": sample.displacement,
			"hostile": pressure.hostile,
			"relief": pressure.relief,
			"signed_relief": -pressure.relief,
			"net": pressure.net,
			"channels": channels.duplicate(true),
		}
	)


func _get_influence_sources(observation: Dictionary) -> Array:
	var result: Array = observation.visible_world.get("structures", []).duplicate()
	result.append_array(observation.visible_world.get("allied_agents", []))
	for remembered_entity in observation.get("remembered_entities", []):
		if remembered_entity.kind == "structure" and not remembered_entity.visible:
			result.push_back(remembered_entity)
	return result


func _predict_projectile_position(projectile: Dictionary, time: float) -> Vector2:
	return _motion_predictor.predict_position(
		projectile.relative_position,
		projectile.velocity,
		projectile.acceleration,
		projectile.motion_confidence,
		time
	)


func _predict_source_position(source: Dictionary, time: float) -> Vector2:
	return _motion_predictor.predict_position(
		source.relative_position,
		source.velocity,
		source.acceleration,
		source.motion_confidence,
		time
	)


func _predict_track_position(track: Dictionary, time: float) -> Vector2:
	return _motion_predictor.predict_position(
		track.relative_position,
		track.estimated_velocity,
		track.estimated_acceleration,
		track.motion_confidence,
		time
	)


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
		"enemy_proximity_pressure": 0.0,
		"projectile_pressure": 0.0,
		"spawn_pressure": 0.0,
		"ranged_source_pressure": 0.0,
		"edge_pressure": 0.0,
		"contact_pressure": 0.0,
		"allied_body_pressure": 0.0,
		"allied_zone_pressure_relief": 0.0,
		"allied_zone_healing_support": 0.0,
		"allied_projectile_interception": 0.0,
		"integrated_hostile_pressure": 0.0,
		"integrated_relief_pressure": 0.0,
		"integrated_survival_pressure": 0.0,
		"peak_survival_pressure": 0.0,
		"initial_survival_pressure": 0.0,
		"terminal_survival_pressure": 0.0,
		"mean_pressure_material_derivative": 0.0,
		"pressure_trace": [],
	}


func _empty_channels() -> Dictionary:
	return {
		"enemy_proximity": 0.0,
		"contact": 0.0,
		"projectile": 0.0,
		"spawn": 0.0,
		"ranged": 0.0,
		"edge": 0.0,
		"ally_body": 0.0,
		"allied_suppression": 0.0,
		"healing_support": 0.0,
		"projectile_interception": 0.0,
	}
