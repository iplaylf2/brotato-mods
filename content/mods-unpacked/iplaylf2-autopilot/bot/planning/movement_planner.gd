extends Reference

# Public planning boundary. It performs budgeted screening followed by weapon-aware
# movement-action scoring and returns a complete, inspectable score ledger.

const MovementActionGenerator := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_action_generator.gd"
)
const PlanningDetailBudgetPolicy := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/planning_detail_budget_policy.gd"
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
var _detail_budget_policy: Reference = PlanningDetailBudgetPolicy.new()
var _outcome_predictor: Reference = MovementOutcomePredictor.new()
var _utility_model: Reference = MovementUtilityModel.new()
var _action_selector: Reference = MovementActionSelector.new()
var _navigation_intent_planner: Reference = NavigationIntentPlanner.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _terminal_collision_constraint: Reference = TerminalCollisionConstraint.new()
var _candidate_pruner: Reference = MovementCandidatePruner.new()


func set_frame_budget_context(frame_budget_context: Dictionary) -> void:
	_detail_budget_policy.set_frame_budget_context(frame_budget_context)


func plan(observation: Dictionary, previous_movement: Vector2, player_index: int) -> Dictionary:
	if observation.empty() or not observation.has("player_state"):
		return _empty_plan("observation_unavailable")
	if observation.player_state.dead:
		return _empty_plan("player_dead")

	var planning_started_usec := OS.get_ticks_usec()
	var context: Dictionary = _utility_model.build_context(observation)
	var timing: Dictionary = MovementTimingModel.derive(observation)
	context.control_interval_seconds = timing.control_interval_seconds
	var detail_budget: Dictionary = _detail_budget_policy.allocate(observation)
	var navigation_intent: Dictionary = _navigation_intent_planner.plan(
		observation, context, detail_budget
	)
	context.navigation_movement_preference = navigation_intent.movement_preference
	var actions: Array = _action_generator.generate(observation, navigation_intent)
	var weapon_refinement_limit: int = detail_budget.weapon_refinement_limit
	var collision_costs := []

	for action in actions:
		var collision_cost: Dictionary = _outcome_predictor.predict_collision_cost(
			observation, action, context
		)
		collision_costs.push_back({"action": action, "outcome": collision_cost})

	var terminal_constraint: Dictionary = _terminal_collision_constraint.apply(collision_costs)
	var candidate_pruning: Dictionary = _candidate_pruner.prune(terminal_constraint.actions)
	var screened_actions := []
	for candidate in candidate_pruning.actions:
		var action: Dictionary = candidate.action
		var base_outcome: Dictionary = _outcome_predictor.predict_base(
			observation, action, previous_movement, context
		)
		var outcome: Dictionary = _outcome_predictor.complete_prediction(
			observation, action, base_outcome, false
		)
		var evaluation: Dictionary = _utility_model.evaluate(outcome, context)
		var scored_action: Dictionary = _make_scored_action(action, outcome, evaluation)
		scored_action.base_outcome = base_outcome
		screened_actions.push_back(scored_action)

	var screening_shortlist := []
	for scored in screened_actions:
		_insert_descending(screening_shortlist, scored, weapon_refinement_limit)

	var weapon_scored_actions := []
	for screened in screening_shortlist:
		var outcome: Dictionary = _outcome_predictor.complete_prediction(
			observation, screened.action, screened.base_outcome, true
		)
		var evaluation: Dictionary = _utility_model.evaluate(outcome, context)
		_insert_descending(
			weapon_scored_actions,
			_make_scored_action(screened.action, outcome, evaluation),
			weapon_refinement_limit
		)

	var rng_seed: int = int(observation.physics_frame) * 31 + player_index
	var plan: Dictionary = _action_selector.select(weapon_scored_actions, context, rng_seed)
	var planning_duration_usec := float(OS.get_ticks_usec() - planning_started_usec)
	detail_budget.merge(
		_detail_budget_policy.observe_planning_duration(planning_duration_usec), true
	)
	plan.status = "ready"
	plan.context = context
	plan.detail_budget = detail_budget.duplicate(true)
	plan.navigation_intent = navigation_intent.duplicate(true)
	plan.action_count = actions.size()
	plan.weapon_refinement_count = weapon_scored_actions.size()
	plan.candidate_filter = terminal_constraint.duplicate(true)
	plan.candidate_filter.erase("actions")
	var pruning_diagnostics: Dictionary = candidate_pruning.duplicate(true)
	pruning_diagnostics.erase("actions")
	plan.candidate_filter.merge(pruning_diagnostics, true)
	plan.ranked_actions = _summarize_actions(weapon_scored_actions, 5)
	plan.model = _model_diagnostics(observation, plan, navigation_intent)
	return plan


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
