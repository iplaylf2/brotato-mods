extends SceneTree

# Executable mechanics contracts for the planning models whose errors are hard
# to detect through script compilation alone. The mod archive is mounted at
# runtime so this check exercises the same res:// paths as the game.

var _failed := false


func _init() -> void:
	var archive_path := _get_archive_path()
	if archive_path.empty() or not ProjectSettings.load_resource_pack(archive_path, false):
		printerr("Could not mount the mod contract-check archive: %s" % archive_path)
		quit(1)
		return
	_check_target_response()
	_check_swept_enemy_contact()
	_check_pickup_interaction_geometry()
	_check_weapon_outcome_contracts()
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
			},
			"effect_rules": [],
			"movement": {"knockback_velocity": Vector2.ZERO},
		},
		"enemy_tracks": [_enemy_track(Vector2(100.0, 0.0), Vector2(-1000.0, 0.0), false)],
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
	var weights := {
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
	var outcome: Dictionary = influence.predict(observation, action, weights, 0.1)
	_expect(
		is_equal_approx(outcome.peak_path_collision_risk, 1.0),
		"enemy contact must be detected between safe-looking sample endpoints"
	)
	_expect(
		is_equal_approx(outcome.maximum_path_collision_damage, 3.0),
		"swept enemy contact must retain the colliding body's damage"
	)


func _check_pickup_interaction_geometry() -> void:
	var spatial_script: Script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/spatial_opportunity_value_model.gd"
	)
	var spatial: Reference = spatial_script.new()
	var material := {
		"kind": "material",
		"relative_position": Vector2(100.0, 0.0),
		"visual_radius": 36.0,
		"existence_confidence": 1.0,
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
			"movement": {"knockback_velocity": Vector2.ZERO},
			"effect_rules": [],
			"weapons": [],
		},
		"remembered_entities": [material],
		"enemy_tracks": [],
		"localization": {"map_bounds": _unknown_bounds()},
	}
	var value: Dictionary = spatial.stationary_value(
		observation, {"state_factors": {"health_resource_value": {}}}, 0.0
	)
	_expect(
		value.material_opportunity > 0.0 and value.material_opportunity < 1.0,
		"pickup opportunity must persist until the material center reaches the collection circle"
	)


func _check_weapon_outcome_contracts() -> void:
	var field_script: Script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapon_outcome_field_model.gd"
	)
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
	var outcome := _empty_weapon_outcome(field_script.OUTCOME_FIELDS)
	field.accumulate_outcome(
		observation,
		action,
		outcome,
		{
			"control_interval_seconds": 0.1,
			"enemy_removal_value_ledger":
			{
				"removal_values": {1: 10.0, 2: 100.0},
			},
			"state_factors": {"health_resource_value": {}},
		}
	)
	_expect(
		is_equal_approx(outcome.expected_weapon_damage, 5.0),
		"weapon benefit and forecast collision cost must use the same action horizon"
	)
	_expect(
		is_equal_approx(outcome.expected_enemy_removal_value_progress, 5.0),
		"automatic weapon value must belong to the nearest fully available target"
	)
	observation.physics_frame = 4
	low_value_track.relative_position = Vector2(200.0, 0.0)
	high_value_track.relative_position = Vector2(100.0, 0.0)
	var high_value_outcome := _empty_weapon_outcome(field_script.OUTCOME_FIELDS)
	field.accumulate_outcome(
		observation,
		action,
		high_value_outcome,
		{
			"control_interval_seconds": 0.1,
			"enemy_removal_value_ledger": {"removal_values": {1: 10.0, 2: 100.0}},
			"state_factors": {"health_resource_value": {}},
		}
	)
	_expect(
		(
			high_value_outcome.expected_enemy_removal_value_progress
			> outcome.expected_enemy_removal_value_progress * 5.0
		),
		"positioning that makes a higher-value target nearest must produce higher combat value"
	)
	observation.physics_frame = 5
	high_value_track.relative_position = Vector2(320.0, 0.0)
	high_value_track.last_measurement.visual_radius = 100.0
	observation.enemy_tracks = [high_value_track]
	var outside_center_range_outcome := _empty_weapon_outcome(field_script.OUTCOME_FIELDS)
	field.accumulate_outcome(
		observation,
		action,
		outside_center_range_outcome,
		{
			"control_interval_seconds": 0.1,
			"enemy_removal_value_ledger": {"removal_values": {2: 100.0}},
			"state_factors": {"health_resource_value": {}},
		}
	)
	_expect(
		is_equal_approx(outside_center_range_outcome.expected_weapon_damage, 0.0),
		"target visual size must not extend the center-distance automatic targeting range"
	)


func _empty_weapon_outcome(field_names: Array) -> Dictionary:
	var outcome := {}
	for field_name in field_names:
		outcome[field_name] = 0.0
	outcome.expected_recovery = 0.0
	outcome.expected_recovery_events = 0.0
	return outcome


func _weapon_attack_model() -> Dictionary:
	return {
		"timing": {"expected_attack_interval_seconds": 1.0, "permitted_while_moving": true},
		"delivery":
		{
			"minimum_targeting_distance": 0.0,
			"maximum_targeting_distance": 300.0,
			"paths":
			{
				"count": 1,
				"angular_half_extent": 0.0,
				"corridor_half_width": 5.0,
				"primary_probability_floor": 1.0,
				"hit_capacity": 1.0,
				"retained_damage": 1.0,
				"maximum_travel_distance": 300.0,
			},
			"redirects":
			{
				"count": 0.0,
				"retained_damage": 0.0,
			},
		},
		"impact":
		{
			"damage": 10.0,
			"critical_chance": 0.0,
			"critical_damage_multiplier": 2.0,
			"lifesteal": 0.0,
			"scaling": [],
		},
		"rules": [],
	}


func _enemy_track(position: Vector2, velocity: Vector2, follows_player: bool) -> Dictionary:
	return {
		"track_id": 1,
		"visible": true,
		"relative_position": position,
		"estimated_velocity": velocity,
		"estimated_acceleration": Vector2.ZERO,
		"motion_confidence": 0.0,
		"recency_confidence": 1.0,
		"uncertainty_radius": 0.0,
		"last_measurement": {"visual_radius": 10.0},
		"behavior_profile":
		{
			"contact_radius": 10.0,
			"contact_damage": 3.0,
			"projectile_attack": {"creates_projectile_pressure": false},
			"charge_attack": {"active": false},
			"target_position_response":
			{
				"responds_to_target_position": follows_player,
				"preferred_distance": 0.0,
				"moves_away_inside_preferred_distance": false,
				"movement_speed": velocity.length(),
				"confidence": 1.0,
			},
		},
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
