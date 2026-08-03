extends Reference

# Produces action-conditioned expected weapon outcomes by sampling a smooth,
# movement-relative target field. It does not roll out individual shots,
# projectiles, contacts, redirects, or triggered event chains.

const WeaponAttackCapacityModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapons/weapon_attack_capacity_model.gd"
)
const PlayerMovementStateProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_movement_state_projector.gd"
)
const OpportunityValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_value_model.gd"
)
const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)
const PlayerKinematicsModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_kinematics_model.gd"
)

const OUTCOME_FIELDS := [
	"expected_attack_hits",
	"expected_weapon_damage",
	"expected_enemy_removal_value_progress",
	"expected_kill_weight",
	"expected_critical_kill_weight",
	"expected_tree_harvest_value_progress",
	"expected_lifesteal_recovery",
]

var _weapon_attack_capacity_model: Reference = WeaponAttackCapacityModel.new()
var _movement_state_projector: Reference = PlayerMovementStateProjector.new()
var _opportunity_value_model: Reference = OpportunityValueModel.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _player_kinematics_model: Reference = PlayerKinematicsModel.new()
var _prepared_physics_frame := -1
var _prepared_targets := []
var _prepared_caps := {}
var _prepared_outcome_fields := {}


func accumulate_outcome(
	observation: Dictionary, action: Dictionary, outcome: Dictionary, planning_context: Dictionary
) -> void:
	_prepare_targets(observation, planning_context)
	if _prepared_targets.empty() or observation.player_state.weapons.empty():
		return
	var control_seconds: float = planning_context.control_interval_seconds
	var displacement: Vector2 = action.samples.back().displacement
	var is_moving: bool = action.movement != Vector2.ZERO
	var weapon_outcome: Dictionary = _sample_outcome_field(
		observation, displacement, control_seconds, is_moving
	)
	for key in OUTCOME_FIELDS:
		if key == "expected_lifesteal_recovery":
			continue
		outcome[key] += weapon_outcome[key]
	var missing_health: float = max(
		0.0,
		(
			observation.player_state.health.maximum
			- observation.player_state.health.current
			- outcome.expected_recovery
		)
	)
	var lifesteal_recovery: float = min(missing_health, weapon_outcome.expected_lifesteal_recovery)
	outcome.expected_recovery += lifesteal_recovery
	outcome.expected_recovery_events += lifesteal_recovery
	_cap_outcome(outcome)


func _prepare_targets(observation: Dictionary, planning_context: Dictionary) -> void:
	var physics_frame: int = observation.get("physics_frame", -1)
	if physics_frame >= 0 and physics_frame == _prepared_physics_frame:
		return
	_prepared_physics_frame = physics_frame
	_prepared_targets = []
	_prepared_outcome_fields = {}
	var total_enemy_health := 0.0
	var positive_removal_value := 0.0
	var negative_removal_value := 0.0
	var visible_enemy_count := 0.0
	var removal_value_ledger: Dictionary = planning_context.enemy_removal_value_ledger
	for track in observation.enemy_tracks:
		if not track.visible:
			continue
		var maximum_health: float = max(
			1.0, float(track.behavior_profile.durability.maximum_health)
		)
		var removal_value: float = _opportunity_value_model.enemy_removal_value(
			removal_value_ledger, track
		)
		_prepared_targets.push_back(
			{
				"kind": "enemy",
				"track": track,
				"radius": track.last_measurement.visual_radius,
				"confidence": track.recency_confidence,
				"maximum_health": maximum_health,
				"removal_value_per_health": removal_value / maximum_health,
			}
		)
		visible_enemy_count += 1.0
		total_enemy_health += maximum_health
		positive_removal_value += max(0.0, removal_value)
		negative_removal_value += min(0.0, removal_value)
	var total_tree_harvest_value := 0.0
	for tree in observation.visible_world.trees:
		var harvest_value: float = _opportunity_value_model.tree_reward_value(
			observation, tree, planning_context.state_factors.health_resource_value
		)
		_prepared_targets.push_back(
			{
				"kind": "tree",
				"tree": tree,
				"radius": tree.get("visual_radius", 0.0),
				"confidence": 1.0,
				"required_hits":
				max(
					1.0,
					tree.get("destructible_profile", {}).get("destruction", {}).get(
						"required_hits", 1.0
					)
				),
				"harvest_value": harvest_value,
			}
		)
		total_tree_harvest_value += harvest_value
	_prepared_caps = {
		"total_enemy_health": total_enemy_health,
		"positive_removal_value": positive_removal_value,
		"negative_removal_value": negative_removal_value,
		"visible_enemy_count": visible_enemy_count,
		"total_tree_harvest_value": total_tree_harvest_value,
	}


func _sample_outcome_field(
	observation: Dictionary, displacement: Vector2, control_seconds: float, is_moving: bool
) -> Dictionary:
	var movement_state := "moving" if is_moving else "standing"
	if not _prepared_outcome_fields.has(movement_state):
		_prepared_outcome_fields[movement_state] = _build_outcome_field(
			observation, displacement, control_seconds, is_moving
		)
	var outcome_field: Dictionary = _prepared_outcome_fields[movement_state]
	if not is_moving:
		return outcome_field.samples[0]
	var radius: float = outcome_field.radius
	var normalized_offset: Vector2 = (displacement - outcome_field.center) / radius
	var x_coordinate: float = clamp(normalized_offset.x, -1.0, 1.0) + 1.0
	var y_coordinate: float = clamp(normalized_offset.y, -1.0, 1.0) + 1.0
	var x0 := int(floor(x_coordinate))
	var y0 := int(floor(y_coordinate))
	var x1 := min(2, x0 + 1)
	var y1 := min(2, y0 + 1)
	var x_fraction: float = x_coordinate - x0
	var y_fraction: float = y_coordinate - y0
	return _interpolate_outcomes(
		outcome_field.samples[y0 * 3 + x0],
		outcome_field.samples[y0 * 3 + x1],
		outcome_field.samples[y1 * 3 + x0],
		outcome_field.samples[y1 * 3 + x1],
		x_fraction,
		y_fraction
	)


func _build_outcome_field(
	observation: Dictionary,
	candidate_displacement: Vector2,
	control_seconds: float,
	is_moving: bool
) -> Dictionary:
	var center: Vector2 = _player_kinematics_model.predict_displacement(
		observation, Vector2.ZERO, control_seconds
	)
	if not is_moving:
		return {
			"center": center,
			"radius": 1.0,
			"samples": [_estimate_outcome_at(observation, center, control_seconds, false)],
		}
	var radius: float = max(
		observation.player_state.collision_radius,
		max(
			observation.player_state.runtime_stats.move_speed * control_seconds,
			(candidate_displacement - center).length()
		)
	)
	var samples := []
	for y_index in 3:
		for x_index in 3:
			var offset := Vector2(x_index - 1, y_index - 1) * radius
			samples.push_back(
				_estimate_outcome_at(observation, center + offset, control_seconds, true)
			)
	return {"center": center, "radius": radius, "samples": samples}


func _estimate_outcome_at(
	observation: Dictionary, displacement: Vector2, control_seconds: float, is_moving: bool
) -> Dictionary:
	var result: Dictionary = _empty_outcome_sample()
	var target_samples: Array = _sample_targets(observation, displacement, control_seconds)
	for observed_weapon in observation.player_state.weapons:
		if is_moving and not observed_weapon.attack_model.timing.permitted_while_moving:
			continue
		var attack_model: Dictionary = _movement_state_projector.project_attack_model(
			observed_weapon, observation, is_moving
		)
		_accumulate_weapon_outcome(
			attack_model, target_samples, observation, control_seconds, result
		)
	return result


func _interpolate_outcomes(
	lower_left: Dictionary,
	lower_right: Dictionary,
	upper_left: Dictionary,
	upper_right: Dictionary,
	x_fraction: float,
	y_fraction: float
) -> Dictionary:
	var result := {}
	for key in OUTCOME_FIELDS:
		var lower: float = lerp(lower_left[key], lower_right[key], x_fraction)
		var upper: float = lerp(upper_left[key], upper_right[key], x_fraction)
		result[key] = lerp(lower, upper, y_fraction)
	return result


func _empty_outcome_sample() -> Dictionary:
	var result := {}
	for key in OUTCOME_FIELDS:
		result[key] = 0.0
	return result


func _sample_targets(observation: Dictionary, player_displacement: Vector2, time: float) -> Array:
	_enemy_motion_predictor.begin_physics_frame(observation.get("physics_frame", -1))
	var result := []
	for target in _prepared_targets:
		var position: Vector2
		if target.kind == "enemy":
			position = _enemy_motion_predictor.predict_position(
				target.track, time, player_displacement
			)
		else:
			position = target.tree.relative_position
		var relative_position: Vector2 = position - player_displacement
		result.push_back(
			{
				"target": target,
				"relative_position": relative_position,
				"distance": relative_position.length(),
			}
		)
	return result


func _accumulate_weapon_outcome(
	attack_model: Dictionary,
	target_samples: Array,
	observation: Dictionary,
	control_seconds: float,
	outcome: Dictionary
) -> void:
	var attack_interval_seconds: float = max(
		0.05, attack_model.timing.expected_attack_interval_seconds
	)
	var expected_attack_count: float = control_seconds / attack_interval_seconds
	if expected_attack_count <= 0.0:
		return
	var transition_width: float = max(
		observation.player_state.collision_radius,
		observation.player_state.runtime_stats.move_speed * control_seconds
	)
	var coverage: Dictionary = _summarize_target_coverage(
		attack_model, target_samples, transition_width
	)
	if coverage.target_availability <= 0.0:
		return
	var expected_hits_per_attack: float = _expected_hits_per_attack(attack_model, coverage)
	var expected_damage_per_attack: float = _expected_damage_per_attack(attack_model, coverage)
	var expected_hits: float = (
		expected_attack_count
		* expected_hits_per_attack
		* coverage.target_availability
	)
	var expected_damage: float = (
		expected_attack_count
		* expected_damage_per_attack
		* coverage.target_availability
	)
	var enemy_hits: float = expected_hits * coverage.enemy_selection_share
	var enemy_damage: float = expected_damage * coverage.enemy_selection_share
	outcome.expected_attack_hits += expected_hits
	outcome.expected_weapon_damage += enemy_damage
	outcome.expected_enemy_removal_value_progress += (
		enemy_damage
		* coverage.mean_removal_value_per_health
	)
	outcome.expected_kill_weight += min(
		coverage.covered_enemy_mass, enemy_damage / max(1.0, coverage.mean_enemy_maximum_health)
	)
	outcome.expected_critical_kill_weight += (
		min(
			coverage.covered_enemy_mass, enemy_damage / max(1.0, coverage.mean_enemy_maximum_health)
		)
		* clamp(attack_model.impact.critical_chance, 0.0, 1.0)
	)
	outcome.expected_tree_harvest_value_progress += (
		expected_hits
		* coverage.tree_selection_share
		* coverage.mean_tree_harvest_value_per_hit
	)
	outcome.expected_lifesteal_recovery += (
		enemy_hits
		* clamp(attack_model.impact.lifesteal, 0.0, 1.0)
	)


func _summarize_target_coverage(
	attack_model: Dictionary, target_samples: Array, transition_width: float
) -> Dictionary:
	var minimum_distance: float = max(0.0, attack_model.delivery.minimum_targeting_distance)
	var maximum_distance: float = max(
		minimum_distance, attack_model.delivery.maximum_targeting_distance
	)
	var total_selection_weight := 0.0
	var enemy_selection_weight := 0.0
	var tree_selection_weight := 0.0
	var covered_enemy_mass := 0.0
	var covered_target_mass := 0.0
	var target_unavailable_probability := 1.0
	var weighted_removal_value_per_health := 0.0
	var weighted_enemy_maximum_health := 0.0
	var weighted_tree_harvest_value_per_hit := 0.0
	var covered_samples := []
	for sample in target_samples:
		var target: Dictionary = sample.target
		var coverage: float = (
			_range_coverage(
				sample.distance, target.radius, minimum_distance, maximum_distance, transition_width
			)
			* clamp(target.confidence, 0.0, 1.0)
		)
		if coverage <= 0.0:
			continue
		var proximity_weight: float = (
			1.0
			+ maximum_distance / max(max(1.0, target.radius), sample.distance)
		)
		var selection_weight: float = coverage * proximity_weight
		covered_samples.push_back(
			{
				"sample": sample,
				"coverage": coverage,
				"selection_weight": selection_weight,
			}
		)
		total_selection_weight += selection_weight
		covered_target_mass += coverage
		target_unavailable_probability *= 1.0 - clamp(coverage, 0.0, 1.0)
		if target.kind == "enemy":
			enemy_selection_weight += selection_weight
			covered_enemy_mass += coverage
			weighted_removal_value_per_health += (
				selection_weight
				* target.removal_value_per_health
			)
			weighted_enemy_maximum_health += selection_weight * target.maximum_health
		else:
			tree_selection_weight += selection_weight
			weighted_tree_harvest_value_per_hit += (
				selection_weight
				* target.harvest_value
				/ target.required_hits
			)
	var enemy_selection_share: float = enemy_selection_weight / max(0.0001, total_selection_weight)
	var tree_selection_share: float = tree_selection_weight / max(0.0001, total_selection_weight)
	return {
		"target_availability": 1.0 - target_unavailable_probability,
		"covered_target_mass": covered_target_mass,
		"covered_enemy_mass": covered_enemy_mass,
		"expected_additional_direct_targets":
		_expected_additional_direct_targets(
			attack_model, covered_samples, total_selection_weight, transition_width
		),
		"enemy_selection_share": enemy_selection_share,
		"tree_selection_share": tree_selection_share,
		"mean_removal_value_per_health":
		weighted_removal_value_per_health / max(0.0001, enemy_selection_weight),
		"mean_enemy_maximum_health":
		weighted_enemy_maximum_health / max(0.0001, enemy_selection_weight),
		"mean_tree_harvest_value_per_hit":
		weighted_tree_harvest_value_per_hit / max(0.0001, tree_selection_weight),
	}


func _expected_additional_direct_targets(
	attack_model: Dictionary,
	covered_samples: Array,
	total_selection_weight: float,
	transition_width: float
) -> float:
	if covered_samples.size() <= 1 or total_selection_weight <= 0.0:
		return 0.0
	var expected_mass := 0.0
	for primary_index in covered_samples.size():
		var primary: Dictionary = covered_samples[primary_index]
		var aim_position: Vector2 = primary.sample.relative_position
		if aim_position.length_squared() <= 0.0:
			continue
		var aligned_mass := 0.0
		for secondary_index in covered_samples.size():
			if secondary_index == primary_index:
				continue
			var secondary: Dictionary = covered_samples[secondary_index]
			aligned_mass += (
				secondary.coverage
				* _direct_path_intersection(
					attack_model,
					aim_position,
					secondary.sample.relative_position,
					secondary.sample.target.radius,
					transition_width
				)
			)
		expected_mass += (primary.selection_weight / total_selection_weight * aligned_mass)
	return expected_mass


func _direct_path_intersection(
	attack_model: Dictionary,
	aim_position: Vector2,
	target_position: Vector2,
	target_radius: float,
	transition_width: float
) -> float:
	var paths: Dictionary = attack_model.delivery.paths
	var path_count := int(paths.count)
	var angular_half_extent: float = paths.angular_half_extent
	var maximum_distance: float = paths.maximum_travel_distance
	var best_intersection := 0.0
	for path_index in path_count:
		var path_angle := 0.0
		if path_count > 1:
			path_angle = lerp(
				-angular_half_extent, angular_half_extent, float(path_index) / float(path_count - 1)
			)
		var direction: Vector2 = aim_position.normalized().rotated(path_angle)
		var forward_distance: float = target_position.dot(direction)
		if forward_distance < -target_radius or forward_distance > maximum_distance + target_radius:
			continue
		var lateral_distance: float = abs(target_position.cross(direction))
		var clearance: float = lateral_distance - paths.corridor_half_width - target_radius
		best_intersection = max(
			best_intersection, clamp(1.0 - clearance / max(1.0, transition_width), 0.0, 1.0)
		)
	return best_intersection


func _range_coverage(
	distance: float,
	radius: float,
	minimum_distance: float,
	maximum_distance: float,
	transition_width: float
) -> float:
	var target_distance: float = max(0.0, distance - max(0.0, radius))
	var upper_coverage: float = clamp(
		(maximum_distance - target_distance) / max(1.0, transition_width), 0.0, 1.0
	)
	if minimum_distance <= 0.0:
		return upper_coverage
	var lower_coverage: float = clamp(
		(target_distance - minimum_distance) / max(1.0, transition_width), 0.0, 1.0
	)
	return min(lower_coverage, upper_coverage)


func _expected_hits_per_attack(attack_model: Dictionary, coverage: Dictionary) -> float:
	var paths: Dictionary = attack_model.delivery.paths
	var primary_hits: float = (
		max(1.0, float(paths.count))
		* clamp(paths.primary_probability_floor, 0.05, 1.0)
	)
	var additional_covered_targets: float = coverage.expected_additional_direct_targets
	var direct_stages: float = min(
		max(0.0, float(paths.hit_capacity) - 1.0), additional_covered_targets
	)
	var redirectable_targets: float = max(0.0, coverage.covered_target_mass - 1.0)
	var redirect_stages: float = min(_expected_redirect_count(attack_model), redirectable_targets)
	return primary_hits * (1.0 + direct_stages + redirect_stages)


func _expected_damage_per_attack(attack_model: Dictionary, coverage: Dictionary) -> float:
	var paths: Dictionary = attack_model.delivery.paths
	var primary_hits: float = (
		max(1.0, float(paths.count))
		* clamp(paths.primary_probability_floor, 0.05, 1.0)
	)
	var impact_damage: float = _weapon_attack_capacity_model.expected_damage_per_hit(attack_model)
	var primary_damage: float = impact_damage * primary_hits
	var additional_covered_targets: float = coverage.expected_additional_direct_targets
	var direct_stages: float = min(
		max(0.0, float(paths.hit_capacity) - 1.0), additional_covered_targets
	)
	var redirectable_targets: float = max(0.0, coverage.covered_target_mass - 1.0)
	var redirect_stages: float = min(_expected_redirect_count(attack_model), redirectable_targets)
	var delivery_multiplier: float = (
		1.0
		+ _retained_stage_sum(direct_stages, clamp(paths.retained_damage, 0.0, 1.0))
		+ _retained_stage_sum(
			redirect_stages, clamp(attack_model.delivery.redirects.retained_damage, 0.0, 1.0)
		)
	)
	return (
		primary_damage * delivery_multiplier
		+ primary_hits * _expected_rule_damage_per_hit(attack_model, coverage, impact_damage)
	)


func _expected_rule_damage_per_hit(
	attack_model: Dictionary, coverage: Dictionary, impact_damage: float
) -> float:
	var result := 0.0
	for rule in attack_model.rules:
		if rule.event != "weapon_hit":
			continue
		for consequence in rule.consequences:
			if consequence.target != "enemy_health" or consequence.operation != "deal_damage":
				continue
			var delivery: Dictionary = consequence.delivery
			var applications := 1.0
			if delivery.target_selection == "area":
				var area_fraction: float = clamp(
					delivery.radius / max(1.0, attack_model.delivery.maximum_targeting_distance),
					0.0,
					1.0
				)
				applications += (
					max(0.0, coverage.covered_enemy_mass - 1.0)
					* area_fraction
					* area_fraction
				)
			elif delivery.target_selection in ["uniform_other_enemy", "random_direction"]:
				applications = max(0.0, coverage.covered_enemy_mass - 1.0)
			applications = min(max(0.0, delivery.capacity_per_event), applications)
			var amount: Dictionary = consequence.amount
			var damage: float = max(
				amount.minimum,
				(
					amount.constant
					+ impact_damage * amount.impact_coefficient
					+ coverage.mean_enemy_maximum_health * amount.target_maximum_health_coefficient
				)
			)
			result += (damage * applications * clamp(consequence.get("probability", 1.0), 0.0, 1.0))
	return result


func _retained_stage_sum(stages: float, retained: float) -> float:
	var result := 0.0
	var whole_stages := int(floor(max(0.0, stages)))
	var stage_damage := retained
	for _stage in whole_stages:
		result += stage_damage
		stage_damage *= retained
	result += (stages - whole_stages) * stage_damage
	return result


func _expected_redirect_count(attack_model: Dictionary) -> float:
	return (
		attack_model.delivery.redirects.count
		+ (
			attack_model.impact.critical_chance
			* _unconditional_rule_addition(
				attack_model.rules, "critical_hit", "delivery.redirects.count"
			)
		)
	)


func _unconditional_rule_addition(rules: Array, event: String, target: String) -> float:
	var result := 0.0
	for rule in rules:
		if rule.event != event or not rule.condition.empty():
			continue
		for consequence in rule.consequences:
			if consequence.target == target and consequence.operation == "add":
				result += consequence.get("value", 0.0)
	return result


func _cap_outcome(outcome: Dictionary) -> void:
	outcome.expected_weapon_damage = min(
		outcome.expected_weapon_damage, _prepared_caps.total_enemy_health
	)
	outcome.expected_enemy_removal_value_progress = clamp(
		outcome.expected_enemy_removal_value_progress,
		_prepared_caps.negative_removal_value,
		_prepared_caps.positive_removal_value
	)
	outcome.expected_kill_weight = min(
		outcome.expected_kill_weight, _prepared_caps.visible_enemy_count
	)
	outcome.expected_critical_kill_weight = min(
		outcome.expected_critical_kill_weight, outcome.expected_kill_weight
	)
	outcome.expected_tree_harvest_value_progress = clamp(
		outcome.expected_tree_harvest_value_progress, 0.0, _prepared_caps.total_tree_harvest_value
	)
