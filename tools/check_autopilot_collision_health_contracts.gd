extends Reference

const PLANNING_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/planning/"
var _failed := false


func run(fixtures: Reference) -> bool:
	var influence: Reference = load(PLANNING_PATH + "battlefield_influence_model.gd").new()
	var impact: Reference = load(PLANNING_PATH + "health/collision_health_impact_model.gd").new()
	var track: Dictionary = fixtures.enemy_track(Vector2(100.0, 15.0), Vector2(-1000.0, 0.0), false)
	var observation: Dictionary = fixtures.planning_observation([track])
	observation.physics_frame = 2
	observation.player_state.health = {"current": 10.0, "maximum": 10.0, "ratio": 1.0}
	var action := {
		"movement": Vector2.ZERO,
		"forecast_seconds": 0.2,
		"samples": [{"time": 0.2, "displacement": Vector2.ZERO, "movement": Vector2.ZERO}],
	}
	var outcome: Dictionary = influence.predict(
		observation, action, _influence_weights(), 0.1, _completion_value_ledger({1: 0.0})
	)
	_expect(
		is_equal_approx(outcome.peak_path_collision_risk, 1.0),
		"a swept collision-boundary crossing must be a complete contact opportunity"
	)
	_expect(
		is_equal_approx(outcome.maximum_path_collision_raw_damage, 3.0),
		"swept enemy contact must retain the colliding body's damage"
	)
	var evidence: Dictionary = _path_collision_evidence(outcome)
	var single_impact: Dictionary = impact.evaluate(observation, action, evidence, false)
	var second_track: Dictionary = observation.enemy_tracks[0].duplicate(true)
	second_track.track_id = 2
	observation.enemy_tracks.push_back(second_track)
	observation.physics_frame += 1
	var swarm_outcome: Dictionary = influence.predict(
		observation, action, _influence_weights(), 0.1, _completion_value_ledger({1: 0.0, 2: 0.0})
	)
	var swarm_impact: Dictionary = impact.evaluate(
		observation, action, _path_collision_evidence(swarm_outcome), false
	)
	_expect(
		is_equal_approx(swarm_impact.expected_health_loss, single_impact.expected_health_loss),
		"simultaneous swept contacts must remain one complete hit under vanilla iframes"
	)
	return not _failed


func _path_collision_evidence(outcome: Dictionary) -> Dictionary:
	return {
		"path_collision_risk": outcome.peak_path_collision_risk,
		"path_contact_evidence_seconds": outcome.path_contact_evidence_seconds,
		"path_raw_damage_evidence_seconds": outcome.path_raw_damage_evidence_seconds,
		"maximum_path_raw_damage": outcome.maximum_path_collision_raw_damage,
		"velocity_collision_risk": 0.0,
		"velocity_contact_evidence_sum": 0.0,
		"velocity_raw_damage_evidence_sum": 0.0,
		"maximum_velocity_raw_damage": 0.0,
	}


func _completion_value_ledger(net_values: Dictionary) -> Dictionary:
	var by_track_id := {}
	for track_id in net_values:
		by_track_id[track_id] = {"net_completion_value": net_values[track_id]}
	return {"by_track_id": by_track_id}


func _influence_weights() -> Dictionary:
	return {
		"enemy_proximity": 1.0,
		"enemy_contact": 1.0,
		"projectile_contact": 1.0,
		"spawn_warning": 1.0,
		"maneuver_constraint": 1.0,
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
	printerr("Autopilot collision-health contract failed: %s" % message)
