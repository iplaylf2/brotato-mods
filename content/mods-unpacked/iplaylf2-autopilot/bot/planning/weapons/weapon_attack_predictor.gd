extends Reference

# Predicts expected automatic-weapon outcomes during one action forecast. Results
# score movement only; this module never invokes or mutates weapons, targets, or
# attacks.

const WeaponFireModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapons/weapon_fire_model.gd"
)
const PlayerMovementStateProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_movement_state_projector.gd"
)
const OpportunityValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_value_model.gd"
)
const WeaponTargetQueryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapons/weapon_target_query_model.gd"
)

var _weapon_fire_model: Reference = WeaponFireModel.new()
var _movement_state_projector: Reference = PlayerMovementStateProjector.new()
var _opportunity_value_model: Reference = OpportunityValueModel.new()
var _target_query_model: Reference = WeaponTargetQueryModel.new()


func accumulate_outcome(
	observation: Dictionary, action: Dictionary, outcome: Dictionary, planning_context: Dictionary
) -> void:
	var material_pickup_times := _material_pickup_times(observation, action)
	var global_material_reload := _has_global_material_reload(observation)
	# Identically timed weapons observe the same candidate-relative battlefield.
	# Reuse that immutable snapshot instead of predicting every enemy again for
	# each weapon slot. The attack model and its target selection remain complete.
	var target_snapshots_by_time := {}
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
		var shot_times: Array = _weapon_fire_model.scheduled_attack_times(
			attack_model, 0.0, action.forecast_seconds, cooldown_reset_times
		)
		for shot_index in shot_times.size():
			_accumulate_weapon_attack(
				observation,
				action,
				attack_model,
				shot_times[shot_index],
				shot_index == 0,
				outcome,
				planning_context,
				target_snapshots_by_time
			)
	_cap_forecast_outcome(observation, outcome, planning_context)


func _cap_forecast_outcome(
	observation: Dictionary, outcome: Dictionary, planning_context: Dictionary
) -> void:
	var total_enemy_health := 0.0
	var positive_removal_value := 0.0
	var negative_removal_value := 0.0
	var visible_enemy_count := 0.0
	var enemy_removal_value_ledger: Dictionary = planning_context.enemy_removal_value_ledger
	for track in observation.enemy_tracks:
		if not track.visible:
			continue
		visible_enemy_count += 1.0
		total_enemy_health += max(1.0, float(track.behavior_profile.durability.maximum_health))
		var removal_value: float = _opportunity_value_model.enemy_removal_value(
			enemy_removal_value_ledger, track
		)
		positive_removal_value += max(0.0, removal_value)
		negative_removal_value += min(0.0, removal_value)
	outcome.expected_weapon_damage = min(outcome.expected_weapon_damage, total_enemy_health)
	outcome.expected_enemy_removal_value_progress = clamp(
		outcome.expected_enemy_removal_value_progress,
		negative_removal_value,
		positive_removal_value
	)
	outcome.expected_kill_weight = min(outcome.expected_kill_weight, visible_enemy_count)
	outcome.expected_critical_kill_weight = min(
		outcome.expected_critical_kill_weight, outcome.expected_kill_weight
	)
	var total_tree_harvest_value := 0.0
	for tree in observation.visible_world.trees:
		total_tree_harvest_value += _opportunity_value_model.tree_reward_value(
			observation, tree, planning_context.state_factors.health_resource_value
		)
	outcome.expected_tree_harvest_value_progress = clamp(
		outcome.expected_tree_harvest_value_progress, 0.0, total_tree_harvest_value
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
	outcome: Dictionary,
	planning_context: Dictionary,
	target_snapshots_by_time: Dictionary
) -> void:
	var remaining_seconds: float = max(0.0, action.forecast_seconds - shot_time)
	var query_radius: float = _target_query_radius(attack_model, remaining_seconds)
	var snapshot: Dictionary = _target_snapshot(
		observation, action, shot_time, query_radius, planning_context, target_snapshots_by_time
	)
	var primary: Dictionary = _target_query_model.nearest_target_in_targeting_range(
		snapshot,
		attack_model.delivery.minimum_targeting_distance,
		attack_model.delivery.maximum_targeting_distance + 50.0
	)
	if primary.empty():
		return

	var attack_outcome := _predict_attack(snapshot, primary, attack_model, remaining_seconds)
	_accumulate_attack_rules(
		attack_outcome, snapshot, attack_model, include_once_per_forecast, remaining_seconds
	)
	outcome.expected_weapon_damage += attack_outcome.expected_damage
	var tree_harvest_progress: float = attack_outcome.expected_tree_harvest_value_progress
	outcome.expected_tree_harvest_value_progress += tree_harvest_progress
	var removal_value_progress: float = attack_outcome.expected_enemy_removal_value_progress
	outcome.expected_enemy_removal_value_progress += removal_value_progress
	outcome.expected_attack_hits += attack_outcome.expected_hits
	outcome.expected_kill_weight += attack_outcome.expected_kill_weight
	outcome.expected_critical_kill_weight += (
		attack_outcome.expected_kill_weight
		* clamp(attack_model.impact.critical_chance, 0.0, 1.0)
	)
	var expected_lifesteal_events: float = (
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


func _target_query_radius(attack_model: Dictionary, remaining_seconds: float) -> float:
	var direct_path_radius: float = attack_model.delivery.paths.maximum_travel_distance
	var result: float = max(
		attack_model.delivery.maximum_targeting_distance + 50.0, direct_path_radius
	)
	var redirects: Dictionary = attack_model.delivery.redirects
	if _expected_redirect_count(attack_model) > 0.0:
		result = max(
			result,
			(
				direct_path_radius
				+ _travel_distance_budget(
					redirects.travel_speed, redirects.maximum_travel_distance, remaining_seconds
				)
			)
		)
	for rule in attack_model.rules:
		if rule.event != "weapon_hit":
			continue
		for consequence in rule.consequences:
			if consequence.target != "enemy_health" or consequence.operation != "deal_damage":
				continue
			var delivery: Dictionary = consequence.delivery
			if delivery.target_selection == "area":
				result = max(result, direct_path_radius + delivery.radius)
			elif delivery.target_selection in ["uniform_other_enemy", "random_direction"]:
				result = max(
					result,
					(
						direct_path_radius
						+ _travel_distance_budget(
							delivery.travel_speed,
							delivery.maximum_travel_distance,
							remaining_seconds
						)
						+ 50.0
					)
				)
	return result


func _target_snapshot(
	observation: Dictionary,
	action: Dictionary,
	shot_time: float,
	query_radius: float,
	planning_context: Dictionary,
	cache: Dictionary
) -> Dictionary:
	var cache_key := stepify(shot_time, 0.0001)
	if cache.has(cache_key) and cache[cache_key].query_radius >= query_radius:
		return cache[cache_key]
	var snapshot: Dictionary = _target_query_model.build_snapshot(
		observation, _sample_displacement(action.samples, shot_time), shot_time, query_radius
	)
	_attach_target_values(snapshot, observation, planning_context)
	cache[cache_key] = snapshot
	return snapshot


func _attach_target_values(
	snapshot: Dictionary, observation: Dictionary, planning_context: Dictionary
) -> void:
	var removal_values: Dictionary = planning_context.enemy_removal_value_ledger.removal_values
	for target in snapshot.targets:
		if target.kind == "enemy":
			target.removal_value_per_health = (
				removal_values.get(target.track_id, 0.0)
				/ target.maximum_health
			)
		else:
			var tree: Dictionary = observation.visible_world.trees[target.tree_index]
			target.harvest_value = _opportunity_value_model.tree_reward_value(
				observation, tree, planning_context.state_factors.health_resource_value
			)


func _predict_attack(
	snapshot: Dictionary, primary: Dictionary, attack_model: Dictionary, remaining_seconds: float
) -> Dictionary:
	var aim: Vector2 = primary.position.normalized()
	var hit_capacity: float = max(
		1.0,
		(
			attack_model.delivery.paths.hit_capacity
			+ (
				attack_model.impact.critical_chance
				* _weapon_fire_model.rule_delta(
					attack_model.rules, "critical_hit", "delivery.paths.hit_capacity"
				)
			)
		)
	)
	# Vanilla resolves a bounce before piercing. A redirected projectile therefore
	# leaves its first contact instead of continuing through the direct corridor.
	if _expected_redirect_count(attack_model) > 0.0:
		hit_capacity = min(hit_capacity, 1.0)
	var damage_retained: float = attack_model.delivery.paths.retained_damage
	var result := _empty_attack_outcome()
	var path_speed: float = attack_model.delivery.paths.travel_speed
	for _path_index in attack_model.delivery.paths.count:
		var remaining_capacity := hit_capacity
		var retained := 1.0
		# The selected target determines aim, not collision order. The snapshot is
		# sorted by distance, so a nearer body crossing the path intercepts first.
		for target in snapshot.targets:
			if remaining_capacity <= 0.0:
				break
			var distance: float = target.position.length()
			var arrival_seconds: float = _travel_seconds(distance, path_speed)
			if arrival_seconds > remaining_seconds:
				continue
			if distance > attack_model.delivery.paths.maximum_travel_distance + target.radius:
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
				_weapon_fire_model.expected_damage_per_hit(attack_model)
				* retained
				* hit_probability
			)
			_accumulate_target_outcome(
				result, target, expected_damage, hit_probability, arrival_seconds, true
			)
			remaining_capacity -= hit_probability
			retained *= lerp(1.0, damage_retained, hit_probability)
	_accumulate_redirected_delivery(result, snapshot, attack_model, remaining_seconds)
	return result


func _accumulate_redirected_delivery(
	result: Dictionary, snapshot: Dictionary, attack_model: Dictionary, remaining_seconds: float
) -> void:
	var expected_retargets: float = _expected_redirect_count(attack_model)
	if expected_retargets <= 0.0:
		return
	var redirects: Dictionary = attack_model.delivery.redirects
	if redirects.target_selection != "uniform_other_enemy":
		return
	var redirect_states := []
	for event in result.hit_events:
		redirect_states.push_back(
			{
				"target": event.target,
				"hit_probability_mass": event.expected_hits,
				"weighted_arrival_seconds": event.expected_hits * event.arrival_seconds,
			}
		)
	if redirect_states.empty():
		return
	var whole_stages := int(floor(expected_retargets))
	var final_fraction: float = expected_retargets - whole_stages
	var stage_count := whole_stages + (1 if final_fraction > 0.0 else 0)
	var retained: float = clamp(redirects.retained_damage, 0.0, 1.0)
	var retained_damage := retained
	for stage_index in stage_count:
		var stage_fraction := 1.0 if stage_index < whole_stages else final_fraction
		var next_states_by_target_id := {}
		for state in redirect_states:
			var source: Dictionary = state.target
			var source_arrival_seconds: float = (
				state.weighted_arrival_seconds
				/ max(0.0001, state.hit_probability_mass)
			)
			var denominator: float = max(
				1.0, float(snapshot.visible_enemy_count - (1 if source.kind == "enemy" else 0))
			)
			for target in _target_query_model.enemy_targets(snapshot, source.track_id):
				var travel_seconds: float = _travel_seconds(
					target.position.distance_to(source.position), redirects.travel_speed
				)
				if (
					target.position.distance_to(source.position) > redirects.maximum_travel_distance
					or source_arrival_seconds + travel_seconds > remaining_seconds
				):
					continue
				var hit_probability_mass: float = (
					state.hit_probability_mass
					* stage_fraction
					/ denominator
				)
				if hit_probability_mass <= 0.0:
					continue
				var target_id = target.track_id
				if not next_states_by_target_id.has(target_id):
					next_states_by_target_id[target_id] = {
						"target": target,
						"hit_probability_mass": 0.0,
						"weighted_arrival_seconds": 0.0,
					}
				next_states_by_target_id[target_id].hit_probability_mass += hit_probability_mass
				next_states_by_target_id[target_id].weighted_arrival_seconds += (
					hit_probability_mass
					* (source_arrival_seconds + travel_seconds)
				)
		var next_states := next_states_by_target_id.values()
		for state in next_states:
			var expected_damage: float = (
				_weapon_fire_model.expected_damage_per_hit(attack_model)
				* retained_damage
				* state.hit_probability_mass
			)
			_accumulate_target_outcome(
				result,
				state.target,
				expected_damage,
				state.hit_probability_mass,
				state.weighted_arrival_seconds / max(0.0001, state.hit_probability_mass),
				true
			)
		redirect_states = next_states
		retained_damage *= retained
		if redirect_states.empty():
			break


func _accumulate_attack_rules(
	result: Dictionary,
	snapshot: Dictionary,
	attack_model: Dictionary,
	include_once_per_forecast: bool,
	remaining_seconds: float
) -> void:
	if result.hit_events.empty():
		return
	for rule in attack_model.rules:
		if rule.event != "weapon_hit":
			continue
		if rule.condition.get("once_per_forecast", false) and not include_once_per_forecast:
			continue
		for consequence in rule.consequences:
			if consequence.target != "enemy_health" or consequence.operation != "deal_damage":
				continue
			var probability: float = clamp(consequence.get("probability", 1.0), 0.0, 1.0)
			for event in result.hit_events:
				_accumulate_rule_event(
					result,
					snapshot,
					event,
					consequence,
					probability,
					attack_model,
					remaining_seconds
				)


func _accumulate_rule_event(
	result: Dictionary,
	snapshot: Dictionary,
	event: Dictionary,
	consequence: Dictionary,
	probability: float,
	attack_model: Dictionary,
	remaining_seconds: float
) -> void:
	var delivery: Dictionary = consequence.delivery
	var capacity: float = max(0.0, delivery.capacity_per_event)
	if capacity <= 0.0 or event.arrival_seconds > remaining_seconds:
		return
	var event_target: Dictionary = event.target
	var event_mass: float = event.expected_hits
	if delivery.target_selection == "event_targets":
		if event_target.kind == "enemy":
			_accumulate_rule_target(
				result,
				event_target,
				min(capacity, 1.0) * event_mass,
				probability,
				consequence.amount,
				attack_model
			)
		return
	if delivery.target_selection == "area":
		var excluded_id = event_target.track_id if delivery.exclude_event_targets else null
		var area_targets: Array = _target_query_model.enemy_targets_in_radius(
			snapshot, event_target.position, delivery.radius, excluded_id
		)
		var remaining_capacity: float = capacity * event_mass
		for target in area_targets:
			if remaining_capacity <= 0.0:
				break
			var applications := min(event_mass, remaining_capacity)
			_accumulate_rule_target(
				result, target, applications, probability, consequence.amount, attack_model
			)
			remaining_capacity -= applications
		return
	var travel_distance_budget: float = _travel_distance_budget(
		delivery.travel_speed,
		delivery.maximum_travel_distance,
		max(0.0, remaining_seconds - event.arrival_seconds)
	)
	var candidates: Array = _target_query_model.enemy_targets(
		snapshot, event_target.track_id if delivery.exclude_event_targets else null
	)
	var denominator: float = max(
		1.0,
		float(
			(
				snapshot.visible_enemy_count
				- (1 if delivery.exclude_event_targets and event_target.kind == "enemy" else 0)
			)
		)
	)
	for target in candidates:
		var distance: float = target.position.distance_to(event_target.position)
		if distance > travel_distance_budget + target.radius:
			continue
		var selection_probability := 0.0
		if delivery.target_selection == "uniform_other_enemy":
			selection_probability = 1.0 / denominator
		elif delivery.target_selection == "random_direction":
			selection_probability = _random_direction_hit_probability(distance, target.radius)
		var applications: float = event_mass * capacity * selection_probability
		_accumulate_rule_target(
			result, target, applications, probability, consequence.amount, attack_model
		)


func _accumulate_rule_target(
	result: Dictionary,
	target: Dictionary,
	applications: float,
	probability: float,
	amount: Dictionary,
	attack_model: Dictionary
) -> void:
	var expected_hits: float = max(0.0, applications) * probability
	if expected_hits <= 0.0:
		return
	var damage_per_application := _rule_damage_amount(amount, attack_model, target.maximum_health)
	var expected_damage: float = expected_hits * damage_per_application
	_accumulate_target_outcome(result, target, expected_damage, expected_hits, 0.0, false)


func _rule_damage_amount(
	amount: Dictionary, attack_model: Dictionary, target_maximum_health: float
) -> float:
	var value: float = (
		amount.constant
		+ (_weapon_fire_model.expected_damage_per_hit(attack_model) * amount.impact_coefficient)
		+ target_maximum_health * amount.target_maximum_health_coefficient
	)
	return max(amount.minimum, value)


func _accumulate_target_outcome(
	result: Dictionary,
	target: Dictionary,
	expected_damage: float,
	expected_hits: float,
	arrival_seconds: float,
	record_hit_event: bool
) -> void:
	if record_hit_event and expected_hits > 0.0:
		result.hit_events.push_back(
			{
				"target": target,
				"expected_hits": expected_hits,
				"arrival_seconds": arrival_seconds,
			}
		)
	if target.kind == "tree":
		result.expected_hits += expected_hits
		result.expected_tree_harvest_value_progress += (
			expected_hits
			/ max(1.0, target.required_hits)
			* target.harvest_value
		)
		return
	result.expected_damage += expected_damage
	result.expected_hits += expected_hits
	result.expected_enemy_hits += expected_hits
	result.expected_kill_weight += min(1.0, expected_damage / target.maximum_health)
	result.expected_enemy_removal_value_progress += (
		expected_damage
		* target.removal_value_per_health
	)


func _sample_displacement(samples: Array, time: float) -> Vector2:
	for sample in samples:
		if sample.time >= time:
			return sample.displacement
	return samples.back().displacement


func _travel_distance_budget(speed: float, maximum_distance: float, seconds: float) -> float:
	if is_inf(speed):
		return maximum_distance
	return min(maximum_distance, max(0.0, speed) * max(0.0, seconds))


func _travel_seconds(distance: float, speed: float) -> float:
	if is_inf(speed):
		return 0.0
	if speed <= 0.0:
		return INF
	return max(0.0, distance) / speed


func _expected_redirect_count(attack_model: Dictionary) -> float:
	return (
		attack_model.delivery.redirects.count
		+ (
			attack_model.impact.critical_chance
			* _weapon_fire_model.rule_delta(
				attack_model.rules, "critical_hit", "delivery.redirects.count"
			)
		)
	)


func _random_direction_hit_probability(distance: float, radius: float) -> float:
	if distance <= max(0.0, radius):
		return 1.0
	return clamp(2.0 * asin(clamp(radius / max(1.0, distance), 0.0, 1.0)) / TAU, 0.0, 1.0)


func _empty_attack_outcome() -> Dictionary:
	return {
		"expected_damage": 0.0,
		"expected_enemy_removal_value_progress": 0.0,
		"expected_tree_harvest_value_progress": 0.0,
		"expected_hits": 0.0,
		"expected_enemy_hits": 0.0,
		"expected_kill_weight": 0.0,
		"hit_events": [],
	}
