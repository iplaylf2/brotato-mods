extends Reference

# Samples among near-optimal trajectories. A deterministic per-frame seed makes
# choices replayable while still breaking stable ties.

const NEAR_OPTIMAL_RELATIVE_BAND := 0.06
const MINIMUM_SCORE_BAND := 0.5


func select(scored_trajectories: Array, context: Dictionary, seed: int) -> Dictionary:
	assert(not scored_trajectories.empty())
	var best_score: float = scored_trajectories[0].score
	var score_band := max(MINIMUM_SCORE_BAND, abs(best_score) * NEAR_OPTIMAL_RELATIVE_BAND)
	var near_optimal := []
	for trajectory in scored_trajectories:
		if trajectory.score >= best_score - score_band:
			near_optimal.push_back(trajectory)

	var temperature: float = max(0.01, context.selection_temperature * score_band)
	var total_weight := 0.0
	var weights := []
	for trajectory in near_optimal:
		var weight := exp(clamp((trajectory.score - best_score) / temperature, -20.0, 0.0))
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
