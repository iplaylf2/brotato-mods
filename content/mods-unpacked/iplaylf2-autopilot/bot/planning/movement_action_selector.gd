extends Reference

# Rejects only a certain terminal collision inside the input interval that will
# actually be committed before replanning. Forecast risk remains in the shared
# utility ledger, including the continuation capital lost on terminal outcomes.


func select(scored_actions: Array) -> Dictionary:
	# The generator always contributes the zero-input action. An empty list is an
	# internal planner contract failure, not a recoverable gameplay condition.
	assert(not scored_actions.empty())
	var viable_actions := retain_viable(scored_actions)
	var selected: Dictionary = viable_actions[0]
	for candidate in viable_actions:
		if candidate.score > selected.score:
			selected = candidate
	selected = selected.duplicate(false)
	selected.selection_diagnostics = {
		"mode": "committed_viability_then_maximum_utility",
		"best_score": selected.score,
		"candidate_count": scored_actions.size(),
		"viable_candidate_count": viable_actions.size(),
		"excluded_certain_terminal_candidate_count": scored_actions.size() - viable_actions.size(),
		"selected_committed_terminal_collision_risk": _committed_terminal_risk(selected),
	}
	return selected


func retain_viable(scored_actions: Array) -> Array:
	return _retain_committed_viable(scored_actions)


func _retain_committed_viable(scored_actions: Array) -> Array:
	assert(not scored_actions.empty())
	var has_nonterminal_action := false
	for candidate in scored_actions:
		if not _is_certain_committed_terminal(candidate):
			has_nonterminal_action = true
			break
	if not has_nonterminal_action:
		return scored_actions.duplicate()
	var result := []
	for candidate in scored_actions:
		if not _is_certain_committed_terminal(candidate):
			result.push_back(candidate)
	return result


func _is_certain_committed_terminal(scored_action: Dictionary) -> bool:
	return _committed_terminal_risk(scored_action) == 1.0


func _committed_terminal_risk(scored_action: Dictionary) -> float:
	return clamp(
		float(scored_action.get("outcome", {}).get("terminal_collision_risk", 0.0)), 0.0, 1.0
	)
