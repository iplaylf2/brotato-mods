extends Reference

# Prices the state transition caused by completing an enemy. Immediate kill
# rewards, the burden removed while the wave is still active, and consequences
# caused by death remain separate channels until the utility boundary.

const OpportunityPricingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_pricing_model.gd"
)
const EnemyHealthModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/enemy_health_model.gd"
)

var _opportunity_pricing_model: Reference = OpportunityPricingModel.new()
var _enemy_health_model: Reference = EnemyHealthModel.new()


func build_ledger(observation: Dictionary, marginal_health_unit_value: float) -> Dictionary:
	var entries_by_track_id := {}
	var tracks: Array = observation.enemy_tracks
	if tracks.empty():
		return _empty_ledger(entries_by_track_id)

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
			direct_burden
			+ _visible_projectile_cleanup_value(observation, track, marginal_health_unit_value)
		)
		base_burdens[track.track_id] = base_burden
		mean_base_burden += base_burden
		mean_enemy_health += max(1.0, track.behavior_profile.durability.maximum_health)
	mean_base_burden /= tracks.size()
	mean_enemy_health /= tracks.size()
	var material_burdens := _material_assimilation_burden_by_track(observation, mean_base_burden)
	var preservation_value := _living_enemy_preservation_value(observation)
	var mean_net_completion_value := 0.0
	var mean_absolute_net_completion_value := 0.0
	for track in tracks:
		var reward_delta_value: float = (
			_opportunity_pricing_model.death_reward_value(
				observation, track.behavior_profile.get("death_rewards", {})
			)
			- preservation_value
		)
		var burden_relief_value: float = (
			base_burdens[track.track_id]
			+ _battlefield_effect_burden(
				observation, track, mean_base_burden, mean_enemy_health, marginal_health_unit_value
			)
			+ material_burdens.get(track.track_id, 0.0)
		)
		var death_consequence_value := _death_consequence_value(track, mean_base_burden)
		var net_completion_value := (
			reward_delta_value
			+ burden_relief_value
			- death_consequence_value
		)
		var remaining_health: float = _enemy_health_model.remaining_health(track)
		entries_by_track_id[track.track_id] = {
			"reward_delta_value": reward_delta_value,
			"burden_relief_value": burden_relief_value,
			"death_consequence_value": death_consequence_value,
			"net_completion_value": net_completion_value,
			"remaining_health": remaining_health,
		}
		mean_net_completion_value += net_completion_value
		mean_absolute_net_completion_value += abs(net_completion_value)
	return {
		"entries_by_track_id": entries_by_track_id,
		"mean_net_completion_value": mean_net_completion_value / tracks.size(),
		"mean_absolute_net_completion_value": mean_absolute_net_completion_value / tracks.size(),
		"living_enemy_preservation_value": preservation_value,
	}


func entry(ledger: Dictionary, track: Dictionary) -> Dictionary:
	return ledger.entries_by_track_id[track.track_id]


func net_completion_value(ledger: Dictionary, track: Dictionary) -> float:
	return entry(ledger, track).net_completion_value


func _empty_ledger(entries_by_track_id: Dictionary) -> Dictionary:
	return {
		"entries_by_track_id": entries_by_track_id,
		"mean_net_completion_value": 0.0,
		"mean_absolute_net_completion_value": 0.0,
		"living_enemy_preservation_value": 0.0,
	}


func _death_consequence_value(track: Dictionary, mean_enemy_burden: float) -> float:
	return (
		max(
			0.0,
			track.behavior_profile.get("removal_effects", {}).get("spawned_hostile_population", 0.0)
		)
		* mean_enemy_burden
	)


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
				_opportunity_pricing_model.material_collection_value(observation, material)
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
	var pressure_horizon: float = sqrt(remaining_seconds)
	var forecast_hostile_population: float = (
		effects.get("hostile_population_per_second", 0.0)
		* remaining_seconds
	)
	var maximum_lifetime_population = effects.get("maximum_lifetime_hostile_population", null)
	if maximum_lifetime_population != null:
		forecast_hostile_population = min(
			forecast_hostile_population, max(0.0, float(maximum_lifetime_population))
		)
	var population_burden: float = forecast_hostile_population * mean_enemy_burden
	var activation_count: float = (
		effects.get("amplification_activations_per_second", 0.0)
		* remaining_seconds
	)
	var amplification_fraction: float = (
		effects.get("enemy_health_fraction_per_activation", 0.0)
		+ effects.get("enemy_damage_fraction_per_activation", 0.0)
		+ effects.get("enemy_speed_fraction_per_activation", 0.0)
	)
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
	var healing_radius: float = max(0.0, effects.get("enemy_healing_radius", 0.0))
	var healing_burden: float = _enemy_healing_burden(
		observation, track, enemy_healing, healing_radius, mean_enemy_health, mean_enemy_burden
	)
	var player_healing: float = (
		effects.get("player_healing_base", 0.0)
		+ (wave_number - 1.0) * effects.get("player_healing_per_wave", 0.0)
	)
	var missing_health: float = max(
		0.0, observation.player_state.health.maximum - observation.player_state.health.current
	)
	var player_movement_distance: float = (
		max(0.0, observation.player_state.runtime_stats.get("move_speed", 0.0))
		* pressure_horizon
	)
	var player_healing_access: float = _radial_accessibility(
		max(
			0.0,
			(
				track.relative_position.length()
				- healing_radius
				- observation.player_state.collision_radius
			)
		),
		_characteristic_movement_distance(track, pressure_horizon) + player_movement_distance
	)
	var player_healing_opportunity: float = (
		min(missing_health, max(0.0, player_healing))
		* marginal_health_unit_value
		* player_healing_access
	)
	return population_burden + amplification_burden + healing_burden - player_healing_opportunity


func _enemy_healing_burden(
	observation: Dictionary,
	healer: Dictionary,
	healing_per_entry: float,
	healing_radius: float,
	mean_enemy_health: float,
	mean_enemy_burden: float
) -> float:
	if healing_per_entry <= 0.0 or healing_radius <= 0.0:
		return 0.0
	var horizon: float = sqrt(max(0.0, observation.wave_state.seconds_remaining))
	var healer_movement_distance: float = _characteristic_movement_distance(healer, horizon)
	var recoverable_health := 0.0
	for candidate in observation.enemy_tracks:
		if candidate.track_id == healer.track_id:
			continue
		var health: Dictionary = candidate.last_measurement.get("health", {})
		var missing_health: float = max(
			0.0, float(health.get("maximum", 0.0)) - float(health.get("current", 0.0))
		)
		if missing_health <= 0.0:
			continue
		var candidate_radius: float = candidate.behavior_profile.get("contact_radius", 0.0)
		var gap: float = max(
			0.0,
			(
				(candidate.relative_position - healer.relative_position).length()
				- healing_radius
				- candidate_radius
			)
		)
		var characteristic_movement_distance: float = (
			healer_movement_distance
			+ _characteristic_movement_distance(candidate, horizon)
		)
		recoverable_health += (
			min(missing_health, healing_per_entry)
			* _radial_accessibility(gap, characteristic_movement_distance)
			* candidate.recency_confidence
		)
	# A body-entered heal can restore at most the health currently missing from
	# the body that reaches the trigger zone.
	return recoverable_health / max(1.0, mean_enemy_health) * mean_enemy_burden


func _characteristic_movement_distance(track: Dictionary, horizon: float) -> float:
	var response: Dictionary = track.behavior_profile.get("target_position_response", {})
	return (
		max(track.estimated_velocity.length(), max(0.0, response.get("movement_speed", 0.0)))
		* max(0.0, horizon)
	)


func _radial_accessibility(gap: float, characteristic_distance: float) -> float:
	if gap <= 0.0:
		return 1.0
	if characteristic_distance <= 0.0:
		return 0.0
	return exp(-gap / characteristic_distance)


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
