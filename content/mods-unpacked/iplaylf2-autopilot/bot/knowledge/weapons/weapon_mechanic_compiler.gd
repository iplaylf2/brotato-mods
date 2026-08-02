extends Reference

# Compiles target-version weapon state and resources into three orthogonal state
# axes plus a generic transition language. Vanilla Effect subclasses and scene
# nodes never cross this boundary.

const StatVocabulary := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/stat_vocabulary.gd"
)

var _stat_vocabulary: Reference = StatVocabulary.new()


func compile(
	weapon: Node, stats: Resource, player_index: int, attacks_allowed_while_moving: bool
) -> Dictionary:
	return {
		"timing": _adapt_timing(weapon, stats, player_index, attacks_allowed_while_moving),
		"delivery": _adapt_delivery(weapon, stats),
		"impact": _adapt_impact(stats),
		"rules": _adapt_rules(weapon, stats, player_index),
	}


func _adapt_timing(
	weapon: Node, stats: Resource, player_index: int, attacks_allowed_while_moving: bool
) -> Dictionary:
	var reload_every: int = stats.additional_cooldown_every_x_shots
	var reload_multiplier: float = stats.additional_cooldown_multiplier
	var attacks_until_long_cycle := -1
	var long_cycle_seconds := stats.get_cooldown_value(player_index, 1.0)
	if reload_every > 0 and reload_multiplier > 1.0:
		var phase: int = weapon._nb_shots_taken % reload_every
		attacks_until_long_cycle = reload_every if phase == 0 else reload_every - phase
		long_cycle_seconds = stats.get_cooldown_value(player_index, reload_multiplier)
	return {
		"cooldown_remaining_seconds": weapon._current_cooldown / 60.0,
		"cycle_seconds": stats.get_cooldown_value(player_index, 1.0),
		"active": weapon._is_shooting,
		"permitted_while_moving": attacks_allowed_while_moving,
		"long_cycle_every_attacks": reload_every,
		"attacks_until_long_cycle": attacks_until_long_cycle,
		"long_cycle_seconds": long_cycle_seconds,
	}


func _adapt_delivery(weapon: Node, stats: Resource) -> Dictionary:
	var result := {
		"minimum_range": stats.min_range,
		"maximum_range": stats.max_range,
		"paths":
		{
			"count": 1,
			"angular_half_extent": 0.0,
			"corridor_half_width": 0.0,
			"direction_error": 0.0,
			"primary_probability_floor": 1.0,
			"hit_capacity": INF,
			"retained_damage": 1.0,
		},
		"redirects": {"count": 0, "retained_damage": 0.0},
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
		}
		result.redirects = {
			"count": stats.bounce,
			"retained_damage": 1.0 - stats.bounce_dmg_reduction,
		}
	elif stats is MeleeWeaponStats:
		var attack_type: int = stats.attack_type
		if "next_attack_type" in weapon:
			attack_type = weapon.next_attack_type
		if attack_type == MeleeWeaponStats.AttackType.SWEEP:
			result.paths.angular_half_extent = 0.9 * PI
		else:
			result.paths.corridor_half_width = 16.0
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
	_append_material_reload_rule(rules, weapon.effects)
	_append_critical_delivery_rules(rules, weapon.effects, player_index)
	_append_hit_result_rules(rules, weapon, stats, player_index)
	return rules


func _append_material_reload_rule(rules: Array, effects: Array) -> void:
	for effect in effects:
		if effect.key_hash != Keys.reload_when_pickup_gold_hash:
			continue
		rules.push_back(
			{
				"event": "material_pickup",
				"condition": {"selected_highest_cooldown_weapon": true},
				"consequences": [{"target": "timing.cooldown", "operation": "set", "value": 0.0}],
			}
		)
		return


func _append_critical_delivery_rules(rules: Array, effects: Array, player_index: int) -> void:
	var penetration := max(
		0, int(RunData.get_player_effect(Keys.pierce_on_crit_hash, player_index))
	)
	var retarget := max(0, int(RunData.get_player_effect(Keys.bounce_on_crit_hash, player_index)))
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
	var critical_multiplier := (
		1.0
		+ projectile_stats.crit_chance * max(0.0, projectile_stats.crit_damage - 1.0)
	)
	_append_damage_rule(
		rules,
		1.0,
		_damage_amount(projectile_stats.damage * critical_multiplier, 0.0, 0.0),
		_target_delivery(false, true, INF, max(0, int(hitbox.projectiles_on_hit[0]))),
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
		var stat_name := _stat_vocabulary.get_name(scaling[0])
		if stat_name.empty():
			continue
		result.push_back({"stat": stat_name, "coefficient": scaling[1]})
	return result
