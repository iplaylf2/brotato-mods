extends Node

# Closes the observation -> planning -> movement-input loop. Planning runs at a
# lower cadence than physics; the chosen movement remains active until replanning.

const AutopilotMovementBehavior := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/control/autopilot_movement_behavior.gd"
)
const MovementPlanner := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_planner.gd"
)
const MovementPlanningTiming := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_planning_timing.gd"
)
const DecisionTelemetry := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/control/decision_telemetry.gd"
)
const PlanningFrameBudgetMonitor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/control/planning_frame_budget_monitor.gd"
)
const REPLAN_INTERVAL_SECONDS := MovementPlanningTiming.CONTROL_INTERVAL_SECONDS

var _observation_service: Node
var _players: Array = []
var _actuators: Array = []
var _original_movement_behaviors: Array = []
var _movement_planners: Array = []
var _current_plans: Array = []
var _previous_movements: Array = []
var _decision_telemetry: Reference = DecisionTelemetry.new()
var _planning_frame_budget_monitor: Reference = PlanningFrameBudgetMonitor.new()
var _seconds_until_replan := 0.0
var _shut_down := false
var _previous_physics_frame_included_planning := false


func initialize(observation_service: Node, players: Array) -> void:
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
	_decision_telemetry.start(players.size(), REPLAN_INTERVAL_SECONDS)


func _physics_process(delta: float) -> void:
	if _shut_down or get_tree().paused or not is_instance_valid(_observation_service):
		return

	_planning_frame_budget_monitor.observe_physics_duration(
		delta, _previous_physics_frame_included_planning
	)
	_previous_physics_frame_included_planning = false
	_seconds_until_replan -= delta
	if _seconds_until_replan > 0.0:
		return
	_seconds_until_replan = REPLAN_INTERVAL_SECONDS
	_replan_all_players()
	_previous_physics_frame_included_planning = true


func shutdown() -> void:
	if _shut_down:
		return
	_shut_down = true
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


func _replan_all_players() -> void:
	var scheduled_planner_count := 0
	for player in _players:
		if is_instance_valid(player):
			scheduled_planner_count += 1
	var frame_budget_context: Dictionary = _planning_frame_budget_monitor.build_context(
		scheduled_planner_count
	)
	for player_index in _players.size():
		var player: Node = _players[player_index]
		if not is_instance_valid(player):
			continue
		_movement_planners[player_index].set_frame_budget_context(frame_budget_context)
		var observation: Dictionary = _observation_service.get_observation(player_index)
		var plan: Dictionary = _movement_planners[player_index].plan(
			observation, _previous_movements[player_index], player_index
		)
		_current_plans[player_index] = plan
		_decision_telemetry.record_decision(
			player_index,
			observation,
			plan,
			_previous_movements[player_index],
			REPLAN_INTERVAL_SECONDS
		)
		var movement: Vector2 = plan.movement
		_actuators[player_index].set_movement(movement)
		_previous_movements[player_index] = movement
