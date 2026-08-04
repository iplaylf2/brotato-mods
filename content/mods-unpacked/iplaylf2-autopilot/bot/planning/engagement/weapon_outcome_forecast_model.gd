extends Reference

# Forecasts action-conditioned weapon outcomes along each retained movement path.
# This model owns target coverage, nearest-target selection, and hit attribution by
# target kind. It does not roll out individual attacks, projectiles, contacts,
# redirects, or triggered event chains.

const WeaponAttackCapacityModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapons/weapon_attack_capacity_model.gd"
)
const PlayerMovementStateProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_movement_state_projector.gd"
)
const OpportunityPricingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_pricing_model.gd"
)
const EnemyCompletionValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/enemy_completion_value_model.gd"
)
const EnemyHealthModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/enemy_health_model.gd"
)
const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)
const WeaponOutcomeConservationModel := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "weapon_outcome_conservation_model.gd"
	)
)
const NeutralDestructionWorkModel := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "neutral_destruction_work_model.gd"
	)
)
const OUTCOME_FIELDS := [
	"expected_attack_hits",
	"expected_enemy_hits",
	"expected_weapon_damage",
	"expected_enemy_completion_equivalents",
	"expected_enemy_reward_delta_value",
	"expected_enemy_burden_relief_value",
	"expected_enemy_death_consequence_value",
	"expected_kill_weight",
	"expected_critical_kill_weight",
	"expected_tree_completion_value",
	"expected_lifesteal_recovery",
]

var _weapon_attack_capacity_model: Reference = WeaponAttackCapacityModel.new()
var _movement_state_projector: Reference = PlayerMovementStateProjector.new()
var _opportunity_pricing_model: Reference = OpportunityPricingModel.new()
var _enemy_completion_value_model: Reference = EnemyCompletionValueModel.new()
var _enemy_health_model: Reference = EnemyHealthModel.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _weapon_outcome_conservation_model: Reference = WeaponOutcomeConservationModel.new()
var _neutral_destruction_work_model: Reference = NeutralDestructionWorkModel.new()
var _prepared_physics_frame := -1
var _prepared_targets := []
var _prepared_target_capacity := {}
var _prepared_attack_models := {}


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_enemy_motion_predictor = predictor


func accumulate_outcome(
	observation: Dictionary, action: Dictionary, outcome: Dictionary, planning_context: Dictionary
) -> void:
	_prepare_targets(observation, planning_context)
	if _prepared_targets.empty() or observation.player_state.weapons.empty():
		return
	var forecast_seconds: float = action.forecast_seconds
	var displacement: Vector2 = action.samples.back().displacement
	var is_moving: bool = action.movement != Vector2.ZERO
	var transition_seconds: float = min(forecast_seconds, planning_context.control_interval_seconds)
	# Nearest-target ownership changes on narrow Voronoi boundaries. A shared 3x3
	# interpolation grid blurred those boundaries and made an off-axis action that
	# exposes a tree look identical to one that leaves a nearer enemy selected.
	# Evaluate the retained action path directly. The search allocator bounds the
	# number of complete action forecasts before this semantic model runs.
	var weapon_outcome: Dictionary = _estimate_outcome_along_path(
		observation, displacement, forecast_seconds, transition_seconds, is_moving
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
	_constrain_outcome(outcome)


func _prepare_targets(observation: Dictionary, planning_context: Dictionary) -> void:
	var physics_frame: int = observation.get("physics_frame", -1)
	if physics_frame >= 0 and physics_frame == _prepared_physics_frame:
		return
	_prepared_physics_frame = physics_frame
	_prepared_targets = []
	_prepared_attack_models = {}
	var enemy_health_capacity := 0.0
	var enemy_count_capacity := 0.0
	var completion_value_ledger: Dictionary = planning_context.enemy_completion_value_ledger
	for track in observation.enemy_tracks:
		if not track.visible:
			continue
		var maximum_health: float = max(
			1.0, float(track.behavior_profile.durability.maximum_health)
		)
		var remaining_health: float = _enemy_health_model.remaining_health(track)
		var completion_value: Dictionary = _enemy_completion_value_model.entry(
			completion_value_ledger, track
		)
		_prepared_targets.push_back(
			{
				"kind": "enemy",
				"track": track,
				"radius": track.last_measurement.visual_radius,
				"confidence": track.recency_confidence,
				"maximum_health": maximum_health,
				"remaining_health": remaining_health,
				"reward_delta_value": completion_value.reward_delta_value,
				"burden_relief_value": completion_value.burden_relief_value,
				"death_consequence_value": completion_value.death_consequence_value,
				"net_completion_value": completion_value.net_completion_value,
			}
		)
		enemy_count_capacity += 1.0
		enemy_health_capacity += remaining_health
	var tree_harvest_value_capacity := 0.0
	for tree in observation.visible_world.trees:
		var remaining_hits: float = _neutral_destruction_work_model.remaining_hits(tree)
		if remaining_hits <= 0.0:
			continue
		var harvest_value: float = _opportunity_pricing_model.tree_destruction_value(
			observation, tree, planning_context.state_factors.health_inventory_value
		)
		_prepared_targets.push_back(
			{
				"kind": "tree",
				"tree": tree,
				"radius": tree.get("visual_radius", 0.0),
				"confidence": 1.0,
				"remaining_hits": remaining_hits,
				"harvest_value": harvest_value,
			}
		)
		tree_harvest_value_capacity += harvest_value
	_prepared_target_capacity = {
		"enemy_health": enemy_health_capacity,
		"enemy_count": enemy_count_capacity,
		"tree_harvest_value": tree_harvest_value_capacity,
	}


func _estimate_outcome_along_path(
	observation: Dictionary,
	terminal_displacement: Vector2,
	forecast_seconds: float,
	transition_seconds: float,
	is_moving: bool
) -> Dictionary:
	var result: Dictionary = _empty_outcome_sample()
	var transition_width: float = max(
		observation.player_state.collision_radius,
		observation.player_state.runtime_stats.move_speed * transition_seconds
	)
	# Simpson integration preserves both the initial opportunity and the time at
	# which candidate movement creates or loses an attack window. Applying the
	# terminal target arrangement to every expected attack would prepay damage that
	# cannot occur while the player is still approaching.
	_accumulate_outcome_at_path_sample(
		observation, Vector2.ZERO, 0.0, forecast_seconds / 6.0, transition_width, is_moving, result
	)
	_accumulate_outcome_at_path_sample(
		observation,
		terminal_displacement * 0.5,
		forecast_seconds * 0.5,
		forecast_seconds * 4.0 / 6.0,
		transition_width,
		is_moving,
		result
	)
	_accumulate_outcome_at_path_sample(
		observation,
		terminal_displacement,
		forecast_seconds,
		forecast_seconds / 6.0,
		transition_width,
		is_moving,
		result
	)
	return result


func _accumulate_outcome_at_path_sample(
	observation: Dictionary,
	player_displacement: Vector2,
	time: float,
	duration_weight: float,
	transition_width: float,
	is_moving: bool,
	result: Dictionary
) -> void:
	var target_samples: Array = _sample_targets(observation, player_displacement, time)
	var coverage_by_delivery := {}
	for attack_model in _attack_models(observation, is_moving):
		var delivery_key := _delivery_coverage_key(attack_model)
		if not coverage_by_delivery.has(delivery_key):
			coverage_by_delivery[delivery_key] = _summarize_target_coverage(
				attack_model, target_samples, transition_width
			)
		_accumulate_weapon_outcome(
			attack_model, coverage_by_delivery[delivery_key], duration_weight, result
		)


func _attack_models(observation: Dictionary, is_moving: bool) -> Array:
	var movement_state := "moving" if is_moving else "standing"
	if _prepared_attack_models.has(movement_state):
		return _prepared_attack_models[movement_state]
	var result := []
	for observed_weapon in observation.player_state.weapons:
		if is_moving and not observed_weapon.attack_model.timing.permitted_while_moving:
			continue
		result.push_back(
			_movement_state_projector.project_attack_model(observed_weapon, observation, is_moving)
		)
	_prepared_attack_models[movement_state] = result
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
	# Every automatic weapon applies the same nearest-target ordering at this path
	# sample. Sort once here instead of allocating and sorting the same target list
	# once per weapon delivery profile.
	result.sort_custom(self, "_closer_target_sample")
	return result


func _accumulate_weapon_outcome(
	attack_model: Dictionary, coverage: Dictionary, exposure_seconds: float, outcome: Dictionary
) -> void:
	var attack_interval_seconds: float = max(
		0.05, attack_model.timing.expected_attack_interval_seconds
	)
	var expected_attack_count: float = exposure_seconds / attack_interval_seconds
	if expected_attack_count <= 0.0:
		return
	if coverage.target_availability <= 0.0:
		return
	var target_hits: Dictionary = _expected_target_hits(attack_model, coverage)
	var expected_hits_per_attack: float = target_hits.total
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
	var enemy_hits: float = expected_attack_count * target_hits.enemy * coverage.target_availability
	var tree_hits: float = expected_attack_count * target_hits.tree * coverage.target_availability
	var enemy_damage: float = expected_damage * enemy_hits / max(0.0001, expected_hits)
	outcome.expected_attack_hits += expected_hits
	outcome.expected_enemy_hits += enemy_hits
	outcome.expected_weapon_damage += enemy_damage
	_weapon_outcome_conservation_model.accumulate_enemy_completion(
		outcome, coverage, enemy_hits, enemy_damage, attack_model.impact.critical_chance
	)
	outcome.expected_tree_completion_value += (tree_hits * coverage.mean_tree_harvest_value_per_hit)
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
	var covered_tree_mass := 0.0
	var covered_target_mass := 0.0
	var weighted_enemy_reward_delta_value := 0.0
	var weighted_enemy_burden_relief_value := 0.0
	var weighted_enemy_death_consequence_value := 0.0
	var weighted_enemy_maximum_health := 0.0
	var weighted_enemy_remaining_health := 0.0
	var weighted_tree_harvest_value_per_hit := 0.0
	var covered_samples := []
	for sample in target_samples:
		var target: Dictionary = sample.target
		var coverage: float = (
			_range_coverage(sample.distance, minimum_distance, maximum_distance, transition_width)
			* clamp(target.confidence, 0.0, 1.0)
		)
		if coverage <= 0.0:
			continue
		covered_samples.push_back(
			{
				"sample": sample,
				"coverage": coverage,
				"selection_weight": 0.0,
			}
		)
	var nearer_targets_unavailable_probability := 1.0
	for covered in covered_samples:
		# Vanilla chooses the nearest target. Smooth range coverage represents the
		# uncertainty at a lock boundary; a farther target is selected only when all
		# nearer targets are unavailable.
		var selection_weight: float = covered.coverage * nearer_targets_unavailable_probability
		covered.selection_weight = selection_weight
		total_selection_weight += selection_weight
		covered_target_mass += covered.coverage
		nearer_targets_unavailable_probability *= 1.0 - clamp(covered.coverage, 0.0, 1.0)
		var target: Dictionary = covered.sample.target
		if target.kind == "enemy":
			enemy_selection_weight += selection_weight
			covered_enemy_mass += covered.coverage
			weighted_enemy_reward_delta_value += selection_weight * target.reward_delta_value
			weighted_enemy_burden_relief_value += selection_weight * target.burden_relief_value
			weighted_enemy_death_consequence_value += (
				selection_weight
				* target.death_consequence_value
			)
			weighted_enemy_maximum_health += selection_weight * target.maximum_health
			weighted_enemy_remaining_health += selection_weight * target.remaining_health
		else:
			tree_selection_weight += selection_weight
			covered_tree_mass += covered.coverage
			weighted_tree_harvest_value_per_hit += (
				covered.coverage
				* target.harvest_value
				/ target.remaining_hits
			)
	var enemy_selection_share: float = enemy_selection_weight / max(0.0001, total_selection_weight)
	var tree_selection_share: float = tree_selection_weight / max(0.0001, total_selection_weight)
	return {
		"target_availability": total_selection_weight,
		"covered_target_mass": covered_target_mass,
		"covered_enemy_mass": covered_enemy_mass,
		"additional_direct_target_mass":
		_additional_direct_target_mass(
			attack_model, covered_samples, total_selection_weight, transition_width
		),
		"covered_tree_mass": covered_tree_mass,
		"enemy_selection_share": enemy_selection_share,
		"tree_selection_share": tree_selection_share,
		"mean_enemy_reward_delta_value":
		weighted_enemy_reward_delta_value / max(0.0001, enemy_selection_weight),
		"mean_enemy_burden_relief_value":
		weighted_enemy_burden_relief_value / max(0.0001, enemy_selection_weight),
		"mean_enemy_death_consequence_value":
		weighted_enemy_death_consequence_value / max(0.0001, enemy_selection_weight),
		"mean_enemy_maximum_health":
		weighted_enemy_maximum_health / max(0.0001, enemy_selection_weight),
		"mean_enemy_remaining_health":
		weighted_enemy_remaining_health / max(0.0001, enemy_selection_weight),
		"mean_tree_harvest_value_per_hit":
		weighted_tree_harvest_value_per_hit / max(0.0001, covered_tree_mass),
	}


func _closer_target_sample(left: Dictionary, right: Dictionary) -> bool:
	return left.distance < right.distance


func _delivery_coverage_key(attack_model: Dictionary) -> String:
	# Coverage depends only on targeting range and direct-path geometry. Timing,
	# damage, criticals, lifesteal, and hit rules consume the shared coverage but
	# remain weapon-specific below.
	var delivery: Dictionary = attack_model.delivery
	var paths: Dictionary = delivery.paths
	return (
		"%s|%s|%s|%s|%s|%s"
		% [
			delivery.minimum_targeting_distance,
			delivery.maximum_targeting_distance,
			paths.count,
			paths.angular_half_extent,
			paths.corridor_half_width,
			paths.maximum_travel_distance,
		]
	)


func _additional_direct_target_mass(
	attack_model: Dictionary,
	covered_samples: Array,
	total_selection_weight: float,
	transition_width: float
) -> Dictionary:
	if covered_samples.size() <= 1 or total_selection_weight <= 0.0:
		return {"enemy": 0.0, "tree": 0.0, "total": 0.0}
	var result := {"enemy": 0.0, "tree": 0.0, "total": 0.0}
	for primary_index in covered_samples.size():
		var primary: Dictionary = covered_samples[primary_index]
		var aim_position: Vector2 = primary.sample.relative_position
		if aim_position.length_squared() <= 0.0:
			continue
		for secondary_index in covered_samples.size():
			if secondary_index == primary_index:
				continue
			var secondary: Dictionary = covered_samples[secondary_index]
			var contact_mass: float = (
				secondary.coverage
				* _direct_path_intersection(
					attack_model,
					aim_position,
					secondary.sample.relative_position,
					secondary.sample.target.radius,
					transition_width
				)
			)
			contact_mass *= primary.selection_weight / total_selection_weight
			var kind: String = secondary.sample.target.kind
			result[kind] += contact_mass
			result.total += contact_mass
	return result


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
	distance: float, minimum_distance: float, maximum_distance: float, transition_width: float
) -> float:
	var upper_coverage: float = clamp(
		(maximum_distance - distance) / max(1.0, transition_width), 0.0, 1.0
	)
	if minimum_distance <= 0.0:
		return upper_coverage
	var lower_coverage: float = clamp(
		(distance - minimum_distance) / max(1.0, transition_width), 0.0, 1.0
	)
	return min(lower_coverage, upper_coverage)


func _expected_target_hits(attack_model: Dictionary, coverage: Dictionary) -> Dictionary:
	var paths: Dictionary = attack_model.delivery.paths
	var primary_hits: float = (
		max(1.0, float(paths.count))
		* clamp(paths.primary_probability_floor, 0.05, 1.0)
	)
	var direct_mass: Dictionary = coverage.additional_direct_target_mass
	var direct_capacity: float = min(max(0.0, float(paths.hit_capacity) - 1.0), direct_mass.total)
	var direct_scale: float = direct_capacity / max(0.0001, direct_mass.total)
	var redirectable_targets: float = max(0.0, coverage.covered_target_mass - 1.0)
	var redirect_stages: float = min(_expected_redirect_count(attack_model), redirectable_targets)
	var enemy_redirect_share: float = (
		coverage.covered_enemy_mass
		/ max(0.0001, coverage.covered_target_mass)
	)
	var tree_redirect_share: float = (
		coverage.covered_tree_mass
		/ max(0.0001, coverage.covered_target_mass)
	)
	var enemy_hits: float = (
		primary_hits
		* (
			coverage.enemy_selection_share
			+ direct_mass.enemy * direct_scale
			+ redirect_stages * enemy_redirect_share
		)
	)
	var tree_hits: float = (
		primary_hits
		* (
			coverage.tree_selection_share
			+ direct_mass.tree * direct_scale
			+ redirect_stages * tree_redirect_share
		)
	)
	return {"enemy": enemy_hits, "tree": tree_hits, "total": enemy_hits + tree_hits}


func _expected_damage_per_attack(attack_model: Dictionary, coverage: Dictionary) -> float:
	var paths: Dictionary = attack_model.delivery.paths
	var primary_hits: float = (
		max(1.0, float(paths.count))
		* clamp(paths.primary_probability_floor, 0.05, 1.0)
	)
	var impact_damage: float = _weapon_attack_capacity_model.expected_damage_per_hit(attack_model)
	var primary_damage: float = impact_damage * primary_hits
	var additional_covered_targets: float = coverage.additional_direct_target_mass.total
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


func _constrain_outcome(outcome: Dictionary) -> void:
	_weapon_outcome_conservation_model.constrain(outcome, _prepared_target_capacity)
