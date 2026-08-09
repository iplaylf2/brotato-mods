extends Reference

# Prices observed materials, consumables, destructibles, and death rewards in
# material-equivalent marginal value using only public state supplied by callers.
# Route accessibility, target completion, and event realization remain in their
# owning predictors; this model only prices any supplied estimated event distance.

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
const StatOpportunityPricingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/stat_opportunity_pricing_model.gd"
)
const HealthLossValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/health/" + "health_loss_value_model.gd"
)

var _rule_projector: Reference = PlayerRuleProjector.new()
var _death_reward_probability_model: Reference = DeathRewardProbabilityModel.new()
var _stat_opportunity_pricing_model: Reference = StatOpportunityPricingModel.new()
var _health_loss_value_model: Reference = HealthLossValueModel.new()


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
	var profile: Dictionary = consumable.get("pickup_profile", {})
	if profile.get("base_health_damage", 0.0) > 0.0:
		return 0.0
	var recovery: float = _rule_projector.project_consumable_health_effect(
		observation.player_state.effect_rules, profile.get("base_recovery", 0.0)
	)
	recovery = _rule_projector.project_recovery(
		observation.player_state.effect_rules, "healing", recovery
	)
	return min(missing_health, max(0.0, recovery))


func consumable_pickup_value(
	observation: Dictionary,
	consumable: Dictionary,
	health_inventory_value: Dictionary,
	run_continuation_value := {}
) -> float:
	var value: float = (
		consumable_recovery_value(observation, consumable)
		* health_inventory_value.get("recovery_conversion_unit_value", 0.0)
	)
	var health_damage := consumable_health_damage(observation, consumable)
	value -= _health_loss_value_model.value(health_damage, health_inventory_value, 1.0)
	if health_damage >= observation.player_state.health.current:
		value -= run_continuation_value.get("total_value", 0.0)
	return value


func consumable_health_damage(observation: Dictionary, consumable: Dictionary) -> float:
	var base_damage: float = consumable.get("pickup_profile", {}).get("base_health_damage", 0.0)
	if base_damage <= 0.0:
		return 0.0
	return _rule_projector.project_consumable_health_effect(
		observation.player_state.effect_rules, base_damage
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
	var profile: Dictionary = enemy_death_reward_profile(observation, death_rewards)
	return profile.material_value + profile.other_value


func enemy_death_reward_profile(observation: Dictionary, death_rewards: Dictionary) -> Dictionary:
	var material_value: float = (
		max(0.0, death_rewards.get("material_quantity", 0.0))
		* _death_reward_probability_model.material_drop_probability(observation, death_rewards)
	)
	var other_value := 0.0
	var item_box_probability: float = _death_reward_probability_model.item_box_drop_probability(
		observation, death_rewards
	)
	if item_box_probability > 0.0:
		other_value += item_box_probability * expected_item_box_item_value(observation)
	other_value += _stat_opportunity_pricing_model.value(
		observation, death_rewards.get("stat_changes", [])
	)
	return {
		"material_value": material_value,
		"other_value": other_value,
		"distance_curves":
		_enemy_material_distance_curves(observation.player_state.get("effect_rules", [])),
	}


func enemy_death_reward_value_at_distance(profile: Dictionary, distance: float) -> float:
	var multiplier := 1.0
	for curve in profile.distance_curves:
		multiplier *= _distance_curve_multiplier(curve, distance)
	return max(0.0, profile.material_value * multiplier) + profile.other_value


func _enemy_material_distance_curves(rules: Array) -> Array:
	var curves := []
	for rule in rules:
		if rule.event != "enemy_death" or not rule.condition.get("killed_by_player", false):
			continue
		for consequence in rule.consequences:
			if (
				consequence.target == "enemy_material_reward"
				and consequence.operation == "multiply_by_distance_curve"
			):
				curves.push_back(consequence.curve)
	return curves


func _distance_curve_multiplier(curve: Dictionary, distance: float) -> float:
	assert(curve.kind == "clamped_linear_percentage")
	var minimum: float = curve.minimum_percentage
	var maximum: float = curve.maximum_percentage
	var curve_range: float = max(0.0001, curve.range)
	var input: float = max(0.0, distance) - curve.buffer
	var slope: float = (abs(minimum) + abs(maximum)) / curve_range
	var percentage := minimum + slope * input
	if curve.inverted:
		percentage = maximum - slope * input
	# Vanilla converts the clamped percentage to an integer before applying it.
	percentage = float(int(clamp(percentage, minimum, maximum)))
	return max(0.0, 1.0 + percentage / 100.0)


func _living_tree_preservation_value(observation: Dictionary) -> float:
	var result := 0.0
	for rule in observation.player_state.effect_rules:
		if rule.event != "wave_end":
			continue
		for consequence in rule.consequences:
			if consequence.target == "materials_and_experience_per_living_tree":
				result += max(0.0, consequence.get("value", 0.0))
	return result
