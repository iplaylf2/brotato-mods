extends Reference

# Maps planning budget pressure into bounded search fidelity. This module
# allocates computation only: opportunity and survival value remain owned by
# the utility models.

const MINIMUM_MOVEMENT_DIRECTION_COUNT := 4
const MINIMUM_NAVIGATION_DIRECTION_COUNT := 2
const MAXIMUM_NAVIGATION_DIRECTION_COUNT := 8
const MINIMUM_SEARCH_FIDELITY := 0.25


func allocate(compute_budget: Dictionary, maximum_movement_direction_count: int) -> Dictionary:
	var budget_pressure: float = compute_budget.budget_pressure
	var movement_search_fidelity := _retained_search_fidelity(budget_pressure)
	var navigation_search_fidelity := _retained_search_fidelity(budget_pressure)
	return {
		"fidelity_model": "budget_pressure_decay",
		"budget_pressure": budget_pressure,
		"minimum_search_fidelity": MINIMUM_SEARCH_FIDELITY,
		"movement_search_fidelity": movement_search_fidelity,
		"navigation_search_fidelity": navigation_search_fidelity,
		"movement_direction_count":
		_scaled_direction_count(
			MINIMUM_MOVEMENT_DIRECTION_COUNT,
			maximum_movement_direction_count,
			movement_search_fidelity
		),
		"navigation_direction_count":
		_scaled_direction_count(
			MINIMUM_NAVIGATION_DIRECTION_COUNT,
			MAXIMUM_NAVIGATION_DIRECTION_COUNT,
			navigation_search_fidelity
		),
		"navigation_extra_evaluation_limit":
		_extra_work_limit(MAXIMUM_NAVIGATION_DIRECTION_COUNT, navigation_search_fidelity),
		"movement_refinement_limit":
		_extra_work_limit(maximum_movement_direction_count, movement_search_fidelity),
	}


func _retained_search_fidelity(budget_pressure: float) -> float:
	if budget_pressure <= 0.0:
		return 1.0
	# All work participates in sustained overload control. Immediate hazards still
	# retain the unbiased four-direction lattice and the complete swept-collision
	# contract, while optional angular resolution yields before background work
	# exceeds its share of the measured frame headroom.
	return pow(MINIMUM_SEARCH_FIDELITY, budget_pressure)


func _scaled_direction_count(minimum_count: int, maximum_count: int, fidelity: float) -> int:
	var count := int(ceil(float(maximum_count) * fidelity))
	count = max(count, minimum_count)
	# Opposite direction pairs keep the uniform lattice unbiased.
	return count + count % 2


func _extra_work_limit(maximum_count: int, fidelity: float) -> int:
	var extra_fraction := (fidelity - MINIMUM_SEARCH_FIDELITY) / (1.0 - MINIMUM_SEARCH_FIDELITY)
	return int(round(float(maximum_count) * extra_fraction))
