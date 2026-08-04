extends Node

# Closes the observation -> planning -> movement-input loop. Planning runs on a
# single background thread at a lower cadence than physics; the chosen movement
# remains active until a completed plan replaces it.

const AutopilotMovementBehavior := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/control/autopilot_movement_behavior.gd"
)
const MovementPlanner := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_planner.gd"
)
const MovementTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_timing_model.gd"
)
const DecisionTelemetry := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/control/decision_telemetry.gd"
)
const PhysicsFrameBudgetMonitor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/control/physics_frame_budget_monitor.gd"
)
var _observation_service: Node
var _players: Array = []
var _actuators: Array = []
var _original_movement_behaviors: Array = []
var _movement_planners: Array = []
var _current_plans: Array = []
var _previous_movements: Array = []
var _decision_telemetry: Reference = DecisionTelemetry.new()
var _physics_frame_budget_monitor: Reference = PhysicsFrameBudgetMonitor.new()
var _planning_thread: Thread = Thread.new()
var _planning_in_flight := false
var _seconds_until_replan := 0.0
var _shut_down := false
var _replan_interval_seconds := 0.0


func initialize(observation_service: Node, players: Array) -> void:
	_replan_interval_seconds = MovementTimingModel.control_interval_seconds()
	_observation_service = observation_service
	_players = players
	for player in players:
		var actuator := AutopilotMovementBehavior.new()
		add_child(actuator)
		_actuators.push_back(actuator)
		_original_movement_behaviors.push_back(player._current_movement_behavior)
		_movement_planners.push_back(MovementPlanner.new())
		_current_plans.push_back({})
		_previous_movements.push_back(Vector2.ZERO)
		player._current_movement_behavior = actuator
	_decision_telemetry.start(players.size(), _replan_interval_seconds)


func _physics_process(delta: float) -> void:
	if _shut_down or get_tree().paused or not is_instance_valid(_observation_service):
		return

	_physics_frame_budget_monitor.observe_physics_duration(delta)
	_seconds_until_replan -= delta
	if _seconds_until_replan > 0.0 or _planning_in_flight:
		return
	_seconds_until_replan = _replan_interval_seconds
	_start_replan()


func shutdown() -> void:
	if _shut_down:
		return
	_shut_down = true
	if _planning_in_flight:
		_planning_thread.wait_to_finish()
		_planning_in_flight = false
	_decision_telemetry.close()
	for player_index in _players.size():
		var player: Node = _players[player_index]
		var actuator: Node = _actuators[player_index]
		actuator.set_movement(Vector2.ZERO)
		if is_instance_valid(player) and player._current_movement_behavior == actuator:
			player._current_movement_behavior = _original_movement_behaviors[player_index]


func _exit_tree() -> void:
	shutdown()


func get_current_plan(player_index: int) -> Dictionary:
	if player_index < 0 or player_index >= _current_plans.size():
		return {}
	return _current_plans[player_index].duplicate(true)


func get_decision_sample_path() -> String:
	return _decision_telemetry.get_current_path()


func _start_replan() -> void:
	var scheduled_planner_count := 0
	for player in _players:
		if is_instance_valid(player) and not player.dead:
			scheduled_planner_count += 1
	if scheduled_planner_count <= 0:
		return
	var frame_budget_context: Dictionary = _physics_frame_budget_monitor.build_context(
		scheduled_planner_count
	)
	var requests := []
	for player_index in _players.size():
		var player: Node = _players[player_index]
		if not is_instance_valid(player) or player.dead:
			continue
		_movement_planners[player_index].set_frame_budget_context(frame_budget_context)
		var observation: Dictionary = _observation_service.get_planning_observation(player_index)
		requests.push_back(
			{
				"player_index": player_index,
				"observation": observation,
				"planner": _movement_planners[player_index],
			}
		)
	var start_error := _planning_thread.start(self, "_plan_in_background", requests)
	if start_error == OK:
		_planning_in_flight = true
		return
	# Thread creation failure is exceptional; preserve control availability with
	# one synchronous fallback instead of silently leaving the actuator stale.
	_apply_plan_results(_compute_plan_results(requests))


func _plan_in_background(requests: Array) -> Array:
	var results := _compute_plan_results(requests)
	call_deferred("_receive_background_plan_results", results)
	return []


func _compute_plan_results(requests: Array) -> Array:
	var results := []
	for request in requests:
		results.push_back(
			{
				"player_index": request.player_index,
				"observation": request.observation,
				"plan": request.planner.plan(request.observation),
			}
		)
	return results


func _receive_background_plan_results(results: Array) -> void:
	if not _planning_in_flight:
		return
	_planning_thread.wait_to_finish()
	_planning_in_flight = false
	if _shut_down:
		return
	_apply_plan_results(results)


func _apply_plan_results(results: Array) -> void:
	for result in results:
		var player_index: int = result.player_index
		var player: Node = _players[player_index]
		if not is_instance_valid(player) or player.dead:
			continue
		var observation: Dictionary = result.observation
		var plan: Dictionary = result.plan
		var compute_budget: Dictionary = plan.get("compute_budget", {})
		if compute_budget.has("planning_started_usec"):
			compute_budget.planning_turnaround_usec = max(
				0, OS.get_ticks_usec() - int(compute_budget.planning_started_usec)
			)
		_current_plans[player_index] = plan
		_decision_telemetry.record_decision(
			player_index,
			observation,
			plan,
			_previous_movements[player_index],
			_replan_interval_seconds
		)
		var movement: Vector2 = plan.movement
		_actuators[player_index].set_movement(movement)
		_previous_movements[player_index] = movement
