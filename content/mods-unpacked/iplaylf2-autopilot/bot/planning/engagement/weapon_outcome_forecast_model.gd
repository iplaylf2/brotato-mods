extends Reference

# Forecasts action-conditioned weapon outcomes along each retained movement path.
# This model owns target coverage, nearest-target selection, and hit attribution by
# completion mechanism, including the event state used to price a completed target.
# It does not roll out individual attacks, projectiles, contacts, redirects, or
# triggered event chains.

const WeaponAttackCapacityModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapons/weapon_attack_capacity_model.gd"
)
const PlayerMovementStateProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_movement_state_projector.gd"
)
const EngagementTargetProjector := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "engagement_target_projector.gd"
	)
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
const WeaponPathContactModel := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "weapon_path_contact_model.gd"
	)
)
const OpportunityPricingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_pricing_model.gd"
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
var _engagement_target_projector: Reference = EngagementTargetProjector.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _weapon_outcome_conservation_model: Reference = WeaponOutcomeConservationModel.new()
var _weapon_path_contact_model: Reference = WeaponPathContactModel.new()
var _opportunity_pricing_model: Reference = OpportunityPricingModel.new()
var _prepared_physics_frame := -1
var _prepared_targets := []
var _prepared_tree_harvest_value_capacity := 0.0
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
	var transition_seconds: float = min(
		forecast_seconds, planning_context.tactical_control_interval_seconds
	)
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
	_weapon_outcome_conservation_model.constrain_tree_value(
		outcome, _prepared_tree_harvest_value_capacity
	)


func _prepare_targets(observation: Dictionary, planning_context: Dictionary) -> void:
	var physics_frame: int = observation.get("physics_frame", -1)
	if physics_frame >= 0 and physics_frame == _prepared_physics_frame:
		return
	_prepared_physics_frame = physics_frame
	_prepared_targets = []
	_prepared_attack_models = {}
	var tree_harvest_value_capacity := 0.0
	for target in _engagement_target_projector.project_visible_targets(
		observation, planning_context
	):
		if target.completion.completed:
			continue
		_prepared_targets.push_back(target)
		if target.weapon_response.hit_limit_progress_per_hit > 0.0:
			tree_harvest_value_capacity += target.value.net_completion_value
	_prepared_tree_harvest_value_capacity = tree_harvest_value_capacity


func _estimate_outcome_along_path(
	observation: Dictionary,
	terminal_displacement: Vector2,
	forecast_seconds: float,
	transition_seconds: float,
	is_moving: bool
) -> Dictionary:
	var result: Dictionary = _empty_outcome_sample()
	var enemy_work_by_target_id := {}
	var transition_width: float = max(
		observation.player_state.collision_radius,
		observation.player_state.runtime_stats.move_speed * transition_seconds
	)
	# Simpson integration preserves both the initial opportunity and the time at
	# which candidate movement creates or loses an attack window. Applying the
	# terminal target arrangement to every expected attack would prepay damage that
	# cannot occur while the player is still approaching.
	_accumulate_outcome_at_path_sample(
		observation,
		Vector2.ZERO,
		0.0,
		forecast_seconds / 6.0,
		forecast_seconds,
		transition_width,
		is_moving,
		enemy_work_by_target_id,
		result
	)
	_accumulate_outcome_at_path_sample(
		observation,
		terminal_displacement * 0.5,
		forecast_seconds * 0.5,
		forecast_seconds * 4.0 / 6.0,
		forecast_seconds,
		transition_width,
		is_moving,
		enemy_work_by_target_id,
		result
	)
	_accumulate_outcome_at_path_sample(
		observation,
		terminal_displacement,
		forecast_seconds,
		forecast_seconds / 6.0,
		forecast_seconds,
		transition_width,
		is_moving,
		enemy_work_by_target_id,
		result
	)
	_weapon_outcome_conservation_model.settle_enemy_work(result, enemy_work_by_target_id)
	return result


func _accumulate_outcome_at_path_sample(
	observation: Dictionary,
	player_displacement: Vector2,
	time: float,
	duration_weight: float,
	forecast_seconds: float,
	transition_width: float,
	is_moving: bool,
	enemy_work_by_target_id: Dictionary,
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
			attack_model,
			coverage_by_delivery[delivery_key],
			duration_weight,
			forecast_seconds,
			enemy_work_by_target_id,
			result
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
		var position: Vector2 = _enemy_motion_predictor.predict_position(
			target.motion_track, time, player_displacement
		)
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
	attack_model: Dictionary,
	coverage: Dictionary,
	exposure_seconds: float,
	forecast_seconds: float,
	enemy_work_by_target_id: Dictionary,
	outcome: Dictionary
) -> void:
	var expected_attack_count: float = (
		_weapon_attack_capacity_model.expected_attack_count(attack_model, forecast_seconds)
		* exposure_seconds
		/ max(0.0001, forecast_seconds)
	)
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
	var tree_damage: float = expected_damage * tree_hits / max(0.0001, expected_hits)
	var enemy_damage: float = expected_damage * enemy_hits / max(0.0001, expected_hits)
	outcome.expected_attack_hits += expected_hits
	_accumulate_enemy_target_work(
		coverage,
		target_hits.enemy_by_target_id,
		enemy_hits,
		enemy_damage,
		attack_model.impact.critical_chance,
		enemy_work_by_target_id
	)
	outcome.expected_tree_completion_value += (max(
		tree_hits * coverage.mean_tree_completion_value_per_hit,
		tree_damage * coverage.mean_tree_completion_value_per_damage
	))
	outcome.expected_lifesteal_recovery += (
		expected_hits
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
	var enemy_primary_contact_weight := 0.0
	var tree_primary_contact_weight := 0.0
	var covered_enemy_mass := 0.0
	var covered_tree_mass := 0.0
	var covered_target_mass := 0.0
	var weighted_enemy_maximum_health := 0.0
	var weighted_tree_completion_value_per_hit := 0.0
	var weighted_tree_completion_value_per_damage := 0.0
	var covered_samples := []
	for sample in target_samples:
		var target: Dictionary = sample.target
		var coverage: float = (
			_range_coverage(sample.distance, minimum_distance, maximum_distance)
			* clamp(target.confidence, 0.0, 1.0)
		)
		if coverage <= 0.0:
			continue
		covered_samples.push_back(
			{
				"sample": sample,
				"coverage": coverage,
				"primary_contact":
				_weapon_path_contact_model.primary_contact_fraction(
					attack_model, sample.relative_position, target.radius, transition_width
				),
				"selection_weight": 0.0,
			}
		)
	var nearer_targets_unavailable_probability := 1.0
	for covered in covered_samples:
		# Vanilla chooses the nearest target inside its exact range. A farther target
		# receives probability only from uncertainty that nearer remembered targets
		# still exist, never from a softened targeting boundary.
		var selection_weight: float = covered.coverage * nearer_targets_unavailable_probability
		covered.selection_weight = selection_weight
		total_selection_weight += selection_weight
		covered_target_mass += covered.coverage
		nearer_targets_unavailable_probability *= 1.0 - clamp(covered.coverage, 0.0, 1.0)
		var target: Dictionary = covered.sample.target
		if target.weapon_response.hit_limit_progress_per_hit <= 0.0:
			enemy_selection_weight += selection_weight
			enemy_primary_contact_weight += selection_weight * covered.primary_contact
			covered_enemy_mass += covered.coverage
			weighted_enemy_maximum_health += (selection_weight * target.completion.health.maximum)
		else:
			tree_selection_weight += selection_weight
			tree_primary_contact_weight += selection_weight * covered.primary_contact
			covered_tree_mass += covered.coverage
			weighted_tree_completion_value_per_hit += (
				covered.coverage
				* target.value.net_completion_value
				* target.weapon_response.hit_limit_progress_per_hit
				/ max(1.0, target.completion.hit_limit.remaining)
			)
			weighted_tree_completion_value_per_damage += (
				covered.coverage
				* target.value.net_completion_value
				/ max(1.0, target.completion.health.remaining)
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
		"covered_samples": covered_samples,
		"enemy_selection_share": enemy_selection_share,
		"tree_selection_share": tree_selection_share,
		"enemy_primary_contact_share":
		enemy_primary_contact_weight / max(0.0001, total_selection_weight),
		"tree_primary_contact_share":
		tree_primary_contact_weight / max(0.0001, total_selection_weight),
		"primary_contact_share":
		(
			(enemy_primary_contact_weight + tree_primary_contact_weight)
			/ max(0.0001, total_selection_weight)
		),
		"mean_enemy_maximum_health":
		weighted_enemy_maximum_health / max(0.0001, enemy_selection_weight),
		"mean_tree_completion_value_per_hit":
		weighted_tree_completion_value_per_hit / max(0.0001, covered_tree_mass),
		"mean_tree_completion_value_per_damage":
		weighted_tree_completion_value_per_damage / max(0.0001, covered_tree_mass),
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
		return {"enemy": 0.0, "tree": 0.0, "total": 0.0, "by_target_id": {}}
	var result := {"enemy": 0.0, "tree": 0.0, "total": 0.0, "by_target_id": {}}
	for primary_index in covered_samples.size():
		var primary: Dictionary = covered_samples[primary_index]
		# Fully available nearer targets reduce every later nearest-target selection
		# weight to zero. Those targets cannot contribute to the expectation, so do
		# not traverse their O(target_count) direct-path intersections.
		if primary.selection_weight <= 0.0:
			continue
		var aim_position: Vector2 = primary.sample.relative_position
		if aim_position.length_squared() <= 0.0:
			continue
		for secondary_index in covered_samples.size():
			if secondary_index == primary_index:
				continue
			var secondary: Dictionary = covered_samples[secondary_index]
			var contact_mass: float = (
				secondary.coverage
				* _weapon_path_contact_model.additional_contact_fraction(
					attack_model,
					aim_position,
					secondary.sample.relative_position,
					secondary.sample.target.radius,
					transition_width
				)
			)
			contact_mass *= primary.selection_weight / total_selection_weight
			var channel := (
				"enemy"
				if secondary.sample.target.weapon_response.hit_limit_progress_per_hit <= 0.0
				else "tree"
			)
			result[channel] += contact_mass
			result.total += contact_mass
			if channel == "enemy":
				var target_id: String = secondary.sample.target.target_id
				result.by_target_id[target_id] = (
					result.by_target_id.get(target_id, 0.0)
					+ contact_mass
				)
	return result


func _range_coverage(distance: float, minimum_distance: float, maximum_distance: float) -> float:
	# Visible target centers and the vanilla lock boundary are both exact. A
	# movement-derived soft band shifted usable range inward and could also keep
	# otherwise certain, mutually exclusive nearest targets alive for unnecessary
	# direct-path intersections.
	return 1.0 if distance >= minimum_distance and distance <= maximum_distance else 0.0


func _expected_target_hits(attack_model: Dictionary, coverage: Dictionary) -> Dictionary:
	var paths: Dictionary = attack_model.delivery.paths
	var primary_hits: float = float(paths.count) * float(paths.primary_probability_floor)
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
			coverage.enemy_primary_contact_share
			+ direct_mass.enemy * direct_scale
			+ redirect_stages * enemy_redirect_share
		)
	)
	var tree_hits: float = (
		primary_hits
		* (
			coverage.tree_primary_contact_share
			+ direct_mass.tree * direct_scale
			+ redirect_stages * tree_redirect_share
		)
	)
	var enemy_by_target_id := {}
	for covered in coverage.covered_samples:
		var target: Dictionary = covered.sample.target
		if target.weapon_response.hit_limit_progress_per_hit > 0.0:
			continue
		var target_id: String = target.target_id
		var primary_share: float = (
			covered.selection_weight
			* covered.primary_contact
			/ max(0.0001, coverage.target_availability)
		)
		var direct_share: float = (
			coverage.additional_direct_target_mass.by_target_id.get(target_id, 0.0)
			* direct_scale
		)
		var redirect_share: float = (
			redirect_stages
			* covered.coverage
			/ max(0.0001, coverage.covered_target_mass)
		)
		enemy_by_target_id[target_id] = (
			primary_hits
			* (primary_share + direct_share + redirect_share)
		)
	return {
		"enemy": enemy_hits,
		"tree": tree_hits,
		"total": enemy_hits + tree_hits,
		"enemy_by_target_id": enemy_by_target_id,
	}


func _accumulate_enemy_target_work(
	coverage: Dictionary,
	hits_per_attack_by_target_id: Dictionary,
	expected_enemy_hits: float,
	expected_enemy_damage: float,
	critical_chance: float,
	work_by_target_id: Dictionary
) -> void:
	if expected_enemy_hits <= 0.0 or expected_enemy_damage <= 0.0:
		return
	var per_attack_enemy_hits := 0.0
	for value in hits_per_attack_by_target_id.values():
		per_attack_enemy_hits += max(0.0, value)
	if per_attack_enemy_hits <= 0.0:
		return
	var damage_per_hit := expected_enemy_damage / expected_enemy_hits
	for covered in coverage.covered_samples:
		var target: Dictionary = covered.sample.target
		if target.weapon_response.hit_limit_progress_per_hit > 0.0:
			continue
		var target_hits: float = max(0.0, hits_per_attack_by_target_id.get(target.target_id, 0.0))
		var realized_hits := expected_enemy_hits * target_hits / per_attack_enemy_hits
		_weapon_outcome_conservation_model.accumulate_target_work(
			work_by_target_id,
			target,
			realized_hits,
			realized_hits * damage_per_hit,
			critical_chance,
			_action_conditioned_reward_delta(target, covered.sample.distance)
		)


func _action_conditioned_reward_delta(target: Dictionary, distance: float) -> float:
	var value: Dictionary = target.value
	if not value.has("action_conditioned_reward_profile"):
		return value.reward_delta_value
	return (
		_opportunity_pricing_model.enemy_death_reward_value_at_distance(
			value.action_conditioned_reward_profile, distance
		)
		- value.get("enemy_reward_preservation_value", 0.0)
	)


func _expected_damage_per_attack(attack_model: Dictionary, coverage: Dictionary) -> float:
	var paths: Dictionary = attack_model.delivery.paths
	var primary_hits: float = float(paths.count) * float(paths.primary_probability_floor)
	var impact_damage: float = _weapon_attack_capacity_model.expected_damage_per_hit(attack_model)
	var primary_damage: float = impact_damage * primary_hits * coverage.primary_contact_share
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
		+ (
			primary_hits
			* coverage.primary_contact_share
			* _expected_rule_damage_per_hit(attack_model, coverage, impact_damage)
		)
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
