extends SceneTree

# Exercises Autopilot's planning-handoff contract with the real MovementPlanner:
# only one request may own the planner graph at a time, completions must remain
# paired with their observations, and shutdown must close the handoff boundary.

var _worker: Reference


func _init() -> void:
	var archive_path := _get_archive_path()
	if archive_path.empty() or not ProjectSettings.load_resource_pack(archive_path, false):
		printerr("Could not mount the planning-worker contract archive: %s" % archive_path)
		quit(1)
		return
	var worker_script: Script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/control/planning_worker.gd"
	)
	_worker = worker_script.new()
	if _worker.submit([]):
		_fail("a stopped worker must reject planning requests")
		return
	if not _worker.start(1):
		_fail("worker must start")
		return
	for cycle in 2:
		var observation := _planning_observation(cycle)
		if not _worker.submit(
			[
				{
					"player_index": 0,
					"observation": observation,
					"frame_budget_context": {"has_frame_time_sample": false},
				}
			]
		):
			_fail("worker must accept cycle %s" % cycle)
			return
		if _worker.submit([]):
			_fail("worker must reject an overlapping planning cycle")
			return
		if not _worker.is_busy():
			_fail("an accepted planning cycle must own the handoff until collected")
			return
		while true:
			var completion: Dictionary = _worker.poll()
			if completion.ready:
				if completion.results.size() != 1:
					_fail("worker must return one result for cycle %s" % cycle)
					return
				var result: Dictionary = completion.results[0]
				if result.player_index != 0 or result.observation.physics_frame != cycle:
					_fail("worker returned the wrong result for cycle %s" % cycle)
					return
				if typeof(result.get("plan")) != TYPE_DICTIONARY:
					_fail("real planner returned no plan for cycle %s" % cycle)
					return
				var plan: Dictionary = result.plan
				if plan.get("status", "") != "ready":
					_fail("real planner must complete cycle %s" % cycle)
					return
				break
			OS.delay_usec(100)
		if _worker.is_busy():
			_fail("collecting a completion must release the planning handoff")
			return
		if _worker.poll().ready:
			_fail("a completion must be consumable exactly once")
			return
	_worker.shutdown()
	if _worker.submit([]):
		_fail("a shut-down worker must reject planning requests")
		return
	quit(0)


func _planning_observation(physics_frame: int) -> Dictionary:
	return {
		"physics_frame": physics_frame,
		"wave_state":
		{
			"number": 1,
			"final_number": 20,
			"endless": false,
			"seconds_remaining": 20.0,
			"duration_seconds": 20.0,
		},
		"player_state":
		{
			"dead": false,
			"health": {"current": 20.0, "maximum": 20.0, "ratio": 1.0},
			"progression": {"level": 1, "experience": 0, "next_level_experience_required": 10},
			"resources": {"materials": 0},
			"inventory": {"item_count": 0},
			"effective_stats":
			{
				"max_health": 20.0,
				"health_regeneration": 0.0,
				"lifesteal": 0.0,
				"percent_damage": 0.0,
				"melee_damage": 0.0,
				"ranged_damage": 0.0,
				"elemental_damage": 0.0,
				"attack_speed": 0.0,
				"critical_chance": 0.0,
				"engineering": 0.0,
				"range": 0.0,
				"armor": 0.0,
				"dodge": 0.0,
				"speed": 0.0,
				"luck": 0.0,
				"harvesting": 0.0,
				"curse": 0.0,
			},
			"stat_opportunity_profiles": {},
			"runtime_stats":
			{
				"move_speed": 100.0,
				"armor": 0.0,
				"dodge_chance": 0.0,
				"hit_protection": 0,
				"minimum_invincibility_seconds": 0.2,
			},
			"collision_radius": 10.0,
			"movement":
			{
				"input_vector": Vector2.ZERO,
				"is_moving": false,
				"velocity": Vector2.ZERO,
				"knockback_velocity": Vector2.ZERO,
				"standing_effects_active": false,
				"moving_effects_active": false,
			},
			"pickup":
			{
				"range_modifier_percent": 0.0,
				"attraction_radius": 100.0,
				"collection_radius": 20.0,
			},
			"weapons": [],
			"effect_rules": [],
		},
		"party_state":
		{
			"teammate_count": 0,
			"living_teammate_count": 0,
			"living_teammate_player_indices": [],
		},
		"localization":
		{
			"odometry_position": Vector2.ZERO,
			"map_x": null,
			"map_y": null,
			"map_position": null,
			"map_bounds":
			{
				"seen_left": false,
				"seen_right": false,
				"seen_top": false,
				"seen_bottom": false,
				"distance_to_left": null,
				"distance_to_right": null,
				"distance_to_top": null,
				"distance_to_bottom": null,
			},
			"observation_grid_cell_size": 0.0,
			"observation_cells": [],
		},
		"enemy_tracks": [],
		"remembered_entities": [],
		"visibility":
		{
			"viewport_size": Vector2(1920.0, 1080.0),
			"viewport_offset_from_player": Vector2(-960.0, -540.0),
			"fog_active": false,
		},
		"visible_world":
		{
			"trees": [],
			"allied_agents": [],
			"structures": [],
			"materials": [],
			"consumables": [],
			"enemy_projectiles": [],
			"spawn_warnings": [],
		},
	}


func _fail(message: String) -> void:
	printerr("Autopilot planning-worker contract failed: %s" % message)
	if _worker != null:
		_worker.shutdown()
	quit(1)


func _get_archive_path() -> String:
	for argument in OS.get_cmdline_args():
		if argument.ends_with(".zip"):
			return argument
	return ""
