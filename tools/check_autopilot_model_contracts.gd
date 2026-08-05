extends SceneTree

const PLANNING_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/planning/"
var _failed := false
var _fixtures: Reference


func _init() -> void:
	var fixtures_path: String = get_script().resource_path.get_base_dir().plus_file(
		"autopilot_model_contract_fixtures.gd"
	)
	_fixtures = load(fixtures_path).new()
	var archive_path := _get_archive_path()
	if archive_path.empty() or not ProjectSettings.load_resource_pack(archive_path, false):
		printerr("Could not mount the mod contract-check archive: %s" % archive_path)
		quit(1)
		return
	_check_target_response()
	_check_swept_enemy_contact()
	_check_projectile_hitbox_ttc()
	_check_navigation_horizon_consistency()
	_check_trajectory_value_field()
	var deadline_checks_path: String = get_script().resource_path.get_base_dir().plus_file(
		"check_autopilot_wave_deadline_contracts.gd"
	)
	if not load(deadline_checks_path).new().run(_fixtures):
		_failed = true
	_check_pickup_interaction_geometry()
	_check_visible_material_quantity_estimate()
	_check_spatial_target_control()
	_check_weapon_outcome_contracts()
	_check_navigation_weapon_completion_value()
	_check_local_enemy_interaction_projection()
	_check_wave_completion_forecast()
	_check_health_inventory_loss()
	_check_recovery_liquidity_pricing()
	_check_additive_collision_damage()
	quit(1 if _failed else 0)


func _check_target_response() -> void:
	var predictor_script: Script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
	)
	var predictor: Reference = predictor_script.new()
	var track := _enemy_track(Vector2(100.0, 0.0), Vector2(-100.0, 0.0), true)
	var position: Vector2 = predictor.predict_position(track, 2.0, Vector2.ZERO)
	_expect(
		position.length() < 0.01,
		"target response must stop at the current player position instead of extrapolating through it"
	)
	var stopping_track := _enemy_track(Vector2(50.0, 0.0), Vector2(-100.0, 0.0), true)
	stopping_track.behavior_profile.target_position_response.preferred_distance = 100.0
	var stopped_position: Vector2 = predictor.predict_position(stopping_track, 1.0, Vector2.ZERO)
	_expect(
		stopped_position.distance_to(Vector2(50.0, 0.0)) < 0.01,
		"a stop-close follower must not be modeled as moving away inside its preferred distance"
	)


func _check_swept_enemy_contact() -> void:
	var influence_script: Script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/battlefield_influence_model.gd"
	)
	var influence: Reference = influence_script.new()
	var impact_script: Script = load(PLANNING_PATH + "health/collision_health_impact_model.gd")
	var impact: Reference = impact_script.new()
	var observation := {
		"physics_frame": 2,
		"wave_state": {"seconds_remaining": 10.0},
		"player_state":
		{
			"collision_radius": 10.0,
			"runtime_stats":
			{
				"move_speed": 100.0,
				"armor": 0.0,
				"dodge_chance": 0.0,
				"hit_protection": 0,
				"minimum_invincibility_seconds": 0.2,
			},
			"health": {"current": 10.0, "maximum": 10.0, "ratio": 1.0},
			"effect_rules": [],
			"movement": {"knockback_velocity": Vector2.ZERO},
		},
		"enemy_tracks": [_enemy_track(Vector2(100.0, 15.0), Vector2(-1000.0, 0.0), false)],
		"remembered_entities": [],
		"visible_world":
		{
			"spawn_warnings": [],
			"enemy_projectiles": [],
			"structures": [],
			"allied_agents": [],
		},
		"localization": {"map_bounds": _unknown_bounds()},
	}
	var action := {
		"movement": Vector2.ZERO,
		"forecast_seconds": 0.2,
		"samples": [{"time": 0.2, "displacement": Vector2.ZERO, "movement": Vector2.ZERO}],
	}
	var weights := _influence_weights()
	var outcome: Dictionary = influence.predict(
		observation, action, weights, 0.1, _completion_value_ledger({1: 0.0})
	)
	_expect(
		is_equal_approx(outcome.peak_path_collision_risk, 1.0),
		"a swept collision-boundary crossing must be a complete contact opportunity"
	)
	_expect(
		is_equal_approx(outcome.maximum_path_collision_raw_damage, 3.0),
		"swept enemy contact must retain the colliding body's damage"
	)
	var single_impact: Dictionary = impact.evaluate(
		observation, action, _path_collision_evidence(outcome), false
	)
	var second_track: Dictionary = observation.enemy_tracks[0].duplicate(true)
	second_track.track_id = 2
	observation.enemy_tracks.push_back(second_track)
	observation.physics_frame += 1
	var swarm_outcome: Dictionary = influence.predict(
		observation, action, weights, 0.1, _completion_value_ledger({1: 0.0, 2: 0.0})
	)
	var swarm_impact: Dictionary = impact.evaluate(
		observation, action, _path_collision_evidence(swarm_outcome), false
	)
	_expect(
		is_equal_approx(swarm_impact.expected_health_loss, single_impact.expected_health_loss),
		"simultaneous swept contacts must remain one complete hit under vanilla iframes"
	)


func _check_projectile_hitbox_ttc() -> void:
	var collision_model: Reference = load(PLANNING_PATH + "velocity_obstacle_collision_model.gd").new()
	var observation: Dictionary = _planning_observation([])
	observation.player_state.collision_radius = 24.0
	observation.player_state.runtime_stats.move_speed = 481.0
	observation.visible_world.enemy_projectiles = [
		{
			"relative_position": Vector2(30.0, -100.0),
			"velocity": Vector2.ZERO,
			"acceleration": Vector2.ZERO,
			"motion_confidence": 1.0,
			"motion_model": {"kind": "linear"},
			"contact_radius": 33.0,
			"contact_damage": 13.0,
		},
	]
	var action := {
		"movement": Vector2.UP,
		"forecast_seconds": 0.4,
		"samples":
		[
			{"time": 0.1, "displacement": Vector2(0.0, -48.1), "movement": Vector2.UP},
			{"time": 0.4, "displacement": Vector2(0.0, -192.4), "movement": Vector2.UP},
		],
	}
	var outcome: Dictionary = collision_model.evaluate(observation, action, 0.1)
	_expect(
		outcome.minimum_time_to_collision < action.forecast_seconds,
		"movement into an observed hostile hitbox must retain its finite collision time"
	)
	_expect(
		(
			outcome.projectile_velocity_obstacle_risk > 0.0
			and outcome.forecast_maximum_velocity_obstacle_raw_damage == 13.0
		),
		"projectile TTC evidence must preserve both contact risk and hostile damage"
	)


func _check_navigation_horizon_consistency() -> void:
	var predictor_script: Script = load(PLANNING_PATH + "movement_outcome_predictor.gd")
	var predictor: Reference = predictor_script.new()
	var observation := _planning_observation([])
	var action := {
		"movement": Vector2.RIGHT,
		"forecast_seconds": 0.4,
		"samples":
		[
			{"time": 0.1, "displacement": Vector2(10.0, 0.0), "movement": Vector2.RIGHT},
			{"time": 0.4, "displacement": Vector2(40.0, 0.0), "movement": Vector2.RIGHT},
		],
	}
	var context := {
		"control_interval_seconds": 0.1,
		"environmental_pressure_weights": _influence_weights(),
		"state_factors": {"positive_damage_is_terminal_rule": false},
		"enemy_completion_value_ledger": _completion_value_ledger({}),
		"navigation_trajectory_value_samples":
		[
			{
				"direction": Vector2.RIGHT,
				"value_rate": 0.01,
			},
			{
				"direction": Vector2.LEFT,
				"value_rate": 0.0,
			},
		],
	}
	var outcome: Dictionary = predictor.predict_base(observation, action, context)
	_expect(
		is_equal_approx(outcome.navigation_trajectory_value_gain, 0.4),
		(
			"navigation and local consequences must realize the same sustained-action "
			+ "forecast horizon"
		)
	)


func _check_trajectory_value_field() -> void:
	var enemy: Dictionary = _enemy_track(Vector2(60.0, 0.0), Vector2.ZERO, false)
	var observation: Dictionary = _planning_observation([enemy])
	var attack: Dictionary = _weapon_attack_model()
	attack.delivery.maximum_targeting_distance = 5.0
	attack.delivery.paths.maximum_travel_distance = 5.0
	observation.player_state.weapons = [{"slot": 0, "attack_model": attack}]
	var context := {
		"environmental_pressure_weights": _influence_weights(),
		"enemy_completion_value_ledger": _completion_value_ledger({1: 10.0}),
		"state_factors":
		{
			"health_inventory_value":
			{"maximum_consumable_recovery": 0.0, "replenishment_unit_value": 0.0},
			"information_value_per_viewport": 0.0,
			"environmental_exposure_value": 0.0,
			"continuation_horizon_seconds": 1.0,
		},
		"wave_completion_forecast": _fixtures.wave_completion_forecast({1: 1.0}),
	}
	var compute_policy: Reference = load(PLANNING_PATH + "planning_compute_budget_policy.gd").new()
	var result: Dictionary = load(PLANNING_PATH + "navigation_intent_planner.gd").new().plan(
		observation,
		context,
		{"has_deadline": false},
		{"navigation_baseline_direction_count": 4, "navigation_extra_evaluation_limit": 0},
		compute_policy
	)
	var spatial: Reference = load(PLANNING_PATH + "spatial_opportunity_value_model.gd").new()
	var timing: Dictionary = load(PLANNING_PATH + "movement_timing_model.gd").derive(observation)
	var endpoint_delta: Dictionary = spatial.point_value_delta(
		observation,
		context,
		Vector2.RIGHT * result.sampling_radius,
		timing.effective_navigation_horizon_seconds
	)
	var right_sample: Dictionary = _nearest_trajectory_sample(
		result.trajectory_value_samples, Vector2.RIGHT
	)
	_expect(
		(
			result.movement_preference.dot(Vector2.RIGHT) > 0.99
			and abs(endpoint_delta.weapon_completion_opportunity) < 0.0001
			and right_sample.value_breakdown.weapon_completion_opportunity > 0.0
		),
		"a trajectory must retain opportunity crossed before its endpoint"
	)


func _nearest_trajectory_sample(samples: Array, direction: Vector2) -> Dictionary:
	var nearest := {}
	var nearest_alignment := -INF
	for sample in samples:
		var alignment: float = sample.direction.dot(direction)
		if alignment > nearest_alignment:
			nearest = sample
			nearest_alignment = alignment
	return nearest


func _check_pickup_interaction_geometry() -> void:
	var spatial_script: Script = load(PLANNING_PATH + "spatial_opportunity_value_model.gd")
	var spatial: Reference = spatial_script.new()
	var material := {
		"kind": "material",
		"relative_position": Vector2(100.0, 0.0),
		"visual_radius": 36.0,
		"existence_confidence": 1.0,
		"material_quantity_estimate": {"minimum_units": 1.0},
	}
	var observation := {
		"physics_frame": 3,
		"wave_state": {"number": 1, "seconds_remaining": 10.0, "duration_seconds": 10.0},
		"player_state":
		{
			"collision_radius": 10.0,
			"pickup": {"attraction_radius": 150.0, "collection_radius": 32.0},
			"runtime_stats":
			{
				"move_speed": 100.0,
				"armor": 0.0,
				"dodge_chance": 0.0,
				"hit_protection": 0,
			},
			"effective_stats": {"luck": 0.0},
			"movement": {"knockback_velocity": Vector2.ZERO},
			"effect_rules": [],
			"weapons": [],
		},
		"remembered_entities": [material],
		"enemy_tracks": [],
		"localization": {"map_bounds": _unknown_bounds()},
	}
	var context := {
		"state_factors": {"health_inventory_value": {}},
		"wave_completion_forecast": _fixtures.wave_completion_forecast({}),
	}
	var value: Dictionary = spatial.point_value_delta(observation, context, Vector2(50.0, 0.0), 0.5)
	_expect(
		value.material_opportunity > 0.0 and value.material_opportunity < 1.0,
		"pickup opportunity must persist until the material center reaches the collection circle"
	)
	var realized_material: Dictionary = material.duplicate(true)
	realized_material.relative_position = Vector2(10.0, 0.0)
	observation.physics_frame += 1
	observation.remembered_entities = [realized_material]
	var realized_value: Dictionary = spatial_script.new().point_value_delta(
		observation, context, Vector2.LEFT * 50.0, 0.5
	)
	_expect(
		abs(realized_value.material_opportunity) < 0.0001,
		"a pickup inside the collection circle must not be repriced by navigation"
	)
	var collection_geometry_script: Script = load(
		PLANNING_PATH + "pickups/pickup_collection_geometry_model.gd"
	)
	var moving_material: Dictionary = material.duplicate(true)
	moving_material.relative_position = Vector2(100.0, 0.0)
	moving_material.velocity = Vector2(-100.0, 0.0)
	var collection: Dictionary = collection_geometry_script.new().first_collection(
		moving_material, [{"time": 1.0, "displacement": Vector2(100.0, 0.0)}], 20.0
	)
	_expect(
		not collection.empty() and collection.time < 0.5,
		"pickup events must use continuous relative motion instead of static sample endpoints"
	)


func _check_spatial_target_control() -> void:
	var spatial_script: Script = load(PLANNING_PATH + "spatial_opportunity_value_model.gd")
	var observation := {
		"physics_frame": 4,
		"wave_state": {"number": 5, "seconds_remaining": 20.0, "duration_seconds": 40.0},
		"player_state":
		{
			"collision_radius": 10.0,
			"pickup": {"attraction_radius": 100.0, "collection_radius": 20.0},
			"runtime_stats":
			{
				"move_speed": 100.0,
				"armor": 0.0,
				"dodge_chance": 0.0,
				"hit_protection": 0,
			},
			"effective_stats": {"luck": 0.0},
			"movement": {"knockback_velocity": Vector2.ZERO},
			"neutral_completion": {"instant_on_player_hit": false},
			"effect_rules": [],
			"weapons": [{"slot": 0, "attack_model": _weapon_attack_model()}],
		},
		"remembered_entities": [],
		"visible_world": {"trees": []},
		"enemy_tracks":
		[
			_enemy_track(Vector2(-100.0, 0.0), Vector2.ZERO, false),
			_enemy_track(Vector2(500.0, 0.0), Vector2.ZERO, false),
		],
		"localization": {"map_bounds": _unknown_bounds()},
	}
	observation.enemy_tracks[1].track_id = 2
	observation.enemy_tracks[0].behavior_profile.durability = {"maximum_health": 10.0}
	observation.enemy_tracks[1].behavior_profile.durability = {"maximum_health": 10.0}
	var context := {
		"enemy_completion_value_ledger": _completion_value_ledger({1: 1.0, 2: 100.0}),
		"state_factors":
		{
			"health_inventory_value":
			{"maximum_consumable_recovery": 0.0, "replenishment_unit_value": 0.0},
			"continuation_horizon_seconds": 1.0,
		},
		"wave_completion_forecast": _fixtures.wave_completion_forecast({1: 1.0, 2: 1.0}),
	}
	var spatial: Reference = spatial_script.new()
	var enemy_delta: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(250.0, 0.0), 1.0
	)
	_expect(
		enemy_delta.weapon_completion_opportunity > 0.0,
		"creating a positive enemy-completion-value attack window must retain a navigation gradient"
	)
	observation.physics_frame += 1
	observation.enemy_tracks[1].relative_position = Vector2(100.0, 0.0)
	spatial = spatial_script.new()
	var in_range_delta: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(50.0, 0.0), 0.5
	)
	_expect(
		in_range_delta.weapon_completion_opportunity > 0.0,
		(
			"a sustained in-range movement must retain the value of changing the "
			+ "future nearest target"
		)
	)

	observation.physics_frame += 1
	observation.enemy_tracks = [_enemy_track(Vector2(100.0, 0.0), Vector2.ZERO, false)]
	observation.remembered_entities = [
		{
			"memory_record_id": 1,
			"kind": "tree",
			"relative_position": Vector2(500.0, 0.0),
			"visual_radius": 10.0,
			"visible": true,
			"existence_confidence": 1.0,
			"destructible_profile": _fixtures.tree_destructible_profile(1.0, 10.0, 8.0),
		}
	]
	context.enemy_completion_value_ledger = _completion_value_ledger({1: 0.0})
	context.wave_completion_forecast = _fixtures.wave_completion_forecast({1: 1.0}, {1: 1.0})
	spatial = spatial_script.new()
	var tree_delta: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(350.0, 0.0), 1.0
	)
	_expect(
		tree_delta.weapon_completion_opportunity > 0.0,
		(
			"a visible tree outside the lock boundary must retain an approach gradient; "
			+ "navigation weapon completion value owns target competition after lock becomes possible"
		)
	)


func _check_visible_material_quantity_estimate() -> void:
	var estimator_script: Script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/pickups/material_quantity_estimator.gd"
	)
	var estimator: Reference = estimator_script.new()
	var material := Node2D.new()
	material.scale = Vector2(1.25, 1.25)
	_expect(
		is_equal_approx(estimator.estimate(material).minimum_units, 2.0),
		"bonus-sized material must expose only its appearance-proven minimum value"
	)
	material.scale = Vector2(1.5, 1.5)
	_expect(
		is_equal_approx(estimator.estimate(material).minimum_units, 7.0),
		"material growth beyond bonus scale must preserve the pooled-unit lower bound"
	)
	material.scale = Vector2(1.49, 1.49)
	_expect(
		is_equal_approx(estimator.estimate(material).minimum_units, 6.0),
		"a noncanonical rendered scale must not be rounded up beyond its visible lower bound"
	)
	material.free()


func _check_weapon_outcome_contracts() -> void:
	var field_script: Script = load(PLANNING_PATH + "engagement/weapon_outcome_forecast_model.gd")
	var field: Reference = field_script.new()
	var low_value_track := _enemy_track(Vector2(100.0, 0.0), Vector2.ZERO, false)
	low_value_track.behavior_profile.durability = {"maximum_health": 10.0}
	var high_value_track := _enemy_track(Vector2(200.0, 0.0), Vector2.ZERO, false)
	high_value_track.track_id = 2
	high_value_track.behavior_profile.durability = {"maximum_health": 10.0}
	var observation := {
		"physics_frame": 3,
		"player_state":
		{
			"collision_radius": 10.0,
			"health": {"current": 10.0, "maximum": 10.0},
			"runtime_stats":
			{
				"move_speed": 100.0,
				"armor": 0.0,
				"dodge_chance": 0.0,
				"hit_protection": 0,
			},
			"effective_stats": {"percent_damage": 0.0, "attack_speed": 0.0},
			"effect_rules": [],
			"movement": {"knockback_velocity": Vector2.ZERO},
			"neutral_completion": {"instant_on_player_hit": false},
			"weapons": [{"slot": 0, "attack_model": _weapon_attack_model()}],
		},
		"enemy_tracks": [low_value_track, high_value_track],
		"visible_world": {"trees": []},
		"localization": {"map_bounds": _unknown_bounds()},
	}
	var action := {
		"movement": Vector2.ZERO,
		"forecast_seconds": 0.5,
		"samples": [{"time": 0.5, "displacement": Vector2.ZERO, "movement": Vector2.ZERO}],
	}
	var context := {
		"control_interval_seconds": 0.1,
		"enemy_completion_value_ledger": _completion_value_ledger({1: 10.0, 2: 100.0}),
		"state_factors": {"health_inventory_value": {}},
		"wave_completion_forecast": _fixtures.wave_completion_forecast({1: 0.0, 2: 0.0}),
	}
	var outcome := _empty_weapon_outcome(field_script.OUTCOME_FIELDS)
	field.accumulate_outcome(observation, action, outcome, context)
	_expect(
		is_equal_approx(outcome.expected_weapon_damage, 5.0),
		"weapon benefit and forecast collision cost must use the same action horizon"
	)
	_expect(
		(
			outcome.expected_enemy_completion_equivalents > 0.0
			and outcome.expected_enemy_completion_equivalents < 1.0
		),
		"insufficient forecast damage must create a partial enemy completion equivalent"
	)
	_expect(
		is_equal_approx(
			outcome.expected_enemy_reward_delta_value,
			outcome.expected_enemy_completion_equivalents * 10.0
		),
		"automatic weapon reward delta must follow the nearest target's completion fraction"
	)
	observation.physics_frame = 4
	observation.player_state.weapons.push_back({"slot": 1, "attack_model": _weapon_attack_model()})
	var shared_delivery_outcome := _empty_weapon_outcome(field_script.OUTCOME_FIELDS)
	field.accumulate_outcome(observation, action, shared_delivery_outcome, context)
	_expect(
		is_equal_approx(
			shared_delivery_outcome.expected_weapon_damage, 2.0 * outcome.expected_weapon_damage
		),
		"weapons sharing target geometry must retain their independent attack capacity"
	)
	_expect(
		is_equal_approx(
			shared_delivery_outcome.expected_enemy_completion_equivalents,
			shared_delivery_outcome.expected_enemy_hits
		),
		"enemy completion mass must not exceed the finite enemy contacts that can realize it"
	)
	observation.player_state.weapons.pop_back()
	observation.physics_frame = 5
	low_value_track.relative_position = Vector2(200.0, 0.0)
	high_value_track.relative_position = Vector2(100.0, 0.0)
	var high_value_outcome := _empty_weapon_outcome(field_script.OUTCOME_FIELDS)
	field.accumulate_outcome(observation, action, high_value_outcome, context)
	_expect(
		(
			high_value_outcome.expected_enemy_reward_delta_value
			> outcome.expected_enemy_reward_delta_value * 5.0
		),
		"positioning that makes a higher-value target nearest must produce higher combat value"
	)
	observation.physics_frame = 6
	high_value_track.relative_position = Vector2(320.0, 0.0)
	high_value_track.last_measurement.visual_radius = 100.0
	observation.enemy_tracks = [high_value_track]
	var outside_center_range_outcome := _empty_weapon_outcome(field_script.OUTCOME_FIELDS)
	context.enemy_completion_value_ledger = _completion_value_ledger({2: 100.0})
	field.accumulate_outcome(observation, action, outside_center_range_outcome, context)
	_expect(
		is_equal_approx(outside_center_range_outcome.expected_weapon_damage, 0.0),
		"target visual size must not extend the center-distance automatic targeting range"
	)
	observation.physics_frame = 7
	observation.wave_state = {"number": 1, "seconds_remaining": 10.0, "duration_seconds": 10.0}
	observation.player_state.effective_stats.luck = 0.0
	low_value_track.relative_position = Vector2(1.0, 0.0)
	observation.enemy_tracks = [low_value_track]
	var tree := {"relative_position": Vector2(58.0, 76.0), "visual_radius": 10.0}
	tree.destructible_profile = _fixtures.tree_destructible_profile(1.0, 10.0, 6.0)
	observation.visible_world.trees = [tree]
	var tree_action := action.duplicate(true)
	tree_action.movement = Vector2(0.6, 0.8)
	tree_action.forecast_seconds = 0.6
	tree_action.samples = [{"time": 0.6, "displacement": Vector2(30.0, 40.0)}]
	var tree_outcome := _empty_weapon_outcome(field_script.OUTCOME_FIELDS)
	var away_outcome := _empty_weapon_outcome(field_script.OUTCOME_FIELDS)
	context.enemy_completion_value_ledger = _completion_value_ledger({1: 1.0})
	context.state_factors.health_inventory_value = {
		"maximum_consumable_recovery": 0.0, "replenishment_unit_value": 0.0
	}
	field.accumulate_outcome(observation, tree_action, tree_outcome, context)
	tree_action.movement *= -1.0
	tree_action.samples[0].displacement *= -1.0
	field.accumulate_outcome(observation, tree_action, away_outcome, context)
	_expect(
		tree_outcome.expected_tree_completion_value > away_outcome.expected_tree_completion_value,
		"this off-axis target geometry must value the toward-tree path above the away path"
	)


func _check_navigation_weapon_completion_value() -> void:
	var value_model_script: Script = load(
		PLANNING_PATH + "engagement/navigation_weapon_completion_value_model.gd"
	)
	var primary := _enemy_track(Vector2(100.0, 0.0), Vector2.ZERO, false)
	var follower := _enemy_track(Vector2(200.0, 20.0), Vector2(-100.0, -10.0), true)
	follower.track_id = 2
	var observation := _planning_observation([primary, follower])
	var piercing_attack: Dictionary = _weapon_attack_model()
	piercing_attack.delivery.paths.hit_capacity = 2.0
	observation.player_state.weapons = [{"slot": 0, "attack_model": piercing_attack}]
	var context := {
		"state_factors": {"continuation_horizon_seconds": 1.0},
		"enemy_completion_value_ledger": _completion_value_ledger({1: 10.0, 2: 10.0}),
		"wave_completion_forecast": _fixtures.wave_completion_forecast({1: 0.0, 2: 0.0}),
	}
	var value_model: Reference = value_model_script.new()
	var follower_value: float = value_model.value_at(observation, context, Vector2.ZERO, 1.0)
	var stationary_secondary: Dictionary = follower.duplicate(true)
	stationary_secondary.estimated_velocity = Vector2.ZERO
	stationary_secondary.behavior_profile.target_position_response.responds_to_target_position = false
	observation.physics_frame += 1
	observation.enemy_tracks[1] = stationary_secondary
	var stationary_value: float = value_model.value_at(observation, context, Vector2.ZERO, 1.0)
	_expect(
		follower_value > stationary_value,
		"a projected follower entering a piercing corridor must improve completion value"
	)
	observation.physics_frame += 1
	observation.enemy_tracks[1] = follower
	context.enemy_completion_value_ledger = _completion_value_ledger({1: 0.0, 2: -10.0})
	_expect(
		value_model.value_at(observation, context, Vector2.ZERO, 1.0) < 0.0,
		"navigation weapon capacity must retain an adverse completion consequence"
	)
	observation.physics_frame += 1
	context.enemy_completion_value_ledger = _completion_value_ledger({1: 10.0, 2: 10.0})
	observation.player_state.weapons[0].attack_model.delivery.paths.hit_capacity = 1.0
	_expect(
		value_model.value_at(observation, context, Vector2.ZERO, 1.0) > 0.0,
		"a single-target weapon must retain its selected primary target's completion value"
	)
	observation.physics_frame += 1
	observation.player_state.weapons[0].attack_model.delivery.paths.hit_capacity = 2.0
	observation.wave_state.seconds_remaining = 1.0
	_expect(
		is_equal_approx(value_model.value_at(observation, context, Vector2.ZERO, 1.0), 0.0),
		"navigation weapon completion value must expire when the wave ends before it can occur"
	)


func _check_health_inventory_loss() -> void:
	var health_inventory_script: Script = load(
		PLANNING_PATH + "health/health_inventory_value_model.gd"
	)
	var health_inventory_model: Reference = health_inventory_script.new()
	var abundant_supply_value := {
		"immediate_survival_buffer": 4.0,
		"projected_health_inventory": 100.0,
		"terminal_health_loss_unit_value": 10.0,
	}
	var scarce_supply_value: Dictionary = abundant_supply_value.duplicate()
	scarce_supply_value.projected_health_inventory = 4.0
	_expect(
		is_equal_approx(
			health_inventory_model.health_loss_value(2.0, abundant_supply_value),
			health_inventory_model.health_loss_value(2.0, scarce_supply_value)
		),
		"wave-scale replacement supply must not discount local collision loss"
	)
	var abundant_catastrophic_loss: float = health_inventory_model.health_loss_value(
		5.0, abundant_supply_value
	)
	_expect(
		is_equal_approx(
			(
				abundant_catastrophic_loss
				- health_inventory_model.health_loss_value(3.0, abundant_supply_value)
			),
			2.0 * abundant_supply_value.terminal_health_loss_unit_value
		),
		"future replacement supply must not absorb current-buffer terminal loss"
	)
	_expect(
		is_equal_approx(
			abundant_catastrophic_loss,
			health_inventory_model.health_loss_value(5.0, scarce_supply_value)
		),
		"replacement liquidity must remain a continuation value, not local hit capacity"
	)
	_expect(
		is_equal_approx(
			health_inventory_model.health_loss_value(2.0, abundant_supply_value, 0.0), 0.0
		),
		"nonlethal health loss must lose its continuation cost at wave cleanup"
	)
	_expect(
		health_inventory_model.health_loss_value(5.0, abundant_supply_value, 0.0) > 0.0,
		"wave cleanup must never erase damage that crosses the immediate survival buffer"
	)


func _check_recovery_liquidity_pricing() -> void:
	var utility_script: Script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_utility_model.gd"
	)
	var utility: Reference = utility_script.new()
	var observation := _planning_observation([])
	observation.player_state.health = {"current": 4.0, "maximum": 20.0, "ratio": 0.2}
	observation.player_state.resources = {"materials": 0.0}
	var fruit := {
		"kind": "consumable",
		"relative_position": Vector2(10.0, 0.0),
		"visual_radius": 10.0,
		"existence_confidence": 1.0,
		"pickup_profile": {"base_recovery": 3.0, "traits": ["fruit"]},
	}
	observation.remembered_entities = [fruit]
	observation.visible_world.consumables = [fruit]
	var context: Dictionary = utility.build_context(observation)
	var pickup_utility: Dictionary = utility.evaluate(
		{
			"forecast_expected_health_loss": 0.0,
			"expected_recovery": 3.0,
			"consumed_consumable_recovery_supply": 3.0,
		},
		context
	)
	_expect(
		(
			pickup_utility.objective_utility_breakdown.recovery > 0.0
			and is_equal_approx(
				context.state_factors.environmental_exposure_value,
				context.state_factors.health_inventory_value.terminal_health_loss_unit_value
			)
		),
		"future supply must reward recovery without discounting rolling-horizon exposure"
	)
	var tree := {
		"destructible_profile":
		{
			"kill_rewards":
			{
				"base_materials": 0.0,
				"base_consumable_drop_chance": 1.0,
				"item_box_conditional_chance": 0.0,
				"guaranteed_consumable": true,
			}
		}
	}
	var opportunity_script: Script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_pricing_model.gd"
	)
	var opportunity: Reference = opportunity_script.new()
	var no_drop_tree: Dictionary = tree.duplicate(true)
	no_drop_tree.destructible_profile.kill_rewards.base_consumable_drop_chance = 0.0
	no_drop_tree.destructible_profile.kill_rewards.guaranteed_consumable = false
	_expect(
		(
			opportunity.tree_destruction_value(
				observation, tree, context.state_factors.health_inventory_value
			)
			> opportunity.tree_destruction_value(
				observation, no_drop_tree, context.state_factors.health_inventory_value
			)
		),
		"a tree that creates reachable healing supply must retain inventory value"
	)


func _check_additive_collision_damage() -> void:
	var impact_script: Script = load(PLANNING_PATH + "health/collision_health_impact_model.gd")
	var impact: Reference = impact_script.new()
	var observation := _planning_observation([])
	observation.player_state.health = {"current": 9.0, "maximum": 20.0, "ratio": 0.45}
	var action := {"movement": Vector2.ZERO, "forecast_seconds": 0.4}
	var single: Dictionary = impact.evaluate(
		observation, action, _collision_evidence(0.5, 0.5, 3.0, 6.0), false
	)
	var swarm: Dictionary = impact.evaluate(
		observation, action, _collision_evidence(0.9, 2.0, 12.0, 6.0), false
	)
	_expect(
		swarm.expected_health_loss > single.expected_health_loss * 2.0,
		"independent collision opportunities must retain additive expected damage"
	)
	_expect(
		is_equal_approx(swarm.terminal_collision_risk, 0.0),
		"sublethal hit accumulation must remain health loss instead of a second terminal penalty"
	)
	observation.physics_frame += 1
	observation.player_state.runtime_stats.hit_protection = 1
	var partially_protected: Dictionary = impact.evaluate(
		observation, action, _collision_evidence(0.9, 2.0, 12.0, 6.0), false
	)
	_expect(
		(
			partially_protected.expected_health_loss > 0.0
			and partially_protected.expected_health_loss < swarm.expected_health_loss
		),
		"one hit-protection charge must consume one opportunity instead of erasing the forecast"
	)


func _check_local_enemy_interaction_projection() -> void:
	var projector_script: Script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/local_enemy_interaction_projector.gd"
	)
	var projector: Reference = projector_script.new()
	var nearby_memory := _enemy_track(Vector2(100.0, 0.0), Vector2.ZERO, false)
	nearby_memory.visible = false
	var remote_memory := _enemy_track(Vector2(5000.0, 0.0), Vector2.ZERO, false)
	remote_memory.track_id = 2
	remote_memory.visible = false
	var remote_visible := _enemy_track(Vector2(5000.0, 0.0), Vector2.ZERO, false)
	remote_visible.track_id = 3
	var visible_weapon_target := _enemy_track(Vector2(250.0, 0.0), Vector2.ZERO, false)
	visible_weapon_target.track_id = 4
	var observation := _planning_observation(
		[nearby_memory, remote_memory, remote_visible, visible_weapon_target]
	)
	observation.player_state.weapons = [{"slot": 0, "attack_model": _weapon_attack_model()}]
	var result: Dictionary = projector.project(observation, 0.4)
	var retained_ids := []
	for track in result.observation.enemy_tracks:
		retained_ids.push_back(track.track_id)
	_expect(
		(
			1 in retained_ids
			and 4 in retained_ids
			and not (2 in retained_ids)
			and not (3 in retained_ids)
			and result.relevant_enemy_track_count == 2
			and result.excluded_enemy_track_count == 2
		),
		(
			"local enemy interaction must retain reachable threats and weapon targets "
			+ "without retaining remote tracks merely because they are visible"
		)
	)


func _check_wave_completion_forecast() -> void:
	var forecast_script: Script = load(
		PLANNING_PATH + "engagement/wave_completion_forecast_model.gd"
	)
	var forecast_model: Reference = forecast_script.new()
	var first := _enemy_track(Vector2(100.0, 0.0), Vector2.ZERO, false)
	first.behavior_profile.durability = {"maximum_health": 100.0}
	first.last_measurement.health = {"current": 100.0, "maximum": 100.0, "ratio": 1.0}
	var observation := _planning_observation([first])
	observation.wave_state.seconds_remaining = 5.0
	observation.player_state.weapons = [{"slot": 0, "attack_model": _weapon_attack_model()}]
	observation.remembered_entities = [
		{
			"kind": "tree",
			"memory_record_id": 1,
			"existence_confidence": 1.0,
			"destructible_profile": _fixtures.tree_destructible_profile(10.0, 100.0),
		}
	]
	var forecast: Dictionary = forecast_model.forecast(observation)
	_expect(
		(
			forecast.allocated_hits <= forecast.primary_hit_capacity + 0.001
			and forecast.completion_fraction_by_target_id["enemy:1"] > 0.0
			and forecast.completion_fraction_by_target_id["tree:1"] > 0.0
		),
		(
			"enemy and tree completion must draw from one attack-capacity ledger "
			+ "without allocating the same future hits twice"
		)
	)
	_expect(
		forecast.competition_scale < 1.0,
		"crowded completion forecasts must expose attack-capacity competition"
	)
	var full_health_fraction: float = forecast.completion_fraction_by_target_id["enemy:1"]
	first.last_measurement.health = {"current": 10.0, "maximum": 100.0, "ratio": 0.1}
	observation.physics_frame += 1
	forecast = forecast_model.forecast(observation)
	_expect(
		forecast.completion_fraction_by_target_id["enemy:1"] > full_health_fraction,
		"observed remaining health must reduce completion work for a damaged enemy"
	)
	observation.player_state.weapons = []
	forecast = forecast_model.forecast(observation)
	_expect(
		forecast.competition_scale == 1.0 and forecast.allocated_hits == 0.0,
		"zero attack supply must report zero allocation without fabricating competition"
	)
	observation.player_state.weapons = [{"slot": 0, "attack_model": _weapon_attack_model()}]
	observation.wave_state.seconds_remaining = 0.0
	forecast = forecast_model.forecast(observation)
	_expect(
		forecast.allocated_hits == 0.0,
		"wave cleanup must remove all remaining attack capacity from the completion forecast"
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
	}


func _empty_weapon_outcome(field_names: Array) -> Dictionary:
	var outcome := {}
	for field_name in field_names:
		outcome[field_name] = 0.0
	outcome.expected_recovery = 0.0
	outcome.expected_recovery_events = 0.0
	return outcome


func _planning_observation(enemy_tracks: Array) -> Dictionary:
	return _fixtures.planning_observation(enemy_tracks)


func _weapon_attack_model() -> Dictionary:
	return _fixtures.weapon_attack_model()


func _enemy_track(position: Vector2, velocity: Vector2, follows_player: bool) -> Dictionary:
	return _fixtures.enemy_track(position, velocity, follows_player)


func _collision_evidence(
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


func _unknown_bounds() -> Dictionary:
	return {
		"seen_left": false,
		"seen_right": false,
		"seen_top": false,
		"seen_bottom": false,
		"distance_to_left": null,
		"distance_to_right": null,
		"distance_to_top": null,
		"distance_to_bottom": null,
	}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot model contract failed: %s" % message)


func _get_archive_path() -> String:
	for argument in OS.get_cmdline_args():
		if argument.ends_with(".zip"):
			return argument
	return ""
