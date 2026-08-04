extends Reference

# Predicts an enemy track from observed motion and stable position-response
# mechanics. Vanilla target-following movement recomputes its normalized heading
# every physics tick, so known pursuit is integrated as a position response
# instead of extrapolating the currently observed heading through the player.

const ObservedMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/observed_motion_predictor.gd"
)

const MAXIMUM_INTEGRATION_STEP_SECONDS := 0.4
const MINIMUM_INTEGRATION_STEP_SECONDS := 0.0125
const INTEGRATION_POSITION_ERROR_TOLERANCE := 1.0

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
	# used by the rolling planner. Embedded midpoint step doubling follows
	# vanilla's immediate heading updates with an explicit position-error bound and
	# prevents a pursuer from being projected through the old target position.
	var enemy_position := initial_enemy_position
	var elapsed := 0.0
	var step_seconds := min(MAXIMUM_INTEGRATION_STEP_SECONDS, time)
	while elapsed < time - 0.00001:
		step_seconds = min(step_seconds, time - elapsed)
		var full_step_position := _integrate_midpoint_step(
			enemy_position,
			player_displacement,
			time,
			elapsed,
			step_seconds,
			movement_speed,
			target_response
		)
		var half_step_seconds := step_seconds * 0.5
		var refined_position := _integrate_midpoint_step(
			enemy_position,
			player_displacement,
			time,
			elapsed,
			half_step_seconds,
			movement_speed,
			target_response
		)
		refined_position = _integrate_midpoint_step(
			refined_position,
			player_displacement,
			time,
			elapsed + half_step_seconds,
			half_step_seconds,
			movement_speed,
			target_response
		)
		var estimated_error: float = full_step_position.distance_to(refined_position)
		if (
			estimated_error > INTEGRATION_POSITION_ERROR_TOLERANCE
			and step_seconds > MINIMUM_INTEGRATION_STEP_SECONDS + 0.00001
		):
			step_seconds = max(MINIMUM_INTEGRATION_STEP_SECONDS, half_step_seconds)
			continue
		enemy_position = refined_position
		elapsed += step_seconds
		if estimated_error < INTEGRATION_POSITION_ERROR_TOLERANCE * 0.25:
			step_seconds = min(MAXIMUM_INTEGRATION_STEP_SECONDS, step_seconds * 2.0)
	return enemy_position


func _integrate_midpoint_step(
	enemy_position: Vector2,
	player_displacement: Vector2,
	total_seconds: float,
	elapsed_seconds: float,
	step_seconds: float,
	movement_speed: float,
	target_response: Dictionary
) -> Vector2:
	var player_position: Vector2 = player_displacement * elapsed_seconds / total_seconds
	var initial_velocity := _target_directed_velocity(
		enemy_position, player_position, movement_speed, target_response
	)
	var midpoint_player_position: Vector2 = (
		player_displacement
		* (elapsed_seconds + step_seconds * 0.5)
		/ total_seconds
	)
	var midpoint_enemy_position: Vector2 = enemy_position + initial_velocity * step_seconds * 0.5
	var midpoint_velocity := _target_directed_velocity(
		midpoint_enemy_position, midpoint_player_position, movement_speed, target_response
	)
	# Landing on or crossing the response surface during the trial step means the
	# initial velocity is the interval average up to that surface; using the
	# reversed midpoint direction would spuriously bounce through the target.
	if (
		midpoint_velocity == Vector2.ZERO
		or (initial_velocity != Vector2.ZERO and midpoint_velocity.dot(initial_velocity) < 0.0)
	):
		midpoint_velocity = initial_velocity
	var displacement: Vector2 = midpoint_velocity * step_seconds
	var terminal_player_position: Vector2 = (
		player_displacement
		* (elapsed_seconds + step_seconds)
		/ total_seconds
	)
	var target_offset: Vector2 = terminal_player_position - enemy_position
	var preferred_distance: float = target_response.preferred_distance
	var distance_to_target_position := abs(target_offset.length() - preferred_distance)
	if displacement.length() > distance_to_target_position:
		displacement = displacement.normalized() * distance_to_target_position
	var result: Vector2 = enemy_position + displacement
	var terminal_offset: Vector2 = result - terminal_player_position
	if (
		abs(terminal_offset.length() - preferred_distance) <= INTEGRATION_POSITION_ERROR_TOLERANCE
		and (
			terminal_offset.length() >= preferred_distance
			or target_response.moves_away_inside_preferred_distance
		)
	):
		result = terminal_player_position + terminal_offset.normalized() * preferred_distance
	return result


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
