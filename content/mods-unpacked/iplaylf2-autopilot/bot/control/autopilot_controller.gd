extends Node

signal control_released

# Closes the observation -> hierarchical planning -> movement-input loop. A fast
# tactical worker evaluates executable movement from fresh observations while a
# slower strategic worker refreshes long-horizon navigation guidance. Neither
# worker can block the other's mailbox or mutable model graph.

const MOD_ID := "iplaylf2-autopilot"
const AutopilotMovementBehavior := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/control/autopilot_movement_behavior.gd"
)
const PlanningTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/planning_timing_model.gd"
)
const PhysicsFrameBudgetMonitor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/control/physics_frame_budget_monitor.gd"
)
const PlanningWorker := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/control/planning_worker.gd"
)
const TacticalMovementPlanner := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/tactical_movement_planner.gd"
)
const StrategicNavigationPlanner := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/strategic_navigation_planner.gd"
)
const TACTICAL_PLANNING_CAPACITY_SHARE := 0.8
const STRATEGIC_PLANNING_CAPACITY_SHARE := 0.2
var _observation_service: Node
var _players: Array = []
var _actuators: Array = []
var _original_movement_behaviors: Array = []
var _current_tactical_plans: Array = []
var _strategic_navigation_guidance: Array = []
var _previous_movements: Array = []
var _battle_sample_recorder: Node = null
var _physics_frame_budget_monitor: Reference = PhysicsFrameBudgetMonitor.new()
var _tactical_worker: Reference = PlanningWorker.new()
var _strategic_worker: Reference = PlanningWorker.new()
var _shut_down := false
var _tactical_control_interval_seconds := 0.0
var _strategic_guidance_interval_seconds := 0.0
var _tactical_control_physics_ticks := 1
var _strategic_guidance_interval_ticks := 1
var _next_tactical_control_physics_frame := 0
var _next_strategic_guidance_physics_frame := 0


func initialize(observation_service: Node, players: Array) -> bool:
	var timing_model := PlanningTimingModel
	_tactical_control_interval_seconds = timing_model.tactical_control_interval_seconds()
	_strategic_guidance_interval_seconds = timing_model.strategic_guidance_interval_seconds()
	_tactical_control_physics_ticks = timing_model.TACTICAL_CONTROL_PHYSICS_TICKS
	_strategic_guidance_interval_ticks = timing_model.strategic_guidance_interval_physics_ticks()
	_next_tactical_control_physics_frame = int(Engine.get_physics_frames())
	_next_strategic_guidance_physics_frame = int(Engine.get_physics_frames())
	_observation_service = observation_service
	_players = players
	if not _tactical_worker.start(players.size(), TacticalMovementPlanner):
		ModLoaderLog.error(
			"Could not start the tactical planning worker; Autopilot will not take control.", MOD_ID
		)
		_shut_down = true
		return false
	if not _strategic_worker.start(players.size(), StrategicNavigationPlanner):
		ModLoaderLog.error(
			"Could not start the strategic planning worker; Autopilot will not take control.",
			MOD_ID
		)
		_tactical_worker.shutdown()
		_shut_down = true
		return false
	for player in players:
		var actuator := AutopilotMovementBehavior.new()
		add_child(actuator)
		_actuators.push_back(actuator)
		_original_movement_behaviors.push_back(player._current_movement_behavior)
		_current_tactical_plans.push_back({})
		_strategic_navigation_guidance.push_back({})
		_previous_movements.push_back(Vector2.ZERO)
		player._current_movement_behavior = actuator
	return true


func set_battle_sample_recorder(recorder: Node) -> void:
	_battle_sample_recorder = recorder


func _physics_process(delta: float) -> void:
	if _shut_down or get_tree().paused or not is_instance_valid(_observation_service):
		return

	_physics_frame_budget_monitor.observe_physics_duration(delta)
	_collect_tactical_plans()
	_collect_strategic_navigation_guidance()
	var physics_frame := int(Engine.get_physics_frames())
	# Tactical scheduling is evaluated first and owns most background capacity.
	# A busy worker skips obsolete releases and accepts a fresh snapshot as soon as
	# it becomes idle; work duration is never added to the nominal cadence.
	if physics_frame >= _next_tactical_control_physics_frame and not _tactical_worker.is_busy():
		_request_tactical_plan(physics_frame)
	if physics_frame >= _next_strategic_guidance_physics_frame and not _strategic_worker.is_busy():
		_request_strategic_navigation_guidance(physics_frame)


func shutdown() -> void:
	if _shut_down:
		return
	_shut_down = true
	_tactical_worker.shutdown()
	_strategic_worker.shutdown()
	for player_index in _players.size():
		var player: Node = _players[player_index]
		var actuator: Node = _actuators[player_index]
		actuator.set_movement(Vector2.ZERO)
		if is_instance_valid(player) and player._current_movement_behavior == actuator:
			player._current_movement_behavior = _original_movement_behaviors[player_index]


func _exit_tree() -> void:
	shutdown()


func get_current_plan(player_index: int) -> Dictionary:
	if player_index < 0 or player_index >= _current_tactical_plans.size():
		return {}
	return _current_tactical_plans[player_index].duplicate(true)


func _request_tactical_plan(physics_frame: int) -> void:
	var scheduled_planner_count := _living_player_count()
	if scheduled_planner_count <= 0:
		return
	var frame_budget_context: Dictionary = _physics_frame_budget_monitor.build_context(
		scheduled_planner_count,
		_tactical_control_interval_seconds,
		TACTICAL_PLANNING_CAPACITY_SHARE
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
				"strategic_navigation_guidance":
				_fresh_strategic_navigation_guidance(
					player_index, int(observation.get("physics_frame", -1))
				),
			}
		)
	if _tactical_worker.submit(requests):
		_next_tactical_control_physics_frame = physics_frame + _tactical_control_physics_ticks
	else:
		_release_control_after_worker_failure("tactical")


func _request_strategic_navigation_guidance(physics_frame: int) -> void:
	var scheduled_planner_count := _living_player_count()
	if scheduled_planner_count <= 0:
		return
	var frame_budget_context: Dictionary = _physics_frame_budget_monitor.build_context(
		scheduled_planner_count,
		_strategic_guidance_interval_seconds,
		STRATEGIC_PLANNING_CAPACITY_SHARE
	)
	var requests := []
	var request_created_usec := OS.get_ticks_usec()
	for player_index in _players.size():
		var player: Node = _players[player_index]
		if not is_instance_valid(player) or player.dead:
			continue
		requests.push_back(
			{
				"player_index": player_index,
				"observation": _observation_service.get_planning_observation(player_index),
				"active_movement": _previous_movements[player_index],
				"request_created_usec": request_created_usec,
				"frame_budget_context": frame_budget_context,
			}
		)
	if _strategic_worker.submit(requests):
		_next_strategic_guidance_physics_frame = (
			physics_frame
			+ _strategic_guidance_interval_ticks
		)
	else:
		_release_control_after_worker_failure("strategic")


func _collect_tactical_plans() -> void:
	var completion: Dictionary = _tactical_worker.poll()
	if not completion.ready:
		return
	_apply_tactical_plans(completion.results)


func _collect_strategic_navigation_guidance() -> void:
	var completion: Dictionary = _strategic_worker.poll()
	if not completion.ready:
		return
	for result in completion.results:
		var player_index: int = result.player_index
		if player_index < 0 or player_index >= _strategic_navigation_guidance.size():
			continue
		var guidance: Dictionary = result.output
		if guidance.get("status", "") == "ready":
			var compute_budget: Dictionary = guidance.get("compute_budget", {})
			if compute_budget.has("planning_started_usec"):
				compute_budget.planning_turnaround_usec = max(
					0, OS.get_ticks_usec() - int(compute_budget.planning_started_usec)
				)
			_strategic_navigation_guidance[player_index] = guidance


func _fresh_strategic_navigation_guidance(player_index: int, observation_frame: int) -> Dictionary:
	var guidance: Dictionary = _strategic_navigation_guidance[player_index]
	if guidance.get("status", "") != "ready":
		return {}
	var age := observation_frame - int(guidance.get("source_physics_frame", -1))
	if age < 0 or age > PlanningTimingModel.strategic_guidance_max_age_physics_ticks():
		return {}
	# Each worker receives exclusive ownership of its Variant graph. The controller
	# may replace the held guidance while tactical evaluation is still running.
	return guidance.duplicate(true)


func _living_player_count() -> int:
	var result := 0
	for player in _players:
		if is_instance_valid(player) and not player.dead:
			result += 1
	return result


func _release_control_after_worker_failure(worker_kind: String) -> void:
	ModLoaderLog.error(
		(
			"The %s planning worker rejected a request; Autopilot is releasing movement control."
			% worker_kind
		),
		MOD_ID
	)
	var recorder := _battle_sample_recorder
	shutdown()
	if is_instance_valid(recorder):
		recorder.switch_to_human()
	emit_signal("control_released")


func _apply_tactical_plans(results: Array) -> void:
	for result in results:
		var player_index: int = result.player_index
		var player: Node = _players[player_index]
		if not is_instance_valid(player) or player.dead:
			continue
		var observation: Dictionary = result.observation
		var plan: Dictionary = result.output
		var compute_budget: Dictionary = plan.get("compute_budget", {})
		if compute_budget.has("planning_started_usec"):
			compute_budget.planning_turnaround_usec = max(
				0, OS.get_ticks_usec() - int(compute_budget.planning_started_usec)
			)
		_current_tactical_plans[player_index] = plan
		if is_instance_valid(_battle_sample_recorder):
			_battle_sample_recorder.record_bot_decision(
				player_index, observation, plan, _previous_movements[player_index]
			)
		var movement: Vector2 = plan.movement
		_actuators[player_index].set_movement(movement)
		_previous_movements[player_index] = movement
