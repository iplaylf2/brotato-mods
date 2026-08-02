extends Reference

# Shared weapon-engagement model. It converts weapon cadence, hit capacity and
# damage into a capability estimate, then estimates output against observed
# targets at a position. Exact shortlisted-action geometry remains in
# WeaponAttackPredictor.

const ObservedMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/observed_motion_predictor.gd"
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
		var weapon: Dictionary = _movement_state_projector.project_weapon(
			observed_weapon, observation, false
		)
		var attacks := _scheduled_attack_count(weapon, 0.0, horizon_seconds)
		var hit_capacity := _hit_capacity_per_attack(weapon)
		var damage_capacity := (
			attacks
			* hit_capacity
			* weapon.damage
			* _critical_damage_multiplier(weapon)
		)
		total_attacks += attacks
		total_hit_capacity += attacks * hit_capacity
		total_damage_capacity += damage_capacity
		weighted_range += weapon.maximum_range * damage_capacity
		weighted_bandwidth += (
			max(0.0, weapon.maximum_range - weapon.minimum_range)
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
		var weapon: Dictionary = _movement_state_projector.project_weapon(
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
			* weapon.damage
			* _critical_damage_multiplier(weapon)
		)
	return {
		"engaged_attack_count": expected_attacks,
		"expected_hits": expected_hits,
		"expected_damage": expected_damage,
	}


func get_scheduled_attack_times(
	weapon: Dictionary, arrival_seconds: float, horizon_seconds: float
) -> Array:
	var result := []
	var attack_time: float = max(arrival_seconds, weapon.cooldown_remaining_seconds)
	var end_time := arrival_seconds + horizon_seconds
	var cycle_seconds: float = max(0.05, weapon.nominal_attack_cycle_seconds)
	while attack_time <= end_time:
		result.push_back(attack_time)
		attack_time += cycle_seconds
	return result


func expected_damage_per_hit(weapon: Dictionary) -> float:
	return weapon.damage * _critical_damage_multiplier(weapon)


func _scheduled_attack_count(
	weapon: Dictionary, arrival_seconds: float, horizon_seconds: float
) -> float:
	return float(get_scheduled_attack_times(weapon, arrival_seconds, horizon_seconds).size())


func _hit_capacity_per_attack(weapon: Dictionary) -> float:
	if weapon.attack_mode == "melee":
		return 1.75 if weapon.attack_pattern == "sweep" else 1.0
	var projectile_count: float = max(1.0, weapon.get("projectile_count", 1.0))
	var accuracy: float = clamp(weapon.accuracy, 0.05, 1.0)
	var pierce_capacity := _retained_chain_capacity(
		weapon.get("piercing", 0), weapon.get("piercing_damage_retained", 0.0)
	)
	var bounce_capacity := _retained_chain_capacity(
		weapon.get("bounce", 0), weapon.get("bounce_damage_retained", 0.0)
	)
	return projectile_count * accuracy * (1.0 + pierce_capacity + bounce_capacity)


func _expected_hits_per_attack(weapon: Dictionary, targets: Array) -> float:
	var capacity := _hit_capacity_per_attack(weapon)
	if weapon.attack_mode == "melee":
		if weapon.attack_pattern == "sweep":
			return min(capacity, float(targets.size()))
		return min(1.0, float(targets.size()))
	# Multiple projectiles may converge on one target, while penetration and
	# bounce require additional targets to realize their capacity.
	var direct_hits: float = min(max(1.0, float(weapon.get("projectile_count", 1))), capacity)
	var secondary_capacity := max(0.0, capacity - direct_hits)
	return direct_hits + min(secondary_capacity, max(0.0, float(targets.size() - 1)))


func _retained_chain_capacity(count: int, retained_damage: float) -> float:
	var result := 0.0
	var retained := clamp(retained_damage, 0.0, 1.0)
	var contribution := retained
	for _index in max(0, count):
		result += contribution
		contribution *= retained
	return result


func _critical_damage_multiplier(weapon: Dictionary) -> float:
	var chance: float = clamp(weapon.critical_chance, 0.0, 1.0)
	return 1.0 + chance * max(0.0, weapon.critical_damage_multiplier - 1.0)


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
		if distance >= weapon.minimum_range and distance <= weapon.maximum_range + target.radius:
			result.push_back(target)
	return result
