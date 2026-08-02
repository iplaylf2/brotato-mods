extends Reference

# Compiles versioned enemy mechanics after an enemy becomes visible. Possible
# boss phases are aggregated; mutable state such as the active phase, current
# cooldown, target, current health, and random rolls is not part of the profile.

const FALLBACK_PRESSURE_INTENSITY := 0.5
const MAX_PRESSURE_INTENSITY := 4.0

var _attack_behaviors_by_archetype := {}


func compile(enemy: Node) -> Dictionary:
	var archetype := ""
	if "enemy_id" in enemy:
		archetype = enemy.enemy_id
	var attack_behavior: Dictionary
	if not archetype.empty() and _attack_behaviors_by_archetype.has(archetype):
		attack_behavior = _attack_behaviors_by_archetype[archetype].duplicate(true)
	else:
		attack_behavior = _compile_attack_behavior(enemy)
		if not archetype.empty():
			_attack_behaviors_by_archetype[archetype] = attack_behavior.duplicate(true)
	return {
		"attack_behavior": attack_behavior,
		# Maximum health is a conservative durability prior; current hidden health
		# is deliberately not read.
		"durability": {"maximum_health": _get_maximum_health(enemy)},
		"contact_damage": _get_contact_damage(enemy),
		"kill_rewards": _compile_kill_rewards(enemy, archetype),
	}


func _compile_kill_rewards(enemy: Node, archetype: String) -> Dictionary:
	var rewards := {
		"base_materials": 0.0,
		"consumable_drop_chance": 0.0,
		"guaranteed_consumable": false,
		"curse_gain": 1.0 if archetype == "evil_mob" else 0.0,
		"has_bonus_reward": bool(enemy.is_loot) if "is_loot" in enemy else false,
	}
	if "stats" in enemy and enemy.stats != null:
		rewards.base_materials = max(0.0, float(enemy.stats.value))
		rewards.consumable_drop_chance = clamp(float(enemy.stats.item_drop_chance), 0.0, 1.0)
		rewards.guaranteed_consumable = bool(enemy.stats.always_drop_consumables)
	rewards.has_bonus_reward = rewards.has_bonus_reward or rewards.curse_gain > 0.0
	return rewards


func _compile_attack_behavior(enemy: Node) -> Dictionary:
	if not "_all_attack_behaviors" in enemy:
		return (
			_unconfirmed_attack_behavior()
			if not _has_attached_projectiles(enemy)
			else _compile_attached_projectiles(enemy)
		)

	var shooting_behaviors := []
	for behavior in enemy._all_attack_behaviors:
		if behavior is ShootingAttackBehavior:
			shooting_behaviors.push_back(behavior)
	var attached_projectiles := []
	_append_attached_projectiles(attached_projectiles, enemy)
	if shooting_behaviors.empty() and attached_projectiles.empty():
		return {
			"kind": "non_projectile_known",
			"confidence": 1.0,
			"knowledge_source": "stable_mechanics",
			"creates_projectile_pressure": false,
			"pressure_intensity": 0.0,
		}

	var minimum_range := INF
	var maximum_range := 0.0
	var maximum_projectile_speed := 0.0
	var maximum_projectiles_per_volley := 0
	var maximum_projectiles_per_second := 0.0
	var delivery_modes := []
	var has_stationary_hazards := false
	var all_projectiles_removed_on_death := true
	for behavior in shooting_behaviors:
		minimum_range = min(minimum_range, float(behavior.min_range))
		maximum_range = max(maximum_range, float(behavior.max_range))
		maximum_projectile_speed = max(
			maximum_projectile_speed,
			float(behavior.projectile_speed + behavior.projectile_speed_randomization)
		)
		maximum_projectiles_per_volley = max(
			maximum_projectiles_per_volley, int(behavior.number_projectiles)
		)
		var cooldown_seconds := (
			max(1.0, float(behavior.cooldown - behavior.max_cd_randomization))
			/ 60.0
		)
		maximum_projectiles_per_second = max(
			maximum_projectiles_per_second, float(behavior.number_projectiles) / cooldown_seconds
		)
		has_stationary_hazards = has_stationary_hazards or behavior.projectile_speed <= 0
		all_projectiles_removed_on_death = (
			all_projectiles_removed_on_death
			and behavior.delete_projectile_on_death
		)
		_append_unique(delivery_modes, _delivery_mode(behavior))
	for projectile in attached_projectiles:
		if "min_target_distance" in projectile:
			minimum_range = min(minimum_range, float(projectile.min_target_distance))
		if "max_target_distance" in projectile:
			maximum_range = max(maximum_range, float(projectile.max_target_distance))
		if "speed" in projectile:
			maximum_projectile_speed = max(maximum_projectile_speed, float(projectile.speed))
	maximum_projectiles_per_volley = max(
		maximum_projectiles_per_volley, attached_projectiles.size()
	)
	maximum_projectiles_per_second = max(
		maximum_projectiles_per_second, float(attached_projectiles.size())
	)
	if not attached_projectiles.empty():
		_append_unique(delivery_modes, "attached_orbit")

	return {
		"kind":
		(
			"ranged_projectile_known"
			if not shooting_behaviors.empty()
			else "attached_projectile_known"
		),
		"confidence": 1.0,
		"knowledge_source": "stable_mechanics",
		"creates_projectile_pressure": true,
		"minimum_range": 0.0 if minimum_range == INF else minimum_range,
		"maximum_range": maximum_range,
		"maximum_projectile_speed": maximum_projectile_speed,
		"maximum_projectiles_per_volley": maximum_projectiles_per_volley,
		"maximum_projectiles_per_second": maximum_projectiles_per_second,
		"volley_interval": _compile_volley_interval(shooting_behaviors),
		"launch_randomness": _compile_launch_randomness(shooting_behaviors),
		"pressure_intensity":
		clamp(
			sqrt(maximum_projectiles_per_second),
			FALLBACK_PRESSURE_INTENSITY,
			MAX_PRESSURE_INTENSITY
		),
		"delivery_modes": delivery_modes,
		"has_stationary_hazards": has_stationary_hazards,
		"all_projectiles_removed_on_death": all_projectiles_removed_on_death,
	}


func _compile_volley_interval(behaviors: Array) -> Dictionary:
	var minimum_interval := INF
	var maximum_interval := 0.0
	var has_random_cooldown := false
	var has_long_cooldown := false
	for behavior in behaviors:
		has_random_cooldown = has_random_cooldown or behavior.max_cd_randomization > 0
		minimum_interval = min(
			minimum_interval, max(1.0, behavior.cooldown - behavior.max_cd_randomization) / 60.0
		)
		maximum_interval = max(
			maximum_interval, max(1.0, behavior.cooldown + behavior.max_cd_randomization) / 60.0
		)
		if behavior.long_cooldown_every_x_shoots > 0:
			has_long_cooldown = true
			maximum_interval = max(maximum_interval, behavior.long_cooldown / 60.0)
	return {
		"minimum_seconds": 0.0 if minimum_interval == INF else minimum_interval,
		"maximum_seconds": maximum_interval,
		"has_random_cooldown": has_random_cooldown,
		"has_long_cooldown": has_long_cooldown,
	}


func _compile_launch_randomness(behaviors: Array) -> Dictionary:
	var has_random_direction := false
	var has_random_speed := false
	var has_random_origin := false
	for behavior in behaviors:
		has_random_direction = (
			has_random_direction
			or behavior.random_direction
			or behavior.base_direction_randomization > 0.0
			or (behavior.projectile_spread > 0.0 and not behavior.constant_spread)
			or behavior.random_rotation > 0.0
		)
		has_random_speed = has_random_speed or behavior.projectile_speed_randomization > 0
		has_random_origin = (
			has_random_origin
			or behavior.constant_spread_rand_base_pos > 0.0
			or (behavior.projectile_spawn_spread > 0 and not behavior.constant_spread)
		)
	return {
		"has_random_direction": has_random_direction,
		"has_random_speed": has_random_speed,
		"has_random_origin": has_random_origin,
	}


func _delivery_mode(behavior: ShootingAttackBehavior) -> String:
	if behavior.spawn_projectiles_on_target:
		return (
			"target_area_perimeter"
			if behavior.projectile_spawn_only_on_borders
			else "target_area"
		)
	if behavior.shoot_away_from_unit:
		return "source_area_outward"
	if behavior.shoot_from_proj_pos_towards_player:
		return "source_area_toward_target"
	if behavior.shoot_in_unit_direction:
		return "source_movement_direction"
	if behavior.random_direction:
		return "source_random_direction"
	return "source_toward_target"


func _append_unique(values: Array, value: String) -> void:
	if not values.has(value):
		values.push_back(value)


func _unconfirmed_attack_behavior() -> Dictionary:
	return {
		"kind": "unconfirmed",
		"confidence": 0.0,
		"knowledge_source": "unavailable",
		"creates_projectile_pressure": false,
		"pressure_intensity": 0.0,
	}


func _compile_attached_projectiles(enemy: Node) -> Dictionary:
	# Fallback for a non-standard enemy that exposes projectile children without
	# the vanilla attack-behavior collection.
	var projectiles := []
	_append_attached_projectiles(projectiles, enemy)
	var maximum_range := 0.0
	var maximum_speed := 0.0
	for projectile in projectiles:
		if "max_target_distance" in projectile:
			maximum_range = max(maximum_range, float(projectile.max_target_distance))
		if "speed" in projectile:
			maximum_speed = max(maximum_speed, float(projectile.speed))
	return {
		"kind": "attached_projectile_known",
		"confidence": 1.0,
		"knowledge_source": "stable_mechanics",
		"creates_projectile_pressure": true,
		"minimum_range": 0.0,
		"maximum_range": maximum_range,
		"maximum_projectile_speed": maximum_speed,
		"maximum_projectiles_per_volley": projectiles.size(),
		"maximum_projectiles_per_second": float(projectiles.size()),
		"pressure_intensity":
		clamp(sqrt(float(projectiles.size())), FALLBACK_PRESSURE_INTENSITY, MAX_PRESSURE_INTENSITY),
		"delivery_modes": ["attached_orbit"],
		"has_stationary_hazards": false,
		"all_projectiles_removed_on_death": true,
	}


func _has_attached_projectiles(enemy: Node) -> bool:
	var projectiles := []
	_append_attached_projectiles(projectiles, enemy)
	return not projectiles.empty()


func _append_attached_projectiles(projectiles: Array, node: Node) -> void:
	for child in node.get_children():
		if child is EnemyProjectile:
			projectiles.push_back(child)
		_append_attached_projectiles(projectiles, child)


func _get_maximum_health(enemy: Node) -> float:
	if "max_stats" in enemy and enemy.max_stats != null and "health" in enemy.max_stats:
		return max(1.0, float(enemy.max_stats.health))
	return 1.0


func _get_contact_damage(enemy: Node) -> float:
	if "_hitbox" in enemy and enemy._hitbox != null:
		return max(0.0, float(enemy._hitbox.damage))
	if "current_stats" in enemy and enemy.current_stats != null and "damage" in enemy.current_stats:
		return max(0.0, float(enemy.current_stats.damage))
	return 1.0
