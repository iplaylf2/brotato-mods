extends Node

# Public read boundary that coordinates current observations, observed-world
# memory, and player-owned state.

const ObservedWorldMemory := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/observation/observed_world_memory.gd"
)
const PlayerStateObserver := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/observation/player_state_observer.gd"
)
const VisibleWorldObserver := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/observation/visible_world_observer.gd"
)

var _main: Node
var _players: Array = []
var _latest_observations: Array = []
var _last_player_positions: Array = []
var _world_memories: Array = []
var _player_state_observer: Reference = PlayerStateObserver.new()
var _visible_world_observer: Reference


func initialize(main: Node, players: Array) -> void:
	_main = main
	_players = players
	_visible_world_observer = VisibleWorldObserver.new(main, players)
	_latest_observations.resize(players.size())
	_last_player_positions.clear()
	_world_memories.clear()

	for player in players:
		_last_player_positions.push_back(player.global_position)
		_world_memories.push_back(ObservedWorldMemory.new())


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_main):
		return
	_capture_observations(delta)


# A duplicate prevents callers from mutating the stored observation.
func get_observation(player_index: int) -> Dictionary:
	if player_index < 0 or player_index >= _latest_observations.size():
		return {}
	if typeof(_latest_observations[player_index]) != TYPE_DICTIONARY:
		return {}
	var observation: Dictionary = _latest_observations[player_index]
	return observation.duplicate(true)


func _capture_observations(delta: float) -> void:
	for player_index in _players.size():
		var player: Node2D = _players[player_index]
		if not is_instance_valid(player):
			_latest_observations[player_index] = {}
			continue

		_latest_observations[player_index] = _build_observation(player_index, player, delta)


func _build_observation(player_index: int, player: Node2D, delta: float) -> Dictionary:
	var position_delta: Vector2 = player.global_position - _last_player_positions[player_index]
	_last_player_positions[player_index] = player.global_position

	var world_observation: Dictionary = _visible_world_observer.observe(player_index, player, delta)
	var world_memory: Reference = _world_memories[player_index]
	var party_state: Dictionary = _get_party_state(player_index)
	var player_state: Dictionary = _player_state_observer.observe(player_index, player)
	world_memory.update(
		delta,
		position_delta,
		world_observation.visible_edges,
		world_observation.enemy_observations,
		world_observation.entity_memory_observations,
		party_state,
		world_observation.visible_world.allied_agents,
		player_state.pickup,
		world_observation.visibility
	)

	return {
		"physics_frame": Engine.get_physics_frames(),
		"wave_state": _get_wave_state(),
		"player_state": player_state,
		"party_state": party_state,
		"localization": world_memory.get_localization_state(),
		"enemy_tracks": world_memory.get_enemy_tracks(),
		"remembered_entities": world_memory.get_remembered_entities(),
		"visibility": world_observation.visibility,
		"visible_world": world_observation.visible_world,
	}


func _get_party_state(player_index: int) -> Dictionary:
	var teammate_count := 0
	var living_teammate_count := 0
	var living_teammate_player_indices := []
	for index in _players.size():
		if index == player_index:
			continue
		teammate_count += 1
		var teammate: Node2D = _players[index]
		if is_instance_valid(teammate) and not teammate.dead:
			living_teammate_count += 1
			living_teammate_player_indices.push_back(index)
	return {
		"teammate_count": teammate_count,
		"living_teammate_count": living_teammate_count,
		"living_teammate_player_indices": living_teammate_player_indices,
	}


func _get_wave_state() -> Dictionary:
	var timer: Timer = _main._wave_timer
	return {
		"number": RunData.current_wave,
		"final_number": RunData.nb_of_waves,
		"endless": RunData.is_endless_run,
		"seconds_remaining": timer.time_left,
		"duration_seconds": timer.wait_time,
	}
