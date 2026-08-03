extends Reference

# Predicts an enemy track from observed motion and stable position-response
# mechanics. Vanilla target-following movement recomputes its normalized heading
# every physics tick, so known pursuit is integrated as a position response
# instead of extrapolating the currently observed heading through the player.

const ObservedMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/observed_motion_predictor.gd"
)

var _observed_motion_predictor: Reference = ObservedMotionPredictor.new()
var _baseline_cache_physics_frame := -1
var _observed_positions_by_track_and_time := {}


func begin_physics_frame(physics_frame: int) -> void:
	if physics_frame >= 0 and physics_frame == _baseline_cache_physics_frame:
		return
	_baseline_cache_physics_frame = physics_frame
	_observed_positions_by_track_and_time.clear()


func predict_position(
	track: Dictionary, time: float, player_displacement: Vector2 = Vector2.ZERO
) -> Vector2:
	var target_response: Dictionary = track.behavior_profile.get("target_position_response", {})
	if not target_response.get("responds_to_target_position", false) or time <= 0.0:
		return _observed_position(track, time)
	var charge_attack: Dictionary = track.behavior_profile.get("charge_attack", {})
	var baseline_movement_speed: float = target_response.movement_speed
	# Vanilla locks the heading during a high-speed charge. Visible velocity is
	# then more authoritative than ordinary target-position response.
	var maximum_charge_speed: float = charge_attack.get(
		"maximum_charge_speed", baseline_movement_speed
	)
	var charge_speed_threshold := (baseline_movement_speed + maximum_charge_speed) * 0.5
	if (
		charge_attack.get("active", false)
		and baseline_movement_speed > 0.0
		and track.estimated_velocity.length() > charge_speed_threshold
	):
		return _observed_position(track, time)
	var movement_speed: float = max(baseline_movement_speed, track.estimated_velocity.length())
	if movement_speed <= 0.0:
		return _observed_position(track, time)
	var mechanic_position := _integrate_target_response(
		track.relative_position, player_displacement, time, movement_speed, target_response
	)
	return _observed_position(track, time).linear_interpolate(
		mechanic_position, clamp(target_response.get("confidence", 0.0), 0.0, 1.0)
	)


func _integrate_target_response(
	initial_enemy_position: Vector2,
	player_displacement: Vector2,
	time: float,
	movement_speed: float,
	target_response: Dictionary
) -> Vector2:
	# The observed contract does not expose a future player path. Candidate
	# movement is first-order, so its endpoint uniquely defines the straight path
	# used by the rolling planner. Short substeps approximate vanilla's immediate
	# heading updates and prevent a pursuer from being projected through and away
	# from the player after reaching the old target position.
	var step_count := int(ceil(time / 0.05))
	var step_seconds: float = time / float(step_count)
	var enemy_position := initial_enemy_position
	for step_index in step_count:
		var player_position: Vector2 = (
			player_displacement
			* float(step_index + 1)
			/ float(step_count)
		)
		var velocity := _target_directed_velocity(
			enemy_position, player_position, movement_speed, target_response
		)
		var displacement: Vector2 = velocity * step_seconds
		var target_offset: Vector2 = player_position - enemy_position
		var preferred_distance: float = target_response.preferred_distance
		var distance_to_target_position := abs(target_offset.length() - preferred_distance)
		if displacement.length() > distance_to_target_position:
			displacement = displacement.normalized() * distance_to_target_position
		enemy_position += displacement
	return enemy_position


func _observed_position(track: Dictionary, time: float) -> Vector2:
	var track_id: int = track.get("track_id", -1)
	if track_id >= 0:
		var positions_by_time: Dictionary = _observed_positions_by_track_and_time.get(track_id, {})
		if positions_by_time.has(time):
			return positions_by_time[time]
		var position: Vector2 = _predict_observed_position(track, time)
		positions_by_time[time] = position
		_observed_positions_by_track_and_time[track_id] = positions_by_time
		return position
	return _predict_observed_position(track, time)


func _predict_observed_position(track: Dictionary, time: float) -> Vector2:
	return _observed_motion_predictor.predict_position(
		track.relative_position,
		track.estimated_velocity,
		track.estimated_acceleration,
		track.motion_confidence,
		time
	)


func _target_directed_velocity(
	enemy_position: Vector2,
	player_position: Vector2,
	movement_speed: float,
	target_response: Dictionary
) -> Vector2:
	var from_player: Vector2 = enemy_position - player_position
	var distance: float = from_player.length()
	if distance <= 0.0:
		return Vector2.ZERO
	var preferred_distance: float = target_response.preferred_distance
	if abs(distance - preferred_distance) <= 1.0:
		return Vector2.ZERO
	if distance > preferred_distance:
		return -from_player.normalized() * movement_speed
	if target_response.moves_away_inside_preferred_distance:
		return from_player.normalized() * movement_speed
	return Vector2.ZERO
