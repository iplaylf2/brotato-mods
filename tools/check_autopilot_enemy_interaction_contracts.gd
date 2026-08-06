extends Reference

const PLANNING_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/planning/"
var _failed := false
var _fixtures: Reference


func run(fixtures: Reference) -> bool:
	_fixtures = fixtures
	_check_bounded_healing_burden()
	_check_player_healing_opportunity()
	_check_predictive_targeted_volley_lane()
	_check_hostile_edge_confinement()
	_check_spawn_warning_opportunity()
	_check_maneuver_space_pressure()
	_check_charge_collision_time_and_aim_distribution()
	_check_health_conditioned_information_value()
	return not _failed


func _check_bounded_healing_burden() -> void:
	var model: Reference = load(PLANNING_PATH + "engagement/enemy_completion_value_model.gd").new()
	var healer: Dictionary = _fixtures.enemy_track(Vector2.ZERO, Vector2.ZERO, false)
	healer.track_id = 1
	healer.behavior_profile.battlefield_effects = {
		"enemy_healing_base": 100.0,
		"enemy_healing_per_wave": 10.0,
		"enemy_healing_radius": 200.0,
	}
	var neighbor: Dictionary = _fixtures.enemy_track(Vector2(100.0, 0.0), Vector2.ZERO, false)
	neighbor.track_id = 2
	neighbor.last_measurement.health = {"current": 200.0, "maximum": 200.0, "ratio": 1.0}
	neighbor.behavior_profile.durability.maximum_health = 200.0
	var observation: Dictionary = _fixtures.planning_observation([healer, neighbor])
	var base_ledger: Dictionary = model.build_ledger(observation, 1.0)
	var base_burden: float = base_ledger.entries_by_track_id[1].burden_relief_value
	for index in range(3, 13):
		var full_health_neighbor: Dictionary = neighbor.duplicate(true)
		full_health_neighbor.track_id = index
		full_health_neighbor.relative_position = Vector2(float(index * 10), 0.0)
		observation.enemy_tracks.push_back(full_health_neighbor)
	observation.physics_frame += 1
	var populated_ledger: Dictionary = model.build_ledger(observation, 1.0)
	var populated_burden: float = populated_ledger.entries_by_track_id[1].burden_relief_value
	_expect(
		is_equal_approx(base_burden, populated_burden),
		"a trigger-zone healer must not invent one heal for every full-health enemy"
	)
	observation.enemy_tracks[1].last_measurement.health.current = 195.0
	observation.physics_frame += 1
	var injured_ledger: Dictionary = model.build_ledger(observation, 1.0)
	var injured_burden: float = injured_ledger.entries_by_track_id[1].burden_relief_value
	observation.enemy_tracks[1].last_measurement.health.current = 0.0
	observation.physics_frame += 1
	var fully_depleted_ledger: Dictionary = model.build_ledger(observation, 1.0)
	var fully_depleted_burden: float = fully_depleted_ledger.entries_by_track_id[1].burden_relief_value
	observation.enemy_tracks[1].relative_position = Vector2(1000.0, 0.0)
	observation.physics_frame += 1
	var distant_stationary_ledger: Dictionary = model.build_ledger(observation, 1.0)
	var distant_entry: Dictionary = distant_stationary_ledger.entries_by_track_id[1]
	var distant_stationary_burden: float = distant_entry.burden_relief_value
	_expect(
		(
			injured_burden > populated_burden
			and is_equal_approx(
				fully_depleted_burden - populated_burden, 20.0 * (injured_burden - populated_burden)
			)
			and is_equal_approx(distant_stationary_burden, populated_burden)
		),
		"healing burden must follow observed missing health and trigger-zone geometry"
	)


func _check_player_healing_opportunity() -> void:
	var model: Reference = load(PLANNING_PATH + "engagement/enemy_completion_value_model.gd").new()
	var healer: Dictionary = _fixtures.enemy_track(Vector2(100.0, 0.0), Vector2.ZERO, false)
	healer.behavior_profile.battlefield_effects = {
		"enemy_healing_radius": 200.0,
		"player_healing_base": 5.0,
		"player_healing_per_wave": 0.0,
	}
	var observation: Dictionary = _fixtures.planning_observation([healer])
	var full_health_ledger: Dictionary = model.build_ledger(observation, 1.0)
	var full_health_burden: float = full_health_ledger.entries_by_track_id[1].burden_relief_value
	observation.player_state.health.current = 15.0
	observation.physics_frame += 1
	var nearby_ledger: Dictionary = model.build_ledger(observation, 1.0)
	var nearby_burden: float = nearby_ledger.entries_by_track_id[1].burden_relief_value
	observation.enemy_tracks[0].relative_position = Vector2(1000.0, 0.0)
	observation.physics_frame += 1
	var distant_ledger: Dictionary = model.build_ledger(observation, 1.0)
	var distant_burden: float = distant_ledger.entries_by_track_id[1].burden_relief_value
	_expect(
		nearby_burden < distant_burden and distant_burden < full_health_burden,
		"player-healing opportunity must require missing health and decay with distance"
	)


func _check_predictive_targeted_volley_lane() -> void:
	var model: Reference = load(PLANNING_PATH + "battlefield_influence_model.gd").new()
	var shooter: Dictionary = _fixtures.enemy_track(Vector2(100.0, 0.0), Vector2.ZERO, false)
	shooter.behavior_profile.projectile_attack = {
		"creates_projectile_pressure": true,
		"confidence": 1.0,
		"pressure_intensity": 1.0,
		"minimum_range": 0.0,
		"maximum_range": 500.0,
		"maximum_projectile_speed": 100.0,
		"delivery_modes": ["source_toward_target"],
		"launch_randomness": {"has_random_direction": false},
	}
	shooter.behavior_profile.next_volley_window = {
		"is_exact": true,
		"earliest_seconds": 0.0,
		"latest_seconds": 0.0,
	}
	var observation: Dictionary = _fixtures.planning_observation([shooter])
	var weights := _influence_weights()
	var in_lane: Dictionary = model.sample_point(observation, Vector2.ZERO, 1.0, weights)
	var outside_lane: Dictionary = model.sample_point(
		observation, Vector2(100.0, 100.0), 1.0, weights
	)
	_expect(
		in_lane.channels.ranged > outside_lane.channels.ranged,
		(
			"a ready deterministic targeted volley must create a prospective corridor "
			+ "that candidate movement can leave"
		)
	)
	var attack: Dictionary = observation.enemy_tracks[0].behavior_profile.projectile_attack
	attack.launch_randomness.has_random_direction = true
	observation.physics_frame += 1
	var random_in_lane: Dictionary = model.sample_point(observation, Vector2.ZERO, 1.0, weights)
	var random_outside_lane: Dictionary = model.sample_point(
		observation, Vector2(100.0, 100.0), 1.0, weights
	)
	_expect(
		is_equal_approx(random_in_lane.channels.ranged, random_outside_lane.channels.ranged),
		"an unresolved random launch direction must not invent a future firing lane"
	)


func _check_hostile_edge_confinement() -> void:
	var model: Reference = load(PLANNING_PATH + "battlefield_influence_model.gd").new()
	var enemy: Dictionary = _fixtures.enemy_track(Vector2(20.0, 0.0), Vector2.ZERO, false)
	var combined: Dictionary = _fixtures.planning_observation([enemy])
	combined.localization.map_bounds.distance_to_left = 10.0
	combined.localization.map_bounds.distance_to_top = 10.0
	var threat_only: Dictionary = _fixtures.planning_observation([enemy])
	var edge_only: Dictionary = _fixtures.planning_observation([])
	edge_only.localization.map_bounds.distance_to_left = 10.0
	edge_only.localization.map_bounds.distance_to_top = 10.0
	var weights := _influence_weights()
	var combined_pressure: float = model.sample_point(
		combined, Vector2.ZERO, 0.0, weights
	).environmental_pressure
	var threat_pressure: float = model.sample_point(
		threat_only, Vector2.ZERO, 0.0, weights
	).environmental_pressure
	var edge_pressure: float = model.sample_point(
		edge_only, Vector2.ZERO, 0.0, weights
	).environmental_pressure
	_expect(
		(
			combined_pressure >= max(threat_pressure, edge_pressure)
			and combined_pressure <= threat_pressure + edge_pressure + 0.0001
		),
		(
			"hostile and boundary constraints must compose through blocked heading coverage "
			+ "without a synthetic corner multiplier"
		)
	)


func _check_spawn_warning_opportunity() -> void:
	var spatial: Reference = load(PLANNING_PATH + "spatial_opportunity_value_model.gd").new()
	var observation: Dictionary = _fixtures.planning_observation([])
	observation.visible_world.spawn_warnings = [
		{
			"kind": "spawn_warning",
			"relative_position": Vector2(90.0, 0.0),
			"disposition": "hostile",
			"interaction_radius": 20.0,
			"resolution_window":
			{"is_exact": false, "earliest_seconds": 0.0, "latest_seconds": 1.0},
			"player_overlap_defers_spawn": true,
		}
	]
	var context := {
		"state_factors":
		{
			"health_inventory_value": {},
			"information_value_per_viewport": 1.0,
		},
		"enemy_completion_value_ledger": _completion_value_ledger({}),
		"wave_completion_forecast": _fixtures.wave_completion_forecast({}),
	}
	var unsupported_hostile: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(20.0, 0.0), 0.2
	)
	context.enemy_completion_value_ledger.mean_burden_relief_value = -4.0
	observation.physics_frame += 1
	var beneficial_hostile: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(20.0, 0.0), 0.2
	)
	context.enemy_completion_value_ledger.mean_burden_relief_value = 4.0
	observation.physics_frame += 1
	var toward_hostile: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(20.0, 0.0), 0.2
	)
	var expired_hostile: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(20.0, 0.0), 1.0
	)
	var influence: Reference = load(PLANNING_PATH + "battlefield_influence_model.gd").new()
	var outside_deferral_zone: Dictionary = influence.sample_point(
		observation, Vector2(59.0, 0.0), 0.0, _influence_weights()
	)
	var inside_deferral_zone: Dictionary = influence.sample_point(
		observation, Vector2(60.0, 0.0), 0.0, _influence_weights()
	)
	observation.physics_frame += 1
	observation.visible_world.spawn_warnings[0].disposition = "neutral"
	observation.visible_world.spawn_warnings[0].player_overlap_defers_spawn = false
	var toward_neutral: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(20.0, 0.0), 0.2
	)
	_expect(
		(
			is_equal_approx(unsupported_hostile.future_event_opportunity, 0.0)
			and beneficial_hostile.future_event_opportunity < 0.0
			and toward_hostile.future_event_opportunity > 0.0
			and is_equal_approx(expired_hostile.future_event_opportunity, 0.0)
			and toward_neutral.future_event_opportunity > 0.0
		),
		"spawn-warning opportunities must follow observed value and resolution windows"
	)
	_expect(
		(
			outside_deferral_zone.channels.spawn > 0.0
			and is_equal_approx(inside_deferral_zone.channels.spawn, 0.0)
		),
		"hostile warning pressure must use the composed player-overlap geometry"
	)


func _check_maneuver_space_pressure() -> void:
	var model: Reference = load(PLANNING_PATH + "motion/maneuver_space_model.gd").new()
	var observation: Dictionary = _fixtures.planning_observation([])
	var geometry: Dictionary = load(PLANNING_PATH + "movement_geometry_model.gd").new().derive(
		observation
	)
	var track: Dictionary = _fixtures.enemy_track(Vector2(50.0, 0.0), Vector2.ZERO, false)
	var nearby_constraint: float = model.constraint_profile(
		[track],
		[track.relative_position],
		observation.localization.map_bounds,
		Vector2.ZERO,
		geometry
	).enemy
	var remote_constraint: float = model.constraint_profile(
		[track], [Vector2(500.0, 0.0)], observation.localization.map_bounds, Vector2.ZERO, geometry
	).enemy
	var overlap_constraint: float = model.constraint_profile(
		[track], [Vector2.ZERO], observation.localization.map_bounds, Vector2.ZERO, geometry
	).enemy
	var influence: Reference = load(PLANNING_PATH + "battlefield_influence_model.gd").new()
	observation.enemy_tracks = [track]
	var channels: Dictionary = influence.sample_point(
		observation, Vector2.ZERO, 0.0, _influence_weights()
	).channels
	_expect(
		(
			nearby_constraint > remote_constraint
			and is_equal_approx(remote_constraint, 0.0)
			and overlap_constraint > 0.0
			and overlap_constraint < track.recency_confidence
			and channels.maneuver_constraint > 0.0
		),
		"reachable enemy disks must consume maneuver space before contact"
	)


func _check_charge_collision_time_and_aim_distribution() -> void:
	var model_path := PLANNING_PATH + "collision/unresolved_collision_risk_model.gd"
	var collision_model: Reference = load(model_path).new()
	var charger: Dictionary = _fixtures.enemy_track(Vector2(-200.0, 0.0), Vector2.ZERO, false)
	charger.behavior_profile.charge_attack = {
		"active": true,
		"confidence": 1.0,
		"minimum_range": 0.0,
		"maximum_range": 300.0,
		"maximum_charge_speed": 500.0,
		"maximum_duration_seconds": 0.75,
		"maximum_travel_distance": 375.0,
		"interval": {"minimum_seconds": 0.5, "maximum_seconds": 0.75},
		"targeting":
		{
			"player_probability": 0.0,
			"random_player_region_probability": 1.0,
			"forward_overshoot_distance": 60.0,
			"random_offset_half_extent": 60.0,
		},
	}
	charger.behavior_profile.next_charge_attack_window = {
		"is_exact": true, "earliest_seconds": 0.0, "latest_seconds": 0.0
	}
	var observation: Dictionary = _fixtures.planning_observation([charger])
	var toward_action := {
		"movement": Vector2.LEFT,
		"forecast_seconds": 0.4,
		"samples":
		[
			{"time": 0.1, "displacement": Vector2(-10.0, 0.0)},
			{"time": 0.4, "displacement": Vector2(-40.0, 0.0)},
		],
	}
	var lateral_action: Dictionary = toward_action.duplicate(true)
	lateral_action.movement = Vector2.UP
	lateral_action.samples = [
		{"time": 0.1, "displacement": Vector2(0.0, -10.0)},
		{"time": 0.4, "displacement": Vector2(0.0, -40.0)},
	]
	var toward: Dictionary = collision_model.evaluate(observation, toward_action, 0.1)
	var lateral: Dictionary = collision_model.evaluate(observation, lateral_action, 0.1)
	_expect(
		(
			toward.enemy_charge_obstacle_risk > lateral.enemy_charge_obstacle_risk
			and toward.forecast_hostile_unresolved_collision_risk > 0.0
			and is_equal_approx(toward.committed_hostile_unresolved_collision_risk, 0.0)
		),
		(
			"prospective charge risk must preserve candidate-dependent lateral risk and become "
			+ "committed only when travel time reaches the control prefix"
		)
	)


func _check_health_conditioned_information_value() -> void:
	var utility_script: Script = load(PLANNING_PATH + "movement_utility_model.gd")
	var full_health_observation: Dictionary = _fixtures.planning_observation([])
	var full_health_information: float = utility_script.new().build_context(
		full_health_observation
	).state_factors.information_value_per_viewport
	var depleted_observation: Dictionary = full_health_observation.duplicate(true)
	depleted_observation.physics_frame += 1
	depleted_observation.player_state.health = {"current": 1.0, "maximum": 20.0, "ratio": 0.05}
	var depleted_information: float = utility_script.new().build_context(
		depleted_observation
	).state_factors.information_value_per_viewport
	_expect(
		depleted_information > full_health_information * 2.0,
		(
			"unobserved map coverage must inherit the marginal value of latent recovery "
			+ "when current health supply is scarce"
		)
	)


func _completion_value_ledger(net_values: Dictionary) -> Dictionary:
	var entries := {}
	for track_id in net_values:
		entries[track_id] = {
			"reward_delta_value": net_values[track_id],
			"burden_relief_value": 0.0,
			"death_consequence_value": 0.0,
			"net_completion_value": net_values[track_id],
			"remaining_health": 10.0,
		}
	return {
		"entries_by_track_id": entries,
		"mean_net_completion_value": 0.0,
		"mean_absolute_net_completion_value": 0.0,
		"mean_burden_relief_value": 0.0,
	}


func _influence_weights() -> Dictionary:
	return {
		"enemy_proximity": 1.0,
		"enemy_contact": 1.0,
		"projectile_contact": 1.0,
		"spawn_warning": 1.0,
		"maneuver_constraint": 1.0,
		"ranged_attack": 1.0,
		"allied_body_proximity": 1.0,
		"allied_pressure_relief": 1.0,
		"projectile_interception_relief": 1.0,
	}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot enemy-interaction contract failed: %s" % message)
