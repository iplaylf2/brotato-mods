extends Reference

# Strategic planning boundary for the multi-rate controller. It computes a
# long-horizon navigation value field from a detached observation and returns
# pure-value guidance with its independent budget diagnostics. The tactical
# planner owns every executable action and may discard stale guidance.

const ActuationStateProjector := preload("actuation_state_projector.gd")
const EnemyMotionPredictor := preload("motion/enemy_motion_predictor.gd")
const MovementUtilityModel := preload("movement_utility_model.gd")
const NavigationIntentPlanner := preload("navigation_intent_planner.gd")
const PlanningComputeBudgetPolicy := preload("planning_compute_budget_policy.gd")
const PlanningSearchWorkAllocator := preload("planning_search_work_allocator.gd")
const ProjectileReachabilityFilter := preload("projectile_reachability_filter.gd")

var _actuation_state_projector: Reference = ActuationStateProjector.new()
var _compute_budget_policy: Reference = PlanningComputeBudgetPolicy.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _navigation_intent_planner: Reference = NavigationIntentPlanner.new()
var _projectile_filter: Reference = ProjectileReachabilityFilter.new()
var _search_work_allocator: Reference = PlanningSearchWorkAllocator.new()
var _utility_model: Reference = MovementUtilityModel.new()


func _init() -> void:
	_navigation_intent_planner.set_enemy_motion_predictor(_enemy_motion_predictor)


func plan(request: Dictionary) -> Dictionary:
	var observation: Dictionary = request.observation
	if observation.empty() or not observation.has("player_state"):
		return _empty_navigation_guidance("observation_unavailable")
	if observation.player_state.dead:
		return _empty_navigation_guidance("player_dead")

	var planning_started_usec := OS.get_ticks_usec()
	_compute_budget_policy.set_frame_budget_context(request.frame_budget_context)
	var compute_budget: Dictionary = _compute_budget_policy.allocate(planning_started_usec)
	var request_queue_delay_usec := max(
		0, planning_started_usec - int(request.request_created_usec)
	)
	compute_budget.request_queue_delay_usec = request_queue_delay_usec
	var expected_result_delay_seconds := (
		float(compute_budget.expected_post_start_actuation_delay_usec + request_queue_delay_usec)
		/ 1000000.0
	)
	var projection: Dictionary = _actuation_state_projector.project(
		observation, request.active_movement, expected_result_delay_seconds
	)
	var projectile_filter: Dictionary = _projectile_filter.filter(projection.observation)
	var planning_observation: Dictionary = projectile_filter.filtered_observation
	var context: Dictionary = _utility_model.build_context(planning_observation)
	var search_work_allocation: Dictionary = _search_work_allocator.allocate_strategic(
		compute_budget
	)
	var navigation_started_usec := OS.get_ticks_usec()
	var navigation_intent: Dictionary = _navigation_intent_planner.plan(
		planning_observation,
		context,
		compute_budget,
		search_work_allocation,
		_compute_budget_policy
	)
	var navigation_duration_usec := OS.get_ticks_usec() - navigation_started_usec
	var planning_duration_usec := float(OS.get_ticks_usec() - planning_started_usec)
	compute_budget.merge(
		_compute_budget_policy.observe_planning_duration(planning_duration_usec), true
	)
	compute_budget.phase_duration_usec = {"navigation": navigation_duration_usec}
	compute_budget.planning_deadline_overrun_usec = (
		max(0, OS.get_ticks_usec() - int(compute_budget.planning_deadline_usec))
		if compute_budget.has_deadline
		else null
	)
	return {
		"status": "ready",
		"source_physics_frame": int(observation.get("physics_frame", -1)),
		"navigation_intent": navigation_intent,
		"compute_budget": compute_budget,
		"search_work_allocation": search_work_allocation,
	}


func _empty_navigation_guidance(status: String) -> Dictionary:
	return {
		"status": status,
		"source_physics_frame": -1,
		"navigation_intent": {},
		"compute_budget": {},
	}
