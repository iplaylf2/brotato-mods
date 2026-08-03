extends Reference

# Analytic collision evidence for ballistic projectiles, allied bodies, and
# known locked charge corridors. Ordinary enemy contact follows curved target
# response and is owned by BattlefieldInfluenceModel's swept path projection;
# treating it as a second constant-velocity obstacle caused contradictory risk.

const PlayerKinematicsModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_kinematics_model.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const MovementTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_timing_model.gd"
)
const ProjectileMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/projectile_motion_predictor.gd"
)
const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)

var _player_kinematics: Reference = PlayerKinematicsModel.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _projectile_motion_predictor: Reference = ProjectileMotionPredictor.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()


func evaluate(observation: Dictionary, action: Dictionary, committed_seconds: float) -> Dictionary:
	_enemy_motion_predictor.begin_physics_frame(observation.get("physics_frame", -1))
	var geometry: Dictionary = _movement_geometry.derive(observation)
	var timing: Dictionary = MovementTimingModel.derive(observation)
	var local_horizon_seconds: float = timing.effective_local_horizon_seconds
	var navigation_horizon_seconds: float = timing.effective_navigation_horizon_seconds
	var player_velocity: Vector2 = _player_kinematics.predict_average_velocity(
		observation, action.movement, max(0.01, local_horizon_seconds)
	)
	var enemy_charge_risk := 0.0
	var committed_enemy_charge_risk := 0.0
	var projectile_risk := 0.0
	var ally_risk := 0.0
	var maximum_collision_damage := 0.0
	var forecast_projectile_risk := 0.0
	var forecast_maximum_collision_damage := 0.0
	var committed_projectile_risk := 0.0
	var committed_maximum_collision_damage := 0.0
	var minimum_ttc := INF

	for track in observation.enemy_tracks:
		var track_charge_risk := 0.0
		var committed_track_charge_risk := 0.0
		for sample in action.samples:
			var sample_charge_risk: float = _charge_collision_risk(
				track, sample.displacement, sample.time, geometry
			)
			track_charge_risk = max(track_charge_risk, sample_charge_risk)
			if sample.time <= committed_seconds + 0.0001:
				committed_track_charge_risk = max(committed_track_charge_risk, sample_charge_risk)
		enemy_charge_risk += track_charge_risk
		committed_enemy_charge_risk += committed_track_charge_risk
		if track_charge_risk > 0.0:
			maximum_collision_damage = max(
				maximum_collision_damage, track.behavior_profile.contact_damage
			)
			forecast_maximum_collision_damage = max(
				forecast_maximum_collision_damage, track.behavior_profile.contact_damage
			)
		if committed_track_charge_risk > 0.0:
			committed_maximum_collision_damage = max(
				committed_maximum_collision_damage, track.behavior_profile.contact_damage
			)

	for projectile in observation.visible_world.enemy_projectiles:
		var predicted_projectile_position: Vector2 = _projectile_motion_predictor.predict_position(
			projectile, local_horizon_seconds
		)
		var projectile_velocity: Vector2 = (
			(predicted_projectile_position - projectile.relative_position)
			/ max(0.01, local_horizon_seconds)
		)
		var ttc := _time_to_collision(
			projectile.relative_position,
			projectile_velocity - player_velocity,
			geometry.player_radius + projectile.contact_radius
		)
		if (
			ttc > navigation_horizon_seconds
			or _intercepted_before_player(observation, projectile, ttc)
		):
			continue
		minimum_ttc = min(minimum_ttc, ttc)
		projectile_risk += 1.5 * _ttc_risk(ttc, max(0.01, local_horizon_seconds))
		maximum_collision_damage = max(maximum_collision_damage, projectile.contact_damage)
		if ttc <= action.forecast_seconds:
			forecast_projectile_risk += (1.5 * _ttc_risk(ttc, max(0.01, local_horizon_seconds)))
			forecast_maximum_collision_damage = max(
				forecast_maximum_collision_damage, projectile.contact_damage
			)
		if ttc <= committed_seconds:
			committed_projectile_risk += 1.5 * _ttc_risk(ttc, max(0.01, local_horizon_seconds))
			committed_maximum_collision_damage = max(
				committed_maximum_collision_damage, projectile.contact_damage
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
			minimum_ttc = min(minimum_ttc, ttc)
			# Do not assume a human or independently controlled ally will reciprocate.
			ally_risk += _ttc_risk(ttc, max(0.01, local_horizon_seconds))

	return {
		"velocity_obstacle_risk": _saturate(enemy_charge_risk + projectile_risk + ally_risk),
		"hostile_velocity_obstacle_risk": _saturate(enemy_charge_risk + projectile_risk),
		"maximum_velocity_obstacle_damage": maximum_collision_damage,
		"forecast_hostile_velocity_obstacle_risk":
		_saturate(enemy_charge_risk + forecast_projectile_risk),
		"forecast_maximum_velocity_obstacle_damage": forecast_maximum_collision_damage,
		"committed_hostile_velocity_obstacle_risk":
		_saturate(committed_enemy_charge_risk + committed_projectile_risk),
		"committed_maximum_velocity_obstacle_damage": committed_maximum_collision_damage,
		"enemy_charge_obstacle_risk": _saturate(enemy_charge_risk),
		"projectile_velocity_obstacle_risk": _saturate(projectile_risk),
		"ally_velocity_obstacle_risk": _saturate(ally_risk),
		"minimum_time_to_collision": null if minimum_ttc == INF else minimum_ttc,
		"candidate_velocity": player_velocity,
	}


func _charge_collision_risk(
	track: Dictionary, player_displacement: Vector2, time: float, geometry: Dictionary
) -> float:
	var charge_attack: Dictionary = track.behavior_profile.get("charge_attack", {})
	if (
		not charge_attack.get("active", false)
		or not charge_attack.get("aims_at_player_region", false)
	):
		return 0.0
	var pressure_distance: float = min(
		max(0.0, charge_attack.get("maximum_range", 0.0)),
		max(0.0, charge_attack.get("maximum_travel_distance", 0.0))
	)
	if pressure_distance <= 0.0:
		return 0.0
	var readiness := _charge_readiness(track, time, charge_attack)
	if readiness <= 0.0:
		return 0.0
	# Vanilla locks the heading before high-speed movement. Compare the candidate
	# position with that swept disk without encoding a preferred escape direction.
	var launch_position: Vector2 = _enemy_motion_predictor.predict_position(
		track, time, Vector2.ZERO
	)
	if launch_position.length_squared() <= 0.0:
		return 0.0
	var charge_corridor_end := (
		launch_position
		+ launch_position.direction_to(Vector2.ZERO) * pressure_distance
	)
	var closest_corridor_point := _closest_point_on_segment(
		launch_position, charge_corridor_end, player_displacement
	)
	var corridor_clearance: float = (
		closest_corridor_point.distance_to(player_displacement)
		- geometry.player_radius
		- track.behavior_profile.contact_radius
		- max(0.0, charge_attack.get("maximum_aim_offset_radius", 0.0))
	)
	var maneuver_margin: float = max(1.0, geometry.control_distance)
	var corridor_intersection := clamp(
		(maneuver_margin - corridor_clearance) / maneuver_margin, 0.0, 1.0
	)
	var launch_clearance: float = (
		launch_position.length()
		- geometry.player_radius
		- track.behavior_profile.contact_radius
	)
	var charge_reach := clamp((pressure_distance - launch_clearance) / pressure_distance, 0.0, 1.0)
	return (
		charge_reach
		* corridor_intersection
		* corridor_intersection
		* readiness
		* track.recency_confidence
		* clamp(charge_attack.get("confidence", 0.0), 0.0, 1.0)
	)


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


func _closest_point_on_segment(
	segment_start: Vector2, segment_end: Vector2, point: Vector2
) -> Vector2:
	var segment: Vector2 = segment_end - segment_start
	var length_squared: float = segment.length_squared()
	if length_squared <= 0.0:
		return segment_start
	var fraction: float = clamp((point - segment_start).dot(segment) / length_squared, 0.0, 1.0)
	return segment_start.linear_interpolate(segment_end, fraction)


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


func _intercepted_before_player(
	observation: Dictionary, projectile: Dictionary, player_ttc: float
) -> bool:
	var predicted_position: Vector2 = _projectile_motion_predictor.predict_position(
		projectile, player_ttc
	)
	var average_projectile_velocity: Vector2 = (
		(predicted_position - projectile.relative_position)
		/ max(0.01, player_ttc)
	)
	for ally in observation.visible_world.get("allied_agents", []):
		var interception: Dictionary = ally.influence.projectile_interception
		if not interception.active or interception.radius <= 0.0:
			continue
		var interception_ttc := _time_to_collision(
			projectile.relative_position - ally.relative_position,
			average_projectile_velocity - ally.velocity,
			interception.radius + projectile.contact_radius
		)
		if interception_ttc <= player_ttc:
			return true
	return false


func _ttc_risk(ttc: float, risk_seconds: float) -> float:
	return exp(-max(0.0, ttc) / risk_seconds)


func _saturate(value: float) -> float:
	return 1.0 - exp(-max(0.0, value))
