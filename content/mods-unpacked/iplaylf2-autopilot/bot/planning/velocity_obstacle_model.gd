extends Reference

# Time-horizon velocity-obstacle risk for Brotato's first-order movement model.
# A candidate input selects a velocity directly; this module asks whether that
# velocity enters the collision cone of a moving disk and reports continuous TTC
# risk instead of inventing a dynamically executed path.

const PLAYER_RADIUS := 24.0
const TTC_RISK_SECONDS := 1.0
const MAX_COLLISION_SECONDS := 1.5
const PlayerKinematicsModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_kinematics_model.gd"
)

var _player_kinematics: Reference = PlayerKinematicsModel.new()


func evaluate(observation: Dictionary, action: Dictionary) -> Dictionary:
	var player_velocity := _player_kinematics.predict_average_velocity(
		observation, action.movement, TTC_RISK_SECONDS
	)
	var enemy_risk := 0.0
	var projectile_risk := 0.0
	var ally_risk := 0.0
	var minimum_ttc := INF

	for track in observation.enemy_tracks:
		var combined_radius: float = (
			PLAYER_RADIUS
			+ track.last_measurement.visual_radius
			+ track.uncertainty_radius
		)
		var ttc := _time_to_collision(
			track.relative_position, track.estimated_velocity - player_velocity, combined_radius
		)
		if ttc <= MAX_COLLISION_SECONDS:
			minimum_ttc = min(minimum_ttc, ttc)
			enemy_risk += _ttc_risk(ttc) * track.recency_confidence

	for projectile in observation.visible_world.enemy_projectiles:
		var ttc := _time_to_collision(
			projectile.relative_position,
			projectile.velocity - player_velocity,
			PLAYER_RADIUS + projectile.visual_radius
		)
		if ttc > MAX_COLLISION_SECONDS or _intercepted_before_player(observation, projectile, ttc):
			continue
		minimum_ttc = min(minimum_ttc, ttc)
		projectile_risk += 1.5 * _ttc_risk(ttc)

	for ally in observation.visible_world.get("allied_agents", []):
		if ally.kind != "player":
			continue
		var ttc := _time_to_collision(
			ally.relative_position,
			ally.velocity - player_velocity,
			PLAYER_RADIUS + ally.visual_radius
		)
		if ttc <= MAX_COLLISION_SECONDS:
			minimum_ttc = min(minimum_ttc, ttc)
			# Do not assume a human or independently controlled ally will reciprocate.
			ally_risk += _ttc_risk(ttc)

	return {
		"velocity_obstacle_risk": _saturate(enemy_risk + projectile_risk + ally_risk),
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
	for ally in observation.visible_world.get("allied_agents", []):
		var interception: Dictionary = ally.influence.projectile_interception
		if not interception.active or interception.radius <= 0.0:
			continue
		var interception_ttc := _time_to_collision(
			projectile.relative_position - ally.relative_position,
			projectile.velocity - ally.velocity,
			interception.radius + projectile.visual_radius
		)
		if interception_ttc <= player_ttc:
			return true
	return false


func _ttc_risk(ttc: float) -> float:
	return exp(-max(0.0, ttc) / TTC_RISK_SECONDS)


func _saturate(value: float) -> float:
	return 1.0 - exp(-max(0.0, value))
