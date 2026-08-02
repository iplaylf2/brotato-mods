extends Reference

# Keeps movement geometry and temporal sampling at their derived fidelity. Only
# optional strategic breadth and expensive weapon simulation respond to measured
# synchronous-frame headroom.

const MIN_OPTIONAL_DETAIL_LEVEL := 0
const MAX_OPTIONAL_DETAIL_LEVEL := 2
const PLANNING_COST_EMA_SAMPLE_WEIGHT := 0.25
const BASELINE_DEVIATION_RESERVE := 2.0
const DETAIL_RECOVERY_BUDGET_RATIO := 0.6

var _optional_detail_level := 1
var _planning_duration_usec_ema := 0.0
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
	return {
		"optional_detail_level": _optional_detail_level,
		"weapon_refinement_limit": _weapon_refinement_limit(_optional_detail_level),
		"navigation_base_direction_count": _navigation_direction_count(_optional_detail_level),
		"planning_duration_budget_usec": _planning_duration_budget_usec(),
		"planning_duration_usec_ema": _planning_duration_usec_ema if _has_cost_estimate else null,
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
		"entity_workload_proxy": enemy_count + projectile_count + interaction_workload_proxy,
	}


func observe_planning_duration(planning_duration_usec: float) -> Dictionary:
	if not _has_cost_estimate:
		_planning_duration_usec_ema = planning_duration_usec
		_has_cost_estimate = true
	else:
		_planning_duration_usec_ema = lerp(
			_planning_duration_usec_ema, planning_duration_usec, PLANNING_COST_EMA_SAMPLE_WEIGHT
		)

	var budget := _planning_duration_budget_usec()
	var has_frame_sample: bool = _frame_budget_context.get("has_frame_time_sample", false)
	if has_frame_sample:
		if budget <= 0.0:
			_optional_detail_level = MIN_OPTIONAL_DETAIL_LEVEL
		elif _planning_duration_usec_ema > budget:
			_optional_detail_level = max(MIN_OPTIONAL_DETAIL_LEVEL, _optional_detail_level - 1)
		elif _planning_duration_usec_ema < budget * DETAIL_RECOVERY_BUDGET_RATIO:
			_optional_detail_level = min(MAX_OPTIONAL_DETAIL_LEVEL, _optional_detail_level + 1)

	return {
		"planning_duration_usec": planning_duration_usec,
		"planning_duration_usec_ema": _planning_duration_usec_ema,
		"next_optional_detail_level": _optional_detail_level,
		"planning_duration_budget_utilization":
		null if not has_frame_sample else planning_duration_usec / budget if budget > 0.0 else INF,
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


func _weapon_refinement_limit(detail_level: int) -> int:
	match detail_level:
		0:
			return 2
		2:
			return 6
	return 4


func _navigation_direction_count(detail_level: int) -> int:
	match detail_level:
		0:
			return 6
		2:
			return 16
	return 12


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
