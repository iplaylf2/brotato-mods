extends Reference

# Models automatic weapons' nearest-target selection as a continuous spatial
# field. The exact nearest-target rule is deterministic, but observation and
# one-control-period movement have finite spatial resolution; a soft Voronoi
# boundary preserves that uncertainty without inventing target priorities.

const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)

var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_enemy_motion_predictor = predictor


func selection_likelihood_by_target(
	observation: Dictionary,
	player_displacement: Vector2,
	forecast_seconds: float,
	maximum_targeting_distance: float,
	transition_distance: float
) -> Dictionary:
	var result := {}
	if maximum_targeting_distance <= 0.0:
		return result
	_enemy_motion_predictor.begin_physics_frame(observation.get("physics_frame", -1))
	var candidates := []
	for track in observation.enemy_tracks:
		if not track.visible:
			continue
		var position: Vector2 = _enemy_motion_predictor.predict_position(
			track, forecast_seconds, player_displacement
		)
		_append_candidate(
			candidates,
			"enemy:%s" % track.track_id,
			(position - player_displacement).length(),
			maximum_targeting_distance,
			transition_distance
		)
	for tree in observation.get("remembered_entities", []):
		if tree.kind != "tree" or not tree.get("visible", false):
			continue
		_append_candidate(
			candidates,
			"tree:%s" % tree.memory_record_id,
			(tree.relative_position - player_displacement).length(),
			maximum_targeting_distance,
			transition_distance
		)
	if candidates.empty():
		return result
	candidates.sort_custom(self, "_nearer_candidate")
	var nearest: Dictionary = candidates[0]
	for candidate in candidates:
		var selection_likelihood: float = candidate.range_coverage
		if candidate != nearest:
			var signed_margin: float = nearest.distance - candidate.distance
			var dominance := _logistic(signed_margin / max(1.0, transition_distance))
			# A nearer target that is itself outside the lock boundary cannot
			# occlude an available farther target.
			selection_likelihood *= lerp(1.0, dominance, nearest.range_coverage)
		result[candidate.key] = selection_likelihood
	return result


func _append_candidate(
	candidates: Array,
	key: String,
	distance: float,
	maximum_targeting_distance: float,
	transition_distance: float
) -> void:
	var range_coverage := clamp(
		(maximum_targeting_distance - distance) / max(1.0, transition_distance), 0.0, 1.0
	)
	if range_coverage <= 0.0:
		return
	candidates.push_back({"key": key, "distance": distance, "range_coverage": range_coverage})


func _logistic(value: float) -> float:
	# Clamp before exp so extreme distance differences remain numerically stable.
	var bounded := clamp(value, -20.0, 20.0)
	return 1.0 / (1.0 + exp(-bounded))


func _nearer_candidate(left: Dictionary, right: Dictionary) -> bool:
	return left.distance < right.distance
