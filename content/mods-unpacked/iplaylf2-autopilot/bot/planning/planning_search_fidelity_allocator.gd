extends Reference

# Maps planning budget pressure into search breadth. Navigation retains a
# bounded all-angle evidence lattice because its selected value direction is an
# input to local action generation. Local movement breadth and optional
# refinement may yield because each retained action owns a complete forecast.

const MINIMUM_MOVEMENT_DIRECTION_COUNT := 4
const MAXIMUM_NAVIGATION_DIRECTION_COUNT := 8
const MINIMUM_SEARCH_FIDELITY := 0.25


func allocate(compute_budget: Dictionary, maximum_movement_direction_count: int) -> Dictionary:
	var budget_pressure: float = compute_budget.budget_pressure
	var search_fidelity := _retained_search_fidelity(budget_pressure)
	var movement_direction_count := _scaled_direction_count(
		MINIMUM_MOVEMENT_DIRECTION_COUNT, maximum_movement_direction_count, search_fidelity
	)
	return {
		"fidelity_model": "fixed_navigation_evidence_with_budgeted_action_breadth",
		"budget_pressure": budget_pressure,
		"minimum_search_fidelity": MINIMUM_SEARCH_FIDELITY,
		"movement_search_fidelity": search_fidelity,
		"navigation_search_fidelity": 1.0,
		"movement_direction_count": movement_direction_count,
		"navigation_direction_count": MAXIMUM_NAVIGATION_DIRECTION_COUNT,
		"navigation_extra_evaluation_limit":
		_extra_work_limit(MAXIMUM_NAVIGATION_DIRECTION_COUNT, search_fidelity),
		"movement_refinement_limit":
		_extra_work_limit(maximum_movement_direction_count, search_fidelity),
	}


func _retained_search_fidelity(budget_pressure: float) -> float:
	if budget_pressure <= 0.0:
		return 1.0
	# Search breadth yields continuously before background planning exceeds its
	# share of measured frame headroom.
	return pow(MINIMUM_SEARCH_FIDELITY, budget_pressure)


func _scaled_direction_count(minimum_count: int, maximum_count: int, fidelity: float) -> int:
	var count := int(ceil(float(maximum_count) * fidelity))
	count = max(count, min(minimum_count, maximum_count))
	# Opposite pairs keep the uniform lattice balanced around the player.
	return count + count % 2


func _extra_work_limit(maximum_count: int, fidelity: float) -> int:
	var extra_fraction := (fidelity - MINIMUM_SEARCH_FIDELITY) / (1.0 - MINIMUM_SEARCH_FIDELITY)
	return int(round(float(maximum_count) * extra_fraction))
