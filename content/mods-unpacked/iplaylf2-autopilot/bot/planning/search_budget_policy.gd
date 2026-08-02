extends Reference

# Adapts search fidelity to measured physics-frame headroom and observed planning
# cost. Entity-count proxies accompany the allocation as cost diagnostics.

const BASE_DIRECTION_COUNT := 8
const BASE_FORECAST_SAMPLE_COUNT := 3
const BASE_GRAPH_RESOLUTION_SCALE := 0.5
const BASE_WEAPON_PREDICTION_LIMIT := 4

# Asymmetric exponents shed effort quickly under overload and restore it gradually
# when headroom returns.
const OVERLOAD_ADJUSTMENT_EXPONENT := 0.75
const RECOVERY_ADJUSTMENT_EXPONENT := 0.25
const PLANNING_COST_EMA_SAMPLE_WEIGHT := 0.25
const MIN_EFFORT_ADJUSTMENT_RATIO := 0.25
const MAX_EFFORT_ADJUSTMENT_RATIO := 2.0

var _search_effort_scale := 1.0
var _allocated_search_effort_scale := 1.0
var _planning_duration_usec_ema := 0.0
var _planning_usec_per_effort_ema := 0.0
var _has_cost_estimate := false
var _frame_budget_context := {}


func set_frame_budget_context(frame_budget_context: Dictionary) -> void:
	_frame_budget_context = frame_budget_context.duplicate(true)


func allocate(observation: Dictionary) -> Dictionary:
	var enemy_count: int = observation.enemy_tracks.size()
	var projectile_count: int = observation.visible_world.enemy_projectiles.size()
	var influence_source_count: int = (
		observation.visible_world.get("structures", []).size()
		+ observation.visible_world.get("allied_agents", []).size()
		+ _estimate_remembered_structure_count(observation)
	)
	var interceptor_count := _count_projectile_interceptors(observation)
	var interaction_workload_proxy := int(
		ceil((enemy_count * influence_source_count + projectile_count * interceptor_count) / 8.0)
	)
	var entity_workload_proxy := enemy_count + projectile_count + interaction_workload_proxy
	var planning_duration_budget_usec := _planning_duration_budget_usec()
	_allocated_search_effort_scale = _search_effort_scale
	var search_resolution_scale := sqrt(_allocated_search_effort_scale)
	return {
		"allocation_mode": "frame_time_feedback",
		"direction_count": max(1, int(round(BASE_DIRECTION_COUNT * search_resolution_scale))),
		"forecast_sample_count":
		max(1, int(round(BASE_FORECAST_SAMPLE_COUNT * search_resolution_scale))),
		"graph_angular_resolution_scale": BASE_GRAPH_RESOLUTION_SCALE * search_resolution_scale,
		"weapon_prediction_limit":
		max(1, int(round(BASE_WEAPON_PREDICTION_LIMIT * search_resolution_scale))),
		"search_effort_scale": _allocated_search_effort_scale,
		"planning_duration_budget_usec": planning_duration_budget_usec,
		"planning_duration_usec_ema": _planning_duration_usec_ema if _has_cost_estimate else null,
		"planning_usec_per_effort_ema":
		_planning_usec_per_effort_ema if _has_cost_estimate else null,
		"physics_frame_capacity_usec":
		_frame_budget_context.get("physics_frame_capacity_usec", 0.0),
		"baseline_physics_duration_usec_ema":
		_frame_budget_context.get("baseline_physics_duration_usec_ema", 0.0),
		"physics_duration_deviation_usec_ema":
		_frame_budget_context.get("physics_duration_deviation_usec_ema", 0.0),
		"has_frame_time_sample": _frame_budget_context.get("has_frame_time_sample", false),
		"scheduled_planner_count": _frame_budget_context.get("scheduled_planner_count", 1),
		"threat_entity_count": enemy_count + projectile_count,
		"influence_source_count": influence_source_count,
		"interaction_workload_proxy": interaction_workload_proxy,
		"entity_workload_proxy": entity_workload_proxy,
	}


func observe_planning_duration(planning_duration_usec: float) -> Dictionary:
	var observed_usec_per_effort: float = (
		planning_duration_usec
		/ max(1.0, _allocated_search_effort_scale)
	)
	if not _has_cost_estimate:
		_planning_duration_usec_ema = planning_duration_usec
		_planning_usec_per_effort_ema = observed_usec_per_effort
		_has_cost_estimate = true
	else:
		_planning_duration_usec_ema = lerp(
			_planning_duration_usec_ema, planning_duration_usec, PLANNING_COST_EMA_SAMPLE_WEIGHT
		)
		_planning_usec_per_effort_ema = lerp(
			_planning_usec_per_effort_ema, observed_usec_per_effort, PLANNING_COST_EMA_SAMPLE_WEIGHT
		)

	var planning_duration_budget_usec := _planning_duration_budget_usec()
	if planning_duration_budget_usec <= 0.0:
		_search_effort_scale = 1.0
	else:
		var sustainable_effort_scale := max(
			1.0, planning_duration_budget_usec / max(1.0, _planning_usec_per_effort_ema)
		)
		var adjustment_ratio := clamp(
			sustainable_effort_scale / _allocated_search_effort_scale,
			MIN_EFFORT_ADJUSTMENT_RATIO,
			MAX_EFFORT_ADJUSTMENT_RATIO
		)
		var adjustment_exponent := (
			RECOVERY_ADJUSTMENT_EXPONENT
			if adjustment_ratio >= 1.0
			else OVERLOAD_ADJUSTMENT_EXPONENT
		)
		_search_effort_scale = max(
			1.0, _allocated_search_effort_scale * pow(adjustment_ratio, adjustment_exponent)
		)

	return {
		"planning_duration_usec": planning_duration_usec,
		"planning_duration_usec_ema": _planning_duration_usec_ema,
		"planning_usec_per_effort_ema": _planning_usec_per_effort_ema,
		"next_search_effort_scale": _search_effort_scale,
		"planning_duration_budget_utilization":
		(
			planning_duration_usec / planning_duration_budget_usec
			if planning_duration_budget_usec > 0.0
			else INF
		),
	}


func _planning_duration_budget_usec() -> float:
	if not _frame_budget_context.get("has_frame_time_sample", false):
		return 0.0
	var frame_capacity: float = _frame_budget_context.get("physics_frame_capacity_usec", 0.0)
	var baseline_duration: float = _frame_budget_context.get(
		"baseline_physics_duration_usec_ema", 0.0
	)
	var physics_duration_deviation: float = _frame_budget_context.get(
		"physics_duration_deviation_usec_ema", 0.0
	)
	var scheduled_planner_count: int = max(
		1, int(_frame_budget_context.get("scheduled_planner_count", 1))
	)
	return (
		max(0.0, frame_capacity - baseline_duration - physics_duration_deviation)
		/ scheduled_planner_count
	)


func _count_projectile_interceptors(observation: Dictionary) -> int:
	var result := 0
	for ally in observation.visible_world.get("allied_agents", []):
		if ally.influence.projectile_interception.active:
			result += 1
	return result


func _estimate_remembered_structure_count(observation: Dictionary) -> int:
	var effective_count := 0.0
	for remembered_entity in observation.get("remembered_entities", []):
		if remembered_entity.kind == "structure" and not remembered_entity.visible:
			effective_count += remembered_entity.existence_confidence
	return int(ceil(effective_count))
