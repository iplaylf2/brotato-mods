extends Reference

# Predicts expected automatic-weapon outcomes during one action forecast. Results
# score movement only; this module never invokes or mutates weapons, targets, or
# attacks.

const ObservedMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/observed_motion_predictor.gd"
)
const WeaponEngagementModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapon_engagement_model.gd"
)
const PlayerMovementStateProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_movement_state_projector.gd"
)

var _motion_predictor: Reference = ObservedMotionPredictor.new()
var _engagement_model: Reference = WeaponEngagementModel.new()
var _movement_state_projector: Reference = PlayerMovementStateProjector.new()


func accumulate_outcome(observation: Dictionary, action: Dictionary, outcome: Dictionary) -> void:
	var material_pickup_times := _material_pickup_times(observation, action)
	var global_material_reload := _has_global_material_reload(observation)
	for observed_weapon in observation.player_state.weapons:
		if (
			action.movement != Vector2.ZERO
			and not observed_weapon.attack_model.timing.permitted_while_moving
		):
			continue
		var attack_model: Dictionary = _movement_state_projector.project_attack_model(
			observed_weapon, observation, action.movement != Vector2.ZERO
		)
		var cooldown_reset_times := []
		if (
			global_material_reload
			or _is_selected_weapon_reload(observed_weapon, observation.player_state.weapons)
		):
			cooldown_reset_times = material_pickup_times
		var shot_times: Array = _engagement_model.get_scheduled_attack_times(
			attack_model, 0.0, action.forecast_seconds, cooldown_reset_times
		)
		for shot_index in shot_times.size():
			_accumulate_weapon_attack(
				observation, action, attack_model, shot_times[shot_index], shot_index == 0, outcome
			)


func _has_global_material_reload(observation: Dictionary) -> bool:
	for rule in observation.player_state.effect_rules:
		if rule.event != "material_pickup" or not rule.condition.empty():
			continue
		for consequence in rule.consequences:
			if (
				consequence.target == "all_automatic_weapon_cooldowns"
				and consequence.operation == "set"
				and consequence.get("value", 1.0) <= 0.0
			):
				return true
	return false


func _material_pickup_times(observation: Dictionary, action: Dictionary) -> Array:
	var result := []
	var collection_radius: float = observation.player_state.pickup.collection_radius
	for material in observation.visible_world.materials:
		for sample in action.samples:
			if (material.relative_position - sample.displacement).length() <= collection_radius:
				result.push_back(sample.time)
				break
	result.sort()
	return result


func _is_selected_weapon_reload(weapon: Dictionary, weapons: Array) -> bool:
	if not _has_cooldown_reset_rule(weapon.attack_model.rules) or weapon.attack_model.timing.active:
		return false
	var highest_cooldown := -INF
	var selected_slot := -1
	for candidate in weapons:
		if (
			not _has_cooldown_reset_rule(candidate.attack_model.rules)
			or candidate.attack_model.timing.active
		):
			continue
		if candidate.attack_model.timing.cooldown_remaining_seconds > highest_cooldown:
			highest_cooldown = candidate.attack_model.timing.cooldown_remaining_seconds
			selected_slot = candidate.slot
	return weapon.slot == selected_slot


func _has_cooldown_reset_rule(rules: Array) -> bool:
	for rule in rules:
		if rule.event != "material_pickup":
			continue
		for consequence in rule.consequences:
			if (
				consequence.target == "timing.cooldown"
				and consequence.operation == "set"
				and consequence.get("value", 1.0) <= 0.0
			):
				return true
	return false


func _accumulate_weapon_attack(
	observation: Dictionary,
	action: Dictionary,
	attack_model: Dictionary,
	shot_time: float,
	include_once_per_forecast: bool,
	outcome: Dictionary
) -> void:
	var displacement := _sample_displacement(action.samples, shot_time)
	var targets := _targets_at_time(observation.enemy_tracks, displacement, shot_time)
	var primary = _nearest_legal_target(
		targets, attack_model.delivery.minimum_range, attack_model.delivery.maximum_range + 50.0
	)
	if primary == null:
		return

	var attack_outcome := _predict_attack(targets, primary, attack_model)
	_accumulate_attack_rules(
		attack_outcome, targets, primary, attack_model, include_once_per_forecast
	)
	outcome.expected_weapon_damage += attack_outcome.expected_damage
	outcome.expected_producer_damage += attack_outcome.expected_producer_damage
	outcome.expected_loot_target_damage += attack_outcome.expected_loot_target_damage
	outcome.ranged_source_suppression_value += attack_outcome.ranged_source_suppression_value
	outcome.expected_attack_hits += attack_outcome.expected_hits
	outcome.expected_kill_weight += attack_outcome.expected_kill_weight
	outcome.expected_critical_kill_weight += (
		attack_outcome.expected_kill_weight
		* clamp(attack_model.impact.critical_chance, 0.0, 1.0)
	)
	var expected_lifesteal_events := (
		attack_outcome.expected_hits
		* clamp(attack_model.impact.lifesteal, 0.0, 1.0)
	)
	var remaining_missing_health := max(
		0.0,
		(
			observation.player_state.health.maximum
			- observation.player_state.health.current
			- outcome.expected_recovery
		)
	)
	var expected_lifesteal_recovery := min(remaining_missing_health, expected_lifesteal_events)
	outcome.expected_recovery += expected_lifesteal_recovery
	outcome.expected_recovery_events += expected_lifesteal_recovery


func _predict_attack(targets: Array, primary: Dictionary, attack_model: Dictionary) -> Dictionary:
	var aim: Vector2 = primary.position.normalized()
	var hit_capacity: float = max(
		1.0,
		(
			attack_model.delivery.paths.hit_capacity
			+ (
				attack_model.impact.critical_chance
				* _engagement_model.get_rule_delta(
					attack_model.rules, "critical_hit", "delivery.paths.hit_capacity"
				)
			)
		)
	)
	var damage_retained: float = attack_model.delivery.paths.retained_damage
	var result := _empty_attack_outcome()
	var ordered_targets := _targets_primary_first(targets, primary)
	for _path_index in attack_model.delivery.paths.count:
		var remaining_capacity := hit_capacity
		var retained := 1.0
		for target in ordered_targets:
			if remaining_capacity <= 0.0:
				break
			var distance: float = target.position.length()
			if (
				distance < attack_model.delivery.minimum_range
				or distance > attack_model.delivery.maximum_range + target.radius
			):
				continue
			var angular_error := abs(aim.angle_to(target.position.normalized()))
			var hard_tolerance: float = (
				attack_model.delivery.paths.angular_half_extent
				+ atan2(
					attack_model.delivery.paths.corridor_half_width + target.radius,
					max(1.0, distance)
				)
			)
			var direction_error: float = attack_model.delivery.paths.direction_error
			var hit_probability := 1.0 if angular_error <= hard_tolerance else 0.0
			if direction_error > 0.0 and hit_probability == 0.0:
				hit_probability = clamp(
					(hard_tolerance + direction_error - angular_error) / direction_error, 0.0, 1.0
				)
			if target.track_id == primary.track_id:
				hit_probability = max(
					hit_probability, attack_model.delivery.paths.primary_probability_floor
				)
			if hit_probability <= 0.0:
				continue
			var expected_damage: float = (
				_engagement_model.expected_damage_per_hit(attack_model)
				* retained
				* hit_probability
			)
			_accumulate_target_outcome(result, target, expected_damage, hit_probability)
			remaining_capacity -= hit_probability
			retained *= lerp(1.0, damage_retained, hit_probability)
	_accumulate_redirected_delivery(result, targets, attack_model)
	return result


func _accumulate_redirected_delivery(
	result: Dictionary, targets: Array, attack_model: Dictionary
) -> void:
	if targets.size() <= 1:
		return
	var expected_retargets: float = (
		attack_model.delivery.redirects.count
		+ (
			attack_model.impact.critical_chance
			* _engagement_model.get_rule_delta(
				attack_model.rules, "critical_hit", "delivery.redirects.count"
			)
		)
	)
	if expected_retargets <= 0.0:
		return
	var realized_retargets := min(
		expected_retargets * max(1.0, float(attack_model.delivery.paths.count)),
		float(targets.size() - 1)
	)
	var retained: float = clamp(attack_model.delivery.redirects.retained_damage, 0.0, 1.0)
	var damage_capacity := _fractional_retained_chain_capacity(realized_retargets, retained)
	var hit_probability: float = attack_model.delivery.paths.primary_probability_floor
	result.expected_damage += (
		_engagement_model.expected_damage_per_hit(attack_model)
		* damage_capacity
		* hit_probability
	)
	result.expected_hits += realized_retargets * hit_probability


func _fractional_retained_chain_capacity(count: float, retained: float) -> float:
	var whole_count := int(floor(max(0.0, count)))
	var fraction := max(0.0, count - whole_count)
	var result := 0.0
	var contribution := retained
	for _index in whole_count:
		result += contribution
		contribution *= retained
	return result + contribution * fraction


func _accumulate_attack_rules(
	result: Dictionary,
	targets: Array,
	primary: Dictionary,
	attack_model: Dictionary,
	include_once_per_forecast: bool
) -> void:
	var trigger_hits: float = min(result.expected_hits, float(targets.size()))
	if trigger_hits <= 0.0:
		return
	var damage_before_rules: float = result.expected_damage
	var mean_maximum_health := 0.0
	for target in targets:
		mean_maximum_health += target.maximum_health
	mean_maximum_health /= max(1.0, float(targets.size()))

	for rule in attack_model.rules:
		if rule.event != "weapon_hit":
			continue
		if rule.condition.get("once_per_forecast", false) and not include_once_per_forecast:
			continue
		for consequence in rule.consequences:
			if consequence.target != "enemy_health" or consequence.operation != "deal_damage":
				continue
			var applications := _delivered_applications(
				consequence.delivery, trigger_hits, targets, primary
			)
			var probability: float = clamp(consequence.get("probability", 1.0), 0.0, 1.0)
			var damage_per_application := _rule_damage_amount(
				consequence.amount, attack_model, mean_maximum_health
			)
			result.expected_damage += applications * probability * damage_per_application
			result.expected_hits += applications * probability

	var rule_damage := max(0.0, result.expected_damage - damage_before_rules)
	result.expected_kill_weight += min(
		float(targets.size()), rule_damage / max(1.0, mean_maximum_health)
	)


func _delivered_applications(
	delivery: Dictionary, trigger_hits: float, targets: Array, primary: Dictionary
) -> float:
	var capacity: float = max(0.0, delivery.capacity_per_event)
	if delivery.reuse_event_targets:
		return min(float(targets.size()), trigger_hits * capacity)

	var eligible_targets := 0.0
	var radius: float = max(0.0, delivery.radius)
	for target in targets:
		if delivery.exclude_event_targets and target.track_id == primary.track_id:
			continue
		if target.position.distance_to(primary.position) <= radius + target.radius:
			eligible_targets += 1.0
	return min(eligible_targets, trigger_hits * capacity)


func _rule_damage_amount(
	amount: Dictionary, attack_model: Dictionary, mean_maximum_health: float
) -> float:
	var value: float = (
		amount.constant
		+ (_engagement_model.expected_damage_per_hit(attack_model) * amount.impact_coefficient)
		+ mean_maximum_health * amount.target_maximum_health_coefficient
	)
	return max(amount.minimum, value)


func _targets_primary_first(targets: Array, primary: Dictionary) -> Array:
	var result := [primary]
	for target in targets:
		if target.track_id == primary.track_id:
			continue
		result.push_back(target)
	return result


func _accumulate_target_outcome(
	result: Dictionary, target: Dictionary, expected_damage: float, expected_hits: float
) -> void:
	result.expected_damage += expected_damage
	result.expected_hits += expected_hits
	result.expected_kill_weight += min(1.0, expected_damage / target.maximum_health)
	if target.enemy_producer:
		result.expected_producer_damage += expected_damage
	if target.loot_reward_target:
		result.expected_loot_target_damage += expected_damage
	if target.ranged_pressure_source:
		result.ranged_source_suppression_value += (
			expected_damage
			/ target.maximum_health
			* target.ranged_pressure_intensity
			* target.source_removal_relief
		)


func _targets_at_time(tracks: Array, displacement: Vector2, time: float) -> Array:
	var targets := []
	for track in tracks:
		if not track.visible:
			continue
		targets.push_back(
			{
				"track_id": track.track_id,
				"position": _predict_track_position(track, time) - displacement,
				"radius": track.last_measurement.visual_radius,
				"enemy_producer": track.behavior_profile.strategic_roles.enemy_producer,
				"loot_reward_target": track.behavior_profile.strategic_roles.loot_reward_target,
				"ranged_pressure_source":
				track.behavior_profile.strategic_roles.ranged_pressure_source,
				"ranged_pressure_intensity":
				track.behavior_profile.attack_behavior.pressure_intensity,
				"maximum_health": max(1.0, float(track.behavior_profile.durability.maximum_health)),
				"source_removal_relief":
				(
					1.25
					if track.behavior_profile.attack_behavior.get(
						"all_projectiles_removed_on_death", false
					)
					else 1.0
				),
			}
		)
	return targets


func _nearest_legal_target(targets: Array, minimum_range: float, maximum_range: float):
	var nearest = null
	var nearest_distance := INF
	for target in targets:
		var distance: float = target.position.length()
		if distance < minimum_range or distance > maximum_range:
			continue
		if distance < nearest_distance:
			nearest = target
			nearest_distance = distance
	return nearest


func _sample_displacement(samples: Array, time: float) -> Vector2:
	for sample in samples:
		if sample.time >= time:
			return sample.displacement
	return samples.back().displacement


func _predict_track_position(track: Dictionary, time: float) -> Vector2:
	return _motion_predictor.predict_position(
		track.relative_position,
		track.estimated_velocity,
		track.estimated_acceleration,
		track.motion_confidence,
		time
	)


func _empty_attack_outcome() -> Dictionary:
	return {
		"expected_damage": 0.0,
		"expected_producer_damage": 0.0,
		"expected_loot_target_damage": 0.0,
		"ranged_source_suppression_value": 0.0,
		"expected_hits": 0.0,
		"expected_kill_weight": 0.0,
	}
