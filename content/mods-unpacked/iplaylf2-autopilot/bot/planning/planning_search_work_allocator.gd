extends Reference

# Maps each planning loop's independent budget pressure into only the work that
# loop owns. Movement geometry owns the tactical baseline; this allocator owns
# tactical refinement limits and the strategic navigation lattice.

const NAVIGATION_BASELINE_DIRECTION_COUNT := 8
const NAVIGATION_MINIMUM_DIRECTION_COUNT := 4
const MINIMUM_REFINEMENT_FIDELITY := 0.25


func allocate_tactical(compute_budget: Dictionary, movement_refinement_capacity: int) -> Dictionary:
	var budget_pressure: float = compute_budget.budget_pressure
	var refinement_fidelity := _retained_refinement_fidelity(budget_pressure)
	return {
		"allocation_model": "budgeted_tactical_search_work",
		"budget_pressure": budget_pressure,
		"minimum_refinement_fidelity": MINIMUM_REFINEMENT_FIDELITY,
		"refinement_fidelity": refinement_fidelity,
		"movement_refinement_limit":
		_extra_work_limit(movement_refinement_capacity, refinement_fidelity),
	}


func allocate_strategic(compute_budget: Dictionary) -> Dictionary:
	var budget_pressure: float = compute_budget.budget_pressure
	var refinement_fidelity := _retained_refinement_fidelity(budget_pressure)
	return {
		"allocation_model": "budgeted_strategic_search_work",
		"budget_pressure": budget_pressure,
		"minimum_refinement_fidelity": MINIMUM_REFINEMENT_FIDELITY,
		"refinement_fidelity": refinement_fidelity,
		# The approximate value field yields uniform resolution before it can consume
		# capacity reserved for the independently scheduled tactical loop.
		"navigation_baseline_direction_count": _navigation_baseline_count(budget_pressure),
		"navigation_extra_evaluation_limit":
		_extra_work_limit(NAVIGATION_BASELINE_DIRECTION_COUNT, refinement_fidelity),
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


func _navigation_baseline_count(budget_pressure: float) -> int:
	var retained: float = lerp(
		float(NAVIGATION_BASELINE_DIRECTION_COUNT),
		float(NAVIGATION_MINIMUM_DIRECTION_COUNT),
		clamp(budget_pressure, 0.0, 1.0)
	)
	var even_count := int(round(retained / 2.0)) * 2
	return int(
		clamp(even_count, NAVIGATION_MINIMUM_DIRECTION_COUNT, NAVIGATION_BASELINE_DIRECTION_COUNT)
	)
