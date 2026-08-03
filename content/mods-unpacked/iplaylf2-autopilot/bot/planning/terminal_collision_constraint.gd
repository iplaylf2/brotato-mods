extends Reference

# Defines only the hard feasibility boundary for collision risk that can end the
# run. Ordinary health expenditure is priced by MovementUtilityModel.

const TERMINAL_RISK_EQUIVALENCE_BAND := 0.04


func apply(collision_predictions: Array) -> Dictionary:
	assert(not collision_predictions.empty())
	var minimum_terminal_risk := INF
	for candidate in collision_predictions:
		minimum_terminal_risk = min(
			minimum_terminal_risk, float(candidate.outcome.terminal_collision_risk)
		)
	var maximum_admissible_terminal_risk := minimum_terminal_risk + TERMINAL_RISK_EQUIVALENCE_BAND
	var admissible_actions := []
	for candidate in collision_predictions:
		if candidate.outcome.terminal_collision_risk <= maximum_admissible_terminal_risk:
			admissible_actions.push_back(candidate)
	return {
		"actions": admissible_actions,
		"minimum_terminal_collision_risk": minimum_terminal_risk,
		"maximum_admissible_terminal_risk": maximum_admissible_terminal_risk,
		"terminal_rejected_action_count": collision_predictions.size() - admissible_actions.size(),
	}
