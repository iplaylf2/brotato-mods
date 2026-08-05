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
		combined_pressure > threat_pressure + edge_pressure,
		"hostile pressure near a corner must price the lost escape headings"
	)


func _influence_weights() -> Dictionary:
	return {
		"enemy_proximity": 1.0,
		"enemy_contact": 1.0,
		"projectile_contact": 1.0,
		"spawn_warning": 1.0,
		"ranged_attack": 1.0,
		"map_edge": 1.0,
		"allied_body_proximity": 1.0,
		"allied_pressure_relief": 1.0,
		"projectile_interception_relief": 1.0,
	}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot enemy-interaction contract failed: %s" % message)
