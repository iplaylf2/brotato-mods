extends Reference

# Predicts an enemy track from observed motion and stable position-response
# mechanics. The observed forecast remains the baseline; mechanics contribute
# only the candidate-vs-stationary response caused by player movement.

const ObservedMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/observed_motion_predictor.gd"
)

var _observed_motion_predictor: Reference = ObservedMotionPredictor.new()


func predict_position(
	track: Dictionary, time: float, player_displacement: Vector2 = Vector2.ZERO
) -> Vector2:
	var observed_position: Vector2 = _observed_motion_predictor.predict_position(
		track.relative_position,
		track.estimated_velocity,
		track.estimated_acceleration,
		track.motion_confidence,
		time
	)
	var target_response: Dictionary = track.behavior_profile.get("target_position_response", {})
	if not target_response.get("responds_to_target_position", false) or time <= 0.0:
		return observed_position
	var charge_attack: Dictionary = track.behavior_profile.get("charge_attack", {})
	var baseline_movement_speed: float = max(0.0, target_response.get("movement_speed", 0.0))
	# Vanilla locks the heading during a high-speed charge. Visible velocity is
	# then more authoritative than ordinary target-position response.
	if (
		charge_attack.get("active", false)
		and baseline_movement_speed > 0.0
		and track.estimated_velocity.length() > baseline_movement_speed * 1.5
	):
		return observed_position
	var movement_speed: float = max(baseline_movement_speed, track.estimated_velocity.length())
	if movement_speed <= 0.0:
		return observed_position
	var stationary_velocity := _target_directed_velocity(
		track.relative_position, Vector2.ZERO, movement_speed, target_response
	)
	var candidate_velocity := _target_directed_velocity(
		track.relative_position, player_displacement, movement_speed, target_response
	)
	var response_seconds: float = max(
		1.0 / 60.0, track.last_measurement.get("visual_radius", 1.0) / movement_speed
	)
	var response_displacement: float = (
		max(0.0, time)
		- response_seconds * (1.0 - exp(-max(0.0, time) / response_seconds))
	)
	return (
		observed_position
		+ (
			(candidate_velocity - stationary_velocity)
			* response_displacement
			* clamp(target_response.get("confidence", 0.0), 0.0, 1.0)
		)
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
	var preferred_distance: float = max(0.0, target_response.get("preferred_distance", 0.0))
	if abs(distance - preferred_distance) <= 1.0:
		return Vector2.ZERO
	return (
		-from_player.normalized() * movement_speed
		if distance > preferred_distance
		else from_player.normalized() * movement_speed
	)
