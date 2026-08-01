extends Reference

# Observes transparent player-owned facts as exact values and normalized mechanics,
# while keeping content IDs and scene objects out of the public observation.

const PlayerMechanicCompiler := preload(
	"res://mods-unpacked/IPlayLF2-Autopilot/bot/knowledge/mechanics/player_mechanic_compiler.gd"
)
const StatVocabulary := preload(
	"res://mods-unpacked/IPlayLF2-Autopilot/bot/knowledge/stat_vocabulary.gd"
)

var _player_mechanic_compiler: Reference = PlayerMechanicCompiler.new()
var _stat_vocabulary: Reference = StatVocabulary.new()


func observe(player_index: int, player: Node) -> Dictionary:
	var compiled_mechanics := _player_mechanic_compiler.compile(player_index, player)
	return {
		"dead": player.dead,
		"health":
		{
			"current": player.current_stats.health,
			"maximum": player.max_stats.health,
			"ratio": _safe_ratio(player.current_stats.health, player.max_stats.health),
		},
		"progression":
		{
			"level": RunData.get_player_level(player_index),
			"experience": RunData.get_player_xp(player_index),
			"next_level_experience_required": RunData.get_next_level_xp_needed(player_index),
		},
		"resources": {"materials": RunData.get_player_gold(player_index)},
		"inventory": {"item_count": RunData.get_player_items(player_index).size()},
		"effective_stats": _get_effective_stats(player_index),
		"runtime_stats": _get_runtime_stats(player),
		"movement": _get_movement_state(player),
		"pickup": _get_pickup_state(player_index, player),
		"weapons":
		_observe_weapons(
			player_index, player, compiled_mechanics.automatic_attacks_allowed_while_moving
		),
		"mechanic_rules": compiled_mechanics.rules,
	}


func _get_effective_stats(player_index: int) -> Dictionary:
	return {
		"max_health": Utils.get_stat(Keys.stat_max_hp_hash, player_index),
		"health_regeneration": Utils.get_stat(Keys.stat_hp_regeneration_hash, player_index),
		"lifesteal": Utils.get_stat(Keys.stat_lifesteal_hash, player_index),
		"percent_damage": Utils.get_stat(Keys.stat_damage_hash, player_index),
		"melee_damage": Utils.get_stat(Keys.stat_melee_damage_hash, player_index),
		"ranged_damage": Utils.get_stat(Keys.stat_ranged_damage_hash, player_index),
		"elemental_damage": Utils.get_stat(Keys.stat_elemental_damage_hash, player_index),
		"attack_speed": Utils.get_stat(Keys.stat_attack_speed_hash, player_index),
		"critical_chance": Utils.get_stat(Keys.stat_crit_chance_hash, player_index),
		"engineering": Utils.get_stat(Keys.stat_engineering_hash, player_index),
		"range": Utils.get_stat(Keys.stat_range_hash, player_index),
		"armor": Utils.get_stat(Keys.stat_armor_hash, player_index),
		"dodge": Utils.get_stat(Keys.stat_dodge_hash, player_index),
		"speed": Utils.get_stat(Keys.stat_speed_hash, player_index),
		"luck": Utils.get_stat(Keys.stat_luck_hash, player_index),
		"harvesting": Utils.get_stat(Keys.stat_harvesting_hash, player_index),
		"curse": Utils.get_stat(Keys.stat_curse_hash, player_index),
	}


func _get_runtime_stats(player: Node) -> Dictionary:
	return {
		"move_speed": player.get_move_speed(),
		"armor": player.current_stats.armor,
		"dodge_chance": player.current_stats.dodge,
	}


func _get_movement_state(player: Node) -> Dictionary:
	return {
		"input_vector": player._current_movement,
		"is_moving": player._current_movement != Vector2.ZERO,
		"velocity": player.linear_velocity,
		"standing_effects_active": player.not_moving_bonuses_applied,
		"moving_effects_active": player.moving_bonuses_applied,
	}


func _get_pickup_state(player_index: int, player: Node) -> Dictionary:
	var attract_shape: CircleShape2D = player._item_attract_area.get_node("CollisionShape2D").shape
	var pickup_shape: CircleShape2D = player._item_pickup_area.get_node("CollisionShape2D").shape
	return {
		"range_modifier_percent": RunData.get_player_effect(Keys.pickup_range_hash, player_index),
		"attraction_radius": attract_shape.radius,
		"collection_radius": pickup_shape.radius,
	}


func _observe_weapons(player_index: int, player: Node, attacks_allowed_while_moving: bool) -> Array:
	var weapons := []
	for weapon in player.current_weapons:
		if not is_instance_valid(weapon):
			continue
		var stats: Resource = weapon.current_stats
		var weapon_observation := {
			"slot": weapon.weapon_pos,
			"tier": weapon.tier,
			"attack_mode": "ranged" if stats is RangedWeaponStats else "melee",
			"damage": stats.damage,
			"cooldown_ticks": stats.cooldown,
			"cooldown_remaining_ticks": weapon._current_cooldown,
			"cooldown_remaining_seconds": weapon._current_cooldown / 60.0,
			"nominal_attack_cycle_seconds": stats.get_cooldown_value(player_index, 1.0),
			"cooldown_ready": weapon._current_cooldown <= 0.0,
			"automatic_attack_active": weapon._is_shooting,
			"movement_permits_automatic_attack":
			attacks_allowed_while_moving or player._current_movement == Vector2.ZERO,
			"reloads_on_material_pickup":
			_weapon_has_effect(weapon, Keys.reload_when_pickup_gold_hash),
			"minimum_range": stats.min_range,
			"maximum_range": stats.max_range,
			"accuracy": stats.accuracy,
			"critical_chance": stats.crit_chance,
			"critical_damage_multiplier": stats.crit_damage,
			"knockback": stats.knockback,
			"lifesteal": stats.lifesteal,
			"scaling": _get_weapon_scaling(stats.scaling_stats),
			"additional_cooldown_every_attacks": stats.additional_cooldown_every_x_shots,
			"additional_cooldown_multiplier": stats.additional_cooldown_multiplier,
		}
		if stats is RangedWeaponStats:
			weapon_observation.merge(_get_ranged_weapon_stats(stats))
		elif stats is MeleeWeaponStats:
			weapon_observation.merge(_get_melee_weapon_stats(stats))
		weapons.push_back(weapon_observation)
	return weapons


func _weapon_has_effect(weapon: Node, effect_hash: int) -> bool:
	for effect in weapon.effects:
		if effect.key_hash == effect_hash or effect.custom_key_hash == effect_hash:
			return true
	return false


func _get_ranged_weapon_stats(stats: RangedWeaponStats) -> Dictionary:
	return {
		"projectile_count": stats.nb_projectiles,
		"projectile_spread": stats.projectile_spread,
		"projectile_speed": stats.projectile_speed,
		"piercing": stats.piercing,
		"piercing_damage_retained": 1.0 - stats.piercing_dmg_reduction,
		"bounce": stats.bounce,
		"bounce_damage_retained": 1.0 - stats.bounce_dmg_reduction,
	}


func _get_melee_weapon_stats(stats: MeleeWeaponStats) -> Dictionary:
	return {
		"attack_pattern":
		"sweep" if stats.attack_type == MeleeWeaponStats.AttackType.SWEEP else "thrust",
		"alternate_attack_type": stats.alternate_attack_type,
		"return_damage": stats.deal_dmg_on_return,
	}


func _get_weapon_scaling(scaling_stats: Array) -> Array:
	var result := []
	for scaling in scaling_stats:
		if scaling.size() < 2:
			continue
		var stat_name := _stat_vocabulary.get_name(scaling[0])
		if stat_name.empty():
			continue
		result.push_back({"stat": stat_name, "coefficient": scaling[1]})
	return result


func _safe_ratio(value: float, maximum: float) -> float:
	return 0.0 if maximum <= 0.0 else value / maximum
