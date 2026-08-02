extends Reference

# Samples among near-optimal movement actions. A deterministic per-frame seed makes
# choices replayable while still breaking stable ties.

const NEAR_OPTIMAL_RELATIVE_BAND := 0.06
const MINIMUM_SCORE_BAND := 0.5


func select(scored_actions: Array, context: Dictionary, seed: int) -> Dictionary:
	assert(not scored_actions.empty())
	var best_score: float = scored_actions[0].score
	var score_band := max(MINIMUM_SCORE_BAND, abs(best_score) * NEAR_OPTIMAL_RELATIVE_BAND)
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
	var roll := rng.randf() * total_weight
	for index in near_optimal.size():
		roll -= weights[index]
		if roll <= 0.0:
			var selected: Dictionary = near_optimal[index].duplicate(true)
			selected.near_optimal_count = near_optimal.size()
			return selected
	var selected: Dictionary = near_optimal.back().duplicate(true)
	selected.near_optimal_count = near_optimal.size()
	return selected
