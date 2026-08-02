extends Reference

# Describes visible allied agents through capabilities, not content IDs. Current
# targets, cooldowns, health, and other transient private state are not read.


func compile(agent: Node, kind: String) -> Dictionary:
	var profile := {
		"roles":
		{
			"party_member": kind == "player",
			"combat_support": false,
			"healing_support": false,
			"projectile_interceptor": false,
			"resource_support": agent is Lootworm,
			"threat_diversion": _can_divert_threat(agent),
		},
		"pressure_relief": _empty_zone(),
		"healing_support": _empty_zone(),
		"projectile_interception": _empty_zone(),
		"coordination_anchor": kind == "player",
	}
	if kind == "player":
		return profile

	var combat_zone := _compile_combat_zone(agent)
	profile.pressure_relief = combat_zone
	profile.roles.combat_support = combat_zone.active

	var healing_zone := _compile_healing_zone(agent)
	profile.healing_support = healing_zone
	profile.roles.healing_support = healing_zone.active

	var interception_zone := _compile_interception_zone(agent)
	profile.projectile_interception = interception_zone
	profile.roles.projectile_interceptor = interception_zone.active
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
		var accuracy := clamp(
			float(stats.get("accuracy") if "accuracy" in stats else 1.0), 0.2, 1.0
		)
		var cycle_seconds := (
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
			"activation_radius": 0.0,
			"player_activation_radius":
			_get_collision_radius(agent, "PlayerTriggerZone/CollisionShape2D"),
			"intensity": intensity,
			"single_use": false,
			"effect": "damage",
		}
	return best_zone


func _compile_healing_zone(agent: Node) -> Dictionary:
	var radius := _get_collision_radius(agent, "BoostZone/CollisionShape2D")
	if radius <= 0.0:
		return _empty_zone()
	return {
		"active": true,
		"radius": radius,
		"activation_radius": 0.0,
		"player_activation_radius": 0.0,
		"intensity": 0.5,
		"single_use": false,
		"effect": "healing_amplification",
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
		"activation_radius": 0.0,
		"player_activation_radius": 0.0,
		"intensity": 1.0,
		"single_use": false,
		"effect": "projectile_interception",
	}


func _can_divert_threat(agent: Node) -> bool:
	return "can_be_targeted_by_enemies" in agent and agent.can_be_targeted_by_enemies


func _get_collision_radius(agent: Node, path: String) -> float:
	if not agent.has_node(path):
		return 0.0
	var collision = agent.get_node(path)
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
		"activation_radius": 0.0,
		"player_activation_radius": 0.0,
		"intensity": 0.0,
		"single_use": false,
		"effect": "none",
	}
