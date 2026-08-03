extends Reference

# Public planning boundary. It performs budgeted screening followed by weapon-aware
# movement-action scoring and returns a complete, inspectable score ledger.

const MovementActionGenerator := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_action_generator.gd"
)
const PlanningComputeBudgetPolicy := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/planning_compute_budget_policy.gd"
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
const TerminalCollisionConstraint := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/terminal_collision_constraint.gd"
)
const MovementCandidatePruner := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_candidate_pruner.gd"
)

var _action_generator: Reference = MovementActionGenerator.new()
var _compute_budget_policy: Reference = PlanningComputeBudgetPolicy.new()
var _projectile_filter: Reference = ProjectileReachabilityFilter.new()
var _direction_refiner: Reference = AdaptiveDirectionRefiner.new()
var _outcome_predictor: Reference = MovementOutcomePredictor.new()
var _utility_model: Reference = MovementUtilityModel.new()
var _action_selector: Reference = MovementActionSelector.new()
var _navigation_intent_planner: Reference = NavigationIntentPlanner.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _terminal_collision_constraint: Reference = TerminalCollisionConstraint.new()
var _candidate_pruner: Reference = MovementCandidatePruner.new()


func set_frame_budget_context(frame_budget_context: Dictionary) -> void:
	_compute_budget_policy.set_frame_budget_context(frame_budget_context)


func plan(observation: Dictionary, previous_movement: Vector2) -> Dictionary:
	if observation.empty() or not observation.has("player_state"):
		return _empty_plan("observation_unavailable")
	if observation.player_state.dead:
		return _empty_plan("player_dead")

	var planning_started_usec := OS.get_ticks_usec()
	var projectile_filter: Dictionary = _projectile_filter.apply(observation)
	var planning_observation: Dictionary = projectile_filter.filtered_observation
	var context: Dictionary = _utility_model.build_context(planning_observation)
	var timing: Dictionary = MovementTimingModel.derive(planning_observation)
	context.control_interval_seconds = timing.control_interval_seconds
	var compute_budget: Dictionary = _compute_budget_policy.allocate(planning_started_usec)
	var navigation_intent: Dictionary = _navigation_intent_planner.plan(
		planning_observation, context, compute_budget, _compute_budget_policy
	)
	context.navigation_movement_preference = navigation_intent.movement_preference
	context.navigation_terminal_value_gain = navigation_intent.terminal_value_gain
	var actions: Array = _action_generator.generate(
		planning_observation, navigation_intent, compute_budget
	)
	var collision_predictions := []

	for action in actions:
		var collision_outcome: Dictionary = _outcome_predictor.predict_collision_outcome(
			planning_observation, action, context
		)
		collision_predictions.push_back({"action": action, "outcome": collision_outcome})

	var terminal_constraint: Dictionary = _terminal_collision_constraint.apply(
		collision_predictions
	)
	var candidate_pruning: Dictionary = _candidate_pruner.prune(terminal_constraint.actions)
	var screened_actions := []
	for candidate in candidate_pruning.actions:
		var action: Dictionary = candidate.action
		var base_outcome: Dictionary = _outcome_predictor.predict_base(
			planning_observation, action, previous_movement, context
		)
		var outcome: Dictionary = _outcome_predictor.complete_prediction(
			planning_observation, action, base_outcome, false, context
		)
		var evaluation: Dictionary = _utility_model.evaluate(outcome, context)
		var scored_action: Dictionary = _make_scored_action(action, outcome, evaluation)
		scored_action.base_outcome = base_outcome
		screened_actions.push_back(scored_action)

	var direction_scores: Array = screened_actions.duplicate()
	var refined_action_count := 0
	while _compute_budget_policy.can_start_budgeted_work(
		compute_budget, _compute_budget_policy.WORK_MOVEMENT_REFINEMENT
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
		var refined_collision: Dictionary = _outcome_predictor.predict_collision_outcome(
			planning_observation, refined_action, context
		)
		collision_predictions.push_back({"action": refined_action, "outcome": refined_collision})
		if (
			refined_collision.terminal_collision_risk
			<= terminal_constraint.maximum_admissible_terminal_risk
		):
			var base_outcome: Dictionary = _outcome_predictor.predict_base(
				planning_observation, refined_action, previous_movement, context
			)
			var outcome: Dictionary = _outcome_predictor.complete_prediction(
				planning_observation, refined_action, base_outcome, false, context
			)
			var evaluation: Dictionary = _utility_model.evaluate(outcome, context)
			var scored_action: Dictionary = _make_scored_action(refined_action, outcome, evaluation)
			scored_action.base_outcome = base_outcome
			screened_actions.push_back(scored_action)
			direction_scores.push_back(scored_action)
		else:
			direction_scores.push_back({"movement": refined_action.movement, "score": -INF})
		_compute_budget_policy.observe_work_duration(
			_compute_budget_policy.WORK_MOVEMENT_REFINEMENT,
			float(OS.get_ticks_usec() - work_started_usec)
		)

	terminal_constraint = _terminal_collision_constraint.apply(collision_predictions)
	screened_actions = _retain_admissible_scored_actions(
		screened_actions, terminal_constraint.actions
	)
	var ranked_screened_actions := []
	for scored in screened_actions:
		_insert_descending(ranked_screened_actions, scored, screened_actions.size())

	var fully_scored_actions := []
	var required_weapon_predictions := (
		2
		if compute_budget.get("quality_mode", "full") == "full"
		else 1
	)
	for rank_index in ranked_screened_actions.size():
		if (
			rank_index >= min(required_weapon_predictions, ranked_screened_actions.size())
			and not _compute_budget_policy.can_start_budgeted_work(
				compute_budget, _compute_budget_policy.WORK_WEAPON_PREDICTION
			)
		):
			break
		var work_started_usec := OS.get_ticks_usec()
		var screened: Dictionary = ranked_screened_actions[rank_index]
		var outcome: Dictionary = _outcome_predictor.complete_prediction(
			planning_observation, screened.action, screened.base_outcome, true, context
		)
		var evaluation: Dictionary = _utility_model.evaluate(outcome, context)
		_insert_descending(
			fully_scored_actions,
			_make_scored_action(screened.action, outcome, evaluation),
			ranked_screened_actions.size()
		)
		_compute_budget_policy.observe_work_duration(
			_compute_budget_policy.WORK_WEAPON_PREDICTION,
			float(OS.get_ticks_usec() - work_started_usec)
		)

	var plan: Dictionary = _action_selector.select(fully_scored_actions)
	var planning_duration_usec := float(OS.get_ticks_usec() - planning_started_usec)
	compute_budget.merge(
		_compute_budget_policy.observe_planning_duration(planning_duration_usec), true
	)
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
	plan.context.erase("enemy_removal_value_ledger")
	plan.compute_budget = compute_budget.duplicate(true)
	plan.projectile_filter = projectile_filter.duplicate(false)
	plan.projectile_filter.erase("filtered_observation")
	plan.navigation_intent = navigation_intent.duplicate(true)
	plan.action_count = actions.size()
	plan.weapon_prediction_count = fully_scored_actions.size()
	plan.refined_action_count = refined_action_count
	plan.candidate_filter = terminal_constraint.duplicate(true)
	plan.candidate_filter.erase("actions")
	var pruning_diagnostics: Dictionary = candidate_pruning.duplicate(true)
	pruning_diagnostics.erase("actions")
	plan.candidate_filter.merge(pruning_diagnostics, true)
	plan.ranked_actions = _summarize_actions(fully_scored_actions, 3)
	plan.model = _model_diagnostics(observation, plan, navigation_intent)
	return plan


func _retain_admissible_scored_actions(scored_actions: Array, admissible: Array) -> Array:
	var admissible_ids := {}
	for candidate in admissible:
		admissible_ids[candidate.action.action_id] = true
	var result := []
	for scored in scored_actions:
		if admissible_ids.has(scored.action.action_id):
			result.push_back(scored)
	return result


func _model_diagnostics(
	observation: Dictionary, plan: Dictionary, navigation_intent: Dictionary
) -> Dictionary:
	var movement_geometry: Dictionary = _movement_geometry.derive(observation)
	return {
		"timing":
		{
			"derivation": "physics_ticks_and_collision_traversal",
			"replan_physics_ticks": MovementTimingModel.REPLAN_PHYSICS_TICKS,
			"control_interval_seconds": MovementTimingModel.control_interval_seconds(),
			"near_term_horizon_seconds":
			MovementTimingModel.derive(observation).near_term_horizon_seconds,
			"default_local_horizon_seconds":
			MovementTimingModel.derive(observation).default_local_horizon_seconds,
			"maximum_local_horizon_seconds":
			MovementTimingModel.derive(observation).maximum_local_horizon_seconds,
			"maximum_navigation_horizon_seconds":
			MovementTimingModel.derive(observation).maximum_navigation_horizon_seconds,
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
	var result := outcome.duplicate(false)
	result.erase("battlefield_exposure_trace")
	return result


func _empty_plan(status: String) -> Dictionary:
	return {
		"status": status,
		"movement": Vector2.ZERO,
		"score": -INF,
		"outcome": {},
		"field_utility_breakdown": {},
		"objective_utility_breakdown": {},
	}
