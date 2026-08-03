extends Reference

# Time-horizon velocity-obstacle collision risk for Brotato's first-order movement model.
# A candidate input selects a velocity directly; this module asks whether that
# velocity enters the collision cone of a moving disk and reports continuous TTC
# risk instead of inventing a dynamically executed path.

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
	var enemy_risk := 0.0
	var projectile_risk := 0.0
	var ally_risk := 0.0
	var maximum_collision_damage := 0.0
	var committed_enemy_risk := 0.0
	var committed_projectile_risk := 0.0
	var committed_maximum_collision_damage := 0.0
	var minimum_ttc := INF

	for track in observation.enemy_tracks:
		var combined_radius: float = geometry.player_radius + track.last_measurement.visual_radius
		var predicted_enemy_position: Vector2 = _enemy_motion_predictor.predict_position(
			track, local_horizon_seconds, player_velocity * local_horizon_seconds
		)
		var predicted_enemy_velocity: Vector2 = (
			(predicted_enemy_position - track.relative_position)
			/ max(0.01, local_horizon_seconds)
		)
		var ttc := _time_to_collision(
			track.relative_position, predicted_enemy_velocity - player_velocity, combined_radius
		)
		if ttc <= navigation_horizon_seconds:
			minimum_ttc = min(minimum_ttc, ttc)
			enemy_risk += (
				_ttc_risk(ttc, max(0.01, local_horizon_seconds))
				* track.recency_confidence
			)
			maximum_collision_damage = max(
				maximum_collision_damage, track.behavior_profile.get("contact_damage", 1.0)
			)
			if ttc <= committed_seconds:
				committed_enemy_risk += (
					_ttc_risk(ttc, max(0.01, local_horizon_seconds))
					* track.recency_confidence
				)
				committed_maximum_collision_damage = max(
					committed_maximum_collision_damage,
					track.behavior_profile.get("contact_damage", 1.0)
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
			geometry.player_radius + projectile.visual_radius
		)
		if (
			ttc > navigation_horizon_seconds
			or _intercepted_before_player(observation, projectile, ttc)
		):
			continue
		minimum_ttc = min(minimum_ttc, ttc)
		projectile_risk += 1.5 * _ttc_risk(ttc, max(0.01, local_horizon_seconds))
		maximum_collision_damage = max(
			maximum_collision_damage, projectile.get("contact_damage", 1.0)
		)
		if ttc <= committed_seconds:
			committed_projectile_risk += 1.5 * _ttc_risk(ttc, max(0.01, local_horizon_seconds))
			committed_maximum_collision_damage = max(
				committed_maximum_collision_damage, projectile.get("contact_damage", 1.0)
			)

	for ally in observation.visible_world.get("allied_agents", []):
		if ally.kind != "player":
			continue
		var ttc := _time_to_collision(
			ally.relative_position,
			ally.velocity - player_velocity,
			geometry.player_radius + ally.visual_radius
		)
		if ttc <= navigation_horizon_seconds:
			minimum_ttc = min(minimum_ttc, ttc)
			# Do not assume a human or independently controlled ally will reciprocate.
			ally_risk += _ttc_risk(ttc, max(0.01, local_horizon_seconds))

	return {
		"velocity_obstacle_risk": _saturate(enemy_risk + projectile_risk + ally_risk),
		"hostile_velocity_obstacle_risk": _saturate(enemy_risk + projectile_risk),
		"maximum_velocity_obstacle_damage": maximum_collision_damage,
		"committed_hostile_velocity_obstacle_risk":
		_saturate(committed_enemy_risk + committed_projectile_risk),
		"committed_maximum_velocity_obstacle_damage": committed_maximum_collision_damage,
		"enemy_velocity_obstacle_risk": _saturate(enemy_risk),
		"projectile_velocity_obstacle_risk": _saturate(projectile_risk),
		"ally_velocity_obstacle_risk": _saturate(ally_risk),
		"minimum_time_to_collision": null if minimum_ttc == INF else minimum_ttc,
		"candidate_velocity": player_velocity,
	}


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
			interception.radius + projectile.visual_radius
		)
		if interception_ttc <= player_ttc:
			return true
	return false


func _ttc_risk(ttc: float, risk_seconds: float) -> float:
	return exp(-max(0.0, ttc) / risk_seconds)


func _saturate(value: float) -> float:
	return 1.0 - exp(-max(0.0, value))
