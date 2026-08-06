extends SceneTree

const PLANNING_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/planning/"
const KNOWLEDGE_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/"
const OBSERVATION_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/observation/"
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
	_check_spawn_warning_resolution_window()
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
	quit(1 if _failed else 0)


func _check_spawn_warning_resolution_window() -> void:
	var script_path := OBSERVATION_PATH + "spawn_warning_resolution_window_estimator.gd"
	var estimator: Reference = load(script_path).new()
	var initial_window: Dictionary = estimator.estimate(1, Vector2(20.0, 30.0), 1.0)
	estimator.advance_time(0.25)
	var elapsed_window: Dictionary = estimator.estimate(1, Vector2(20.0, 30.0), 1.0)
	estimator.advance_time(0.25)
	var relocated_window: Dictionary = estimator.estimate(1, Vector2(40.0, 30.0), 1.0)
	_expect(
		(
			is_equal_approx(initial_window.latest_seconds, 1.0)
			and is_equal_approx(elapsed_window.latest_seconds, 0.75)
			and is_equal_approx(relocated_window.latest_seconds, 1.0)
		),
		"spawn-warning latest resolution must decrease and restart after visible relocation"
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
			"forecast_expected_health_loss": 5.0,
			"forecast_terminal_collision_risk": 0.0,
		},
		{
			"objective_weights": {"survival": {"forecast_run_continuation_value_at_risk": -1.0}},
			"state_factors":
			{
				"wave_seconds_remaining": 10.0,
				"continuation_horizon_seconds": 1.0,
				"health_inventory_value":
				{
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
				evaluation.field_utility_breakdown.forecast_run_continuation_value_at_risk, -10.0
			)
		),
		"sublethal buffer erosion must expose run capital through the common utility ledger"
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
			"terminal_collision_risk": committed_terminal_risk,
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
