extends Reference

# Prices observed materials, consumables, destructibles, and enemy removal in
# material-equivalent marginal value using only current public state. Route
# accessibility and event realization remain in their owning predictors.

# Generating an item box creates a wave-end item choice that did not previously
# exist. Price that creation by the minimum recyclable item value. Once a box is
# already on the ground, vanilla collects it at wave end, so moving toward it
# earns only its immediate healing and pickup-event effects.
const MINIMUM_COMMON_ITEM_BASE_VALUE := 8.0
const BASE_RECYCLING_SHARE := 0.25
const BASE_ITEM_INFLATION_PER_WAVE := 0.1
const PlayerRuleProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_rule_projector.gd"
)
const StatOpportunityPricingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/stat_opportunity_pricing_model.gd"
)
const ConsumableDropProbabilityModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/consumable_drop_probability_model.gd"
)

var _rule_projector: Reference = PlayerRuleProjector.new()
var _stat_opportunity_pricing_model: Reference = StatOpportunityPricingModel.new()
var _consumable_drop_probability_model: Reference = ConsumableDropProbabilityModel.new()


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
	var minimum_units: float = material.material_quantity_estimate.minimum_units
	return minimum_units * material_unit_collection_value(observation)


func tree_destruction_value(
	observation: Dictionary, tree: Dictionary, health_inventory_value: Dictionary
) -> float:
	var rewards: Dictionary = tree.get("destructible_profile", {}).get("kill_rewards", {})
	var kill_value := kill_reward_value(observation, rewards)
	# Tree materials are still wave pickups, so their timing value must use the
	# same price as already visible materials. A tree's base consumable chance is
	# 100%; its high conditional item-box chance creates item value. Every possible
	# consumable also carries healing, including an item box, so recovery uses the
	# full consumable chance rather than only the complementary fruit outcome.
	kill_value += (
		max(0.0, rewards.get("base_materials", 0.0))
		* (material_unit_collection_value(observation) - 1.0)
	)
	kill_value += (
		_consumable_drop_probability_model.any_consumable_drop_chance(observation, rewards)
		* health_inventory_value.maximum_consumable_recovery
		# Destroying the tree creates replenishment supply; it does not merely
		# convert supply already on the floor into liquid health.
		* health_inventory_value.replenishment_unit_value
	)
	return max(0.0, kill_value - _living_tree_preservation_value(observation))


func build_enemy_removal_value_ledger(
	observation: Dictionary, marginal_health_unit_value: float
) -> Dictionary:
	# This aggregate is intentionally built once per planning frame. Population,
	# amplification and healing effects depend on the battlefield as a whole; doing
	# the same scan once per enemy made crowded waves quadratic.
	var values := {}
	var tracks: Array = observation.enemy_tracks
	if tracks.empty():
		return {
			"removal_value_by_track_id": values,
			"mean_removal_value_per_enemy_health": 0.0,
			"mean_absolute_removal_value": 0.0,
			"living_enemy_preservation_value": 0.0,
		}

	var remaining_seconds: float = max(0.0, observation.wave_state.seconds_remaining)
	var pressure_horizon: float = sqrt(remaining_seconds)
	var base_burdens := {}
	var mean_base_burden := 0.0
	var mean_enemy_health := 0.0
	for track in tracks:
		var direct_burden: float = (
			_direct_enemy_pressure(observation, track)
			* pressure_horizon
			* marginal_health_unit_value
		)
		var base_burden: float = (
			kill_reward_value(observation, track.behavior_profile.get("kill_rewards", {}))
			+ direct_burden
			+ _visible_projectile_cleanup_value(observation, track, marginal_health_unit_value)
		)
		base_burdens[track.track_id] = base_burden
		mean_base_burden += base_burden
		mean_enemy_health += max(1.0, track.behavior_profile.durability.maximum_health)
	mean_base_burden /= tracks.size()
	mean_enemy_health /= tracks.size()
	var material_assimilation_burden_by_track := _material_assimilation_burden_by_track(
		observation, mean_base_burden
	)

	var preservation_value := _living_enemy_preservation_value(observation)
	var mean_removal_value_per_enemy_health := 0.0
	var mean_absolute_removal_value := 0.0
	for track in tracks:
		var value: float = (
			base_burdens[track.track_id]
			+ _battlefield_effect_burden(
				observation, track, mean_base_burden, mean_enemy_health, marginal_health_unit_value
			)
			+ material_assimilation_burden_by_track.get(track.track_id, 0.0)
			- preservation_value
		)
		values[track.track_id] = value
		mean_absolute_removal_value += abs(value)
		mean_removal_value_per_enemy_health += (
			value
			/ max(1.0, track.behavior_profile.durability.maximum_health)
		)
	return {
		"removal_value_by_track_id": values,
		"mean_removal_value_per_enemy_health": mean_removal_value_per_enemy_health / tracks.size(),
		"mean_absolute_removal_value": mean_absolute_removal_value / tracks.size(),
		"living_enemy_preservation_value": preservation_value,
	}


func _material_assimilation_burden_by_track(
	observation: Dictionary, mean_enemy_burden: float
) -> Dictionary:
	var result := {}
	var consumers := []
	for track in observation.enemy_tracks:
		var assimilation: Dictionary = track.behavior_profile.get("material_assimilation", {})
		if not track.visible or not assimilation.get("active", false):
			continue
		var movement_speed: float = max(
			0.0,
			track.behavior_profile.get("target_position_response", {}).get("movement_speed", 0.0)
		)
		if movement_speed <= 0.0:
			continue
		consumers.push_back(
			{
				"track": track,
				"movement_speed": movement_speed,
				"attraction_radius": max(0.0, assimilation.get("attraction_radius", 0.0)),
				"growth_burden_per_material":
				_growth_burden_per_material(assimilation, mean_enemy_burden),
			}
		)
		result[track.track_id] = 0.0
	if consumers.empty():
		return result

	# Assign each visible material to the earliest arriving consumer so multiple
	# enemies cannot claim the same threatened material in the removal ledger.
	# Urgency follows the observed race geometry and remaining time; no enemy ID or
	# fixed target bonus participates in the ledger.
	var horizon: float = max(0.01, sqrt(max(0.0, observation.wave_state.seconds_remaining)))
	var player_speed: float = max(1.0, observation.player_state.runtime_stats.move_speed)
	var player_collection_radius: float = observation.player_state.pickup.collection_radius
	for material in observation.visible_world.materials:
		var best_consumer := {}
		var earliest_arrival := INF
		for consumer in consumers:
			var track: Dictionary = consumer.track
			var gap: float = max(
				0.0,
				(
					(material.relative_position - track.relative_position).length()
					- consumer.attraction_radius
				)
			)
			var arrival_seconds: float = gap / consumer.movement_speed
			if arrival_seconds < earliest_arrival:
				earliest_arrival = arrival_seconds
				best_consumer = consumer
		if best_consumer.empty():
			continue
		var player_gap: float = max(
			0.0, material.relative_position.length() - player_collection_radius
		)
		var player_arrival: float = player_gap / player_speed
		var race_advantage: float = player_arrival - earliest_arrival
		var consumer_race_share: float = clamp(0.5 + race_advantage / (2.0 * horizon), 0.0, 1.0)
		var assimilation_likelihood: float = exp(-earliest_arrival / horizon) * consumer_race_share
		var track_id: int = best_consumer.track.track_id
		result[track_id] += (
			assimilation_likelihood
			* (
				material_collection_value(observation, material)
				+ best_consumer.growth_burden_per_material
			)
		)
	return result


func _growth_burden_per_material(assimilation: Dictionary, mean_enemy_burden: float) -> float:
	var thresholds: Array = assimilation.get("evolution_material_thresholds", [])
	if thresholds.empty():
		return 0.0
	var final_threshold: float = max(1.0, float(thresholds.back()))
	var maximum_health_multiplier: float = max(
		1.0, assimilation.get("maximum_health_multiplier", 1.0)
	)
	return mean_enemy_burden * (maximum_health_multiplier - 1.0) / final_threshold


func enemy_removal_value(enemy_removal_value_ledger: Dictionary, track: Dictionary) -> float:
	return enemy_removal_value_ledger.removal_value_by_track_id.get(track.track_id, 0.0)


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


func _generated_item_box_value(observation: Dictionary) -> float:
	var wave: float = max(1.0, float(observation.wave_state.number))
	var inflated_minimum_value := (
		MINIMUM_COMMON_ITEM_BASE_VALUE
		+ wave
		+ MINIMUM_COMMON_ITEM_BASE_VALUE * wave * BASE_ITEM_INFLATION_PER_WAVE
	)
	return max(1.0, floor(inflated_minimum_value * BASE_RECYCLING_SHARE))


func kill_reward_value(observation: Dictionary, rewards: Dictionary) -> float:
	var value: float = max(0.0, rewards.get("base_materials", 0.0))
	value += (
		_consumable_drop_probability_model.item_box_drop_chance(observation, rewards)
		* _generated_item_box_value(observation)
	)
	value += _stat_opportunity_pricing_model.value(
		observation, rewards.get("player_stat_changes", [])
	)
	return value


func _visible_projectile_cleanup_value(
	observation: Dictionary, track: Dictionary, marginal_health_unit_value: float
) -> float:
	if not track.visible:
		return 0.0
	var raw_damage: float = track.behavior_profile.get("removal_effects", {}).get(
		"visible_projectile_damage", 0.0
	)
	if raw_damage <= 0.0:
		return 0.0
	var armor: float = observation.player_state.runtime_stats.armor
	var armor_multiplier := (
		1.0 / (1.0 + armor / 15.0)
		if armor >= 0.0
		else 2.0 - 1.0 / (1.0 - armor / 15.0)
	)
	var dodge_failure: float = 1.0 - observation.player_state.runtime_stats.dodge_chance
	return raw_damage * armor_multiplier * dodge_failure * marginal_health_unit_value


func _direct_enemy_pressure(observation: Dictionary, track: Dictionary) -> float:
	var maximum_player_health: float = max(1.0, observation.player_state.health.maximum)
	var contact_pressure: float = track.behavior_profile.contact_damage / maximum_player_health
	var projectile_attack: Dictionary = track.behavior_profile.projectile_attack
	var ranged_pressure: float = (
		projectile_attack.get("pressure_intensity", 0.0) * projectile_attack.get("confidence", 0.0)
		if projectile_attack.get("creates_projectile_pressure", false)
		else 0.0
	)
	return contact_pressure + ranged_pressure


func _battlefield_effect_burden(
	observation: Dictionary,
	track: Dictionary,
	mean_enemy_burden: float,
	mean_enemy_health: float,
	marginal_health_unit_value: float
) -> float:
	var effects: Dictionary = track.behavior_profile.get("battlefield_effects", {})
	var remaining_seconds: float = max(0.0, observation.wave_state.seconds_remaining)
	var population_burden: float = (
		effects.get("hostile_population_per_second", 0.0)
		* remaining_seconds
		* mean_enemy_burden
	)
	var activation_count: float = (
		effects.get("amplification_activations_per_second", 0.0)
		* remaining_seconds
	)
	var amplification_fraction: float = (
		effects.get("enemy_health_fraction_per_activation", 0.0)
		+ effects.get("enemy_damage_fraction_per_activation", 0.0)
		+ effects.get("enemy_speed_fraction_per_activation", 0.0)
	)
	# Vanilla buffers only boost entities whose is_boosted flag is still false.
	# One activation also affects at most nb_entities_boosted_at_once, which is
	# already represented by the compiled activation rate. Cap the forecast by
	# the number of other entities instead of multiplying every activation by the
	# whole population and repeatedly charging the same boost.
	var eligible_enemy_count := max(0, observation.enemy_tracks.size() - 1)
	var expected_amplified_enemy_count := min(activation_count, eligible_enemy_count)
	var amplification_burden: float = (
		expected_amplified_enemy_count
		* amplification_fraction
		* mean_enemy_burden
	)
	var wave_number: float = max(1, observation.wave_state.number)
	var enemy_healing: float = (
		effects.get("enemy_healing_base", 0.0)
		+ (wave_number - 1.0) * effects.get("enemy_healing_per_wave", 0.0)
	)
	var healing_burden: float = (
		enemy_healing
		/ mean_enemy_health
		* max(0, observation.enemy_tracks.size() - 1)
		* mean_enemy_burden
	)
	var player_healing: float = (
		effects.get("player_healing_base", 0.0)
		+ (wave_number - 1.0) * effects.get("player_healing_per_wave", 0.0)
	)
	var missing_health: float = max(
		0.0, observation.player_state.health.maximum - observation.player_state.health.current
	)
	var player_healing_opportunity: float = (
		min(missing_health, max(0.0, player_healing))
		* marginal_health_unit_value
	)
	return population_burden + amplification_burden + healing_burden - player_healing_opportunity


func _living_enemy_preservation_value(observation: Dictionary) -> float:
	var result := 0.0
	for rule in observation.player_state.effect_rules:
		if rule.event != "wave_end":
			continue
		for consequence in rule.consequences:
			if consequence.target != "materials_and_experience_per_living_enemy":
				continue
			result += max(0.0, consequence.get("value", 0.0))
			result += max(0.0, consequence.get("event_value_coefficient", 0.0))
	return result


func _living_tree_preservation_value(observation: Dictionary) -> float:
	var result := 0.0
	for rule in observation.player_state.effect_rules:
		if rule.event != "wave_end":
			continue
		for consequence in rule.consequences:
			if consequence.target == "materials_and_experience_per_living_tree":
				result += max(0.0, consequence.get("value", 0.0))
	return result
