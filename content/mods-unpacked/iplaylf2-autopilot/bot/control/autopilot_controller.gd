extends Node

signal control_released

# Closes the observation -> planning -> movement-input loop. Planning runs on a
# single background thread at a lower cadence than physics; the chosen movement
# remains active until a completed plan replaces it.

const MOD_ID := "iplaylf2-autopilot"
const AutopilotMovementBehavior := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/control/autopilot_movement_behavior.gd"
)
const MovementTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_timing_model.gd"
)
const PhysicsFrameBudgetMonitor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/control/physics_frame_budget_monitor.gd"
)
const PlanningWorker := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/control/planning_worker.gd"
)
var _observation_service: Node
var _players: Array = []
var _actuators: Array = []
var _original_movement_behaviors: Array = []
var _current_plans: Array = []
var _previous_movements: Array = []
var _battle_sample_recorder: Node = null
var _physics_frame_budget_monitor: Reference = PhysicsFrameBudgetMonitor.new()
var _planning_worker: Reference = PlanningWorker.new()
var _shut_down := false
var _replan_interval_seconds := 0.0
var _replan_physics_ticks := 1
var _next_replan_physics_frame := 0


func initialize(observation_service: Node, players: Array) -> bool:
	_replan_interval_seconds = MovementTimingModel.control_interval_seconds()
	_replan_physics_ticks = MovementTimingModel.REPLAN_PHYSICS_TICKS
	_next_replan_physics_frame = int(Engine.get_physics_frames())
	_observation_service = observation_service
	_players = players
	if not _planning_worker.start(players.size()):
		ModLoaderLog.error(
			"Could not start the planning worker; Autopilot will not take control.", MOD_ID
		)
		_shut_down = true
		return false
	for player in players:
		var actuator := AutopilotMovementBehavior.new()
		add_child(actuator)
		_actuators.push_back(actuator)
		_original_movement_behaviors.push_back(player._current_movement_behavior)
		_current_plans.push_back({})
		_previous_movements.push_back(Vector2.ZERO)
		player._current_movement_behavior = actuator
	return true


func set_battle_sample_recorder(recorder: Node) -> void:
	_battle_sample_recorder = recorder


func _physics_process(delta: float) -> void:
	if _shut_down or get_tree().paused or not is_instance_valid(_observation_service):
		return

	_physics_frame_budget_monitor.observe_physics_duration(delta)
	if _planning_worker.is_busy():
		_collect_planning_results()
		if _planning_worker.is_busy():
			return
	var physics_frame := int(Engine.get_physics_frames())
	if physics_frame < _next_replan_physics_frame:
		return
	# Start-to-start cadence follows the same physics-tick contract used by the
	# planner. Worker time consumes this window instead of being added after it.
	_next_replan_physics_frame = physics_frame + _replan_physics_ticks
	_start_replan()


func shutdown() -> void:
	if _shut_down:
		return
	_shut_down = true
	_planning_worker.shutdown()
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


func _start_replan() -> void:
	var scheduled_planner_count := 0
	for player in _players:
		if is_instance_valid(player) and not player.dead:
			scheduled_planner_count += 1
	if scheduled_planner_count <= 0:
		return
	var frame_budget_context: Dictionary = _physics_frame_budget_monitor.build_context(
		scheduled_planner_count, _replan_interval_seconds
	)
	var requests := []
	var request_created_usec := OS.get_ticks_usec()
	for player_index in _players.size():
		var player: Node = _players[player_index]
		if not is_instance_valid(player) or player.dead:
			continue
		var observation: Dictionary = _observation_service.get_planning_observation(player_index)
		requests.push_back(
			{
				"player_index": player_index,
				"observation": observation,
				"active_movement": _previous_movements[player_index],
				"request_created_usec": request_created_usec,
				"frame_budget_context": frame_budget_context,
			}
		)
	if not _planning_worker.submit(requests):
		ModLoaderLog.error(
			"The planning worker rejected a request; Autopilot is releasing movement control.",
			MOD_ID
		)
		var recorder := _battle_sample_recorder
		shutdown()
		if is_instance_valid(recorder):
			recorder.switch_to_human()
		emit_signal("control_released")


func _collect_planning_results() -> void:
	var completion: Dictionary = _planning_worker.poll()
	if not completion.ready:
		return
	_apply_plan_results(completion.results)


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
		if is_instance_valid(_battle_sample_recorder):
			_battle_sample_recorder.record_bot_decision(
				player_index, observation, plan, _previous_movements[player_index]
			)
		var movement: Vector2 = plan.movement
		_actuators[player_index].set_movement(movement)
		_previous_movements[player_index] = movement
