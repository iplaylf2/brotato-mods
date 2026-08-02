extends Reference

# Compiles stable, player-legible structure effects into planning semantics.
# Runtime targets, cooldowns, and other hidden transient state are never read.

const BASE_EXPLOSION_RADIUS := 147.34
const DEFAULT_LANDMINE_SCALE := 1.0


func compile(structure: Node) -> Dictionary:
	var profile := {
		"pressure_relief": _empty_zone(),
		"healing_support": _empty_zone(),
		"resource_producer": structure is Garden,
	}
	if structure is Garden:
		return profile
	if structure is Landmine:
		profile.pressure_relief = _compile_landmine(structure)
		return profile
	if _has_slow_field(structure):
		profile.pressure_relief = {
			"active": true,
			"radius": _get_circle_radius(structure.get_node("SlowHitbox/Collision")),
			"activation_radius": 0.0,
			"player_activation_radius": 0.0,
			"intensity": 0.65,
			"single_use": false,
			"effect": "control",
		}
		return profile
	if not structure is Turret or not "stats" in structure or structure.stats == null:
		return profile

	var stats: Resource = structure.stats
	var radius := max(0.0, float(stats.max_range))
	var projectiles := max(0.0, float(stats.nb_projectiles))
	var cycle_seconds := max(1.0, float(stats.cooldown)) / 60.0
	if stats.is_healing and radius > 0.0 and projectiles > 0.0:
		profile.healing_support = {
			"active": true,
			"radius": radius,
			"activation_radius": 0.0,
			"player_activation_radius": 0.0,
			"intensity": clamp(float(stats.damage) * projectiles / cycle_seconds / 3.0, 0.1, 2.5),
			"single_use": false,
			"effect": "healing",
		}
	elif radius > 0.0 and stats.damage > 0 and projectiles > 0.0:
		var expected_output := (
			float(stats.damage)
			* projectiles
			* clamp(float(stats.accuracy), 0.2, 1.0)
			/ cycle_seconds
		)
		profile.pressure_relief = {
			"active": true,
			"radius": radius,
			"activation_radius": 0.0,
			"player_activation_radius": 0.0,
			"intensity": clamp(expected_output / 25.0, 0.1, 2.5),
			"single_use": false,
			"effect": "damage",
		}
	return profile


func _compile_landmine(structure: Node) -> Dictionary:
	var scale := DEFAULT_LANDMINE_SCALE
	if not structure.effects.empty() and "scale" in structure.effects[0]:
		scale = max(0.1, float(structure.effects[0].scale))
	var damage := 10.0
	if "stats" in structure and structure.stats != null:
		damage = max(1.0, float(structure.stats.damage))
	return {
		"active": true,
		"radius": BASE_EXPLOSION_RADIUS * scale,
		"activation_radius": _get_landmine_activation_radius(structure),
		"player_activation_radius": 0.0,
		"intensity": clamp(damage / 30.0, 0.2, 2.5),
		"single_use": true,
		"effect": "damage",
	}


func _has_slow_field(structure: Node) -> bool:
	return (
		structure.has_node("SlowHitbox/Collision")
		and (structure.get_node("SlowHitbox/Collision") is CollisionShape2D)
	)


func _get_circle_radius(collision: CollisionShape2D) -> float:
	if collision.shape is CircleShape2D:
		return (
			collision.shape.radius
			* max(abs(collision.global_scale.x), abs(collision.global_scale.y))
		)
	return 0.0


func _get_landmine_activation_radius(structure: Node) -> float:
	if not structure.has_node("Area2D/Collision"):
		return 24.0
	var collision = structure.get_node("Area2D/Collision")
	if not collision is CollisionShape2D:
		return 24.0
	if collision.shape is CapsuleShape2D:
		return (
			collision.shape.radius
			* max(abs(collision.global_scale.x), abs(collision.global_scale.y))
		)
	return _get_circle_radius(collision)


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
