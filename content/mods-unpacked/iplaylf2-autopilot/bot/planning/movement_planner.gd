extends Reference

# Public planning boundary. It performs bounded screening followed by weapon-aware
# movement-action scoring and returns a complete, inspectable score ledger.

const MovementActionGenerator := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_action_generator.gd"
)
const SearchBudgetPolicy := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/search_budget_policy.gd"
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
const NavigationValueGraphBuilder := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/navigation_value_graph_builder.gd"
)
const MovementPlanningTiming := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_planning_timing.gd"
)
const MovementScaleModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_scale_model.gd"
)

# Bump whenever a formula, parameter meaning, or logged planning
# contract changes. Samples use it to keep incompatible calibration groups separate.
const MODEL_REVISION := "2026-08-02.1"

var _action_generator: Reference = MovementActionGenerator.new()
var _search_budget_policy: Reference = SearchBudgetPolicy.new()
var _outcome_predictor: Reference = MovementOutcomePredictor.new()
var _utility_model: Reference = MovementUtilityModel.new()
var _action_selector: Reference = MovementActionSelector.new()
var _navigation_graph_builder: Reference = NavigationValueGraphBuilder.new()
var _movement_scale: Reference = MovementScaleModel.new()


func plan(observation: Dictionary, previous_movement: Vector2, player_index: int) -> Dictionary:
	if observation.empty() or not observation.has("player_state"):
		return _empty_plan("observation_unavailable")
	if observation.player_state.dead:
		return _empty_plan("player_dead")

	var context: Dictionary = _utility_model.build_context(observation)
	context.control_interval_seconds = MovementPlanningTiming.CONTROL_INTERVAL_SECONDS
	var search_budget: Dictionary = _search_budget_policy.allocate(observation)
	var navigation_graph: Dictionary = _navigation_graph_builder.build(
		observation, context, search_budget
	)
	context.navigation_guidance = navigation_graph.navigation_guidance
	var actions: Array = _action_generator.generate(observation, search_budget, navigation_graph)
	var weapon_prediction_limit: int = search_budget.weapon_prediction_limit
	var screening_shortlist := []

	for action in actions:
		var outcome: Dictionary = _outcome_predictor.predict(
			observation, action, previous_movement, false, context
		)
		var evaluation: Dictionary = _utility_model.evaluate(outcome, context)
		var scored := _make_scored_action(action, outcome, evaluation)
		_insert_descending(screening_shortlist, scored, weapon_prediction_limit)

	var weapon_scored_actions := []
	for screened in screening_shortlist:
		var outcome: Dictionary = _outcome_predictor.predict(
			observation, screened.action, previous_movement, true, context
		)
		var evaluation: Dictionary = _utility_model.evaluate(outcome, context)
		_insert_descending(
			weapon_scored_actions,
			_make_scored_action(screened.action, outcome, evaluation),
			weapon_prediction_limit
		)

	var seed: int = int(observation.physics_frame) * 31 + player_index
	var plan: Dictionary = _action_selector.select(weapon_scored_actions, context, seed)
	plan.status = "ready"
	plan.context = context
	plan.search_budget = search_budget.duplicate(true)
	plan.navigation_graph = navigation_graph.duplicate(true)
	plan.action_count = actions.size()
	plan.weapon_prediction_count = weapon_scored_actions.size()
	plan.ranked_actions = _summarize_actions(weapon_scored_actions, 5)
	plan.model = _model_diagnostics(observation, plan, navigation_graph)
	return plan


func _model_diagnostics(
	observation: Dictionary, plan: Dictionary, navigation_graph: Dictionary
) -> Dictionary:
	var movement_scale: Dictionary = _movement_scale.derive(observation)
	return {
		"revision": MODEL_REVISION,
		"timing":
		{
			"control_interval_seconds": MovementPlanningTiming.CONTROL_INTERVAL_SECONDS,
			"local_forecast_min_seconds": MovementPlanningTiming.LOCAL_FORECAST_MIN_SECONDS,
			"local_forecast_default_seconds": MovementPlanningTiming.LOCAL_FORECAST_DEFAULT_SECONDS,
			"local_forecast_max_seconds": MovementPlanningTiming.LOCAL_FORECAST_MAX_SECONDS,
			"navigation_forecast_max_seconds":
			MovementPlanningTiming.NAVIGATION_FORECAST_MAX_SECONDS,
		},
		"derived":
		{
			"movement_scale": movement_scale,
			"action_forecast_seconds": plan.action.forecast_seconds,
			"near_node_spacing": navigation_graph.near_node_spacing,
			"local_detail_radius": navigation_graph.local_detail_radius,
			"local_prediction_radius": navigation_graph.local_prediction_radius,
			"control_distance": navigation_graph.control_distance,
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
				"outcome": entry.outcome.duplicate(true),
				"field_utility_breakdown": entry.field_utility_breakdown.duplicate(true),
				"objective_utility_breakdown": entry.objective_utility_breakdown.duplicate(true),
			}
		)
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
