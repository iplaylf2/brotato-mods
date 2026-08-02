extends Reference

# Shared weapon-engagement model. It converts weapon cadence, hit capacity and
# damage into a capability estimate, then estimates output against observed
# targets at a position. Exact candidate-action geometry remains in
# WeaponAttackPredictor.

const ObservedMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/observed_motion_predictor.gd"
)
const PlayerMovementStateProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_movement_state_projector.gd"
)

var _motion_predictor: Reference = ObservedMotionPredictor.new()
var _movement_state_projector: Reference = PlayerMovementStateProjector.new()


func estimate_capacity(observation: Dictionary, horizon_seconds: float) -> Dictionary:
	var total_attacks := 0.0
	var total_hit_capacity := 0.0
	var total_damage_capacity := 0.0
	var weighted_range := 0.0
	var weighted_bandwidth := 0.0
	for observed_weapon in observation.player_state.weapons:
		var weapon: Dictionary = _movement_state_projector.project_attack_model(
			observed_weapon, observation, false
		)
		var attacks: float = _scheduled_attack_count(weapon, 0.0, horizon_seconds)
		var hit_capacity: float = _hit_capacity_per_attack(weapon)
		var damage_capacity: float = (
			attacks
			* hit_capacity
			* weapon.impact.damage
			* _critical_damage_multiplier(weapon)
		)
		total_attacks += attacks
		total_hit_capacity += attacks * hit_capacity
		total_damage_capacity += damage_capacity
		weighted_range += weapon.delivery.maximum_range * damage_capacity
		weighted_bandwidth += (
			max(0.0, weapon.delivery.maximum_range - weapon.delivery.minimum_range)
			* damage_capacity
		)
	var divisor := max(0.001, total_damage_capacity)
	return {
		"scheduled_attack_count": total_attacks,
		"hit_capacity": total_hit_capacity,
		"damage_capacity": total_damage_capacity,
		"damage_weighted_range": weighted_range / divisor,
		"damage_weighted_engagement_span": weighted_bandwidth / divisor,
	}


func estimate_at_position(
	observation: Dictionary,
	player_displacement: Vector2,
	arrival_seconds: float,
	engagement_seconds: float
) -> Dictionary:
	var targets := _targets_at_time(observation.enemy_tracks, player_displacement, arrival_seconds)
	var expected_attacks := 0.0
	var expected_hits := 0.0
	var expected_damage := 0.0
	for observed_weapon in observation.player_state.weapons:
		var weapon: Dictionary = _movement_state_projector.project_attack_model(
			observed_weapon, observation, false
		)
		var eligible_targets := _eligible_targets(targets, weapon)
		if eligible_targets.empty():
			continue
		var attacks := _scheduled_attack_count(weapon, arrival_seconds, engagement_seconds)
		if attacks <= 0.0:
			continue
		var hits_per_attack := _expected_hits_per_attack(weapon, eligible_targets)
		expected_attacks += attacks
		expected_hits += attacks * hits_per_attack
		expected_damage += (
			attacks
			* hits_per_attack
			* weapon.impact.damage
			* _critical_damage_multiplier(weapon)
		)
	return {
		"engaged_attack_count": expected_attacks,
		"expected_hits": expected_hits,
		"expected_damage": expected_damage,
	}


func get_scheduled_attack_times(
	weapon: Dictionary, arrival_seconds: float, horizon_seconds: float, cooldown_reset_times := []
) -> Array:
	var result := []
	var attack_time: float = weapon.timing.cooldown_remaining_seconds
	var end_time := arrival_seconds + horizon_seconds
	var cycle_seconds: float = max(0.05, weapon.timing.cycle_seconds)
	var attacks_until_reload: int = weapon.timing.attacks_until_long_cycle
	var reload_every: int = weapon.timing.long_cycle_every_attacks
	var reload_cycle_seconds: float = max(cycle_seconds, weapon.timing.long_cycle_seconds)
	var reset_index := 0
	while attack_time <= end_time:
		while (
			reset_index < cooldown_reset_times.size()
			and cooldown_reset_times[reset_index] <= attack_time
		):
			attack_time = float(cooldown_reset_times[reset_index])
			reset_index += 1
		if attack_time >= arrival_seconds:
			result.push_back(attack_time)
		var next_cycle := cycle_seconds
		if attacks_until_reload > 0:
			attacks_until_reload -= 1
			if attacks_until_reload == 0:
				next_cycle = reload_cycle_seconds
				attacks_until_reload = reload_every
		attack_time += next_cycle
	return result


func expected_damage_per_hit(weapon: Dictionary) -> float:
	return weapon.impact.damage * _critical_damage_multiplier(weapon)


func _scheduled_attack_count(
	weapon: Dictionary, arrival_seconds: float, horizon_seconds: float
) -> float:
	return float(get_scheduled_attack_times(weapon, arrival_seconds, horizon_seconds).size())


func _hit_capacity_per_attack(weapon: Dictionary) -> float:
	var path_count: float = max(1.0, weapon.delivery.paths.count)
	var hit_probability: float = clamp(weapon.delivery.paths.primary_probability_floor, 0.05, 1.0)
	var expected_path_capacity: float = (
		weapon.delivery.paths.hit_capacity
		+ (
			weapon.impact.critical_chance
			* get_rule_delta(weapon.rules, "critical_hit", "delivery.paths.hit_capacity")
		)
	)
	if is_inf(expected_path_capacity):
		expected_path_capacity = 1.0 + weapon.delivery.paths.angular_half_extent / PI
	var expected_redirects: float = (
		weapon.delivery.redirects.count
		+ (
			weapon.impact.critical_chance
			* get_rule_delta(weapon.rules, "critical_hit", "delivery.redirects.count")
		)
	)
	var path_continuation_capacity := _fractional_retained_chain_capacity(
		max(0.0, expected_path_capacity - 1.0), weapon.delivery.paths.retained_damage
	)
	var redirect_capacity := _fractional_retained_chain_capacity(
		expected_redirects, weapon.delivery.redirects.retained_damage
	)
	return path_count * hit_probability * (1.0 + path_continuation_capacity + redirect_capacity)


func _expected_hits_per_attack(weapon: Dictionary, targets: Array) -> float:
	var capacity := _hit_capacity_per_attack(weapon)
	# Multiple paths may converge on one target, while continuations require
	# additional targets to realize their capacity.
	var direct_hits: float = min(max(1.0, float(weapon.delivery.paths.count)), capacity)
	var continuation_capacity := max(0.0, capacity - direct_hits)
	return direct_hits + min(continuation_capacity, max(0.0, float(targets.size() - 1)))


func _retained_chain_capacity(count: int, retained_damage: float) -> float:
	var result := 0.0
	var retained := clamp(retained_damage, 0.0, 1.0)
	var contribution := retained
	for _index in max(0, count):
		result += contribution
		contribution *= retained
	return result


func _fractional_retained_chain_capacity(count: float, retained_damage: float) -> float:
	var whole_count := int(floor(max(0.0, count)))
	var fraction := max(0.0, count - whole_count)
	var result := _retained_chain_capacity(whole_count, retained_damage)
	return result + pow(clamp(retained_damage, 0.0, 1.0), whole_count + 1) * fraction


func _critical_damage_multiplier(weapon: Dictionary) -> float:
	var chance: float = clamp(weapon.impact.critical_chance, 0.0, 1.0)
	return 1.0 + chance * max(0.0, weapon.impact.critical_damage_multiplier - 1.0)


func get_rule_delta(rules: Array, event: String, target: String) -> float:
	var result := 0.0
	for rule in rules:
		if rule.event != event or not rule.condition.empty():
			continue
		for consequence in rule.consequences:
			if consequence.target == target and consequence.operation == "add":
				result += consequence.get("value", 0.0)
	return result


func _targets_at_time(tracks: Array, displacement: Vector2, time: float) -> Array:
	var result := []
	for track in tracks:
		if not track.visible:
			continue
		result.push_back(
			{
				"position":
				(
					_motion_predictor.predict_position(
						track.relative_position,
						track.estimated_velocity,
						track.estimated_acceleration,
						track.motion_confidence,
						time
					)
					- displacement
				),
				"radius": track.last_measurement.visual_radius,
			}
		)
	return result


func _eligible_targets(targets: Array, weapon: Dictionary) -> Array:
	var result := []
	for target in targets:
		var distance: float = target.position.length()
		if (
			distance >= weapon.delivery.minimum_range
			and distance <= weapon.delivery.maximum_range + target.radius
		):
			result.push_back(target)
	return result
