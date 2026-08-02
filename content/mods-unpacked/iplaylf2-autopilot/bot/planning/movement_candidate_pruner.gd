extends Reference

# Removes fine-lattice directions that add no collision-avoidance capability over
# strategic candidates while preserving the collision-feasibility set.


func prune(admissible_actions: Array) -> Dictionary:
	assert(not admissible_actions.empty())
	var evaluation_actions := []
	var best_strategic_collision_risk := INF
	var minimum_collision_risk := INF
	for candidate in admissible_actions:
		minimum_collision_risk = min(
			minimum_collision_risk, float(candidate.outcome.collision_risk)
		)
		if candidate.action.is_strategic_candidate:
			evaluation_actions.push_back(candidate)
			best_strategic_collision_risk = min(
				best_strategic_collision_risk, float(candidate.outcome.collision_risk)
			)

	# Preserve every equally best fine-lattice escape only when it improves on
	# the coarser strategic set. In an open field this adds no redundant work.
	if minimum_collision_risk < best_strategic_collision_risk:
		for candidate in admissible_actions:
			if (
				not candidate.action.is_strategic_candidate
				and is_equal_approx(candidate.outcome.collision_risk, minimum_collision_risk)
			):
				evaluation_actions.push_back(candidate)
	if evaluation_actions.empty():
		evaluation_actions = admissible_actions

	return {
		"actions": evaluation_actions,
		"minimum_collision_risk": minimum_collision_risk,
		"redundant_direction_action_count": admissible_actions.size() - evaluation_actions.size(),
	}
