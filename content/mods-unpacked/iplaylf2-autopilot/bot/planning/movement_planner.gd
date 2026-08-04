extends Reference

# Public planning boundary. It scores every retained movement action with one
# complete semantic model and returns an inspectable utility ledger.

const MovementActionGenerator := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_action_generator.gd"
)
const PlanningComputeBudgetPolicy := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/planning_compute_budget_policy.gd"
)
const PlanningSearchWorkAllocator := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/planning_search_work_allocator.gd"
)
const ProjectileReachabilityFilter := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/projectile_reachability_filter.gd"
)
const AdaptiveDirectionRefiner := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/adaptive_direction_refiner.gd"
)
const MovementOutcomePredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_outcome_predictor.gd"
)
const MovementUtilityModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_utility_model.gd"
)
const MovementActionSelector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_action_selector.gd"
)
const NavigationIntentPlanner := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/navigation_intent_planner.gd"
)
const MovementTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_timing_model.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const LocalEnemyInteractionProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/local_enemy_interaction_projector.gd"
)
const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)
var _action_generator: Reference = MovementActionGenerator.new()
var _compute_budget_policy: Reference = PlanningComputeBudgetPolicy.new()
var _search_work_allocator: Reference = PlanningSearchWorkAllocator.new()
var _projectile_filter: Reference = ProjectileReachabilityFilter.new()
var _direction_refiner: Reference = AdaptiveDirectionRefiner.new()
var _outcome_predictor: Reference = MovementOutcomePredictor.new()
var _utility_model: Reference = MovementUtilityModel.new()
var _action_selector: Reference = MovementActionSelector.new()
var _navigation_intent_planner: Reference = NavigationIntentPlanner.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _local_enemy_interaction_projector: Reference = LocalEnemyInteractionProjector.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()


func _init() -> void:
	# Candidate models ask many of the same (track, time, player position)
	# questions. One frame-scoped predictor owns those projections so semantic
	# models share computation without owning independent mutable caches.
	_navigation_intent_planner.set_enemy_motion_predictor(_enemy_motion_predictor)
	_outcome_predictor.set_enemy_motion_predictor(_enemy_motion_predictor)


func set_frame_budget_context(frame_budget_context: Dictionary) -> void:
	_compute_budget_policy.set_frame_budget_context(frame_budget_context)


func plan(observation: Dictionary) -> Dictionary:
	if observation.empty() or not observation.has("player_state"):
		return _empty_plan("observation_unavailable")
	if observation.player_state.dead:
		return _empty_plan("player_dead")

	var planning_started_usec := OS.get_ticks_usec()
	var phase_started_usec := planning_started_usec
	var phase_duration_usec := {}
	var projectile_filter: Dictionary = _projectile_filter.filter(observation)
	var planning_observation: Dictionary = projectile_filter.filtered_observation
	var context: Dictionary = _utility_model.build_context(planning_observation)
	var movement_geometry: Dictionary = _movement_geometry.derive(planning_observation)
	var timing: Dictionary = MovementTimingModel.derive(planning_observation)
	context.control_interval_seconds = timing.control_interval_seconds
	var compute_budget: Dictionary = _compute_budget_policy.allocate(planning_started_usec)
	var search_work_allocation: Dictionary = _search_work_allocator.allocate(
		compute_budget, int(movement_geometry.direction_count)
	)
	phase_duration_usec.observation_preparation = OS.get_ticks_usec() - phase_started_usec
	phase_started_usec = OS.get_ticks_usec()
	var navigation_intent: Dictionary = _navigation_intent_planner.plan(
		planning_observation,
		context,
		compute_budget,
		search_work_allocation,
		_compute_budget_policy
	)
	context.navigation_directional_value_samples = navigation_intent.directional_value_samples
	phase_duration_usec.navigation = OS.get_ticks_usec() - phase_started_usec
	phase_started_usec = OS.get_ticks_usec()
	var actions: Array = _action_generator.generate(planning_observation, navigation_intent)
	var local_domain: Dictionary = _local_enemy_interaction_projector.project(
		planning_observation, actions[0].forecast_seconds
	)
	var local_observation: Dictionary = local_domain.observation
	var scored_actions := []
	for action in actions:
		scored_actions.push_back(_score_action(local_observation, action, context))
	phase_duration_usec.action_evaluation = OS.get_ticks_usec() - phase_started_usec
	phase_started_usec = OS.get_ticks_usec()

	var direction_scores: Array = scored_actions.duplicate()
	var refined_action_count := 0
	while (
		refined_action_count < search_work_allocation.movement_refinement_limit
		and _compute_budget_policy.can_start_budgeted_work(
			compute_budget, _compute_budget_policy.WORK_MOVEMENT_REFINEMENT
		)
	):
		var proposed_direction: Vector2 = _direction_refiner.propose_direction(direction_scores)
		if proposed_direction == Vector2.ZERO:
			break
		var work_started_usec := OS.get_ticks_usec()
		var refined_action: Dictionary = _action_generator.make_refined_action(
			planning_observation, proposed_direction, actions[0], refined_action_count
		)
		refined_action_count += 1
		actions.push_back(refined_action)
		var scored_action: Dictionary = _score_action(local_observation, refined_action, context)
		scored_actions.push_back(scored_action)
		direction_scores.push_back(scored_action)
		_compute_budget_policy.observe_work_duration(
			_compute_budget_policy.WORK_MOVEMENT_REFINEMENT,
			float(OS.get_ticks_usec() - work_started_usec)
		)

	var ranked_actions := []
	for scored in scored_actions:
		_insert_descending(ranked_actions, scored, scored_actions.size())
	phase_duration_usec.refinement = OS.get_ticks_usec() - phase_started_usec
	var plan: Dictionary = _action_selector.select(ranked_actions)
	var planning_duration_usec := float(OS.get_ticks_usec() - planning_started_usec)
	compute_budget.merge(
		_compute_budget_policy.observe_planning_duration(planning_duration_usec), true
	)
	compute_budget.phase_duration_usec = phase_duration_usec
	compute_budget.planning_deadline_overrun_usec = (
		max(0, OS.get_ticks_usec() - int(compute_budget.planning_deadline_usec))
		if compute_budget.has_deadline
		else null
	)
	plan.status = "ready"
	# Per-enemy values are an execution cache, not telemetry. Keeping the cache out
	# of the returned plan avoids duplicating an O(enemy_count) dictionary whenever
	# a sampled decision is serialized.
	plan.context = context.duplicate(false)
	plan.context.erase("enemy_completion_value_ledger")
	plan.context.erase("wave_completion_forecast")
	plan.context.erase("navigation_directional_value_samples")
	plan.wave_completion_forecast = context.wave_completion_forecast.duplicate(false)
	plan.wave_completion_forecast.erase("enemy_completion_fraction_by_track_id")
	plan.wave_completion_forecast.erase("tree_completion_fraction_by_memory_record_id")
	plan.compute_budget = compute_budget.duplicate(true)
	plan.search_work_allocation = search_work_allocation.duplicate(true)
	plan.projectile_filter = projectile_filter.duplicate(false)
	plan.projectile_filter.erase("filtered_observation")
	plan.local_enemy_interaction_domain = local_domain.duplicate(false)
	plan.local_enemy_interaction_domain.erase("observation")
	plan.navigation_intent = navigation_intent.duplicate(true)
	plan.action_count = actions.size()
	plan.refined_action_count = refined_action_count
	plan.ranked_actions = _summarize_actions(ranked_actions, 3)
	plan.model = _model_diagnostics(observation, plan, navigation_intent)
	return plan


func _model_diagnostics(
	observation: Dictionary, plan: Dictionary, navigation_intent: Dictionary
) -> Dictionary:
	var movement_geometry: Dictionary = _movement_geometry.derive(observation)
	var timing: Dictionary = MovementTimingModel.derive(observation)
	return {
		"timing":
		{
			"derivation": "physics_ticks_and_collision_traversal",
			"replan_physics_ticks": MovementTimingModel.REPLAN_PHYSICS_TICKS,
			"control_interval_seconds": MovementTimingModel.control_interval_seconds(),
			"near_term_horizon_seconds": timing.near_term_horizon_seconds,
			"default_local_horizon_seconds": timing.default_local_horizon_seconds,
			"maximum_local_horizon_seconds": timing.maximum_local_horizon_seconds,
			"maximum_navigation_horizon_seconds": timing.maximum_navigation_horizon_seconds,
			"effective_local_horizon_seconds": timing.effective_local_horizon_seconds,
			"effective_navigation_horizon_seconds": timing.effective_navigation_horizon_seconds,
		},
		"derived":
		{
			"movement_geometry": movement_geometry,
			"action_forecast_seconds": plan.action.forecast_seconds,
			"action_forecast_sample_count": plan.action.samples.size(),
			"geometry_direction_count": movement_geometry.direction_count,
			"local_prediction_radius": navigation_intent.local_prediction_radius,
			"navigation_sampling_radius": navigation_intent.sampling_radius,
			"control_distance": navigation_intent.control_distance,
			"enemy_position_response_cache": _enemy_motion_predictor.cache_diagnostics(),
		},
	}


func _make_scored_action(
	action: Dictionary, outcome: Dictionary, evaluation: Dictionary
) -> Dictionary:
	return {
		"action": action,
		"movement": action.movement,
		"outcome": outcome,
		"score": evaluation.score,
		"field_utility_breakdown": evaluation.field_utility_breakdown,
		"objective_utility_breakdown": evaluation.objective_utility_breakdown,
	}


func _score_action(observation: Dictionary, action: Dictionary, context: Dictionary) -> Dictionary:
	var base_outcome: Dictionary = _outcome_predictor.predict_base(observation, action, context)
	var outcome: Dictionary = _outcome_predictor.complete_prediction(
		observation, action, base_outcome, context
	)
	var evaluation: Dictionary = _utility_model.evaluate(outcome, context)
	return _make_scored_action(action, outcome, evaluation)


func _insert_descending(entries: Array, entry: Dictionary, limit: int) -> void:
	var inserted := false
	for index in entries.size():
		if entry.score > entries[index].score:
			entries.insert(index, entry)
			inserted = true
			break
	if not inserted:
		entries.push_back(entry)
	if entries.size() > limit:
		entries.pop_back()


func _summarize_actions(entries: Array, limit: int) -> Array:
	var result := []
	for index in min(limit, entries.size()):
		var entry: Dictionary = entries[index]
		result.push_back(
			{
				"action_id": entry.action.action_id,
				"movement": entry.movement,
				"forecast_seconds": entry.action.forecast_seconds,
				"score": entry.score,
				"outcome": _summarize_outcome(entry.outcome),
				"field_utility_breakdown": entry.field_utility_breakdown.duplicate(true),
				"objective_utility_breakdown": entry.objective_utility_breakdown.duplicate(true),
			}
		)
	return result


func _summarize_outcome(outcome: Dictionary) -> Dictionary:
	return outcome.duplicate(false)


func _empty_plan(status: String) -> Dictionary:
	return {
		"status": status,
		"movement": Vector2.ZERO,
		"score": -INF,
		"outcome": {},
		"field_utility_breakdown": {},
		"objective_utility_breakdown": {},
	}
