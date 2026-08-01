extends "res://main.gd"

const ObservationService := preload(
	"res://mods-unpacked/IPlayLF2-Autopilot/bot/observation/observation_service.gd"
)

var autopilot_observation_service: Node = null


func _on_EntitySpawner_players_spawned(players: Array) -> void:
	._on_EntitySpawner_players_spawned(players)

	if is_instance_valid(autopilot_observation_service):
		autopilot_observation_service.queue_free()

	autopilot_observation_service = ObservationService.new()
	autopilot_observation_service.name = "AutopilotObservationService"
	add_child(autopilot_observation_service)
	autopilot_observation_service.initialize(self, players)
