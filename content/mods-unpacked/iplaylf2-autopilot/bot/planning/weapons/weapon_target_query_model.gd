extends Reference

# Builds and queries one candidate-relative target snapshot for a weapon event
# horizon. A conservative distance bound is the broad phase; exact motion
# prediction is the narrow phase. Target selection probabilities, event geometry,
# and damage semantics remain with WeaponAttackPredictor.

const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)

var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()


func build_snapshot(
	observation: Dictionary, player_displacement: Vector2, time: float, query_radius: float
) -> Dictionary:
	_enemy_motion_predictor.begin_physics_frame(observation.get("physics_frame", -1))
	var targets := []
	var visible_enemy_count := 0
	for track in observation.enemy_tracks:
		if not track.visible:
			continue
		visible_enemy_count += 1
		var radius: float = track.last_measurement.visual_radius
		if not _can_enter_query_radius(track, player_displacement, time, query_radius, radius):
			continue
		var position: Vector2 = (
			_enemy_motion_predictor.predict_position(track, time, player_displacement)
			- player_displacement
		)
		if position.length() - radius > query_radius:
			continue
		var maximum_health: float = max(
			1.0, float(track.behavior_profile.durability.maximum_health)
		)
		targets.push_back(
			{
				"kind": "enemy",
				"track_id": track.track_id,
				"position": position,
				"distance_squared": position.length_squared(),
				"radius": radius,
				"maximum_health": maximum_health,
			}
		)
	for tree_index in observation.visible_world.trees.size():
		var tree: Dictionary = observation.visible_world.trees[tree_index]
		var position: Vector2 = tree.relative_position - player_displacement
		var radius: float = tree.get("visual_radius", 0.0)
		if position.length() - radius > query_radius:
			continue
		targets.push_back(
			{
				"kind": "tree",
				"track_id": "tree_%s" % tree_index,
				"tree_index": tree_index,
				"position": position,
				"distance_squared": position.length_squared(),
				"radius": radius,
				"maximum_health": 1.0,
				"required_hits":
				max(
					1.0,
					tree.get("destructible_profile", {}).get("destruction", {}).get(
						"required_hits", 1.0
					)
				),
			}
		)
	targets.sort_custom(self, "_nearer_target")
	return {
		"targets": targets,
		"query_radius": query_radius,
		"visible_enemy_count": visible_enemy_count,
	}


func nearest_target_in_targeting_range(
	snapshot: Dictionary, minimum_distance: float, maximum_distance: float
) -> Dictionary:
	var minimum_squared: float = minimum_distance * minimum_distance
	var maximum_squared: float = maximum_distance * maximum_distance
	for target in snapshot.targets:
		if target.distance_squared > maximum_squared:
			break
		if target.distance_squared >= minimum_squared:
			return target
	return {}


func enemy_targets_in_radius(
	snapshot: Dictionary, anchor: Vector2, radius: float, excluded_track_id = null
) -> Array:
	var result := []
	for target in snapshot.targets:
		if target.kind != "enemy" or target.track_id == excluded_track_id:
			continue
		var combined_radius: float = max(0.0, radius) + target.radius
		if target.position.distance_squared_to(anchor) <= combined_radius * combined_radius:
			result.push_back(target)
	return result


func enemy_targets(snapshot: Dictionary, excluded_track_id = null) -> Array:
	var result := []
	for target in snapshot.targets:
		if target.kind == "enemy" and target.track_id != excluded_track_id:
			result.push_back(target)
	return result


func _can_enter_query_radius(
	track: Dictionary,
	player_displacement: Vector2,
	time: float,
	query_radius: float,
	target_radius: float
) -> bool:
	var target_response: Dictionary = track.behavior_profile.get("target_position_response", {})
	var possible_speed: float = max(
		track.estimated_velocity.length(), max(0.0, target_response.get("movement_speed", 0.0))
	)
	var charge_attack: Dictionary = track.behavior_profile.get("charge_attack", {})
	if charge_attack.get("active", false):
		possible_speed = max(
			possible_speed, max(0.0, charge_attack.get("maximum_charge_speed", 0.0))
		)
	var motion_bound: float = (
		possible_speed * max(0.0, time)
		+ (
			0.5
			* track.estimated_acceleration.length()
			* clamp(track.motion_confidence, 0.0, 1.0)
			* time
			* time
		)
		+ track.uncertainty_radius
	)
	return (
		(track.relative_position - player_displacement).length() - motion_bound - target_radius
		<= query_radius
	)


func _nearer_target(left: Dictionary, right: Dictionary) -> bool:
	return left.distance_squared < right.distance_squared
