extends Reference

# Samples among near-optimal movement actions. A deterministic per-frame seed makes
# choices replayable while still breaking stable ties.

const NEAR_OPTIMAL_SPREAD_BAND := 0.06
const MINIMUM_SCORE_BAND := 0.5


func select(scored_actions: Array, context: Dictionary, seed: int) -> Dictionary:
	# The generator always contributes the zero-input action. An empty list is an
	# internal planner contract failure, not a recoverable gameplay condition.
	assert(not scored_actions.empty())
	var best_score: float = scored_actions[0].score
	var worst_score: float = scored_actions.back().score
	# A value shared by every action must not alter selection temperature or the
	# near-optimal set. Use the action score spread, which is translation invariant.
	var score_band := max(MINIMUM_SCORE_BAND, (best_score - worst_score) * NEAR_OPTIMAL_SPREAD_BAND)
	var near_optimal := []
	for action in scored_actions:
		if action.score >= best_score - score_band:
			near_optimal.push_back(action)

	var temperature: float = max(0.01, context.selection_temperature * score_band)
	var total_weight := 0.0
	var weights := []
	for action in near_optimal:
		var weight := exp(clamp((action.score - best_score) / temperature, -20.0, 0.0))
		weights.push_back(weight)
		total_weight += weight

	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var initial_roll := rng.randf() * total_weight
	var roll := initial_roll
	for index in near_optimal.size():
		roll -= weights[index]
		if roll <= 0.0:
			var selected: Dictionary = near_optimal[index].duplicate(true)
			selected.near_optimal_count = near_optimal.size()
			selected.selection_diagnostics = _selection_diagnostics(
				seed,
				best_score,
				worst_score,
				score_band,
				temperature,
				initial_roll,
				total_weight,
				index,
				weights[index]
			)
			return selected
	var selected: Dictionary = near_optimal.back().duplicate(true)
	selected.near_optimal_count = near_optimal.size()
	selected.selection_diagnostics = _selection_diagnostics(
		seed,
		best_score,
		worst_score,
		score_band,
		temperature,
		initial_roll,
		total_weight,
		near_optimal.size() - 1,
		weights.back()
	)
	return selected


func _selection_diagnostics(
	seed: int,
	best_score: float,
	worst_score: float,
	score_band: float,
	temperature: float,
	roll: float,
	total_weight: float,
	selected_near_optimal_index: int,
	selected_weight: float
) -> Dictionary:
	return {
		"seed": seed,
		"best_score": best_score,
		"worst_score": worst_score,
		"score_spread": best_score - worst_score,
		"near_optimal_score_band": score_band,
		"temperature": temperature,
		"roll_fraction": roll / max(0.000001, total_weight),
		"selected_near_optimal_index": selected_near_optimal_index,
		"selected_probability": selected_weight / max(0.000001, total_weight),
	}
