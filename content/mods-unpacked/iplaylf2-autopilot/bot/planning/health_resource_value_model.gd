extends Reference

# Prices wave-local health and replacement supply from the projected survival
# buffer, while preserving an undiscounted value for terminal collision.

const PlayerRuleProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_rule_projector.gd"
)
const OpportunityValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_value_model.gd"
)
const WeaponFireModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapon_fire_model.gd"
)

const RECOVERY_LOOKAHEAD_SECONDS := 8.0
const BASE_HEALTH_VALUE := 0.75
const SURVIVAL_BUFFER_VALUE := 12.0

var _rule_projector: Reference = PlayerRuleProjector.new()
var _opportunity_value_model: Reference = OpportunityValueModel.new()
var _weapon_fire_model: Reference = WeaponFireModel.new()


func estimate(observation: Dictionary, rule_projection: Dictionary) -> Dictionary:
	var current_health: float = observation.player_state.health.current
	var maximum_health: float = max(1.0, observation.player_state.health.maximum)
	var remaining_seconds: float = max(0.0, observation.wave_state.seconds_remaining)
	var wave_duration: float = max(0.01, observation.wave_state.duration_seconds)
	var remaining_fraction: float = clamp(remaining_seconds / wave_duration, 0.0, 1.0)
	var horizon_seconds := min(remaining_seconds, RECOVERY_LOOKAHEAD_SECONDS)
	var consumable_recovery: float = rule_projection.recovery.maximum_consumable_recovery
	var observed_supply := _observed_consumable_supply(observation)
	var reachable_observed_supply := _reachable_observed_consumable_supply(
		observation, horizon_seconds
	)
	var expected_drop_supply := _expected_drop_supply(
		observation, consumable_recovery, horizon_seconds
	)
	var passive_health_rate: float = (
		rule_projection.survival.health_rate
		+ rule_projection.survival.recovery_rate
	)
	var passive_supply := max(0.0, passive_health_rate) * horizon_seconds
	var passive_drain := max(0.0, -passive_health_rate) * horizon_seconds
	var lifesteal_supply := _expected_lifesteal_supply(observation, horizon_seconds)
	var replacement_supply := (
		reachable_observed_supply
		+ expected_drop_supply
		+ passive_supply
		+ lifesteal_supply
	)
	var survival_reserve := _observed_hit_reserve(observation)
	var unreplaced_buffer := max(1.0, current_health - passive_drain - survival_reserve)
	var effective_buffer := max(1.0, unreplaced_buffer + replacement_supply)
	var unreplaced_health_value := (
		BASE_HEALTH_VALUE
		+ SURVIVAL_BUFFER_VALUE * (1.0 + remaining_fraction) / unreplaced_buffer
	)
	var replacement_adjusted_health_value := (
		BASE_HEALTH_VALUE
		+ SURVIVAL_BUFFER_VALUE * (1.0 + remaining_fraction) / effective_buffer
	)
	# Non-terminal health and replacement supply are wave-local resources. Their
	# shadow prices decline over the whole remaining wave because any reserve left
	# at cleanup is discarded. Immediate lethal damage keeps the undiscounted price.
	var nonterminal_health_value := replacement_adjusted_health_value * remaining_fraction
	var unreplaced_nonterminal_health_value := unreplaced_health_value * remaining_fraction
	var terminal_health_value := (
		BASE_HEALTH_VALUE
		+ (
			SURVIVAL_BUFFER_VALUE
			* (1.0 + remaining_fraction)
			/ max(1.0, current_health - survival_reserve)
		)
	)
	var recovery_supply_value := nonterminal_health_value
	var scarcity := clamp(
		(
			(
				survival_reserve
				+ maximum_health * 0.35
				+ passive_drain
				- current_health
				- replacement_supply
			)
			/ maximum_health
		),
		0.0,
		1.0
	)
	return {
		"marginal_health_value": nonterminal_health_value,
		"terminal_health_value": terminal_health_value,
		"recovery_supply_value": recovery_supply_value,
		"recovery_conversion_value":
		max(0.0, unreplaced_nonterminal_health_value - nonterminal_health_value),
		"observed_recovery_supply": observed_supply,
		"reachable_observed_recovery_supply": reachable_observed_supply,
		"expected_drop_recovery_supply": expected_drop_supply,
		"passive_recovery_supply": passive_supply,
		"expected_lifesteal_recovery_supply": lifesteal_supply,
		"expected_passive_health_drain": passive_drain,
		"replacement_health_supply": replacement_supply,
		"observed_hit_reserve": survival_reserve,
		"effective_survival_buffer": effective_buffer,
		"wave_remaining_fraction": remaining_fraction,
		"health_scarcity": scarcity,
		"maximum_consumable_recovery": consumable_recovery,
	}


func _observed_consumable_supply(observation: Dictionary) -> float:
	var result := 0.0
	for entity in observation.get("remembered_entities", []):
		if entity.kind != "consumable":
			continue
		result += _consumable_recovery(observation, entity) * entity.existence_confidence
	return result


func _reachable_observed_consumable_supply(
	observation: Dictionary, horizon_seconds: float
) -> float:
	if horizon_seconds <= 0.0:
		return 0.0
	var result := 0.0
	var travel_capacity: float = (
		max(1.0, observation.player_state.runtime_stats.move_speed)
		* horizon_seconds
	)
	var collection_radius: float = observation.player_state.pickup.collection_radius
	for entity in observation.get("remembered_entities", []):
		if entity.kind != "consumable":
			continue
		var interaction_gap: float = max(
			0.0,
			entity.relative_position.length() - collection_radius - entity.get("visual_radius", 0.0)
		)
		var accessibility: float = clamp(1.0 - interaction_gap / travel_capacity, 0.0, 1.0)
		result += (
			_consumable_recovery(observation, entity)
			* entity.existence_confidence
			* accessibility
		)
	return result


func _expected_lifesteal_supply(observation: Dictionary, horizon_seconds: float) -> float:
	if horizon_seconds <= 0.0 or observation.enemy_tracks.empty():
		return 0.0
	# Context pricing uses target-independent moving fire capacity only when a
	# tracked target exists. Exact per-action target geometry owns realized healing.
	return (
		_weapon_fire_model.expected_lifesteal_rate(observation.player_state.weapons, true)
		* horizon_seconds
	)


func _expected_drop_supply(
	observation: Dictionary, consumable_recovery: float, horizon_seconds: float
) -> float:
	if consumable_recovery <= 0.0 or horizon_seconds <= 0.0:
		return 0.0
	var result := 0.0
	var remaining_seconds: float = max(0.01, observation.wave_state.seconds_remaining)
	var horizon_fraction := clamp(horizon_seconds / remaining_seconds, 0.0, 1.0)
	for track in observation.enemy_tracks:
		var rewards: Dictionary = track.behavior_profile.get("kill_rewards", {})
		var drop_chance := _drop_chance(observation, rewards)
		result += (
			consumable_recovery
			* drop_chance
			* _opportunity_value_model.enemy_kill_feasibility(observation, track)
			* track.recency_confidence
			* horizon_fraction
		)
	for tree in observation.get("remembered_entities", []):
		if tree.kind != "tree":
			continue
		var rewards: Dictionary = tree.get("destructible_profile", {}).get("kill_rewards", {})
		result += (
			consumable_recovery
			* _drop_chance(observation, rewards)
			* _opportunity_value_model.tree_harvest_feasibility(observation, tree)
			* tree.existence_confidence
			* horizon_fraction
		)
	return result


func _drop_chance(observation: Dictionary, rewards: Dictionary) -> float:
	if rewards.get("guaranteed_consumable", false):
		return 1.0
	var chance: float = rewards.get("consumable_drop_chance", 0.0)
	var luck: float = observation.player_state.effective_stats.luck
	return clamp(chance * max(0.0, 1.0 + luck / 100.0), 0.0, 1.0)


func _consumable_recovery(observation: Dictionary, consumable: Dictionary) -> float:
	var recovery: float = consumable.get("pickup_profile", {}).get("base_recovery", 0.0)
	recovery = _rule_projector.project_recovery(
		observation.player_state.effect_rules, "consumable_pickup", recovery
	)
	return max(
		0.0,
		_rule_projector.project_recovery(observation.player_state.effect_rules, "healing", recovery)
	)


func _observed_hit_reserve(observation: Dictionary) -> float:
	var maximum_raw_damage := 1.0
	for projectile in observation.visible_world.enemy_projectiles:
		maximum_raw_damage = max(maximum_raw_damage, projectile.get("contact_damage", 0.0))
	for track in observation.enemy_tracks:
		var measurement: Dictionary = track.get("last_measurement", {})
		maximum_raw_damage = max(
			maximum_raw_damage, measurement.get("contact_damage", measurement.get("damage", 0.0))
		)
	var armor: float = observation.player_state.runtime_stats.armor
	var armor_multiplier := (
		1.0 / (1.0 + armor / 15.0)
		if armor >= 0.0
		else 2.0 - 1.0 / (1.0 - armor / 15.0)
	)
	return max(1.0, round(maximum_raw_damage * armor_multiplier))
