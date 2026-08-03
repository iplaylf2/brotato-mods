extends Reference

# Compiles target-version weapon state and resources into three orthogonal state
# axes plus a generic transition language. Vanilla Effect subclasses and scene
# nodes never cross this boundary.

const StatMetadata := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/stats/stat_metadata.gd"
)
# Weapon.should_shoot() admits the nearest target through this fixed margin
# beyond current_stats.max_range. Keep the target-version rule at the knowledge
# boundary instead of reconstructing it from a target's visual or collision size.
const VANILLA_TARGETING_RANGE_ALLOWANCE := 50.0

var _stat_metadata: Reference = StatMetadata.new()


func compile(
	weapon: Node, stats: Resource, player_index: int, attacks_allowed_while_moving: bool
) -> Dictionary:
	return {
		"timing": _adapt_timing(stats, player_index, attacks_allowed_while_moving),
		"delivery": _adapt_delivery(weapon, stats),
		"impact": _adapt_impact(stats),
		"rules": _adapt_rules(weapon, stats, player_index),
	}


func _adapt_timing(
	stats: Resource, player_index: int, attacks_allowed_while_moving: bool
) -> Dictionary:
	var reload_every: int = stats.additional_cooldown_every_x_shots
	var reload_multiplier: float = stats.additional_cooldown_multiplier
	var expected_attack_interval_multiplier := 1.0
	if reload_every > 0 and reload_multiplier > 1.0:
		expected_attack_interval_multiplier = (
			(float(reload_every - 1) + reload_multiplier)
			/ reload_every
		)
	return {
		"expected_attack_interval_seconds":
		stats.get_cooldown_value(player_index, expected_attack_interval_multiplier),
		"permitted_while_moving": attacks_allowed_while_moving,
	}


func _adapt_delivery(weapon: Node, stats: Resource) -> Dictionary:
	var result := {
		"minimum_targeting_distance": stats.min_range,
		"maximum_targeting_distance": stats.max_range + VANILLA_TARGETING_RANGE_ALLOWANCE,
		"paths":
		{
			"count": 1,
			"angular_half_extent": 0.0,
			"corridor_half_width": 0.0,
			"direction_error": 0.0,
			"primary_probability_floor": 1.0,
			"hit_capacity": INF,
			"retained_damage": 1.0,
			"travel_speed": INF,
			"maximum_travel_distance": stats.max_range,
		},
		"redirects":
		{
			"count": 0,
			"retained_damage": 0.0,
			"travel_speed": 0.0,
			"maximum_travel_distance": 0.0,
			"target_selection": "none",
		},
	}
	if stats is RangedWeaponStats:
		result.paths = {
			"count": stats.nb_projectiles,
			"angular_half_extent": 0.0,
			"corridor_half_width": 0.0,
			"direction_error": max(0.02, stats.projectile_spread + max(0.0, 1.0 - stats.accuracy)),
			"primary_probability_floor": clamp(stats.accuracy, 0.1, 1.0),
			"hit_capacity": stats.piercing + 1,
			"retained_damage": 1.0 - stats.piercing_dmg_reduction,
			"travel_speed": max(0.0, float(stats.projectile_speed)),
			# PlayerProjectile remains alive for this original extra distance.
			"maximum_travel_distance": stats.max_range + 100.0,
		}
		result.redirects = {
			"count": stats.bounce,
			"retained_damage": 1.0 - stats.bounce_dmg_reduction,
			"travel_speed": max(0.0, float(stats.projectile_speed)),
			"maximum_travel_distance": 10000.0,
			"target_selection": "uniform_other_enemy",
		}
	elif stats is MeleeWeaponStats:
		var attack_type: int = stats.attack_type
		if "next_attack_type" in weapon:
			attack_type = weapon.next_attack_type
		if attack_type == MeleeWeaponStats.AttackType.SWEEP:
			result.paths.angular_half_extent = 0.9 * PI
		else:
			result.paths.corridor_half_width = 16.0
		result.paths.travel_speed = INF
	return result


func _adapt_impact(stats: Resource) -> Dictionary:
	return {
		"damage": stats.damage,
		"critical_chance": stats.crit_chance,
		"critical_damage_multiplier": stats.crit_damage,
		"lifesteal": stats.lifesteal,
		"scaling": _adapt_scaling(stats.scaling_stats),
	}


func _adapt_rules(weapon: Node, stats: Resource, player_index: int) -> Array:
	var rules := []
	_append_critical_delivery_rules(rules, weapon.effects, player_index)
	_append_hit_result_rules(rules, weapon, stats, player_index)
	return rules


func _append_critical_delivery_rules(rules: Array, effects: Array, player_index: int) -> void:
	var penetration: int = max(
		0, int(RunData.get_player_effect(Keys.pierce_on_crit_hash, player_index))
	)
	var retarget: int = max(
		0, int(RunData.get_player_effect(Keys.bounce_on_crit_hash, player_index))
	)
	for effect in effects:
		if effect.key_hash == Keys.pierce_on_crit_hash:
			penetration += max(0, int(effect.value))
		elif effect.key_hash == Keys.bounce_on_crit_hash:
			retarget += max(0, int(effect.value))
	_append_add_rule(rules, "critical_hit", "delivery.paths.hit_capacity", penetration)
	_append_add_rule(rules, "critical_hit", "delivery.redirects.count", retarget)


func _append_add_rule(rules: Array, event: String, target: String, value: float) -> void:
	if value == 0.0:
		return
	rules.push_back(
		{
			"event": event,
			"condition": {},
			"consequences": [{"target": target, "operation": "add", "value": value}],
		}
	)


func _append_hit_result_rules(
	rules: Array, weapon: Node, stats: Resource, player_index: int
) -> void:
	for effect in weapon.effects:
		if effect is OneShotOnHitEffect:
			_append_damage_rule(
				rules,
				clamp(effect.value / 100.0, 0.0, 1.0),
				_damage_amount(0.0, -1.0, 1.0),
				_target_delivery(true, false, 0.0, 1.0),
				false
			)
		elif effect is ExplodingEffect:
			var area_bonus: float = Utils.get_stat(Keys.explosion_size_hash, player_index) / 100.0
			var area_scale: float = max(0.1, effect.scale * (1.0 + area_bonus))
			_append_damage_rule(
				rules,
				clamp(effect.chance, 0.0, 1.0),
				_damage_amount(0.0, 1.0, 0.0),
				_target_delivery(false, true, 150.0 * area_scale, INF),
				false
			)

	var burning: Resource = stats.burning_data
	if burning != null and not burning.is_not_burning():
		_append_damage_rule(
			rules,
			clamp(burning.chance, 0.0, 1.0),
			_damage_amount(burning.damage * max(0, burning.duration), 0.0, 0.0),
			_target_delivery(true, false, 0.0, 1.0),
			true
		)

	var hitbox: Node = weapon._hitbox
	if hitbox == null or hitbox.projectiles_on_hit.size() < 2:
		return
	var projectile_stats: Resource = hitbox.projectiles_on_hit[1]
	var critical_multiplier: float = (
		1.0
		+ projectile_stats.crit_chance * max(0.0, projectile_stats.crit_damage - 1.0)
	)
	var projectile_delivery := _target_delivery(
		false, true, INF, max(0, int(hitbox.projectiles_on_hit[0]))
	)
	projectile_delivery.target_selection = (
		"uniform_other_enemy"
		if bool(hitbox.projectiles_on_hit[2])
		else "random_direction"
	)
	projectile_delivery.travel_speed = max(0.0, float(projectile_stats.projectile_speed))
	projectile_delivery.maximum_travel_distance = max(
		0.0, float(projectile_stats.max_range) + 100.0
	)
	_append_damage_rule(
		rules,
		1.0,
		_damage_amount(projectile_stats.damage * critical_multiplier, 0.0, 0.0),
		projectile_delivery,
		false
	)


func _damage_amount(
	constant: float, impact_coefficient: float, target_maximum_health_coefficient: float
) -> Dictionary:
	return {
		"constant": constant,
		"impact_coefficient": impact_coefficient,
		"target_maximum_health_coefficient": target_maximum_health_coefficient,
		"minimum": 0.0,
	}


func _target_delivery(
	reuse_event_targets: bool, exclude_event_targets: bool, radius: float, capacity_per_event: float
) -> Dictionary:
	return {
		"reuse_event_targets": reuse_event_targets,
		"exclude_event_targets": exclude_event_targets,
		"anchor_on_event_entity": true,
		"radius": radius,
		"capacity_per_event": capacity_per_event,
		"target_selection": "event_targets" if reuse_event_targets else "area",
		"travel_speed": INF,
		"maximum_travel_distance": radius,
	}


func _append_damage_rule(
	rules: Array,
	probability: float,
	amount: Dictionary,
	delivery: Dictionary,
	once_per_forecast: bool
) -> void:
	if probability <= 0.0:
		return
	rules.push_back(
		{
			"event": "weapon_hit",
			"condition": {"once_per_forecast": once_per_forecast},
			"consequences":
			[
				{
					"target": "enemy_health",
					"operation": "deal_damage",
					"probability": probability,
					"amount": amount,
					"delivery": delivery,
				}
			],
		}
	)


func _adapt_scaling(scaling_stats: Array) -> Array:
	var result := []
	for scaling in scaling_stats:
		if scaling.size() < 2:
			continue
		var stat_name: String = _stat_metadata.get_stat_name(scaling[0])
		if stat_name.empty():
			continue
		result.push_back({"stat": stat_name, "coefficient": scaling[1]})
	return result
