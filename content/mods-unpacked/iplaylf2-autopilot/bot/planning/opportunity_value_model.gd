extends Reference

# Prices observed materials, consumables, destructibles, and enemy removal in
# material-equivalent marginal value using only current public state. Geometry
# and event realization remain in their owning predictors.

const CONSUMABLE_DROP_OPPORTUNITY_VALUE := 1.0
const PlayerRuleProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_rule_projector.gd"
)
const StatOpportunityValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/stat_opportunity_value_model.gd"
)

var _rule_projector: Reference = PlayerRuleProjector.new()
var _stat_opportunity_value_model: Reference = StatOpportunityValueModel.new()


func material_collection_value(observation: Dictionary) -> float:
	# A material collected during the wave is immediately available for the next
	# shop and level-up processing. Vanilla defers uncollected materials through
	# bonus gold, so the value of avoiding that deferral rises continuously as the
	# current collection window closes.
	var duration: float = max(0.01, observation.wave_state.duration_seconds)
	var remaining_ratio: float = clamp(
		observation.wave_state.seconds_remaining / duration, 0.0, 1.0
	)
	return 1.0 + (1.0 - remaining_ratio)


func tree_reward_value(observation: Dictionary, tree: Dictionary) -> float:
	var rewards: Dictionary = tree.get("destructible_profile", {}).get("kill_rewards", {})
	var kill_value := kill_reward_value(observation, rewards)
	return (
		max(0.0, kill_value - _living_tree_preservation_value(observation))
		* tree_harvest_feasibility(observation, tree)
	)


func tree_harvest_feasibility(observation: Dictionary, tree: Dictionary) -> float:
	var required_hits: float = max(
		1.0, tree.get("destructible_profile", {}).get("destruction", {}).get("required_hits", 1.0)
	)
	var remaining_seconds: float = max(0.0, observation.wave_state.seconds_remaining)
	return clamp(weapon_hit_rate(observation) * remaining_seconds / required_hits, 0.0, 1.0)


func build_enemy_removal_value_ledger(
	observation: Dictionary, marginal_health_value: float
) -> Dictionary:
	# This aggregate is intentionally built once per planning frame. Population,
	# amplification and healing effects depend on the battlefield as a whole; doing
	# the same scan once per enemy made crowded waves quadratic.
	var values := {}
	var tracks: Array = observation.enemy_tracks
	if tracks.empty():
		return {
			"removal_values": values,
			"mean_value_per_health": 0.0,
			"mean_absolute_value": 0.0,
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
			* marginal_health_value
		)
		var base_burden: float = (
			kill_reward_value(observation, track.behavior_profile.get("kill_rewards", {}))
			+ direct_burden
			+ _visible_projectile_cleanup_value(observation, track, marginal_health_value)
		)
		base_burdens[track.track_id] = base_burden
		mean_base_burden += base_burden
		mean_enemy_health += max(1.0, track.behavior_profile.durability.maximum_health)
	mean_base_burden /= tracks.size()
	mean_enemy_health /= tracks.size()

	var preservation_value := _living_enemy_preservation_value(observation)
	var mean_value_per_health := 0.0
	var mean_absolute_value := 0.0
	for track in tracks:
		var value: float = (
			base_burdens[track.track_id]
			+ _battlefield_effect_burden(
				observation, track, mean_base_burden, mean_enemy_health, marginal_health_value
			)
			- preservation_value
		)
		values[track.track_id] = value
		mean_absolute_value += abs(value)
		mean_value_per_health += (
			value
			/ max(1.0, track.behavior_profile.durability.maximum_health)
		)
	return {
		"removal_values": values,
		"mean_value_per_health": mean_value_per_health / tracks.size(),
		"mean_absolute_value": mean_absolute_value / tracks.size(),
		"living_enemy_preservation_value": preservation_value,
	}


func enemy_removal_value(enemy_removal_value_ledger: Dictionary, track: Dictionary) -> float:
	return enemy_removal_value_ledger.removal_values.get(track.track_id, 0.0)


func enemy_kill_feasibility(observation: Dictionary, track: Dictionary) -> float:
	var maximum_health: float = max(1.0, float(track.behavior_profile.durability.maximum_health))
	var remaining_seconds: float = max(0.0, observation.wave_state.seconds_remaining)
	var damage_rate := _weapon_damage_rate(observation)
	return clamp(damage_rate * remaining_seconds / maximum_health, 0.0, 1.0)


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


func kill_reward_value(observation: Dictionary, rewards: Dictionary) -> float:
	var value: float = max(0.0, rewards.get("base_materials", 0.0))
	var drop_chance: float = clamp(rewards.get("consumable_drop_chance", 0.0), 0.0, 1.0)
	if rewards.get("guaranteed_consumable", false):
		drop_chance = 1.0
	else:
		var luck: float = observation.player_state.effective_stats.luck
		drop_chance = clamp(drop_chance * max(0.0, 1.0 + luck / 100.0), 0.0, 1.0)
	value += drop_chance * CONSUMABLE_DROP_OPPORTUNITY_VALUE
	value += _stat_opportunity_value_model.value(
		observation, rewards.get("player_stat_changes", [])
	)
	return value


func _visible_projectile_cleanup_value(
	observation: Dictionary, track: Dictionary, marginal_health_value: float
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
	return raw_damage * armor_multiplier * dodge_failure * marginal_health_value


func _direct_enemy_pressure(observation: Dictionary, track: Dictionary) -> float:
	var maximum_player_health: float = max(1.0, observation.player_state.health.maximum)
	var contact_pressure: float = track.behavior_profile.contact_damage / maximum_player_health
	var attack: Dictionary = track.behavior_profile.attack_behavior
	var ranged_pressure: float = (
		attack.get("pressure_intensity", 0.0) * attack.get("confidence", 0.0)
		if attack.get("creates_projectile_pressure", false)
		else 0.0
	)
	return contact_pressure + ranged_pressure


func _battlefield_effect_burden(
	observation: Dictionary,
	track: Dictionary,
	mean_enemy_burden: float,
	mean_enemy_health: float,
	marginal_health_value: float
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
	var amplification_burden: float = (
		activation_count
		* amplification_fraction
		* max(1, observation.enemy_tracks.size() - 1)
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
		* marginal_health_value
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


func _weapon_damage_rate(observation: Dictionary) -> float:
	var result := 0.0
	for weapon in observation.player_state.weapons:
		var attack: Dictionary = weapon.attack_model
		var cycle_seconds: float = max(0.05, attack.timing.cycle_seconds)
		var path_count: float = max(1.0, float(attack.delivery.paths.count))
		var hit_probability: float = clamp(
			attack.delivery.paths.primary_probability_floor, 0.05, 1.0
		)
		var critical_multiplier: float = (
			1.0
			+ (
				clamp(attack.impact.critical_chance, 0.0, 1.0)
				* max(0.0, attack.impact.critical_damage_multiplier - 1.0)
			)
		)
		result += (
			attack.impact.damage
			* path_count
			* hit_probability
			* critical_multiplier
			/ cycle_seconds
		)
	return result


func weapon_hit_rate(observation: Dictionary, is_moving: bool = false) -> float:
	var result := 0.0
	for weapon in observation.player_state.weapons:
		var attack: Dictionary = weapon.attack_model
		if is_moving and not attack.timing.permitted_while_moving:
			continue
		var cycle_seconds: float = max(0.05, attack.timing.cycle_seconds)
		var path_count: float = max(1.0, float(attack.delivery.paths.count))
		var hit_probability: float = clamp(
			attack.delivery.paths.primary_probability_floor, 0.05, 1.0
		)
		result += path_count * hit_probability / cycle_seconds
	return result
