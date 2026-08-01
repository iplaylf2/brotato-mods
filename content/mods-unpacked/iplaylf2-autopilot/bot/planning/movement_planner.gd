extends Reference

# Public planning boundary. It performs bounded coarse-to-fine trajectory
# search and returns a complete, inspectable score ledger.

const TrajectoryGenerator := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/trajectory_generator.gd"
)
const SearchBudgetPolicy := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/search_budget_policy.gd"
)
const TrajectoryOutcomePredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/trajectory_outcome_predictor.gd"
)
const UtilityModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/utility_model.gd"
)
const TrajectorySelector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/trajectory_selector.gd"
)

var _trajectory_generator: Reference = TrajectoryGenerator.new()
var _search_budget_policy: Reference = SearchBudgetPolicy.new()
var _trajectory_outcome_predictor: Reference = TrajectoryOutcomePredictor.new()
var _utility_model: Reference = UtilityModel.new()
var _trajectory_selector: Reference = TrajectorySelector.new()


func plan(observation: Dictionary, previous_movement: Vector2, player_index: int) -> Dictionary:
	if observation.empty() or not observation.has("player_state"):
		return _empty_plan("observation_unavailable")
	if observation.player_state.dead:
		return _empty_plan("player_dead")

	var context: Dictionary = _utility_model.build_context(observation)
	var search_budget: Dictionary = _search_budget_policy.build(observation)
	var trajectories: Array = _trajectory_generator.generate(observation, search_budget)
	var full_evaluation_limit: int = search_budget.full_evaluation_limit
	var coarse_shortlist := []

	for trajectory in trajectories:
		var outcome: Dictionary = _trajectory_outcome_predictor.predict(
			observation, trajectory, previous_movement, false
		)
		var evaluation: Dictionary = _utility_model.evaluate(outcome, context)
		var scored := _make_scored_trajectory(trajectory, outcome, evaluation)
		_insert_descending(coarse_shortlist, scored, full_evaluation_limit)

	var fully_scored_trajectories := []
	for coarse in coarse_shortlist:
		var outcome: Dictionary = _trajectory_outcome_predictor.predict(
			observation, coarse.trajectory, previous_movement, true
		)
		var evaluation: Dictionary = _utility_model.evaluate(outcome, context)
		_insert_descending(
			fully_scored_trajectories,
			_make_scored_trajectory(coarse.trajectory, outcome, evaluation),
			full_evaluation_limit
		)

	var seed: int = int(observation.physics_frame) * 31 + player_index
	var plan: Dictionary = _trajectory_selector.select(fully_scored_trajectories, context, seed)
	plan.status = "ready"
	plan.context = context
	plan.search_budget = search_budget.duplicate(true)
	plan.trajectory_count = trajectories.size()
	plan.full_evaluation_count = fully_scored_trajectories.size()
	plan.ranked_trajectories = _summarize_trajectories(fully_scored_trajectories, 5)
	return plan


func _make_scored_trajectory(
	trajectory: Dictionary, outcome: Dictionary, evaluation: Dictionary
) -> Dictionary:
	return {
		"trajectory": trajectory,
		"movement": trajectory.movement,
		"outcome": outcome,
		"score": evaluation.score,
		"utility_breakdown": evaluation.breakdown,
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


func _summarize_trajectories(entries: Array, limit: int) -> Array:
	var result := []
	for index in min(limit, entries.size()):
		var entry: Dictionary = entries[index]
		result.push_back(
			{
				"trajectory_id": entry.trajectory.trajectory_id,
				"movement": entry.movement,
				"score": entry.score,
				"outcome": entry.outcome.duplicate(true),
				"utility_breakdown": entry.utility_breakdown.duplicate(true),
			}
		)
	return result


func _empty_plan(status: String) -> Dictionary:
	return {
		"status": status,
		"movement": Vector2.ZERO,
		"score": -INF,
		"outcome": {},
		"utility_breakdown": {},
	}
