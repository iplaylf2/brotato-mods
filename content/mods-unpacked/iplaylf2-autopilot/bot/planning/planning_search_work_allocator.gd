extends Reference

# Maps planning budget pressure into optional search work. Navigation retains a
# bounded all-angle evidence lattice because its selected value direction is an
# input to local action generation. Movement geometry owns the local action
# baseline; this allocator owns the navigation baseline and optional work limits.

const NAVIGATION_BASELINE_DIRECTION_COUNT := 8
const MINIMUM_REFINEMENT_FIDELITY := 0.25


func allocate(compute_budget: Dictionary, movement_refinement_capacity: int) -> Dictionary:
	var budget_pressure: float = compute_budget.budget_pressure
	var refinement_fidelity := _retained_refinement_fidelity(budget_pressure)
	return {
		"allocation_model": "budgeted_optional_search_work",
		"budget_pressure": budget_pressure,
		"minimum_refinement_fidelity": MINIMUM_REFINEMENT_FIDELITY,
		"refinement_fidelity": refinement_fidelity,
		"navigation_baseline_direction_count": NAVIGATION_BASELINE_DIRECTION_COUNT,
		"navigation_extra_evaluation_limit":
		_extra_work_limit(NAVIGATION_BASELINE_DIRECTION_COUNT, refinement_fidelity),
		"movement_refinement_limit":
		_extra_work_limit(movement_refinement_capacity, refinement_fidelity),
	}


func _retained_refinement_fidelity(budget_pressure: float) -> float:
	if budget_pressure <= 0.0:
		return 1.0
	# Refinement capacity yields continuously before background planning exceeds its
	# share of measured frame headroom.
	return pow(MINIMUM_REFINEMENT_FIDELITY, budget_pressure)


func _extra_work_limit(work_capacity: int, fidelity: float) -> int:
	var extra_fraction := (
		(fidelity - MINIMUM_REFINEMENT_FIDELITY)
		/ (1.0 - MINIMUM_REFINEMENT_FIDELITY)
	)
	return int(round(float(work_capacity) * extra_fraction))
