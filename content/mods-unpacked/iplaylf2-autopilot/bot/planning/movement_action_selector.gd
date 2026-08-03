extends Reference

# Selection is deliberately mechanical: all trade-offs, including command
# switching cost, already live in the shared utility ledger.


func select(scored_actions: Array) -> Dictionary:
	# The generator always contributes the zero-input action. An empty list is an
	# internal planner contract failure, not a recoverable gameplay condition.
	assert(not scored_actions.empty())
	var selected: Dictionary = scored_actions[0].duplicate(true)
	selected.selection_diagnostics = {
		"mode": "maximum_utility",
		"best_score": selected.score,
		"candidate_count": scored_actions.size(),
	}
	return selected
