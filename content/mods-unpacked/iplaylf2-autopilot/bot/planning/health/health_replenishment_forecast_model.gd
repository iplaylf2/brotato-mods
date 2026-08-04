extends Reference

# Forecasts health replenishment that can be realized before wave cleanup.
# This module owns source mechanics and availability; inventory valuation owns
# neither source enumeration nor target-completion allocation.

const PlayerRuleProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_rule_projector.gd"
)
const TargetCompletionAllocationModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/target_completion_allocation_model.gd"
)
const ConsumableDropProbabilityModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/consumable_drop_probability_model.gd"
)
const WeaponAttackCapacityModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapons/weapon_attack_capacity_model.gd"
)

var _rule_projector: Reference = PlayerRuleProjector.new()
var _target_completion_allocation_model: Reference = TargetCompletionAllocationModel.new()
var _consumable_drop_probability_model: Reference = ConsumableDropProbabilityModel.new()
var _weapon_attack_capacity_model: Reference = WeaponAttackCapacityModel.new()


func forecast(
	observation: Dictionary, rule_projection: Dictionary, completion_ledger: Dictionary
) -> Dictionary:
	var remaining_seconds: float = max(0.0, observation.wave_state.seconds_remaining)
	var maximum_consumable_recovery: float = rule_projection.recovery.maximum_consumable_recovery
	var observed_replenishment := _observed_replenishment(observation)
	var reachable_observed_replenishment := _reachable_observed_replenishment(
		observation, remaining_seconds
	)
	var expected_drop_replenishment := _expected_drop_replenishment(
		observation, maximum_consumable_recovery, completion_ledger
	)
	var passive_health_rate: float = (
		rule_projection.survival.health_rate
		+ rule_projection.survival.recovery_rate
	)
	var passive_replenishment := max(0.0, passive_health_rate) * remaining_seconds
	var expected_passive_health_drain := max(0.0, -passive_health_rate) * remaining_seconds
	var expected_lifesteal_replenishment := _expected_lifesteal_replenishment(
		observation, remaining_seconds
	)
	return {
		"observed_replenishment": observed_replenishment,
		"reachable_observed_replenishment": reachable_observed_replenishment,
		"expected_drop_replenishment": expected_drop_replenishment,
		"passive_replenishment": passive_replenishment,
		"expected_lifesteal_replenishment": expected_lifesteal_replenishment,
		"expected_passive_health_drain": expected_passive_health_drain,
		"total_replenishment":
		(
			reachable_observed_replenishment
			+ expected_drop_replenishment
			+ passive_replenishment
			+ expected_lifesteal_replenishment
		),
		"maximum_consumable_recovery": maximum_consumable_recovery,
	}


func _observed_replenishment(observation: Dictionary) -> float:
	var result := 0.0
	for entity in observation.get("remembered_entities", []):
		if entity.kind != "consumable":
			continue
		result += _consumable_recovery(observation, entity) * entity.existence_confidence
	return result


func _reachable_observed_replenishment(observation: Dictionary, remaining_seconds: float) -> float:
	if remaining_seconds <= 0.0:
		return 0.0
	var result := 0.0
	var travel_capacity: float = (
		max(1.0, observation.player_state.runtime_stats.move_speed)
		* remaining_seconds
	)
	var collection_radius: float = observation.player_state.pickup.collection_radius
	for entity in observation.get("remembered_entities", []):
		if entity.kind != "consumable":
			continue
		var interaction_gap: float = max(
			0.0,
			entity.relative_position.length() - collection_radius - entity.get("visual_radius", 0.0)
		)
		var availability: float = clamp(1.0 - interaction_gap / travel_capacity, 0.0, 1.0)
		result += (
			_consumable_recovery(observation, entity)
			* entity.existence_confidence
			* availability
		)
	return result


func _expected_lifesteal_replenishment(observation: Dictionary, remaining_seconds: float) -> float:
	if remaining_seconds <= 0.0 or observation.enemy_tracks.empty():
		return 0.0
	# Context pricing uses target-independent moving fire capacity only when a
	# tracked target exists. Exact per-action target geometry owns realized healing.
	return (
		_weapon_attack_capacity_model.expected_primary_lifesteal_rate(
			observation.player_state.weapons, true
		)
		* remaining_seconds
	)


func _expected_drop_replenishment(
	observation: Dictionary, maximum_consumable_recovery: float, completion_ledger: Dictionary
) -> float:
	if maximum_consumable_recovery <= 0.0:
		return 0.0
	var result := 0.0
	for track in observation.enemy_tracks:
		var rewards: Dictionary = track.behavior_profile.get("kill_rewards", {})
		var drop_chance: float = _consumable_drop_probability_model.any_consumable_drop_chance(
			observation, rewards
		)
		result += (
			maximum_consumable_recovery
			* drop_chance
			* _target_completion_allocation_model.enemy_completion_likelihood(
				completion_ledger, track
			)
		)
	for tree in observation.get("remembered_entities", []):
		if tree.kind != "tree":
			continue
		var rewards: Dictionary = tree.get("destructible_profile", {}).get("kill_rewards", {})
		result += (
			maximum_consumable_recovery
			* _consumable_drop_probability_model.any_consumable_drop_chance(observation, rewards)
			* _target_completion_allocation_model.tree_completion_likelihood(
				completion_ledger, tree
			)
		)
	return result


func _consumable_recovery(observation: Dictionary, consumable: Dictionary) -> float:
	var recovery: float = consumable.get("pickup_profile", {}).get("base_recovery", 0.0)
	recovery = _rule_projector.project_recovery(
		observation.player_state.effect_rules, "consumable_pickup", recovery
	)
	return max(
		0.0,
		_rule_projector.project_recovery(observation.player_state.effect_rules, "healing", recovery)
	)
