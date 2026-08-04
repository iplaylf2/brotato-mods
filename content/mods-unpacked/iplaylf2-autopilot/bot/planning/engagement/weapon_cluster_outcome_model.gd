extends Reference

# Values the additional future weapon outcomes created by a projected
# target cluster. Primary-target completion remains in the ordinary strategic
# opportunity field, so density cannot create value for a single-target build
# and cannot pay the same completion twice.

const WeaponAttackCapacityModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapons/weapon_attack_capacity_model.gd"
)
const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)
const EngagementTargetProjector := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "engagement_target_projector.gd"
	)
)

var _weapon_attack_capacity_model: Reference = WeaponAttackCapacityModel.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _engagement_target_projector: Reference = EngagementTargetProjector.new()


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_enemy_motion_predictor = predictor


func estimate_value(
	observation: Dictionary,
	context: Dictionary,
	player_displacement: Vector2,
	forecast_seconds: float
) -> float:
	if observation.player_state.weapons.empty():
		return 0.0
	var post_forecast_seconds: float = max(
		0.0, observation.wave_state.seconds_remaining - forecast_seconds
	)
	var outcome_horizon_seconds: float = min(
		post_forecast_seconds, context.state_factors.continuation_horizon_seconds
	)
	if outcome_horizon_seconds <= 0.0:
		return 0.0
	var targets := _project_visible_targets(
		observation, context, player_displacement, forecast_seconds
	)
	if targets.size() < 2:
		return 0.0
	var result := 0.0
	for observed_weapon in observation.player_state.weapons:
		result += _weapon_cluster_outcome(
			observed_weapon.attack_model, targets, outcome_horizon_seconds
		)
	return result


func _project_visible_targets(
	observation: Dictionary,
	context: Dictionary,
	player_displacement: Vector2,
	forecast_seconds: float
) -> Array:
	_enemy_motion_predictor.begin_physics_frame(observation.get("physics_frame", -1))
	var result := []
	for target in _engagement_target_projector.project_visible_targets(observation, context):
		var position: Vector2 = _enemy_motion_predictor.predict_position(
			target.motion_track, forecast_seconds, player_displacement
		)
		var relative_position: Vector2 = position - player_displacement
		result.push_back(
			{
				"target": target,
				"relative_position": relative_position,
				"distance": relative_position.length(),
				"radius": target.radius,
				"confidence": target.confidence,
				"completion_headroom": 1.0 - target.completion.forecast_fraction,
				"net_completion_value": target.value.net_completion_value,
			}
		)
	result.sort_custom(self, "_nearer_target")
	return result


func _weapon_cluster_outcome(
	attack_model: Dictionary, targets: Array, outcome_horizon_seconds: float
) -> float:
	var delivery: Dictionary = attack_model.delivery
	var minimum_distance: float = max(0.0, delivery.minimum_targeting_distance)
	var maximum_distance: float = max(minimum_distance, delivery.maximum_targeting_distance)
	var primary := {}
	for target in targets:
		if target.distance >= minimum_distance and target.distance <= maximum_distance:
			primary = target
			break
	if primary.empty() or primary.relative_position.length_squared() <= 0.0:
		return 0.0
	var paths: Dictionary = delivery.paths
	var direct_capacity: float = max(0.0, float(paths.hit_capacity) - 1.0)
	var redirect_capacity: float = max(0.0, float(delivery.redirects.count))
	var area_capacity := _area_capacity(attack_model)
	if direct_capacity + redirect_capacity + area_capacity <= 0.0:
		return 0.0

	var direct_mass := 0.0
	var redirect_mass := 0.0
	var area_mass := 0.0
	var direct_value := 0.0
	var redirect_value := 0.0
	var area_value := 0.0
	var negative_value_cap := 0.0
	var positive_value_cap := 0.0
	var damage_per_hit: float = _weapon_attack_capacity_model.expected_damage_per_hit(attack_model)
	for secondary in targets:
		if secondary == primary or secondary.distance > maximum_distance:
			continue
		var available_mass: float = secondary.confidence * secondary.completion_headroom
		if available_mass <= 0.0:
			continue
		negative_value_cap += available_mass * min(0.0, secondary.net_completion_value)
		positive_value_cap += available_mass * max(0.0, secondary.net_completion_value)
		var direct_coverage := _direct_path_coverage(primary, secondary, paths)
		direct_mass += available_mass * direct_coverage
		direct_value += (
			available_mass
			* direct_coverage
			* _completion_value_per_hit(
				secondary.target, damage_per_hit, clamp(paths.retained_damage, 0.0, 1.0)
			)
		)
		redirect_mass += available_mass
		redirect_value += (
			available_mass
			* _completion_value_per_hit(
				secondary.target,
				damage_per_hit,
				clamp(delivery.redirects.retained_damage, 0.0, 1.0)
			)
		)
		var area_coverage := (
			_area_coverage(primary, secondary, attack_model)
			if secondary.target.weapon_response.health_damage_applies
			else 0.0
		)
		area_mass += available_mass * area_coverage
		area_value += (
			available_mass
			* area_coverage
			* _completion_value_per_hit(secondary.target, damage_per_hit, 1.0)
		)

	var attack_interval: float = max(0.05, attack_model.timing.expected_attack_interval_seconds)
	var primary_path_count: float = (
		max(1.0, float(paths.count))
		* clamp(paths.primary_probability_floor, 0.05, 1.0)
	)
	var base_hit_capacity: float = primary_path_count * outcome_horizon_seconds / attack_interval
	var direct_share := min(direct_capacity, direct_mass)
	var redirect_share := min(redirect_capacity, redirect_mass)
	var area_share := min(area_capacity, area_mass)
	var projected_value := (
		base_hit_capacity
		* (
			direct_share * _mean_value(direct_value, direct_mass)
			+ redirect_share * _mean_value(redirect_value, redirect_mass)
			+ area_share * _mean_value(area_value, area_mass)
		)
	)
	# Secondary completion can be beneficial or harmful. Bound each sign by the
	# corresponding visible target value without discarding adverse consequences.
	return clamp(projected_value, negative_value_cap, positive_value_cap)


func _direct_path_coverage(primary: Dictionary, secondary: Dictionary, paths: Dictionary) -> float:
	var aim: Vector2 = primary.relative_position
	var direction: Vector2 = aim.normalized()
	var forward_distance: float = secondary.relative_position.dot(direction)
	if forward_distance < 0.0 or forward_distance > paths.maximum_travel_distance:
		return 0.0
	var lateral_distance: float = abs(secondary.relative_position.cross(direction))
	var corridor_radius: float = paths.corridor_half_width + secondary.radius
	return clamp(1.0 - lateral_distance / max(1.0, corridor_radius), 0.0, 1.0)


func _area_capacity(attack_model: Dictionary) -> float:
	var result := 0.0
	for rule in attack_model.rules:
		if rule.event != "weapon_hit":
			continue
		for consequence in rule.consequences:
			if (
				consequence.target == "enemy_health"
				and consequence.operation == "deal_damage"
				and consequence.delivery.target_selection == "area"
			):
				result += max(0.0, float(consequence.delivery.capacity_per_event) - 1.0)
	return result


func _area_coverage(primary: Dictionary, secondary: Dictionary, attack_model: Dictionary) -> float:
	var result := 0.0
	for rule in attack_model.rules:
		if rule.event != "weapon_hit":
			continue
		for consequence in rule.consequences:
			if consequence.target != "enemy_health" or consequence.operation != "deal_damage":
				continue
			if consequence.delivery.target_selection != "area":
				continue
			var radius: float = max(0.0, consequence.delivery.radius) + secondary.radius
			if radius <= 0.0:
				continue
			var distance: float = primary.relative_position.distance_to(secondary.relative_position)
			result = max(result, clamp(1.0 - distance / radius, 0.0, 1.0))
	return result


func _mean_value(weighted_value: float, mass: float) -> float:
	return weighted_value / max(0.0001, mass)


func _completion_value_per_hit(
	target: Dictionary, damage_per_hit: float, retained_damage: float
) -> float:
	var completion_fraction := 0.0
	if target.weapon_response.health_damage_applies:
		completion_fraction = max(
			completion_fraction,
			damage_per_hit * retained_damage / max(1.0, target.completion.health.remaining)
		)
	if target.weapon_response.hit_limit_progress_per_hit > 0.0:
		completion_fraction = max(
			completion_fraction,
			(
				target.weapon_response.hit_limit_progress_per_hit
				/ max(1.0, target.completion.hit_limit.remaining)
			)
		)
	return target.value.net_completion_value * clamp(completion_fraction, 0.0, 1.0)


func _nearer_target(left: Dictionary, right: Dictionary) -> bool:
	return left.distance < right.distance
