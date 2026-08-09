extends SceneTree

# Exercises the two independent planning handoffs with their real planners:
# tactical work must not occupy the strategic mailbox (or vice versa), each
# worker accepts only one generation, and guidance crosses as detached values.

var _tactical_worker: Reference
var _strategic_worker: Reference


func _init() -> void:
	var archive_path := _get_archive_path()
	if archive_path.empty() or not ProjectSettings.load_resource_pack(archive_path, false):
		printerr("Could not mount the planning-worker contract archive: %s" % archive_path)
		quit(1)
		return
	var worker_script: Script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/control/planning_worker.gd"
	)
	var tactical_movement_planner_script: Script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/tactical_movement_planner.gd"
	)
	var strategic_navigation_planner_script: Script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/strategic_navigation_planner.gd"
	)
	_tactical_worker = worker_script.new()
	_strategic_worker = worker_script.new()
	if _tactical_worker.submit([]):
		_fail("a stopped worker must reject planning requests")
		return
	if not _tactical_worker.start(1, tactical_movement_planner_script):
		_fail("tactical worker must start")
		return
	if not _strategic_worker.start(1, strategic_navigation_planner_script):
		_fail("strategic worker must start independently")
		return
	var strategic_navigation_guidance := {}
	for cycle in 2:
		var observation := _planning_observation(cycle)
		var request_created_usec := OS.get_ticks_usec()
		var request := {
			"player_index": 0,
			"observation": observation,
			"active_movement": Vector2.ZERO,
			"request_created_usec": request_created_usec,
			"frame_budget_context": {"has_frame_time_sample": false},
			"strategic_navigation_guidance": strategic_navigation_guidance.duplicate(true),
		}
		if not _tactical_worker.submit([request]):
			_fail("worker must accept cycle %s" % cycle)
			return
		var strategic_request: Dictionary = request.duplicate(true)
		strategic_request.erase("strategic_navigation_guidance")
		if not _strategic_worker.submit([strategic_request]):
			_fail("strategic worker must accept while tactical work is in flight")
			return
		if _tactical_worker.submit([]):
			_fail("worker must reject an overlapping planning cycle")
			return
		if not _tactical_worker.is_busy() or not _strategic_worker.is_busy():
			_fail("each accepted planning cycle must own its own handoff until collected")
			return
		var tactical_ready := false
		var strategic_ready := false
		while not tactical_ready or not strategic_ready:
			var completion: Dictionary = _tactical_worker.poll()
			if completion.ready:
				tactical_ready = true
				if completion.results.size() != 1:
					_fail("worker must return one result for cycle %s" % cycle)
					return
				var result: Dictionary = completion.results[0]
				if result.player_index != 0 or result.observation.physics_frame != cycle:
					_fail("worker returned the wrong result for cycle %s" % cycle)
					return
				if typeof(result.get("output")) != TYPE_DICTIONARY:
					_fail("real planner returned no plan for cycle %s" % cycle)
					return
				var plan: Dictionary = result.output
				if plan.get("status", "") != "ready":
					_fail("real planner must complete cycle %s" % cycle)
					return
			var strategic_completion: Dictionary = _strategic_worker.poll()
			if strategic_completion.ready:
				strategic_ready = true
				if strategic_completion.results.size() != 1:
					_fail("strategic worker must return one result for cycle %s" % cycle)
					return
				strategic_navigation_guidance = strategic_completion.results[0].output
				if (
					strategic_navigation_guidance.get("status", "") != "ready"
					or strategic_navigation_guidance.get("source_physics_frame", -1) != cycle
					or not strategic_navigation_guidance.has("navigation_intent")
				):
					_fail("strategic guidance must remain paired with its source observation")
					return
			OS.delay_usec(100)
		if _tactical_worker.is_busy() or _strategic_worker.is_busy():
			_fail("collecting completions must release both planning handoffs")
			return
		if _tactical_worker.poll().ready or _strategic_worker.poll().ready:
			_fail("a completion must be consumable exactly once")
			return
	_tactical_worker.shutdown()
	_strategic_worker.shutdown()
	if _tactical_worker.submit([]):
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
				"maximum_invincibility_seconds": 0.4,
				"invincibility_seconds_remaining": 0.0,
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
	if _tactical_worker != null:
		_tactical_worker.shutdown()
	if _strategic_worker != null:
		_strategic_worker.shutdown()
	quit(1)


func _get_archive_path() -> String:
	for argument in OS.get_cmdline_args():
		if argument.ends_with(".zip"):
			return argument
	return ""
