extends Node

# Coordinates battle sampling on the main thread. This node owns sampling policy,
# control-source-specific admission, and the wave-scoped segment lifecycle.

const BattleSampleWriter := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/sampling/battle_sample_writer.gd"
)
const HUMAN_SAMPLE_INTERVAL_SECONDS := 1.0
const BOT_DECISIONS_PER_SAMPLE := 10

var _observation_service: Node = null
var _player_count := 0
var _battle_run_id := ""
var _control_source := ""
var _human_sample_elapsed_seconds := 0.0
var _decision_counts := []
var _sample_counts := []
var _decisions_until_sample := []
var _writer: Reference = BattleSampleWriter.new()
var _shut_down := false


func initialize(
	observation_service: Node, players: Array, battle_run_id: String, control_source: String
) -> void:
	_observation_service = observation_service
	_player_count = players.size()
	_battle_run_id = battle_run_id
	_control_source = control_source
	_start_segment()


func _physics_process(delta: float) -> void:
	if (
		_shut_down
		or _control_source != "human"
		or get_tree().paused
		or not is_instance_valid(_observation_service)
	):
		return
	_human_sample_elapsed_seconds += delta
	if _human_sample_elapsed_seconds < HUMAN_SAMPLE_INTERVAL_SECONDS:
		return
	_human_sample_elapsed_seconds = fmod(
		_human_sample_elapsed_seconds, HUMAN_SAMPLE_INTERVAL_SECONDS
	)
	for player_index in _player_count:
		var observation: Dictionary = _observation_service.get_planning_observation(player_index)
		if observation.empty() or observation.get("player_state", {}).get("dead", false):
			continue
		_sample_counts[player_index] += 1
		_writer.record_human_sample(player_index, _sample_counts[player_index], observation)


func record_bot_decision(
	player_index: int, observation: Dictionary, plan: Dictionary, previous_movement: Vector2
) -> void:
	if _shut_down or _control_source != "bot":
		return
	_decision_counts[player_index] += 1
	var should_sample: bool = _decisions_until_sample[player_index] <= 0
	if plan.get("status", "") != "ready":
		should_sample = true
	if not should_sample:
		_decisions_until_sample[player_index] -= 1
		return
	_decisions_until_sample[player_index] = BOT_DECISIONS_PER_SAMPLE - 1
	_sample_counts[player_index] += 1
	_writer.record_bot_sample(
		player_index,
		_decision_counts[player_index],
		_sample_counts[player_index],
		observation,
		plan,
		previous_movement
	)


func switch_to_human() -> void:
	if _shut_down or _control_source == "human":
		return
	_close_segment()
	_writer = BattleSampleWriter.new()
	_control_source = "human"
	_human_sample_elapsed_seconds = 0.0
	_start_segment()


func shutdown() -> void:
	if _shut_down:
		return
	_shut_down = true
	_close_segment()


func _exit_tree() -> void:
	shutdown()


func get_current_path() -> String:
	return _writer.get_current_path()


func _start_segment() -> void:
	_decision_counts.resize(_player_count)
	_sample_counts.resize(_player_count)
	_decisions_until_sample.resize(_player_count)
	for player_index in _player_count:
		_decision_counts[player_index] = 0
		_sample_counts[player_index] = 0
		_decisions_until_sample[player_index] = 0
	_writer.start(
		_player_count, _battle_run_id, RunData.current_wave, _control_source, _sampling_policy()
	)


func _sampling_policy() -> Dictionary:
	if _control_source == "bot":
		return {"decisions_per_sample": BOT_DECISIONS_PER_SAMPLE}
	return {"interval_seconds": HUMAN_SAMPLE_INTERVAL_SECONDS}


func _close_segment() -> void:
	_writer.close(_decision_counts, _sample_counts, _final_player_states())


func _final_player_states() -> Array:
	var result := []
	for player_index in _player_count:
		var observation: Dictionary = _observation_service.get_observation(player_index)
		var player_state: Dictionary = observation.get("player_state", {})
		if player_state.empty():
			result.push_back({"available": false})
			continue
		var health: Dictionary = player_state.get("health", {})
		result.push_back(
			{
				"available": true,
				"dead": player_state.get("dead", false),
				"health":
				{
					"current": health.get("current"),
					"maximum": health.get("maximum"),
				},
			}
		)
	return result
