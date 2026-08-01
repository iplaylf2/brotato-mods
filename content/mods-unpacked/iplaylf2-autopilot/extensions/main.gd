extends "res://main.gd"

const MOD_ID := "iplaylf2-autopilot"
const ObservationService := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/observation/observation_service.gd"
)

var autopilot_observation_service: Node = null
var _autopilot_mod: Node = null


func _ready() -> void:
	._ready()

	_autopilot_mod = get_node_or_null("/root/ModLoader/%s" % MOD_ID)
	if not is_instance_valid(_autopilot_mod):
		ModLoaderLog.error("Mod entrypoint was not found.", MOD_ID)
		return

	var connect_error := _autopilot_mod.connect(
		"enabled_changed", self, "_on_autopilot_enabled_changed"
	)
	if connect_error != OK:
		ModLoaderLog.error("Could not observe the Autopilot setting.", MOD_ID)


func _on_EntitySpawner_players_spawned(players: Array) -> void:
	._on_EntitySpawner_players_spawned(players)
	_sync_autopilot_service(players)


func _on_autopilot_enabled_changed(_enabled: bool) -> void:
	_sync_autopilot_service(_players)


func _sync_autopilot_service(players: Array) -> void:
	if is_instance_valid(autopilot_observation_service):
		autopilot_observation_service.queue_free()
		autopilot_observation_service = null

	if not is_instance_valid(_autopilot_mod) or not _autopilot_mod.is_enabled() or players.empty():
		return

	autopilot_observation_service = ObservationService.new()
	autopilot_observation_service.name = "AutopilotObservationService"
	add_child(autopilot_observation_service)
	autopilot_observation_service.initialize(self, players)
