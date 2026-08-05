extends Reference

# Observes transparent player-owned state, then coordinates version-knowledge
# translation without exposing content IDs or scene objects.

const PlayerEffectAdapter := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/player_effects/player_effect_adapter.gd"
)
const StatOpportunityProfileAdapter := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/stats/stat_opportunity_profile_adapter.gd"
)
const ItemBoxItemValueProfileAdapter := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/pickups/"
		+ "item_box_item_value_profile_adapter.gd"
	)
)
const WeaponMechanicCompiler := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/weapons/weapon_mechanic_compiler.gd"
)

var _player_effect_adapter: Reference = PlayerEffectAdapter.new()
var _stat_opportunity_profile_adapter: Reference = StatOpportunityProfileAdapter.new()
var _item_box_item_value_profile_adapter: Reference = ItemBoxItemValueProfileAdapter.new()
var _weapon_mechanic_compiler: Reference = WeaponMechanicCompiler.new()


func observe(player_index: int, player: Node) -> Dictionary:
	var adapted_effects: Dictionary = _player_effect_adapter.adapt(player_index, player)
	var effective_stats := _get_effective_stats(player_index)
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
		"effective_stats": effective_stats,
		"stat_opportunity_profiles": _stat_opportunity_profile_adapter.adapt(),
		"item_box_item_value_profile":
		_item_box_item_value_profile_adapter.adapt(player_index, effective_stats.luck),
		"runtime_stats": _get_runtime_stats(player),
		"collision_radius": _get_collision_radius(player),
		"movement": _get_movement_state(player),
		"pickup": _get_pickup_state(player_index, player),
		"weapons":
		_observe_weapons(
			player_index, player, adapted_effects.automatic_attacks_allowed_while_moving
		),
		"neutral_completion":
		{
			"instant_on_player_hit": adapted_effects.instant_neutral_completion_on_player_hit,
		},
		"effect_rules": adapted_effects.effect_rules,
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
		"hit_protection": player.life_bar_effects().get("hit_protection", 0),
		# Zero damage selects vanilla's current minimum iframe duration, including
		# endless-mode scaling, without duplicating that rule in planning.
		"minimum_invincibility_seconds": player.get_iframes(0.0),
	}


func _get_collision_radius(player: Node) -> float:
	var collision_shape: CollisionShape2D = player.get_node("Collision")
	assert(collision_shape.shape is CircleShape2D)
	return (
		collision_shape.shape.radius
		* max(abs(collision_shape.global_scale.x), abs(collision_shape.global_scale.y))
	)


func _get_movement_state(player: Node) -> Dictionary:
	return {
		"input_vector": player._current_movement,
		"is_moving": player._current_movement != Vector2.ZERO,
		"velocity": player.linear_velocity,
		# RigidBody2D.linear_velocity may contain a one-frame spawn relocation artifact.
		# Vanilla's knockback state is the authoritative external disturbance consumed
		# by Unit.get_next_velocity().
		"knockback_velocity": player.get_knockback_value(),
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
		var weapon_observation := {
			"slot": weapon.weapon_pos,
			"tier": weapon.tier,
			"attack_model":
			_weapon_mechanic_compiler.compile(
				weapon, weapon.current_stats, player_index, attacks_allowed_while_moving
			),
		}
		weapons.push_back(weapon_observation)
	return weapons


func _safe_ratio(value: float, maximum: float) -> float:
	return 0.0 if maximum <= 0.0 else value / maximum
