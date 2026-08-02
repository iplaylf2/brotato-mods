extends "res://main.gd"

const MOD_ID := "iplaylf2-autopilot"
const ObservationService := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/observation/observation_service.gd"
)
const AutopilotController := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/control/autopilot_controller.gd"
)

var autopilot_observation_service: Node = null
var autopilot_controller: Node = null
var _autopilot_mod: Node = null


func _ready() -> void:
	# The installed script-extension chain already runs the base Main._ready().
	# Calling it here would repeat vanilla initialization and signal connections.
	_autopilot_mod = get_node_or_null("/root/ModLoader/%s" % MOD_ID)
	if not is_instance_valid(_autopilot_mod):
		ModLoaderLog.error("Autopilot mod entrypoint was not found; Autopilot is disabled.", MOD_ID)
		return

	var connect_error: int = _autopilot_mod.connect(
		"enabled_changed", self, "_on_autopilot_enabled_changed"
	)
	if connect_error != OK:
		ModLoaderLog.error("Could not subscribe to Autopilot enable-state changes.", MOD_ID)

	# Vanilla spawns the players from Main._ready(). Depending on script-extension
	# notification order, its players_spawned signal can arrive before this
	# extension is ready. Reconcile once the complete ready chain has finished.
	call_deferred("_start_autopilot_runtime_if_needed")


func _on_EntitySpawner_players_spawned(players: Array) -> void:
	._on_EntitySpawner_players_spawned(players)
	_sync_autopilot_runtime(players)


func clean_up_room() -> void:
	# Vanilla frees combat containers during cleanup. Stop observation and planning
	# first so no later physics tick can traverse nodes queued for deletion.
	_stop_autopilot_runtime()
	.clean_up_room()


func _on_autopilot_enabled_changed(_enabled: bool) -> void:
	_sync_autopilot_runtime(_players)


func _start_autopilot_runtime_if_needed() -> void:
	if is_instance_valid(autopilot_controller):
		return
	_sync_autopilot_runtime(_players)


func _sync_autopilot_runtime(players: Array) -> void:
	_stop_autopilot_runtime()

	if not is_instance_valid(_autopilot_mod) or not _autopilot_mod.is_enabled() or players.empty():
		return

	autopilot_observation_service = ObservationService.new()
	autopilot_observation_service.name = "AutopilotObservationService"
	add_child(autopilot_observation_service)
	autopilot_observation_service.initialize(self, players)

	autopilot_controller = AutopilotController.new()
	autopilot_controller.name = "AutopilotController"
	add_child(autopilot_controller)
	autopilot_controller.initialize(autopilot_observation_service, players)


func _stop_autopilot_runtime() -> void:
	if is_instance_valid(autopilot_controller):
		autopilot_controller.shutdown()
		autopilot_controller.queue_free()
		autopilot_controller = null

	if is_instance_valid(autopilot_observation_service):
		autopilot_observation_service.queue_free()
		autopilot_observation_service = null
