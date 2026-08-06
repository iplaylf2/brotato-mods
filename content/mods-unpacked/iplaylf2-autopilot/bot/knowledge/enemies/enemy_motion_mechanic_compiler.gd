extends Reference

# Compiles stable mechanics that can change an enemy's future position. Current
# targets, active charge state, resolved random values, and observed motion stay
# in the observation boundary.


func compile(enemy: Node) -> Dictionary:
	return {
		"target_position_response": _compile_target_position_response(enemy),
		"charge_attack": _compile_charge_attack(enemy),
	}


func _compile_target_position_response(enemy: Node) -> Dictionary:
	var behavior: Node = enemy.get_node_or_null("MovementBehavior")
	var responds_to_target_position := behavior is FollowTargetMovementBehavior
	var preferred_distance := 0.0
	if behavior is FollowTargetMovementBehavior and behavior.stop_close_to_target:
		preferred_distance = max(0.0, float(behavior.distance_to_target))
	elif behavior is StayInRangeFromPlayerMovementBehavior:
		responds_to_target_position = true
		preferred_distance = max(0.0, float(behavior.target_range))
	return {
		"responds_to_target_position": responds_to_target_position,
		"preferred_distance": preferred_distance,
		"moves_away_inside_preferred_distance": behavior is StayInRangeFromPlayerMovementBehavior,
		"movement_speed": _base_movement_speed(enemy),
		"confidence": 1.0,
		"knowledge_source": "stable_mechanics",
	}


func _compile_charge_attack(enemy: Node) -> Dictionary:
	var minimum_range := INF
	var maximum_range := 0.0
	var maximum_charge_speed := 0.0
	var maximum_duration := 0.0
	var minimum_interval := INF
	var maximum_interval := 0.0
	var charge_behavior_count := 0
	var player_target_count := 0
	var random_player_region_target_count := 0
	var maximum_forward_overshoot_distance := 0.0
	var maximum_random_offset_half_extent := 0.0
	if "_all_attack_behaviors" in enemy:
		for behavior in enemy._all_attack_behaviors:
			if not behavior is ChargingAttackBehavior:
				continue
			charge_behavior_count += 1
			minimum_range = min(minimum_range, float(behavior.min_range))
			maximum_range = max(maximum_range, float(behavior.max_range))
			maximum_charge_speed = max(
				maximum_charge_speed, _base_movement_speed(enemy) + float(behavior.charge_speed)
			)
			maximum_duration = max(maximum_duration, float(behavior.charge_duration))
			minimum_interval = min(
				minimum_interval,
				max(1.0, float(behavior.cooldown - behavior.max_cd_randomization)) / 60.0
			)
			maximum_interval = max(
				maximum_interval, float(behavior.cooldown + behavior.max_cd_randomization) / 60.0
			)
			if behavior.target == ChargingAttackBehavior.PLAYER:
				player_target_count += 1
			elif behavior.target == ChargingAttackBehavior.RAND_POINT_AROUND_PLAYER:
				random_player_region_target_count += 1
				var target_extent := (
					min(600.0, float(behavior.max_range) / 5.0)
					if behavior.rand_target_size < 0
					else float(behavior.rand_target_size)
				)
				maximum_forward_overshoot_distance = max(
					maximum_forward_overshoot_distance, target_extent
				)
				maximum_random_offset_half_extent = max(
					maximum_random_offset_half_extent, target_extent
				)
	if maximum_charge_speed <= 0.0 or maximum_duration <= 0.0:
		return {
			"active": false,
			"confidence": 1.0,
			"knowledge_source": "stable_mechanics",
		}
	return {
		"active": true,
		"confidence": 1.0,
		"knowledge_source": "stable_mechanics",
		"minimum_range": 0.0 if minimum_range == INF else minimum_range,
		"maximum_range": maximum_range,
		"maximum_charge_speed": maximum_charge_speed,
		"maximum_duration_seconds": maximum_duration,
		"maximum_travel_distance": maximum_charge_speed * maximum_duration,
		"interval":
		{
			"minimum_seconds": 0.0 if minimum_interval == INF else minimum_interval,
			"maximum_seconds": maximum_interval,
		},
		"targeting":
		{
			"player_probability":
			float(player_target_count) / max(1.0, float(charge_behavior_count)),
			"random_player_region_probability":
			float(random_player_region_target_count) / max(1.0, float(charge_behavior_count)),
			"forward_overshoot_distance": maximum_forward_overshoot_distance,
			"random_offset_half_extent": maximum_random_offset_half_extent,
		},
	}


func _base_movement_speed(enemy: Node) -> float:
	if "stats" in enemy and enemy.stats != null and "speed" in enemy.stats:
		return max(0.0, float(enemy.stats.speed))
	return 0.0
