extends Reference

# Read-only model of expected automatic-weapon outcomes along one trajectory.
# It scores movement and must never invoke or mutate weapons, targets, or attacks.

const RAY_BUCKET_COUNT := 8


func accumulate_outcome(
	observation: Dictionary, trajectory: Dictionary, outcome: Dictionary
) -> void:
	for weapon in observation.player_state.weapons:
		if (
			trajectory.movement != Vector2.ZERO
			and not weapon.automatic_attacks_allowed_while_moving
		):
			continue
		var shot_time: float = max(0.0, weapon.cooldown_remaining_seconds)
		var attack_cycle: float = max(0.05, weapon.nominal_attack_cycle_seconds)
		while shot_time <= trajectory.horizon_seconds:
			_accumulate_weapon_attack(observation, trajectory, weapon, shot_time, outcome)
			shot_time += attack_cycle


func _accumulate_weapon_attack(
	observation: Dictionary,
	trajectory: Dictionary,
	weapon: Dictionary,
	shot_time: float,
	outcome: Dictionary
) -> void:
	var displacement := _sample_displacement(trajectory.samples, shot_time)
	var targets := _targets_at_time(observation.enemy_tracks, displacement, shot_time)
	var primary = _nearest_legal_target(targets, weapon.minimum_range, weapon.maximum_range + 50.0)
	if primary == null:
		return

	var attack_outcome: Dictionary
	if weapon.attack_mode == "ranged":
		attack_outcome = _predict_ranged_attack(targets, primary, weapon)
	else:
		attack_outcome = _predict_melee_attack(targets, primary, weapon)
	outcome.expected_enemy_damage += attack_outcome.expected_damage
	outcome.expected_producer_damage += attack_outcome.expected_producer_damage
	outcome.expected_loot_target_damage += attack_outcome.expected_loot_target_damage
	outcome.expected_attack_hits += attack_outcome.expected_hits


func _predict_ranged_attack(targets: Array, primary: Dictionary, weapon: Dictionary) -> Dictionary:
	var aim: Vector2 = primary.position.normalized()
	var accuracy_cone: float = max(0.0, 1.0 - weapon.accuracy)
	var cone: float = max(0.02, weapon.projectile_spread + accuracy_cone)
	var hit_capacity: float = max(1.0, float(weapon.piercing + 1))
	var damage_retained: float = weapon.piercing_damage_retained
	var result := _empty_attack_outcome()
	var ordered_targets := _targets_along_aim(targets, aim, weapon.maximum_range + 100.0)
	for _projectile_index in weapon.projectile_count:
		var remaining_capacity := hit_capacity
		var retained := 1.0
		for target in ordered_targets:
			if remaining_capacity <= 0.0:
				break
			var distance: float = target.position.length()
			var angular_error := abs(aim.angle_to(target.position.normalized()))
			var angular_radius := target.radius / max(1.0, distance)
			var hit_probability := clamp((cone + angular_radius - angular_error) / cone, 0.0, 1.0)
			if target.track_id == primary.track_id:
				hit_probability = max(hit_probability, clamp(weapon.accuracy, 0.1, 1.0))
			if hit_probability <= 0.0:
				continue
			var expected_damage: float = weapon.damage * retained * hit_probability
			_accumulate_target_outcome(result, target, expected_damage, hit_probability)
			remaining_capacity -= hit_probability
			retained *= lerp(1.0, damage_retained, hit_probability)
	return result


func _targets_along_aim(targets: Array, aim: Vector2, maximum_range: float) -> Array:
	var buckets := []
	for _bucket_index in RAY_BUCKET_COUNT:
		buckets.push_back([])

	for target in targets:
		var projection: float = target.position.dot(aim)
		if projection <= 0.0 or projection > maximum_range:
			continue
		var bucket_index := min(
			RAY_BUCKET_COUNT - 1, int(floor(projection / maximum_range * RAY_BUCKET_COUNT))
		)
		buckets[bucket_index].push_back(target)

	var result := []
	for bucket in buckets:
		result.append_array(bucket)
	return result


func _predict_melee_attack(targets: Array, primary: Dictionary, weapon: Dictionary) -> Dictionary:
	var aim: Vector2 = primary.position.normalized()
	var result := _empty_attack_outcome()
	for target in targets:
		var distance: float = target.position.length()
		if distance < weapon.minimum_range or distance > weapon.maximum_range + target.radius:
			continue
		var angular_error := abs(aim.angle_to(target.position.normalized()))
		var hit_probability := 0.0
		if weapon.attack_pattern == "sweep":
			hit_probability = 1.0 if angular_error <= 0.9 * PI else 0.0
		else:
			var corridor_angle := atan2(target.radius + 16.0, max(1.0, distance))
			hit_probability = 1.0 if angular_error <= corridor_angle else 0.0
		_accumulate_target_outcome(result, target, weapon.damage * hit_probability, hit_probability)
	return result


func _accumulate_target_outcome(
	result: Dictionary, target: Dictionary, expected_damage: float, expected_hits: float
) -> void:
	result.expected_damage += expected_damage
	result.expected_hits += expected_hits
	if target.enemy_producer:
		result.expected_producer_damage += expected_damage
	if target.loot_reward_target:
		result.expected_loot_target_damage += expected_damage


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
	return track.relative_position + track.last_observed_velocity * time


func _empty_attack_outcome() -> Dictionary:
	return {
		"expected_damage": 0.0,
		"expected_producer_damage": 0.0,
		"expected_loot_target_damage": 0.0,
		"expected_hits": 0.0,
	}
