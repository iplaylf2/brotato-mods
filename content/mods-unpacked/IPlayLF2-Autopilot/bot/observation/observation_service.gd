extends Node

# Public read boundary that coordinates current observations, battle memory,
# and player-owned state.

const BattleMemory := preload(
	"res://mods-unpacked/IPlayLF2-Autopilot/bot/knowledge/battle_memory.gd"
)
const PlayerStateObserver := preload(
	"res://mods-unpacked/IPlayLF2-Autopilot/bot/observation/player_state_observer.gd"
)
const VisibleWorldObserver := preload(
	"res://mods-unpacked/IPlayLF2-Autopilot/bot/observation/visible_world_observer.gd"
)

var _main: Node
var _players: Array = []
var _latest_observations: Array = []
var _last_player_positions: Array = []
var _battle_memories: Array = []
var _player_state_observer: Reference = PlayerStateObserver.new()
var _visible_world_observer: Reference


func initialize(main: Node, players: Array) -> void:
	_main = main
	_players = players
	_visible_world_observer = VisibleWorldObserver.new(main, players)
	_latest_observations.resize(players.size())
	_last_player_positions.clear()
	_battle_memories.clear()

	for player in players:
		_last_player_positions.push_back(player.global_position)
		_battle_memories.push_back(BattleMemory.new())


func _physics_process(delta: float) -> void:
	if not is_instance_valid(_main):
		return
	_capture_observations(delta)


# A duplicate prevents callers from mutating the stored observation.
func get_observation(player_index: int) -> Dictionary:
	if player_index < 0 or player_index >= _latest_observations.size():
		return {}
	var observation = _latest_observations[player_index]
	if typeof(observation) != TYPE_DICTIONARY:
		return {}
	return observation.duplicate(true)


func _capture_observations(delta: float) -> void:
	for player_index in _players.size():
		var player = _players[player_index]
		if not is_instance_valid(player):
			_latest_observations[player_index] = {}
			continue

		_latest_observations[player_index] = _build_observation(player_index, player, delta)


func _build_observation(player_index: int, player: Node2D, delta: float) -> Dictionary:
	var motion_delta: Vector2 = player.global_position - _last_player_positions[player_index]
	_last_player_positions[player_index] = player.global_position

	var world_observation: Dictionary = _visible_world_observer.observe(player_index, player)
	var battle_memory: Reference = _battle_memories[player_index]
	battle_memory.update(
		delta, motion_delta, world_observation.visible_edges, world_observation.enemy_observations
	)

	return {
		"physics_frame": Engine.get_physics_frames(),
		"player_state": _player_state_observer.observe(player_index, player),
		"localization": battle_memory.get_localization_state(),
		"enemy_tracks": battle_memory.get_enemy_tracks(),
		"visibility": world_observation.visibility,
		"visible_world": world_observation.visible_world,
	}
