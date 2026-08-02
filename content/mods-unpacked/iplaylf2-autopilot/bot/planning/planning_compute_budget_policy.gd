extends Reference

# Converts measured physics-frame headroom into a deadline-gated compute budget.
# Baseline planning may cross the deadline; budgeted work must leave a guard
# based on its observed unit duration.

const PLANNING_DURATION_EMA_SAMPLE_WEIGHT := 0.25
const WORK_UNIT_DURATION_EMA_SAMPLE_WEIGHT := 0.25
const BASELINE_DEVIATION_RESERVE := 2.0
const DEFAULT_WORK_UNIT_DURATION_USEC := 150.0
const DEADLINE_GUARD_MULTIPLIER := 1.5
const NAVIGATION_DEADLINE_FRACTION := 0.2
const MOVEMENT_REFINEMENT_DEADLINE_FRACTION := 0.6
const WORK_NAVIGATION_EVALUATION := "navigation_evaluation"
const WORK_MOVEMENT_REFINEMENT := "movement_refinement"
const WORK_WEAPON_PREDICTION := "weapon_prediction"

var _planning_duration_usec_ema := 0.0
var _has_planning_duration_estimate := false
var _work_unit_duration_usec_ema := {}
var _frame_budget_context := {}


func set_frame_budget_context(frame_budget_context: Dictionary) -> void:
	_frame_budget_context = frame_budget_context.duplicate(true)


func allocate(planning_started_usec: int) -> Dictionary:
	var planning_budget_usec: float = _planning_duration_budget_usec()
	var has_deadline: bool = (
		_frame_budget_context.get("has_frame_time_sample", false)
		and planning_budget_usec > 0.0
	)
	var planning_deadline_usec: int = (
		planning_started_usec + int(planning_budget_usec)
		if has_deadline
		else planning_started_usec
	)
	return {
		"allocation_mode": "deadline_gated",
		"has_deadline": has_deadline,
		"planning_started_usec": planning_started_usec,
		"planning_deadline_usec": planning_deadline_usec,
		"navigation_deadline_usec":
		planning_started_usec + int(planning_budget_usec * NAVIGATION_DEADLINE_FRACTION),
		"movement_refinement_deadline_usec":
		planning_started_usec + int(planning_budget_usec * MOVEMENT_REFINEMENT_DEADLINE_FRACTION),
		"planning_duration_budget_usec": planning_budget_usec,
		"planning_duration_usec_ema":
		_planning_duration_usec_ema if _has_planning_duration_estimate else null,
		"physics_frame_capacity_usec":
		_frame_budget_context.get("physics_frame_capacity_usec", 0.0),
		"baseline_physics_duration_usec_ema":
		_frame_budget_context.get("baseline_physics_duration_usec_ema", 0.0),
		"physics_duration_deviation_usec_ema":
		_frame_budget_context.get("physics_duration_deviation_usec_ema", 0.0),
		"has_frame_time_sample": _frame_budget_context.get("has_frame_time_sample", false),
		"scheduled_planner_count": _frame_budget_context.get("scheduled_planner_count", 1),
		"estimated_work_unit_duration_usec": _work_unit_duration_usec_ema.duplicate(true),
	}


func can_start_budgeted_work(compute_budget: Dictionary, work_kind: String) -> bool:
	if not compute_budget.has_deadline:
		return false
	var deadline_key := ""
	if work_kind == WORK_NAVIGATION_EVALUATION:
		deadline_key = "navigation_deadline_usec"
	elif work_kind == WORK_MOVEMENT_REFINEMENT:
		deadline_key = "movement_refinement_deadline_usec"
	elif work_kind == WORK_WEAPON_PREDICTION:
		deadline_key = "planning_deadline_usec"
	else:
		return false
	var deadline_usec: int = int(compute_budget[deadline_key])
	var estimated_duration: float = _work_unit_duration_usec_ema.get(
		work_kind, DEFAULT_WORK_UNIT_DURATION_USEC
	)
	return OS.get_ticks_usec() + int(estimated_duration * DEADLINE_GUARD_MULTIPLIER) < deadline_usec


func observe_work_duration(work_kind: String, duration_usec: float) -> void:
	var previous: float = _work_unit_duration_usec_ema.get(work_kind, duration_usec)
	_work_unit_duration_usec_ema[work_kind] = lerp(
		previous, duration_usec, WORK_UNIT_DURATION_EMA_SAMPLE_WEIGHT
	)


func observe_planning_duration(planning_duration_usec: float) -> Dictionary:
	if not _has_planning_duration_estimate:
		_planning_duration_usec_ema = planning_duration_usec
		_has_planning_duration_estimate = true
	else:
		_planning_duration_usec_ema = lerp(
			_planning_duration_usec_ema, planning_duration_usec, PLANNING_DURATION_EMA_SAMPLE_WEIGHT
		)
	var budget := _planning_duration_budget_usec()
	var has_frame_sample: bool = _frame_budget_context.get("has_frame_time_sample", false)
	return {
		"planning_duration_usec": planning_duration_usec,
		"planning_duration_usec_ema": _planning_duration_usec_ema,
		"planning_duration_budget_utilization":
		null if not has_frame_sample else planning_duration_usec / budget if budget > 0.0 else INF,
		"estimated_work_unit_duration_usec": _work_unit_duration_usec_ema.duplicate(true),
	}


func _planning_duration_budget_usec() -> float:
	if not _frame_budget_context.get("has_frame_time_sample", false):
		return 0.0
	var frame_capacity: float = _frame_budget_context.get("physics_frame_capacity_usec", 0.0)
	var baseline_duration: float = _frame_budget_context.get(
		"baseline_physics_duration_usec_ema", 0.0
	)
	var baseline_deviation: float = _frame_budget_context.get(
		"physics_duration_deviation_usec_ema", 0.0
	)
	var scheduled_planner_count: int = max(
		1, int(_frame_budget_context.get("scheduled_planner_count", 1))
	)
	return (
		max(
			0.0,
			frame_capacity - baseline_duration - BASELINE_DEVIATION_RESERVE * baseline_deviation
		)
		/ scheduled_planner_count
	)
