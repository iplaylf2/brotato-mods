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
		printerr("Could not mount the Autopilot runtime contract archive: %s" % archive_path)
		quit(1)
		return
	_check_planning_budget_and_search_allocation()
	_check_neutral_completion_work()
	_check_neutral_progress_completion_forecast()
	_check_tree_visibility_absence_evidence()
	quit(1 if _failed else 0)


func _check_planning_budget_and_search_allocation() -> void:
	var budget_policy: Reference = load(PLANNING_PATH + "planning_compute_budget_policy.gd").new()
	budget_policy.set_frame_budget_context(
		{
			"has_frame_time_sample": true,
			"physics_frame_capacity_usec": 16666.0,
			"physics_process_peak_usec_ema": 5000.0,
			"planning_window_usec": 100000.0,
			"planning_window_physics_frames": 6,
			"scheduled_planner_count": 1,
		}
	)
	var budget: Dictionary = budget_policy.allocate(OS.get_ticks_usec())
	_expect(
		(
			budget.planning_duration_budget_usec > 16666.0 - 5000.0
			and budget.planning_duration_budget_usec <= 100000.0
		),
		"background planning must draw on aggregate control-window frame headroom"
	)
	var allocator_script: Script = load(PLANNING_PATH + "planning_search_work_allocator.gd")
	var search: Dictionary = allocator_script.new().allocate({"budget_pressure": 1.0}, 12)
	_expect(
		search.movement_refinement_limit == 0 and search.navigation_extra_evaluation_limit == 0,
		"saturated budget pressure must remove optional navigation and refinement work"
	)


func _check_neutral_completion_work() -> void:
	var work_script: Script = load(PLANNING_PATH + "engagement/neutral_completion_work_model.gd")
	var work_model: Reference = work_script.new()
	var tree := {
		"destructible_profile": {"destruction": {"hit_limit": 8.0, "maximum_health": 80.0}},
		"destruction_state":
		{
			"received_hits": 6.0,
			"remaining_hits_to_limit": 2.0,
			"health": {"current": 80.0, "maximum": 80.0, "ratio": 1.0},
		},
	}
	_expect(
		is_equal_approx(work_model.remaining_hits_to_limit(tree), 2.0),
		"visible neutral progress must be the source of remaining destruction work"
	)
	_expect(
		is_equal_approx(work_model.expected_hits_to_complete(tree, 1.0, false), 2.0),
		"the remaining hit limit must complete a neutral before insufficient damage does"
	)
	tree.destruction_state = {
		"received_hits": 0.0,
		"remaining_hits_to_limit": 8.0,
		"health": {"current": 5.0, "maximum": 80.0, "ratio": 0.0625},
	}
	_expect(
		is_equal_approx(work_model.expected_hits_to_complete(tree, 10.0, false), 0.5),
		"remaining health and weapon damage must complete a neutral before its hit limit"
	)
	_expect(
		is_equal_approx(work_model.expected_hits_to_complete(tree, 1.0, true), 1.0),
		"the observed one-shot-tree effect must reduce neutral completion to one player hit"
	)
	tree.destruction_state = {"received_hits": 8.0, "remaining_hits_to_limit": 0.0}
	_expect(
		is_equal_approx(work_model.remaining_hits_to_limit(tree), 0.0),
		"completed neutral work must remain complete instead of becoming a synthetic hit"
	)
	tree.erase("destruction_state")
	_expect(
		is_equal_approx(work_model.remaining_hits_to_limit(tree), 8.0),
		"unobserved neutral progress must fall back to stable required hits"
	)


func _check_neutral_progress_completion_forecast() -> void:
	var forecast_script: Script = load(
		PLANNING_PATH + "engagement/wave_completion_forecast_model.gd"
	)
	var forecast_model: Reference = forecast_script.new()
	var observation: Dictionary = _fixtures.planning_observation([])
	observation.wave_state.seconds_remaining = 5.0
	observation.player_state.weapons = [
		{"slot": 0, "attack_model": _fixtures.weapon_attack_model()}
	]
	observation.remembered_entities = [
		{
			"kind": "tree",
			"memory_record_id": 1,
			"existence_confidence": 1.0,
			"destructible_profile": {"destruction": {"hit_limit": 10.0, "maximum_health": 100.0}},
		}
	]
	var untouched: Dictionary = forecast_model.forecast(observation)
	observation.remembered_entities[0].destruction_state = {
		"received_hits": 0.0,
		"remaining_hits_to_limit": 10.0,
		"health": {"current": 10.0, "maximum": 100.0, "ratio": 0.1},
	}
	var damaged: Dictionary = forecast_model.forecast(observation)
	_expect(
		(
			damaged.completion_fraction_by_target_id["tree:1"]
			> untouched.completion_fraction_by_target_id["tree:1"]
		),
		"observed neutral damage must increase its feasible completion fraction"
	)
	observation.remembered_entities[0].destruction_state = {
		"received_hits": 10.0, "remaining_hits_to_limit": 0.0
	}
	var completed: Dictionary = forecast_model.forecast(observation)
	_expect(
		is_equal_approx(completed.completion_fraction_by_target_id.get("tree:1", 0.0), 0.0),
		"completed neutral work must consume no future attack capacity"
	)


func _check_tree_visibility_absence_evidence() -> void:
	var estimator_script: Script = load(
		(
			"res://mods-unpacked/iplaylf2-autopilot/bot/observation/"
			+ "remembered_entity_existence_estimator.gd"
		)
	)
	var estimator: Reference = estimator_script.new()
	estimator.update(0.0, Vector2.ZERO, [])
	var memory_record := {
		"odometry_position": Vector2(100.0, 0.0),
		"observation": {"kind": "tree", "visual_radius": 24.0},
	}
	var visibility := {
		"viewport_size": Vector2(400.0, 300.0),
		"viewport_offset_from_player": Vector2(-200.0, -150.0),
		"fog_active": false,
	}
	var clear_estimate: Dictionary = estimator.estimate(memory_record, {}, {}, visibility)
	_expect(
		clear_estimate.absence_confirmed,
		"an absent stationary tree in a revisited clear viewport must be confirmed gone"
	)
	visibility.fog_active = true
	var fog_estimate: Dictionary = estimator.estimate(memory_record, {}, {}, visibility)
	_expect(
		not fog_estimate.absence_confirmed,
		"a fog viewport must not manufacture rectangular tree-absence evidence"
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot runtime contract failed: %s" % message)


func _get_archive_path() -> String:
	for argument in OS.get_cmdline_args():
		if argument.ends_with(".zip"):
			return argument
	return ""
