extends Reference

# Keeps transitions inside the predicted terminal health reserve whenever the
# action set contains one. This is the terminal reserve condition used by rolling
# planning: scoring may trade health for value inside the retained domain,
# but cannot repeatedly borrow the reserve needed to survive the next reachable
# hit. When every action is outside the domain, retain the actions with the
# greatest reserve margin, then let the common utility ledger break ties.


func select(scored_actions: Array) -> Dictionary:
	# The generator always contributes the zero-input action. An empty list is an
	# internal planner contract failure, not a recoverable gameplay condition.
	assert(not scored_actions.empty())
	var committed_viable_actions := _retain_committed_viable(scored_actions)
	var reserve_viable_actions := _retain_terminal_reserve_viable(committed_viable_actions)
	var viable_actions := (
		reserve_viable_actions
		if not reserve_viable_actions.empty()
		else _retain_greatest_terminal_reserve_margin(committed_viable_actions)
	)
	var selected: Dictionary = viable_actions[0]
	for candidate in viable_actions:
		if candidate.score > selected.score:
			selected = candidate
	selected = selected.duplicate(false)
	selected.selection_diagnostics = {
		"mode": "terminal_health_reserve_then_maximum_utility",
		"best_score": selected.score,
		"candidate_count": scored_actions.size(),
		"viable_candidate_count": viable_actions.size(),
		"committed_viable_candidate_count": committed_viable_actions.size(),
		"terminal_health_reserve_viable_candidate_count": reserve_viable_actions.size(),
		"excluded_certain_terminal_candidate_count":
		scored_actions.size() - committed_viable_actions.size(),
		"terminal_health_reserve_fallback_active": reserve_viable_actions.empty(),
		"selected_committed_terminal_collision_risk": _committed_terminal_risk(selected),
		"selected_terminal_health_reserve_margin": _terminal_health_reserve_margin(selected),
	}
	return selected


func retain_viable(scored_actions: Array) -> Array:
	var committed_viable_actions := _retain_committed_viable(scored_actions)
	var reserve_viable_actions := _retain_terminal_reserve_viable(committed_viable_actions)
	return (
		reserve_viable_actions
		if not reserve_viable_actions.empty()
		else _retain_greatest_terminal_reserve_margin(committed_viable_actions)
	)


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


func _retain_terminal_reserve_viable(scored_actions: Array) -> Array:
	var result := []
	for candidate in scored_actions:
		if candidate.get("outcome", {}).get("retains_terminal_health_reserve", true):
			result.push_back(candidate)
	return result


func _retain_greatest_terminal_reserve_margin(scored_actions: Array) -> Array:
	assert(not scored_actions.empty())
	var greatest_margin := -INF
	for candidate in scored_actions:
		greatest_margin = max(greatest_margin, _terminal_health_reserve_margin(candidate))
	var result := []
	for candidate in scored_actions:
		if is_equal_approx(_terminal_health_reserve_margin(candidate), greatest_margin):
			result.push_back(candidate)
	return result


func _is_certain_committed_terminal(scored_action: Dictionary) -> bool:
	return _committed_terminal_risk(scored_action) == 1.0


func _committed_terminal_risk(scored_action: Dictionary) -> float:
	return clamp(
		float(scored_action.get("outcome", {}).get("terminal_collision_risk", 0.0)), 0.0, 1.0
	)


func _terminal_health_reserve_margin(scored_action: Dictionary) -> float:
	return float(scored_action.get("outcome", {}).get("terminal_health_reserve_margin", INF))
