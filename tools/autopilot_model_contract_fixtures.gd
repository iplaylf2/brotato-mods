extends Reference

# Shared, behavior-free fixtures for executable Autopilot model contracts.


func planning_observation(enemy_tracks: Array) -> Dictionary:
	for track in enemy_tracks:
		track.behavior_profile.durability = track.behavior_profile.get(
			"durability", {"maximum_health": 10.0}
		)
		track.behavior_profile.kill_rewards = track.behavior_profile.get(
			"kill_rewards",
			{
				"base_materials": 1.0,
				"base_consumable_drop_chance": 0.0,
				"item_box_conditional_chance": 0.0,
			}
		)
	return {
		"physics_frame": 20,
		"wave_state": {"number": 1, "seconds_remaining": 10.0, "duration_seconds": 10.0},
		"player_state":
		{
			"collision_radius": 10.0,
			"health": {"current": 20.0, "maximum": 20.0, "ratio": 1.0},
			"pickup": {"attraction_radius": 100.0, "collection_radius": 20.0},
			"runtime_stats":
			{
				"move_speed": 100.0,
				"armor": 0.0,
				"dodge_chance": 0.0,
				"hit_protection": 0,
				"minimum_invincibility_seconds": 0.2,
			},
			"effective_stats": {"luck": 0.0},
			"movement": {"knockback_velocity": Vector2.ZERO},
			"effect_rules": [],
			"weapons": [],
		},
		"enemy_tracks": enemy_tracks,
		"remembered_entities": [],
		"visibility": {"viewport_size": Vector2.ZERO, "viewport_offset_from_player": Vector2.ZERO},
		"visible_world":
		{
			"materials": [],
			"consumables": [],
			"trees": [],
			"enemy_projectiles": [],
			"spawn_warnings": [],
			"structures": [],
			"allied_agents": [],
		},
		"localization": {"map_bounds": _unknown_bounds()},
	}


func weapon_attack_model() -> Dictionary:
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
			"redirects": {"count": 0.0, "retained_damage": 0.0},
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


func enemy_track(position: Vector2, velocity: Vector2, follows_player: bool) -> Dictionary:
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
