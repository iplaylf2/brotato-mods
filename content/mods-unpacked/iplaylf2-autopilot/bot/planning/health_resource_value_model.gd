extends Reference

# Prices one point of health from the current survival buffer and the discounted
# supply of replacement health. This is a state valuation, not a damage budget:
# ordinary damage remains admissible whenever another outcome pays for it.

const PlayerRuleProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_rule_projector.gd"
)
const OpportunityValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_value_model.gd"
)

const RECOVERY_LOOKAHEAD_SECONDS := 8.0
const BASE_HEALTH_VALUE := 0.75
const SURVIVAL_BUFFER_VALUE := 12.0

var _rule_projector: Reference = PlayerRuleProjector.new()
var _opportunity_value_model: Reference = OpportunityValueModel.new()


func estimate(observation: Dictionary, rule_projection: Dictionary) -> Dictionary:
	var current_health: float = observation.player_state.health.current
	var maximum_health: float = max(1.0, observation.player_state.health.maximum)
	var remaining_seconds: float = max(0.0, observation.wave_state.seconds_remaining)
	var horizon_seconds := min(remaining_seconds, RECOVERY_LOOKAHEAD_SECONDS)
	var consumable_recovery: float = rule_projection.recovery.maximum_consumable_recovery
	var observed_supply := _observed_consumable_supply(observation)
	var expected_drop_supply := _expected_drop_supply(
		observation, consumable_recovery, horizon_seconds
	)
	var passive_supply := max(0.0, rule_projection.survival.recovery_rate) * horizon_seconds
	var replacement_supply := observed_supply + expected_drop_supply + passive_supply
	var survival_reserve := _observed_hit_reserve(observation)
	# Remote and stochastic recovery cannot absorb the next collision, so it only
	# partially softens the marginal price of current health.
	var effective_buffer := max(
		1.0, current_health + 0.25 * (expected_drop_supply + passive_supply) - survival_reserve
	)
	var exposure_fraction := clamp(remaining_seconds / 60.0, 0.0, 1.0)
	var marginal_health_value := (
		BASE_HEALTH_VALUE
		+ SURVIVAL_BUFFER_VALUE * (1.0 + exposure_fraction) / effective_buffer
	)
	var recovery_supply_buffer := max(1.0, current_health + replacement_supply - survival_reserve)
	var recovery_supply_value := (
		BASE_HEALTH_VALUE
		+ SURVIVAL_BUFFER_VALUE * (1.0 + exposure_fraction) / recovery_supply_buffer
	)
	var scarcity := clamp(
		(
			(survival_reserve + maximum_health * 0.35 - current_health - replacement_supply)
			/ maximum_health
		),
		0.0,
		1.0
	)
	return {
		"marginal_health_value": marginal_health_value,
		"recovery_supply_value": recovery_supply_value,
		"recovery_conversion_value": max(0.0, marginal_health_value - recovery_supply_value),
		"observed_recovery_supply": observed_supply,
		"expected_drop_recovery_supply": expected_drop_supply,
		"passive_recovery_supply": passive_supply,
		"replacement_health_supply": replacement_supply,
		"observed_hit_reserve": survival_reserve,
		"effective_survival_buffer": effective_buffer,
		"health_scarcity": scarcity,
	}


func _observed_consumable_supply(observation: Dictionary) -> float:
	var result := 0.0
	for entity in observation.get("remembered_entities", []):
		if entity.kind != "consumable":
			continue
		result += _consumable_recovery(observation, entity) * entity.existence_confidence
	return result


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
