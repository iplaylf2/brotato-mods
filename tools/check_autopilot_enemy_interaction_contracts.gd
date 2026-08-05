extends Reference

const PLANNING_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/planning/"
var _failed := false
var _fixtures: Reference


func run(fixtures: Reference) -> bool:
	_fixtures = fixtures
	_check_bounded_healing_burden()
	_check_player_healing_opportunity()
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


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot enemy-interaction contract failed: %s" % message)
