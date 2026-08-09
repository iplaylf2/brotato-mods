extends Reference

# Collision evidence for motion whose future realization is not yet resolved:
# independently controlled allied players and prospective charge target
# distributions. Entities with a supported trajectory belong exclusively to
# BattlefieldInfluenceModel's swept path projection.

const PlayerKinematicsModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_kinematics_model.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const PlanningTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/planning_timing_model.gd"
)
const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)

var _player_kinematics: Reference = PlayerKinematicsModel.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_enemy_motion_predictor = predictor


func evaluate(observation: Dictionary, action: Dictionary, committed_seconds: float) -> Dictionary:
	_enemy_motion_predictor.begin_physics_frame(observation.get("physics_frame", -1))
	var geometry: Dictionary = _movement_geometry.derive(observation)
	var timing: Dictionary = PlanningTimingModel.derive(observation)
	var local_horizon_seconds: float = timing.effective_local_horizon_seconds
	var navigation_horizon_seconds: float = timing.effective_navigation_horizon_seconds
	var player_velocity: Vector2 = _player_kinematics.predict_average_velocity(
		observation, action.movement, max(0.01, local_horizon_seconds)
	)
	var enemy_charge_risk := 0.0
	var forecast_enemy_charge_risk := 0.0
	var committed_enemy_charge_risk := 0.0
	var ally_risk := 0.0
	var maximum_collision_raw_damage := 0.0
	var forecast_maximum_collision_raw_damage := 0.0
	var committed_maximum_collision_raw_damage := 0.0
	var forecast_hostile_contact_evidence_sum := 0.0
	var forecast_hostile_raw_damage_evidence_sum := 0.0
	var committed_hostile_contact_evidence_sum := 0.0
	var committed_hostile_raw_damage_evidence_sum := 0.0
	var minimum_ally_ttc := INF

	for track in observation.enemy_tracks:
		var charge_attack: Dictionary = track.behavior_profile.get("charge_attack", {})
		if not _has_player_region_charge(charge_attack):
			continue
		if _charge_is_already_observed_in_motion(track, charge_attack):
			continue
		var track_charge_risk := 0.0
		var forecast_track_charge_risk := 0.0
		var committed_track_charge_risk := 0.0
		for sample in action.samples:
			var sample_charge: Dictionary = _charge_collision_risk(
				track,
				player_velocity,
				sample.displacement,
				sample.time,
				geometry,
				navigation_horizon_seconds,
				action.forecast_seconds,
				committed_seconds
			)
			track_charge_risk = max(track_charge_risk, sample_charge.navigation)
			forecast_track_charge_risk = max(forecast_track_charge_risk, sample_charge.forecast)
			committed_track_charge_risk = max(committed_track_charge_risk, sample_charge.committed)
		enemy_charge_risk += track_charge_risk
		forecast_enemy_charge_risk += forecast_track_charge_risk
		committed_enemy_charge_risk += committed_track_charge_risk
		forecast_hostile_contact_evidence_sum += forecast_track_charge_risk
		forecast_hostile_raw_damage_evidence_sum += (
			forecast_track_charge_risk
			* track.behavior_profile.contact_damage
		)
		committed_hostile_contact_evidence_sum += committed_track_charge_risk
		committed_hostile_raw_damage_evidence_sum += (
			committed_track_charge_risk
			* track.behavior_profile.contact_damage
		)
		if track_charge_risk > 0.0:
			maximum_collision_raw_damage = max(
				maximum_collision_raw_damage, track.behavior_profile.contact_damage
			)
		if forecast_track_charge_risk > 0.0:
			forecast_maximum_collision_raw_damage = max(
				forecast_maximum_collision_raw_damage, track.behavior_profile.contact_damage
			)
		if committed_track_charge_risk > 0.0:
			committed_maximum_collision_raw_damage = max(
				committed_maximum_collision_raw_damage, track.behavior_profile.contact_damage
			)

	for ally in observation.visible_world.get("allied_agents", []):
		if ally.kind != "player":
			continue
		var ttc := _time_to_collision(
			ally.relative_position,
			ally.velocity - player_velocity,
			geometry.player_radius + ally.collision_radius
		)
		if ttc <= navigation_horizon_seconds:
			minimum_ally_ttc = min(minimum_ally_ttc, ttc)
			# Do not assume a human or independently controlled ally will reciprocate.
			ally_risk += _ttc_risk(ttc, max(0.01, local_horizon_seconds))

	return {
		"unresolved_collision_risk": _saturate(enemy_charge_risk + ally_risk),
		"hostile_unresolved_collision_risk": _saturate(enemy_charge_risk),
		"maximum_unresolved_collision_raw_damage": maximum_collision_raw_damage,
		"forecast_hostile_unresolved_collision_risk": _saturate(forecast_enemy_charge_risk),
		"forecast_maximum_unresolved_collision_raw_damage": forecast_maximum_collision_raw_damage,
		"committed_hostile_unresolved_collision_risk": _saturate(committed_enemy_charge_risk),
		"committed_maximum_unresolved_collision_raw_damage": committed_maximum_collision_raw_damage,
		# Saturated union risk is suitable for avoidance pressure, but it is not a
		# sufficient statistic for health loss. The additive charge evidence and
		# damage-weighted evidence remain distinct until dodge and iframes are applied.
		"forecast_hostile_unresolved_contact_evidence_sum": forecast_hostile_contact_evidence_sum,
		"forecast_hostile_unresolved_raw_damage_evidence_sum":
		forecast_hostile_raw_damage_evidence_sum,
		"committed_hostile_unresolved_contact_evidence_sum": committed_hostile_contact_evidence_sum,
		"committed_hostile_unresolved_raw_damage_evidence_sum":
		committed_hostile_raw_damage_evidence_sum,
		"enemy_charge_obstacle_risk": _saturate(enemy_charge_risk),
		"ally_unresolved_collision_risk": _saturate(ally_risk),
		"minimum_ally_time_to_collision": null if minimum_ally_ttc == INF else minimum_ally_ttc,
		"candidate_velocity": player_velocity,
	}


func _charge_collision_risk(
	track: Dictionary,
	player_velocity: Vector2,
	player_displacement: Vector2,
	launch_time: float,
	geometry: Dictionary,
	navigation_horizon_seconds: float,
	forecast_seconds: float,
	committed_seconds: float
) -> Dictionary:
	var charge_attack: Dictionary = track.behavior_profile.get("charge_attack", {})
	var empty_result := {"navigation": 0.0, "forecast": 0.0, "committed": 0.0}
	if not _has_player_region_charge(charge_attack):
		return empty_result
	var readiness := _charge_readiness(track, launch_time, charge_attack)
	if readiness <= 0.0:
		return empty_result
	var launch_position: Vector2 = _enemy_motion_predictor.predict_position(
		track, launch_time, player_displacement
	)
	var relative_launch_position: Vector2 = launch_position - player_displacement
	var launch_distance := relative_launch_position.length()
	if (
		launch_distance < max(0.0, float(charge_attack.get("minimum_range", 0.0)))
		or launch_distance > max(0.0, float(charge_attack.get("maximum_range", 0.0)))
	):
		return empty_result
	var targeting: Dictionary = charge_attack.get("targeting", {})
	var collision: Dictionary = _charge_target_collision(
		launch_position,
		player_displacement,
		player_velocity,
		charge_attack,
		targeting,
		geometry.player_radius + track.behavior_profile.contact_radius,
		launch_time,
		navigation_horizon_seconds,
		forecast_seconds,
		committed_seconds
	)
	if collision.navigation <= 0.0:
		return empty_result
	var confidence: float = (
		readiness
		* track.recency_confidence
		* clamp(charge_attack.get("confidence", 0.0), 0.0, 1.0)
	)
	return {
		"navigation": collision.navigation * confidence,
		"forecast": collision.forecast * confidence,
		"committed": collision.committed * confidence,
	}


func _charge_target_collision(
	launch_position: Vector2,
	player_position: Vector2,
	player_velocity: Vector2,
	charge_attack: Dictionary,
	targeting: Dictionary,
	combined_radius: float,
	launch_time: float,
	navigation_horizon_seconds: float,
	forecast_seconds: float,
	committed_seconds: float
) -> Dictionary:
	var result := {"navigation": 0.0, "forecast": 0.0, "committed": 0.0}
	var collision_context := {
		"launch_position": launch_position,
		"player_position": player_position,
		"player_velocity": player_velocity,
		"charge_speed": max(0.0, float(charge_attack.get("maximum_charge_speed", 0.0))),
		"combined_radius": combined_radius,
		"duration": max(0.0, float(charge_attack.get("maximum_duration_seconds", 0.0))),
		"launch_time": launch_time,
		"navigation_horizon_seconds": navigation_horizon_seconds,
		"forecast_seconds": forecast_seconds,
		"committed_seconds": committed_seconds,
	}
	var player_probability: float = clamp(targeting.get("player_probability", 0.0), 0.0, 1.0)
	_accumulate_charge_aim(result, collision_context, player_position, player_probability)
	var region_probability: float = clamp(
		targeting.get("random_player_region_probability", 0.0), 0.0, 1.0
	)
	if region_probability <= 0.0:
		return result
	var extent := max(0.0, float(targeting.get("random_offset_half_extent", 0.0)))
	var toward_player: Vector2 = launch_position.direction_to(player_position)
	var mean_target: Vector2 = (
		player_position
		+ toward_player * max(0.0, float(targeting.get("forward_overshoot_distance", 0.0)))
	)
	# This fixed five-point cubature matches the unresolved uniform square's mean
	# and axis variances. Unlike a worst-case inflated collision radius, it retains
	# candidate-dependent lateral risk without reading the random roll.
	var aim_points := [
		{"offset": Vector2.ZERO, "weight": 1.0 / 3.0},
		{"offset": Vector2(extent, 0.0), "weight": 1.0 / 6.0},
		{"offset": Vector2(-extent, 0.0), "weight": 1.0 / 6.0},
		{"offset": Vector2(0.0, extent), "weight": 1.0 / 6.0},
		{"offset": Vector2(0.0, -extent), "weight": 1.0 / 6.0},
	]
	for aim in aim_points:
		_accumulate_charge_aim(
			result, collision_context, mean_target + aim.offset, region_probability * aim.weight
		)
	return result


func _accumulate_charge_aim(
	result: Dictionary, collision_context: Dictionary, aim_position: Vector2, probability: float
) -> void:
	var launch_position: Vector2 = collision_context.launch_position
	if probability <= 0.0 or launch_position.distance_squared_to(aim_position) <= 0.0001:
		return
	var charge_velocity: Vector2 = (
		launch_position.direction_to(aim_position)
		* collision_context.charge_speed
	)
	var time_to_contact := _time_to_collision(
		launch_position - collision_context.player_position,
		charge_velocity - collision_context.player_velocity,
		collision_context.combined_radius
	)
	var duration: float = collision_context.duration
	if time_to_contact > duration:
		return
	var risk := probability * _ttc_risk(time_to_contact, max(0.01, duration))
	var absolute_contact_time: float = collision_context.launch_time + time_to_contact
	if absolute_contact_time <= collision_context.navigation_horizon_seconds + 0.0001:
		result.navigation += risk
	if absolute_contact_time <= collision_context.forecast_seconds + 0.0001:
		result.forecast += risk
	if absolute_contact_time <= collision_context.committed_seconds + 0.0001:
		result.committed += risk


func _has_player_region_charge(charge_attack: Dictionary) -> bool:
	if not charge_attack.get("active", false):
		return false
	var targeting: Dictionary = charge_attack.get("targeting", {})
	return (
		(
			float(targeting.get("player_probability", 0.0))
			+ float(targeting.get("random_player_region_probability", 0.0))
		)
		> 0.0
	)


func _charge_is_already_observed_in_motion(track: Dictionary, charge_attack: Dictionary) -> bool:
	var baseline_speed: float = track.behavior_profile.get("target_position_response", {}).get(
		"movement_speed", 0.0
	)
	var charge_speed: float = charge_attack.get("maximum_charge_speed", baseline_speed)
	return track.estimated_velocity.length() > (baseline_speed + charge_speed) * 0.5


func _charge_readiness(track: Dictionary, time: float, charge_attack: Dictionary) -> float:
	var window: Dictionary = track.behavior_profile.get("next_charge_attack_window", {})
	var earliest: float = max(0.0, window.get("earliest_seconds", 0.0))
	var latest: float = window.get("latest_seconds", INF)
	if window.get("is_exact", false):
		return 0.0 if time < earliest else 1.0
	if latest != INF:
		return clamp((time - earliest) / max(0.01, latest - earliest), 0.0, 1.0)
	# An unbounded residual window supplies a hazard rate, not evidence that a
	# charge is already certain.
	var interval: Dictionary = charge_attack.get("interval", {})
	var mean_interval := (
		(
			max(0.0, interval.get("minimum_seconds", 0.0))
			+ max(0.0, interval.get("maximum_seconds", 0.0))
		)
		* 0.5
	)
	if mean_interval <= 0.0:
		return 0.0
	return 1.0 - exp(-max(0.0, time) / mean_interval)


func _time_to_collision(
	relative_position: Vector2, relative_velocity: Vector2, combined_radius: float
) -> float:
	var c := relative_position.length_squared() - combined_radius * combined_radius
	if c <= 0.0:
		return 0.0
	var a := relative_velocity.length_squared()
	if a <= 0.0001:
		return INF
	var b := 2.0 * relative_position.dot(relative_velocity)
	if b >= 0.0:
		return INF
	var discriminant := b * b - 4.0 * a * c
	if discriminant < 0.0:
		return INF
	return max(0.0, (-b - sqrt(discriminant)) / (2.0 * a))


func _ttc_risk(ttc: float, risk_seconds: float) -> float:
	return exp(-max(0.0, ttc) / risk_seconds)


func _saturate(value: float) -> float:
	return 1.0 - exp(-max(0.0, value))
