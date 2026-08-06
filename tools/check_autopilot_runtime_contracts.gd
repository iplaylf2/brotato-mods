extends SceneTree

const PLANNING_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/planning/"
const KNOWLEDGE_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/"
const OBSERVATION_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/observation/"
const SAMPLING_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/sampling/"
var _failed := false
var _fixtures: Reference
var _observed_world_memory_script: Script


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
	_observed_world_memory_script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/observation/observed_world_memory.gd"
	)
	_check_planning_budget_and_search_allocation()
	_check_neutral_completion_work()
	_check_item_box_tier_expectation()
	_check_neutral_progress_completion_forecast()
	_check_exact_observed_state()
	_check_tree_visibility_absence_evidence()
	_check_visibility_coverage()
	_check_enemy_negative_visibility_evidence()
	_check_persistent_enemy_health_observation()
	_check_enemy_death_product_matching()
	_check_collision_shape_radius_adapter()
	_check_projectile_motion_bound()
	_check_action_forecast_domain()
	_check_immediate_hit_reserve_reachability()
	_check_run_continuation_risk_and_action_selection()
	_check_battle_sample_storage_contract()
	quit(1 if _failed else 0)


func _check_battle_sample_storage_contract() -> void:
	var writer: Reference = load(SAMPLING_PATH + "battle_sample_writer.gd").new()
	writer.start(2, "contract-run", 7, "human", {"interval_seconds": 1.0})
	var path: String = writer.get_current_path()
	var observation := {
		"physics_frame": 123,
		"wave_state":
		{
			"number": 7,
			"final_number": 20,
			"endless": false,
			"is_horde": false,
			"seconds_remaining": 42.0,
			"duration_seconds": 60.0,
		},
		"player_state":
		{
			"movement": {"input_vector": Vector2.RIGHT},
			"effect_rules": [{"event": "consumable_pickup", "consequences": []}],
			"stat_opportunity_profiles": {"maximum_health": {"weight": 1.0}},
		},
		"enemy_tracks": [],
		"sampling_context": {"character_id": "character_chef"},
	}
	writer.record_human_sample(0, 1, observation)
	var second_observation: Dictionary = observation.duplicate(true)
	second_observation.physics_frame = 124
	second_observation.sampling_context.character_id = "character_ranger"
	second_observation.player_state.effect_rules[0].event = "material_pickup"
	second_observation.player_state.stat_opportunity_profiles.maximum_health.weight = 2.0
	writer.record_human_sample(1, 1, second_observation)
	writer.close([0, 0], [1, 1], [])
	_expect(
		path.find("/contract-run/wave-007-human-") >= 0 and path.ends_with(".jsonl"),
		"each wave and control source must use one file in the enclosing run directory"
	)
	var file := File.new()
	var open_error: int = file.open(path, File.READ)
	_expect(open_error == OK, "the sample writer must create a readable human segment")
	if open_error != OK:
		return
	var records := []
	while not file.eof_reached():
		var line: String = file.get_line()
		if line.empty():
			continue
		records.push_back(JSON.parse(line).result)
	file.close()
	var header := {}
	var wave_context := {}
	var player_contexts := {}
	var header_count := 0
	var wave_context_count := 0
	var player_context_count := 0
	var action_count := 0
	var samples_are_compact := true
	var sampled_rule_events := []
	var segment_end_count := 0
	var wave_context_index := -1
	var player_context_index := -1
	var action_index := -1
	for record_index in records.size():
		var record: Dictionary = records[record_index]
		match record.get("record_type", ""):
			"segment_start":
				header = record
				header_count += 1
			"wave_context":
				wave_context = record
				wave_context_count += 1
				wave_context_index = record_index
			"player_context":
				player_contexts[int(record.player_index)] = record
				player_context_count += 1
				player_context_index = record_index
			"action_sample":
				action_count += 1
				action_index = record_index
				sampled_rule_events.push_back(record.observation.player_state.effect_rules[0].event)
				samples_are_compact = (
					samples_are_compact
					and not record.has("run_id")
					and not record.observation.wave_state.has("number")
					and not record.observation.player_state.has("stat_opportunity_profiles")
					and record.observation.player_state.has("effect_rules")
					and not record.observation.has("sampling_context")
				)
			"segment_end":
				segment_end_count += 1
	_expect(
		(
			header_count == 1
			and wave_context_count == 1
			and player_context_count == 2
			and action_count == 2
			and segment_end_count == 1
			and wave_context_index < action_index
			and player_context_index < action_index
		),
		"a human segment must declare its wave and player contexts before sampling and end once"
	)
	if (
		header_count != 1
		or wave_context_count != 1
		or player_context_count != 2
		or action_count != 2
		or segment_end_count != 1
	):
		return
	_expect(
		header.control_source == "human" and header.run_id == "contract-run",
		"the file header must associate the segment with its run and control source"
	)
	_expect(
		(
			wave_context.wave_state.number == 7
			and player_contexts[0].character_id == "character_chef"
			and player_contexts[1].character_id == "character_ranger"
			and player_contexts[0].stat_opportunity_profiles.maximum_health.weight == 1.0
			and player_contexts[1].stat_opportunity_profiles.maximum_health.weight == 2.0
			and sampled_rule_events == ["consumable_pickup", "material_pickup"]
		),
		"wave-wide context must be shared while player context remains player-specific"
	)
	_expect(
		samples_are_compact,
		"per-sample records must omit metadata already declared by the file context"
	)


func _check_exact_observed_state() -> void:
	var world_observer: Reference = load(OBSERVATION_PATH + "visible_world_observer.gd").new(
		null, []
	)
	var warning_window: Dictionary = world_observer.call("_exact_tick_window", 30.0)
	_expect(
		(
			warning_window.is_exact
			and is_equal_approx(warning_window.earliest_seconds, 0.5)
			and is_equal_approx(warning_window.latest_seconds, 0.5)
		),
		"a visible spawn warning must preserve its exact presented countdown phase"
	)

	var motion_estimator: Reference = load(OBSERVATION_PATH + "observed_motion_estimator.gd").new()
	var source := Reference.new()
	var first := {
		"_source": source,
		"_world_position": Vector2.ZERO,
		"_velocity_is_authoritative": true,
		"velocity": Vector2(10.0, 0.0),
	}
	motion_estimator.update([first], 0.1)
	var second := {
		"_source": source,
		"_world_position": Vector2(100.0, 0.0),
		"_velocity_is_authoritative": true,
		"velocity": Vector2(20.0, 0.0),
	}
	motion_estimator.update([second], 0.1)
	_expect(
		second.velocity == Vector2(20.0, 0.0),
		"visible motion must retain vanilla's authoritative current velocity"
	)
	var inferred_source := Reference.new()
	var inferred_first := {
		"_source": inferred_source,
		"_world_position": Vector2.ZERO,
		"velocity": Vector2.ZERO,
	}
	motion_estimator.update([inferred_first], 0.1)
	var inferred_second := {
		"_source": inferred_source,
		"_world_position": Vector2(5.0, 0.0),
		"velocity": Vector2.ZERO,
	}
	motion_estimator.update([inferred_second], 0.1)
	_expect(
		is_equal_approx(inferred_second.velocity.x, 50.0),
		"visible position history must supply velocity when vanilla exposes none"
	)


func _check_action_forecast_domain() -> void:
	var observation: Dictionary = _fixtures.planning_observation(
		[_fixtures.enemy_track(Vector2(230.0, 0.0), Vector2.UP * 370.0, true)]
	)
	observation.player_state.collision_radius = 36.0
	observation.player_state.runtime_stats.move_speed = 445.0
	observation.player_state.movement.input_vector = Vector2.RIGHT
	var generator: Reference = load(PLANNING_PATH + "movement_action_generator.gd").new()
	var actions: Array = generator.generate(observation, {"movement_preference": Vector2.ZERO})
	var timing: Dictionary = load(PLANNING_PATH + "movement_timing_model.gd").derive(observation)
	_expect(
		_all_actions_share_forecast(actions, timing.maximum_local_horizon_seconds),
		(
			"a reachable pursuer must keep candidate comparisons on the shared extended "
			+ "horizon even when its current heading does not intersect the previous input"
		)
	)
	observation.physics_frame += 1
	observation.enemy_tracks[0].relative_position = Vector2(2000.0, 0.0)
	actions = generator.generate(observation, {"movement_preference": Vector2.ZERO})
	_expect(
		_all_actions_share_forecast(actions, timing.default_local_horizon_seconds),
		"a threat outside the local reachable domain must not expand action-search work"
	)
	observation.physics_frame += 1
	observation.enemy_tracks[0].relative_position = Vector2(230.0, 0.0)
	observation.wave_state.seconds_remaining = 0.25
	actions = generator.generate(observation, {"movement_preference": Vector2.ZERO})
	_expect(
		_all_actions_share_forecast(actions, 0.25),
		"the shared threat horizon must remain clipped to observable time before cleanup"
	)


func _all_actions_share_forecast(actions: Array, expected_seconds: float) -> bool:
	for action in actions:
		if not is_equal_approx(action.forecast_seconds, expected_seconds):
			return false
	return not actions.empty()


func _check_projectile_motion_bound() -> void:
	var predictor: Reference = load(PLANNING_PATH + "motion/projectile_motion_predictor.gd").new()
	var projectile := {
		"relative_position": Vector2(30.0, -20.0),
		"velocity": Vector2(40.0, -10.0),
		"acceleration": Vector2.ZERO,
		"motion_confidence": 1.0,
		"motion_model":
		{
			"kind": "sinusoidal_velocity",
			"phase": Vector2(0.7, -0.3),
			"angular_velocity": Vector2(8.0, 3.0),
			"velocity_amplitude": Vector2(120.0, 50.0),
		},
	}
	var origin: Vector2 = projectile.relative_position
	var bound_contains_samples := true
	for sample_index in range(1, 17):
		var sample_time := float(sample_index) / 16.0
		var displacement: float = predictor.predict_position(projectile, sample_time).distance_to(
			origin
		)
		if displacement > predictor.maximum_displacement(projectile, sample_time) + 0.0001:
			bound_contains_samples = false
			break
	_expect(
		bound_contains_samples,
		"the shared projectile displacement bound must contain resolved curved motion"
	)


func _check_collision_shape_radius_adapter() -> void:
	var adapter: Reference = load(KNOWLEDGE_PATH + "collision_shape_radius_adapter.gd").new()
	var owner := Node2D.new()
	get_root().add_child(owner)
	var collision := CollisionShape2D.new()
	collision.name = "Collision"
	collision.position = Vector2(10.0, 0.0)
	collision.scale = Vector2(2.0, 1.0)
	var rectangle := RectangleShape2D.new()
	rectangle.extents = Vector2(16.0, 9.0)
	collision.shape = rectangle
	owner.add_child(collision)
	_expect(
		is_equal_approx(
			adapter.adapt_owner_centered_radius(owner, "Collision"),
			10.0 + Vector2(32.0, 9.0).length()
		),
		"a rectangular hostile projectile must expose a finite enclosing collision radius"
	)
	_expect(
		is_equal_approx(
			adapter.adapt_collision_centered_radius(collision), Vector2(32.0, 9.0).length()
		),
		"projectile collision support must be centered on its moving hitbox"
	)
	var circle := CircleShape2D.new()
	circle.radius = 10.0
	collision.position = Vector2(5.0, 0.0)
	collision.shape = circle
	_expect(
		is_equal_approx(adapter.adapt_owner_centered_radius(owner, "Collision"), 25.0),
		"circle observations must retain their scaled support without rectangle-corner inflation"
	)
	owner.free()


func _check_item_box_tier_expectation() -> void:
	var adapter_script: Script = load(
		(
			"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/pickups/"
			+ "item_box_item_value_profile_adapter.gd"
		)
	)
	var probabilities: Array = adapter_script.new().tier_probabilities(10, 0.0)
	var total := 0.0
	for probability in probabilities:
		total += probability
	_expect(
		is_equal_approx(total, 1.0),
		"item-box tier probabilities must partition the shared vanilla random roll"
	)
	_expect(
		probabilities[2] + probabilities[3] > 0.0,
		"wave-tier expectation must retain non-common reward opportunities"
	)
	var pricing: Reference = load(PLANNING_PATH + "opportunity_pricing_model.gd").new()
	var observation: Dictionary = _fixtures.planning_observation([])
	observation.player_state.item_box_item_value_profile = {
		"tier_probabilities": [0.4, 0.3, 0.2, 0.1],
		"mean_shop_price_by_tier": [10.0, 20.0, 30.0, 40.0],
	}
	_expect(
		is_equal_approx(pricing.expected_item_box_item_value(observation), 20.0),
		"item-box item value must use its probability-weighted shop-price proxy"
	)


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
	var allocator: Reference = allocator_script.new()
	var search: Dictionary = allocator.allocate({"budget_pressure": 1.0}, 12)
	var unconstrained_search: Dictionary = allocator.allocate({"budget_pressure": 0.0}, 12)
	_expect(
		(
			search.movement_refinement_limit == 0
			and search.navigation_extra_evaluation_limit == 0
			and (
				search.navigation_baseline_direction_count
				< unconstrained_search.navigation_baseline_direction_count
			)
		),
		"saturated pressure must reduce the strategic baseline and remove optional search work"
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
		is_equal_approx(work_model.expected_hits_to_complete(tree, 10.0, false), 1.0),
		"overkill must still consume one discrete hit instead of creating fractional work"
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


func _check_visibility_coverage() -> void:
	var coverage_script: Script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/observation/" + "visibility_coverage_model.gd"
	)
	var coverage: Reference = coverage_script.new()
	var visibility := {
		"viewport_size": Vector2(400.0, 300.0),
		"viewport_offset_from_player": Vector2(-200.0, -150.0),
		"fog_active": false,
	}
	_expect(
		coverage.covers_reachable_circle(Vector2.ZERO, 20.0, 40.0, visibility),
		"an absent moving entity whose complete reach set is visible must be confirmed gone"
	)
	_expect(
		not coverage.covers_reachable_circle(Vector2(190.0, 0.0), 20.0, 40.0, visibility),
		"negative visibility must retain an entity that could have crossed the viewport edge"
	)
	visibility.fog_active = true
	_expect(
		not coverage.covers_reachable_circle(Vector2.ZERO, 20.0, 0.0, visibility),
		"fog must not manufacture rectangular negative evidence for moving entities"
	)


func _check_enemy_negative_visibility_evidence() -> void:
	var memory: Reference = _observed_world_memory_script.new()
	var visibility := {
		"viewport_size": Vector2(400.0, 300.0),
		"viewport_offset_from_player": Vector2(-200.0, -150.0),
		"fog_active": false,
	}
	var source := Reference.new()
	var observation: Dictionary = _enemy_memory_observation(source)
	observation.velocity = Vector2(100.0, 0.0)
	observation.features.stable_mechanic_profile.target_position_response.movement_speed = 100.0
	var party_state := {"living_teammate_player_indices": []}
	var player_pickup := {"collection_radius": 0.0, "attraction_radius": 0.0}
	memory.update(
		0.0,
		Vector2.ZERO,
		{},
		_memory_inputs([observation]),
		party_state,
		[],
		player_pickup,
		visibility
	)
	_expect(
		memory.get_planning_enemy_tracks().size() == 1,
		"a visible enemy must create one planning track"
	)
	memory.update(
		1.0 / 60.0, Vector2.ZERO, {}, _memory_inputs([]), party_state, [], player_pickup, visibility
	)
	_expect(
		memory.get_planning_enemy_tracks().empty(),
		(
			"an enemy absent from a clear viewport covering its complete reach set "
			+ "must not remain as a planning target"
		)
	)


func _check_persistent_enemy_health_observation() -> void:
	var memory: Reference = _observed_world_memory_script.new()
	var source := Reference.new()
	var enemy: Dictionary = _enemy_memory_observation(source)
	enemy.features.persistent_health_observation = true
	var health_observation := {
		"_source": source,
		"alive": true,
		"health": {"current": 8.0, "maximum": 10.0, "ratio": 0.8},
	}
	var fog_visibility := {
		"viewport_size": Vector2(400.0, 300.0),
		"viewport_offset_from_player": Vector2(-200.0, -150.0),
		"fog_active": true,
	}
	var party_state := {"living_teammate_player_indices": []}
	var pickup := {"collection_radius": 0.0, "attraction_radius": 0.0}
	memory.update(
		0.0,
		Vector2.ZERO,
		{},
		_memory_inputs([enemy], [health_observation], [], true),
		party_state,
		[],
		pickup,
		fog_visibility
	)
	health_observation.health = {"current": 2.0, "maximum": 10.0, "ratio": 0.2}
	memory.update(
		5.0,
		Vector2.ZERO,
		{},
		_memory_inputs([], [health_observation], [], true),
		party_state,
		[],
		pickup,
		fog_visibility
	)
	var tracks: Array = memory.get_planning_enemy_tracks()
	_expect(
		(
			tracks.size() == 1
			and tracks[0].last_measurement.health.current == 2.0
			and tracks[0].existence_confidence == 1.0
			and tracks[0].recency_confidence == 0.0
		),
		(
			"a persistent health observation must retain exact life and existence "
			+ "without refreshing position"
		)
	)
	var planning_observation: Dictionary = _fixtures.planning_observation(tracks)
	planning_observation.player_state.weapons = [
		{"slot": 0, "attack_model": _fixtures.weapon_attack_model()}
	]
	var completion_forecast_script: Script = load(
		PLANNING_PATH + "engagement/wave_completion_forecast_model.gd"
	)
	var completion_forecast_model: Reference = completion_forecast_script.new()
	var completion_forecast: Dictionary = completion_forecast_model.forecast(planning_observation)
	_expect(
		completion_forecast.completion_fraction_by_target_id.get("enemy:1", 0.0) > 0.0,
		"known life without fresh position must remain part of wave-scale completion work"
	)
	var local_projector_script: Script = load(
		PLANNING_PATH + "local_enemy_interaction_projector.gd"
	)
	var local_projector: Reference = local_projector_script.new()
	var local_projection: Dictionary = local_projector.project(planning_observation, 0.4)
	_expect(
		local_projection.relevant_enemy_track_count == 0,
		"known life without fresh position must not enter local collision geometry"
	)
	memory.update(
		1.0 / 60.0,
		Vector2.ZERO,
		{},
		_memory_inputs([], [], [], true),
		party_state,
		[],
		pickup,
		fog_visibility
	)
	_expect(
		memory.get_planning_enemy_tracks().empty(),
		"a target missing from the complete persistent-health snapshot must retire its track"
	)


func _check_enemy_death_product_matching() -> void:
	var memory: Reference = _observed_world_memory_script.new()
	var source := Reference.new()
	var enemy: Dictionary = _enemy_memory_observation(source)
	enemy.features.stable_mechanic_profile.death_rewards = {
		"guaranteed_death_products": [{"kind": "item_box", "maximum_spawn_displacement": 100.0}]
	}
	var party_state := {"living_teammate_player_indices": []}
	var pickup := {"collection_radius": 0.0, "attraction_radius": 0.0}
	var fog_visibility := {
		"viewport_size": Vector2(400.0, 300.0),
		"viewport_offset_from_player": Vector2(-200.0, -150.0),
		"fog_active": true,
	}
	memory.update(
		0.0, Vector2.ZERO, {}, _memory_inputs([enemy]), party_state, [], pickup, fog_visibility
	)
	var item_box := {
		"_source": Reference.new(),
		"kind": "consumable",
		"relative_position": Vector2(60.0, 0.0),
		"velocity": Vector2.ZERO,
		"visual_radius": 20.0,
		"pickup_profile": {"traits": ["item_box"]},
	}
	memory.update(
		1.0 / 60.0,
		Vector2.ZERO,
		{},
		_memory_inputs([], [], [item_box]),
		party_state,
		[],
		pickup,
		fog_visibility
	)
	_expect(
		memory.get_planning_enemy_tracks().empty(),
		"an unambiguous guaranteed death product must retire its source track"
	)
	var matcher_script: Script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/observation/" + "enemy_death_product_matcher.gd"
	)
	var matcher: Reference = matcher_script.new()
	var death_rewards: Dictionary = enemy.features.stable_mechanic_profile.death_rewards
	var product_contracts: Array = death_rewards.guaranteed_death_products
	var ambiguous_matches: Array = matcher.match_track_ids(
		[
			{
				"track_id": 1,
				"products": product_contracts,
				"relative_position": Vector2(-20.0, 0.0),
				"position_uncertainty_radius": 0.0,
			},
			{
				"track_id": 2,
				"products": product_contracts,
				"relative_position": Vector2(20.0, 0.0),
				"position_uncertainty_radius": 0.0,
			},
		],
		[{"kind": "item_box", "relative_position": Vector2.ZERO}]
	)
	_expect(
		ambiguous_matches.empty(),
		"a death product in multiple mechanic support domains must not claim a source"
	)


func _check_run_continuation_risk_and_action_selection() -> void:
	var selector_script: Script = load(PLANNING_PATH + "movement_action_selector.gd")
	var selector: Reference = selector_script.new()
	var safe_low_value := _scored_action(2.0, 0.0, 0.0)
	var safe_high_value := _scored_action(3.0, 0.0, 0.0)
	var certain_terminal := _scored_action(100.0, 1.0, 1.0)
	var selected: Dictionary = selector.select([safe_low_value, certain_terminal, safe_high_value])
	_expect(
		selected.score == safe_high_value.score,
		"a certain committed terminal collision must not be purchasable with utility"
	)
	_expect(
		(
			selected.selection_diagnostics.mode == "committed_viability_then_maximum_utility"
			and selected.selection_diagnostics.viable_candidate_count == 2
			and selected.selection_diagnostics.excluded_certain_terminal_candidate_count == 1
			and is_equal_approx(
				selected.selection_diagnostics.selected_committed_terminal_health_risk, 0.0
			)
		),
		"selection diagnostics must expose the committed viability boundary"
	)
	var safe_passive := _scored_action(1.0, 0.0, 0.0)
	var uncertain_engagement := _scored_action(10.0, 0.05, 0.4)
	selected = selector.select([safe_passive, uncertain_engagement])
	_expect(
		selected.score == uncertain_engagement.score,
		(
			"probabilistic engagement must remain eligible for attack, pressure relief, "
			+ "and recovery utility"
		)
	)

	var continuation_path := PLANNING_PATH + "run_continuation_value_model.gd"
	var continuation_model: Reference = load(continuation_path).new()
	var observation: Dictionary = _fixtures.planning_observation([])
	observation.player_state.resources = {"materials": 10.0}
	observation.player_state.inventory = {"item_count": 2}
	observation.player_state.weapons = [{"slot": 0}]
	var continuation_value: Dictionary = continuation_model.estimate(observation)
	_expect(
		(
			continuation_value.equipment_count == 3
			and is_equal_approx(continuation_value.total_value, 40.0)
		),
		"run continuation value must include observable held materials and equipment"
	)

	var utility_model: Reference = load(PLANNING_PATH + "movement_utility_model.gd").new()
	var evaluation: Dictionary = utility_model.evaluate(
		{
			"forecast_seconds": 0.7,
			"forecast_expected_health_loss": 0.0,
			"committed_expected_health_loss": 0.0,
			"forecast_terminal_health_risk": 0.25,
			"committed_terminal_health_risk": 0.0,
		},
		{
			"control_interval_seconds": 0.1,
			"objective_weights": {"survival": {"expected_run_continuation_value_loss": -1.0}},
			"state_factors":
			{
				"wave_seconds_remaining": 0.8,
				"continuation_horizon_seconds": 1.0,
				"health_inventory_value":
				{
					"health_inventory_value_scale": 12.0,
					"immediate_survival_buffer": 20.0,
					"terminal_health_loss_unit_value": 1.0,
				},
				"run_continuation_value": continuation_value,
			},
		}
	)
	_expect(
		(
			is_equal_approx(evaluation.score, -10.0)
			and is_equal_approx(
				evaluation.field_utility_breakdown.expected_run_continuation_value_loss, -10.0
			)
		),
		"run capital must be charged exactly once by forecast terminal probability"
	)
	var survivable_evaluation: Dictionary = utility_model.evaluate(
		{
			"forecast_seconds": 0.7,
			"forecast_expected_health_loss": 0.0,
			"committed_expected_health_loss": 5.0,
			"forecast_terminal_health_risk": 0.0,
			"committed_terminal_health_risk": 0.0,
		},
		{
			"objective_weights": {"survival": {"expected_run_continuation_value_loss": -1.0}},
			"state_factors":
			{
				"health_inventory_value":
				{
					"health_inventory_value_scale": 12.0,
					"immediate_survival_buffer": 20.0,
					"terminal_health_loss_unit_value": 1.0,
				},
				"run_continuation_value": continuation_value,
				"wave_seconds_remaining": 0.8,
				"continuation_horizon_seconds": 1.0,
			},
		}
	)
	_expect(
		is_equal_approx(survivable_evaluation.score, 0.0),
		"survivable buffer erosion must not masquerade as a second death probability"
	)


func _check_immediate_hit_reserve_reachability() -> void:
	var inventory_script: Script = load(PLANNING_PATH + "health/health_inventory_value_model.gd")
	var inventory: Reference = inventory_script.new()
	var nearby_memory: Dictionary = _fixtures.enemy_track(Vector2(25.0, 0.0), Vector2.ZERO, false)
	nearby_memory.visible = false
	nearby_memory.behavior_profile.contact_damage = 10.0
	var remote_memory: Dictionary = _fixtures.enemy_track(Vector2(5000.0, 0.0), Vector2.ZERO, false)
	remote_memory.track_id = 2
	remote_memory.visible = false
	remote_memory.behavior_profile.contact_damage = 100.0
	var remote_visible: Dictionary = _fixtures.enemy_track(
		Vector2(5000.0, 0.0), Vector2.ZERO, false
	)
	remote_visible.track_id = 3
	remote_visible.behavior_profile.contact_damage = 1000.0
	var observation: Dictionary = _fixtures.planning_observation(
		[nearby_memory, remote_memory, remote_visible]
	)
	var result: Dictionary = inventory.estimate(
		observation,
		{
			"recovery": {"maximum_consumable_recovery": 0.0},
			"survival": {"health_rate": 0.0, "recovery_rate": 0.0},
		},
		_fixtures.wave_completion_forecast({})
	)
	_expect(
		is_equal_approx(result.immediate_hit_reserve, 10.0),
		"reserve must cover joint player-threat reach"
	)
	observation.physics_frame += 1
	observation.enemy_tracks = []
	result = inventory.estimate(
		observation,
		{
			"recovery": {"maximum_consumable_recovery": 0.0},
			"survival": {"health_rate": 0.0, "recovery_rate": 0.0},
		},
		_fixtures.wave_completion_forecast({})
	)
	_expect(
		is_equal_approx(result.immediate_hit_reserve, 0.0),
		"the next-hit reserve must be zero when no threat can arrive before replanning"
	)


func _scored_action(
	score: float, committed_terminal_risk: float, forecast_terminal_risk: float
) -> Dictionary:
	return {
		"movement": Vector2.ZERO,
		"score": score,
		"outcome":
		{
			"committed_terminal_health_risk": committed_terminal_risk,
			"forecast_terminal_collision_risk": forecast_terminal_risk,
		},
	}


func _enemy_memory_observation(source: Object) -> Dictionary:
	return {
		"_source": source,
		"relative_position": Vector2.ZERO,
		"velocity": Vector2.ZERO,
		"acceleration": Vector2.ZERO,
		"motion_confidence": 1.0,
		"features":
		{
			"visual_radius": 20.0,
			"health": {"current": 10.0, "maximum": 10.0, "ratio": 1.0},
			"persistent_health_observation": false,
			"stable_mechanic_profile":
			{
				"projectile_attack": {"kind": "non_projectile_known"},
				"charge_attack": {"active": false},
				"material_assimilation": {"active": false},
				"target_position_response":
				{
					"responds_to_target_position": false,
					"movement_speed": 0.0,
				},
				"durability": {"maximum_health": 10.0},
				"contact_damage": 1.0,
				"contact_radius": 10.0,
				"death_rewards": {"guaranteed_death_products": []},
				"battlefield_effects": {},
				"removal_effects": {},
			},
			"next_volley_window": {},
			"next_charge_attack_window": {},
			"ranged_attack_inferred": false,
			"visible_removable_projectile_damage": 0.0,
		},
	}


func _memory_inputs(
	enemy_observations: Array,
	persistent_health_observations := [],
	entity_observations := [],
	persistent_health_snapshot_complete := false
) -> Dictionary:
	return {
		"enemy_observations": enemy_observations,
		"persistent_enemy_health_observations": persistent_health_observations,
		"persistent_enemy_health_snapshot_complete": persistent_health_snapshot_complete,
		"entity_observations": entity_observations,
	}


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
