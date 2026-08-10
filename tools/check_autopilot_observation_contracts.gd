extends Reference

# Focused contracts for public observations and remembered-world evidence.

const OBSERVATION_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/observation/"

var _failed := false


func run() -> bool:
	_check_local_pickup_existence_evidence()
	_check_enemy_disposition_partition()
	_check_enemy_disposition_transition()
	return not _failed


func _check_local_pickup_existence_evidence() -> void:
	var estimator_script: Script = load(
		OBSERVATION_PATH + "remembered_entity_existence_estimator.gd"
	)
	var estimator: Reference = estimator_script.new()
	estimator.update(0.0, Vector2.ZERO, [])
	var record := {
		"odometry_position": Vector2(100.0, 0.0),
		"observation": {"kind": "consumable"},
	}
	var solo := {"living_teammate_player_indices": []}
	var geometry := {"collection_radius": 32.0, "attraction_radius": 150.0}
	var attracted: Dictionary = estimator.estimate(record, solo, geometry, {})
	_expect(
		(
			not attracted.absence_confirmed
			and is_equal_approx(attracted.disappearance_hazard_per_second, 0.0)
		),
		"the solo player's attraction radius must not imply probabilistic absence"
	)
	record.odometry_position = Vector2(20.0, 0.0)
	var collected: Dictionary = estimator.estimate(record, solo, geometry, {})
	_expect(collected.absence_confirmed, "the solo player's collection circle must prove absence")


func _check_enemy_disposition_partition() -> void:
	var observer: Reference = load(OBSERVATION_PATH + "visible_world_observer.gd").new(null, [])
	var hostile := Reference.new()
	var converted := Reference.new()
	var partition: Dictionary = observer.call(
		"_partition_enemy_nodes", [hostile, converted], [hostile]
	)
	_expect(
		partition.hostile == [hostile] and partition.allied == [converted],
		(
			"the vanilla attackable-enemy domain must remain hostile while converted "
			+ "enemies enter the allied-agent domain"
		)
	)


func _check_enemy_disposition_transition() -> void:
	var source := Reference.new()
	var memory: Reference = load(OBSERVATION_PATH + "observed_world_memory.gd").new()
	memory.set("_tracks", {1: {"source_id": source.get_instance_id()}})
	memory.call("_retire_non_hostile_source_tracks", [source])
	_expect(
		memory.get("_tracks").empty(),
		"a converted source must immediately retire its prior hostile track"
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot observation contract failed: %s" % message)
