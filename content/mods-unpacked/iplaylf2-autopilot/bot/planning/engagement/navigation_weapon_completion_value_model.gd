extends Reference

# Values the target completion enabled at a sampled future player state.
# Primary nearest-target selection and additional delivery paths share this
# contract so every trajectory sample uses the same selection and valuation.

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
const DamageCompletionWorkModel := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "damage_completion_work_model.gd"
	)
)

var _weapon_attack_capacity_model: Reference = WeaponAttackCapacityModel.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _engagement_target_projector: Reference = EngagementTargetProjector.new()
var _damage_completion_work_model: Reference = DamageCompletionWorkModel.new()
var _prepared_physics_frame := -1
var _prepared_targets := []


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_enemy_motion_predictor = predictor


func value_at(
	observation: Dictionary,
	context: Dictionary,
	player_displacement: Vector2,
	forecast_seconds: float
) -> float:
	if observation.player_state.weapons.empty():
		return 0.0
	var seconds_remaining_after_navigation: float = max(
		0.0, observation.wave_state.seconds_remaining - forecast_seconds
	)
	var completion_horizon_seconds: float = min(
		seconds_remaining_after_navigation, context.state_factors.continuation_horizon_seconds
	)
	if completion_horizon_seconds <= 0.0:
		return 0.0
	var targets := _project_targets(observation, context, player_displacement, forecast_seconds)
	if targets.empty():
		return 0.0
	var result := 0.0
	var range_transition_distance: float = max(
		1.0, observation.player_state.runtime_stats.move_speed * completion_horizon_seconds
	)
	for observed_weapon in observation.player_state.weapons:
		result += _weapon_completion_value(
			observed_weapon.attack_model,
			targets,
			completion_horizon_seconds,
			range_transition_distance
		)
	var negative_value_cap := 0.0
	var positive_value_cap := 0.0
	for target in targets:
		var available_value: float = target.confidence * target.net_completion_value
		negative_value_cap += min(0.0, available_value)
		positive_value_cap += max(0.0, available_value)
	return clamp(result, negative_value_cap, positive_value_cap)


func _project_targets(
	observation: Dictionary,
	context: Dictionary,
	player_displacement: Vector2,
	forecast_seconds: float
) -> Array:
	_enemy_motion_predictor.begin_physics_frame(observation.get("physics_frame", -1))
	_prepare_targets(observation, context)
	var result := []
	for target in _prepared_targets:
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
				"net_completion_value": target.value.net_completion_value,
			}
		)
	result.sort_custom(self, "_nearer_target")
	return result


func _prepare_targets(observation: Dictionary, context: Dictionary) -> void:
	var physics_frame: int = observation.get("physics_frame", -1)
	if physics_frame >= 0 and physics_frame == _prepared_physics_frame:
		return
	_prepared_physics_frame = physics_frame
	_prepared_targets = []
	for target in _engagement_target_projector.project_navigation_targets(observation, context):
		if not target.completion.completed:
			_prepared_targets.push_back(target)


func _weapon_completion_value(
	attack_model: Dictionary,
	targets: Array,
	completion_horizon_seconds: float,
	range_transition_distance: float
) -> float:
	var delivery: Dictionary = attack_model.delivery
	var minimum_distance: float = max(0.0, delivery.minimum_targeting_distance)
	var maximum_distance: float = max(minimum_distance, delivery.maximum_targeting_distance)
	var primary: Dictionary = _nearest_target_inside_range(
		targets, minimum_distance, maximum_distance
	)
	if not primary.empty():
		primary = primary.duplicate(false)
		primary.selection_coverage = 1.0
	else:
		primary = _nearest_reachable_target(
			targets, minimum_distance, maximum_distance, range_transition_distance
		)
	if primary.empty() or primary.relative_position.length_squared() <= 0.0:
		return 0.0
	var paths: Dictionary = delivery.paths
	var direct_capacity: float = max(0.0, float(paths.hit_capacity) - 1.0)
	var redirect_capacity: float = max(0.0, float(delivery.redirects.count))
	var area_capacity := _area_capacity(attack_model)
	var direct_mass := 0.0
	var redirect_mass := 0.0
	var area_mass := 0.0
	var direct_value := 0.0
	var redirect_value := 0.0
	var area_value := 0.0
	var damage_per_hit: float = _weapon_attack_capacity_model.expected_damage_per_hit(attack_model)
	for secondary in targets:
		if secondary.target.target_id == primary.target.target_id:
			continue
		var available_mass: float = (
			secondary.confidence
			* _range_coverage(
				secondary.distance, minimum_distance, maximum_distance, range_transition_distance
			)
		)
		if available_mass <= 0.0:
			continue
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
	var base_hit_capacity: float = primary_path_count * completion_horizon_seconds / attack_interval
	var primary_value: float = (
		base_hit_capacity
		* primary.confidence
		* primary.selection_coverage
		* _completion_value_per_hit(primary.target, damage_per_hit, 1.0)
	)
	var direct_share: float = min(direct_capacity, direct_mass)
	var redirect_share: float = min(redirect_capacity, redirect_mass)
	var area_share: float = min(area_capacity, area_mass)
	var projected_value: float = (
		primary_value
		+ (
			base_hit_capacity
			* (
				direct_share * _mean_value(direct_value, direct_mass)
				+ redirect_share * _mean_value(redirect_value, redirect_mass)
				+ area_share * _mean_value(area_value, area_mass)
			)
		)
	)
	return projected_value


func _nearest_target_inside_range(
	targets: Array, minimum_distance: float, maximum_distance: float
) -> Dictionary:
	for target in targets:
		if target.distance >= minimum_distance and target.distance <= maximum_distance:
			return target
	return {}


func _nearest_reachable_target(
	targets: Array,
	minimum_distance: float,
	maximum_distance: float,
	range_transition_distance: float
) -> Dictionary:
	for target in targets:
		var coverage: float = _range_coverage(
			target.distance, minimum_distance, maximum_distance, range_transition_distance
		)
		if coverage > 0.0:
			var result: Dictionary = target.duplicate(false)
			result.selection_coverage = coverage
			return result
	return {}


func _range_coverage(
	distance: float,
	minimum_distance: float,
	maximum_distance: float,
	range_transition_distance: float
) -> float:
	if distance < minimum_distance:
		return clamp(1.0 - (minimum_distance - distance) / range_transition_distance, 0.0, 1.0)
	if distance > maximum_distance:
		return clamp(1.0 - (distance - maximum_distance) / range_transition_distance, 0.0, 1.0)
	return 1.0


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
			_damage_completion_work_model.completion_fraction_per_hit(
				target.completion.health.remaining, damage_per_hit * retained_damage
			)
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
