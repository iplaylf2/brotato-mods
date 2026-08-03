extends Reference

# Describes visible allied agents through capabilities, not content IDs. Current
# targets, cooldowns, health, and other transient private state are not read.


func compile(agent: Node, kind: String) -> Dictionary:
	var profile := {
		"combat_support": _empty_zone(),
		"healing_support": _empty_zone(),
		"projectile_interception": _empty_zone(),
	}
	if kind == "player":
		return profile

	var combat_zone := _compile_combat_zone(agent)
	profile.combat_support = combat_zone

	var healing_zone := _compile_healing_zone(agent)
	profile.healing_support = healing_zone

	var interception_zone := _compile_interception_zone(agent)
	profile.projectile_interception = interception_zone
	return profile


func _compile_combat_zone(agent: Node) -> Dictionary:
	if not agent is Pet:
		return _empty_zone()
	var stats_list: Array = agent.get_stats()
	var best_zone := _empty_zone()
	for stats in stats_list:
		if not stats is Resource or not "damage" in stats or stats.damage <= 0:
			continue
		var radius := 0.0
		if "max_range" in stats:
			radius = max(0.0, float(stats.max_range))
		if radius <= 0.0:
			radius = _get_collision_radius(agent, "Hitbox/Collision")
		if radius <= 0.0:
			continue
		var projectiles := max(
			1.0, float(stats.get("nb_projectiles") if "nb_projectiles" in stats else 1)
		)
		var accuracy: float = clamp(
			float(stats.get("accuracy") if "accuracy" in stats else 1.0), 0.2, 1.0
		)
		var cycle_seconds: float = (
			max(1.0, float(stats.get("cooldown") if "cooldown" in stats else 60))
			/ 60.0
		)
		var intensity := clamp(
			float(stats.damage) * projectiles * accuracy / cycle_seconds / 25.0, 0.1, 2.5
		)
		if intensity <= best_zone.intensity:
			continue
		best_zone = {
			"active": true,
			"radius": radius,
			"enemy_trigger_radius": 0.0,
			"player_enablement_radius":
			_get_collision_radius(agent, "PlayerTriggerZone/CollisionShape2D"),
			"player_trigger_radius": 0.0,
			"intensity": intensity,
			"single_use": false,
			"simultaneous_target_capacity": 1.0,
		}
	return best_zone


func _compile_healing_zone(agent: Node) -> Dictionary:
	var radius := _get_collision_radius(agent, "BoostZone/CollisionShape2D")
	if radius <= 0.0:
		return _empty_zone()
	return {
		"active": true,
		"radius": radius,
		"enemy_trigger_radius": 0.0,
		"player_enablement_radius": 0.0,
		"player_trigger_radius": 0.0,
		"intensity": 0.5,
		"single_use": false,
		"requires_recovery_opportunity": true,
	}


func _compile_interception_zone(agent: Node) -> Dictionary:
	if not agent is Jellyshield:
		return _empty_zone()
	var radius := _get_collision_radius(agent, "Hurtbox/Collision")
	if radius <= 0.0:
		return _empty_zone()
	return {
		"active": true,
		"radius": radius,
		"enemy_trigger_radius": 0.0,
		"player_enablement_radius": 0.0,
		"player_trigger_radius": 0.0,
		"intensity": 1.0,
		"single_use": false,
	}


func _get_collision_radius(agent: Node, path: String) -> float:
	if not agent.has_node(path):
		return 0.0
	var collision: Node = agent.get_node(path)
	if not collision is CollisionShape2D or not collision.shape is CircleShape2D:
		return 0.0
	return (
		collision.shape.radius
		* max(abs(collision.global_scale.x), abs(collision.global_scale.y))
	)


func _empty_zone() -> Dictionary:
	return {
		"active": false,
		"radius": 0.0,
		"enemy_trigger_radius": 0.0,
		"player_enablement_radius": 0.0,
		"player_trigger_radius": 0.0,
		"intensity": 0.0,
		"single_use": false,
		"simultaneous_target_capacity": 0.0,
		"requires_recovery_opportunity": false,
	}
