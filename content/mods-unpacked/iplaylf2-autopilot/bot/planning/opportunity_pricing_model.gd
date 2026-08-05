extends Reference

# Prices observed materials, consumables, destructibles, and death rewards in
# material-equivalent marginal value using only current public state. Route
# accessibility and event realization remain in their owning predictors.

# Generating an item box creates a wave-end item choice that did not previously
# exist. Its item-value profile uses the expected shop-price proxy under the exact
# wave-tier distribution and current unlocked item pools. Once a box is on the ground,
# vanilla collects it at wave end, so moving toward it earns only its immediate
# healing and pickup-event effects.
const PlayerRuleProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_rule_projector.gd"
)
const DeathRewardProbabilityModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/death_reward_probability_model.gd"
)

var _rule_projector: Reference = PlayerRuleProjector.new()
var _death_reward_probability_model: Reference = DeathRewardProbabilityModel.new()


func material_unit_collection_value(observation: Dictionary) -> float:
	# A material collected during the wave is immediately available for the next
	# shop and level-up processing. Vanilla defers uncollected materials through
	# bonus gold, so the value of avoiding that deferral rises continuously as the
	# current collection window closes.
	var duration: float = max(0.01, observation.wave_state.duration_seconds)
	var remaining_ratio: float = clamp(
		observation.wave_state.seconds_remaining / duration, 0.0, 1.0
	)
	return 1.0 + (1.0 - remaining_ratio)


func material_collection_value(observation: Dictionary, material: Dictionary) -> float:
	var material_quantity: float = max(0.0, material.material_quantity)
	return material_quantity * material_unit_collection_value(observation)


func tree_destruction_value(
	observation: Dictionary, tree: Dictionary, health_inventory_value: Dictionary
) -> float:
	var death_rewards: Dictionary = tree.destructible_profile.death_rewards
	var destruction_value := death_reward_value(observation, death_rewards)
	# Tree materials are still wave pickups, so their timing value must use the
	# same price as already visible materials. A tree's base consumable chance is
	# 100%; its high conditional item-box chance creates item value. Every possible
	# consumable also carries healing, including an item box, so recovery uses the
	# full consumable chance rather than only the complementary fruit outcome.
	destruction_value += (
		max(0.0, death_rewards.get("material_quantity", 0.0))
		* _death_reward_probability_model.material_drop_probability(observation, death_rewards)
		* (material_unit_collection_value(observation) - 1.0)
	)
	destruction_value += (
		_death_reward_probability_model.any_consumable_drop_probability(observation, death_rewards)
		* health_inventory_value.maximum_consumable_recovery
		# Destroying the tree creates replenishment supply; it does not merely
		# convert supply already on the floor into liquid health.
		* health_inventory_value.replenishment_unit_value
	)
	return max(0.0, destruction_value - _living_tree_preservation_value(observation))


func consumable_recovery_value(observation: Dictionary, consumable: Dictionary) -> float:
	var missing_health: float = max(
		0.0, observation.player_state.health.maximum - observation.player_state.health.current
	)
	if missing_health <= 0.0:
		return 0.0
	var recovery: float = consumable.get("pickup_profile", {}).get("base_recovery", 0.0)
	recovery = _rule_projector.project_recovery(
		observation.player_state.effect_rules, "consumable_pickup", recovery
	)
	recovery = _rule_projector.project_recovery(
		observation.player_state.effect_rules, "healing", recovery
	)
	return min(missing_health, max(0.0, recovery))


func consumable_pickup_value(
	observation: Dictionary, consumable: Dictionary, health_inventory_value: Dictionary
) -> float:
	return (
		consumable_recovery_value(observation, consumable)
		* health_inventory_value.get("recovery_conversion_unit_value", 0.0)
	)


func expected_item_box_item_value(observation: Dictionary) -> float:
	var profile: Dictionary = observation.player_state.item_box_item_value_profile
	var probabilities: Array = profile.tier_probabilities
	var values: Array = profile.mean_shop_price_by_tier
	assert(probabilities.size() == values.size())
	var result := 0.0
	for tier in probabilities.size():
		result += probabilities[tier] * values[tier]
	return result


func death_reward_value(observation: Dictionary, death_rewards: Dictionary) -> float:
	var value: float = (
		max(0.0, death_rewards.get("material_quantity", 0.0))
		* _death_reward_probability_model.material_drop_probability(observation, death_rewards)
	)
	var item_box_probability: float = _death_reward_probability_model.item_box_drop_probability(
		observation, death_rewards
	)
	if item_box_probability > 0.0:
		value += item_box_probability * expected_item_box_item_value(observation)
	return value


func _living_tree_preservation_value(observation: Dictionary) -> float:
	var result := 0.0
	for rule in observation.player_state.effect_rules:
		if rule.event != "wave_end":
			continue
		for consequence in rule.consequences:
			if consequence.target == "materials_and_experience_per_living_tree":
				result += max(0.0, consequence.get("value", 0.0))
	return result
