extends Reference

# Focused contracts for public observations and remembered-world evidence.

const OBSERVATION_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/observation/"

var _failed := false


func run() -> bool:
	_check_local_pickup_existence_evidence()
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


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot observation contract failed: %s" % message)
