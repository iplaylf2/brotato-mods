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
	_expect(
		(
			outcome.contact_opportunities.size() == 1
			and outcome.contact_opportunities[0].source_id == "enemy:1"
			and is_equal_approx(outcome.contact_opportunities[0].time_seconds, 0.2)
		),
		"swept enemy contact must expose its source and opportunity time"
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
	_check_additive_collision_damage(fixtures, impact)
	_check_timestamped_contact_state(fixtures, impact)
	return not _failed


func _check_additive_collision_damage(fixtures: Reference, impact: Reference) -> void:
	var observation: Dictionary = fixtures.planning_observation([])
	observation.player_state.health = {"current": 9.0, "maximum": 20.0, "ratio": 0.45}
	var action := {"movement": Vector2.ZERO, "forecast_seconds": 0.4}
	var single: Dictionary = impact.evaluate(
		observation, action, _velocity_collision_evidence(0.5, 0.5, 3.0, 6.0), false
	)
	var swarm: Dictionary = impact.evaluate(
		observation, action, _velocity_collision_evidence(0.9, 2.0, 12.0, 6.0), false
	)
	_expect(
		swarm.expected_health_loss > single.expected_health_loss * 2.0,
		"independent collision opportunities must retain additive expected damage"
	)
	_expect(
		is_equal_approx(swarm.terminal_collision_risk, 0.0),
		(
			"aggregate sublethal contact evidence must remain health loss until the "
			+ "projection exposes a supported joint hit-count distribution"
		)
	)
	observation.physics_frame += 1
	observation.player_state.runtime_stats.hit_protection = 1
	var partially_protected: Dictionary = impact.evaluate(
		observation, action, _velocity_collision_evidence(0.9, 2.0, 12.0, 6.0), false
	)
	_expect(
		(
			partially_protected.expected_health_loss > 0.0
			and partially_protected.expected_health_loss < swarm.expected_health_loss
		),
		"one hit-protection charge must consume one opportunity instead of erasing the forecast"
	)


func _check_timestamped_contact_state(fixtures: Reference, impact: Reference) -> void:
	var observation: Dictionary = fixtures.planning_observation([])
	observation.player_state.health = {"current": 10.0, "maximum": 20.0, "ratio": 0.5}
	var action := {"movement": Vector2.ZERO, "forecast_seconds": 0.6}
	var opportunities := [
		_contact_opportunity(0.1, "enemy:1", 6.0),
		_contact_opportunity(0.55, "enemy:1", 6.0),
	]
	var lethal_sequence: Dictionary = impact.evaluate(
		observation, action, _opportunity_collision_evidence(opportunities), false
	)
	_expect(
		(
			is_equal_approx(lethal_sequence.expected_health_loss, 10.0)
			and is_equal_approx(lethal_sequence.terminal_collision_risk, 1.0)
		),
		"timestamped contacts separated by vanilla iframes must propagate cumulative death"
	)
	observation.physics_frame += 1
	observation.player_state.runtime_stats.dodge_chance = 0.5
	var dodged_sequence: Dictionary = impact.evaluate(
		observation, action, _opportunity_collision_evidence(opportunities), false
	)
	_expect(
		(
			is_equal_approx(dodged_sequence.expected_health_loss, 5.5)
			and is_equal_approx(dodged_sequence.terminal_collision_risk, 0.25)
		),
		"dodge must branch the same timestamped health process instead of scaling a hit count"
	)
	observation.physics_frame += 1
	observation.player_state.runtime_stats.dodge_chance = 0.0
	observation.player_state.runtime_stats.hit_protection = 1
	var protected_sequence: Dictionary = impact.evaluate(
		observation, action, _opportunity_collision_evidence(opportunities), false
	)
	_expect(
		(
			is_equal_approx(protected_sequence.expected_health_loss, 6.0)
			and is_equal_approx(protected_sequence.terminal_collision_risk, 0.0)
		),
		"hit protection must be consumed before later timestamped damage"
	)
	observation.physics_frame += 1
	observation.player_state.runtime_stats.hit_protection = 0
	observation.player_state.runtime_stats.invincibility_seconds_remaining = 0.3
	var active_iframe_evidence := _opportunity_collision_evidence(opportunities)
	active_iframe_evidence.path_collision_risk = 1.0
	active_iframe_evidence.path_contact_evidence_seconds = 0.4
	active_iframe_evidence.path_raw_damage_evidence_seconds = 2.4
	active_iframe_evidence.maximum_path_raw_damage = 6.0
	var active_iframe_sequence: Dictionary = impact.evaluate(
		observation, action, active_iframe_evidence, false
	)
	_expect(
		is_equal_approx(active_iframe_sequence.expected_health_loss, 6.0),
		"timestamped path opportunities must replace aggregates so active iframes stay effective"
	)


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
		"contact_opportunities": outcome.contact_opportunities,
	}


func _velocity_collision_evidence(
	risk: float,
	contact_evidence_sum: float,
	raw_damage_evidence_sum: float,
	maximum_raw_damage: float
) -> Dictionary:
	return {
		"path_collision_risk": 0.0,
		"path_contact_evidence_seconds": 0.0,
		"path_raw_damage_evidence_seconds": 0.0,
		"maximum_path_raw_damage": 0.0,
		"velocity_collision_risk": risk,
		"velocity_contact_evidence_sum": contact_evidence_sum,
		"velocity_raw_damage_evidence_sum": raw_damage_evidence_sum,
		"maximum_velocity_raw_damage": maximum_raw_damage,
	}


func _opportunity_collision_evidence(opportunities: Array) -> Dictionary:
	var evidence := _velocity_collision_evidence(0.0, 0.0, 0.0, 0.0)
	evidence.contact_opportunities = opportunities
	return evidence


func _contact_opportunity(time_seconds: float, source_id: String, raw_damage: float) -> Dictionary:
	return {
		"time_seconds": time_seconds,
		"source_id": source_id,
		"realization_probability": 1.0,
		"raw_damage": raw_damage,
		"source_consumed_on_contact": false,
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
		"allied_body_proximity": 1.0,
		"allied_pressure_relief": 1.0,
		"projectile_interception_relief": 1.0,
	}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot collision-health contract failed: %s" % message)
