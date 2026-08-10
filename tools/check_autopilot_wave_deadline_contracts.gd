extends Reference

# Focused model contracts for opportunities that expire at wave cleanup. These
# run inside the main model-contract process; this file only separates domain
# ownership from the already broad model suite.

const PLANNING_PATH := "res://mods-unpacked/iplaylf2-autopilot/bot/planning/"

var _failed := false
var _fixtures: Reference


func run(fixtures: Reference) -> bool:
	_fixtures = fixtures
	_check_short_deadline_combat_setup()
	_check_pickup_deadline()
	_check_autonomous_target_access_counterfactual()
	_check_target_specific_interval_capacity()
	_check_minimum_targeting_distance_access()
	_check_long_range_access_gradients()
	return not _failed


func _check_short_deadline_combat_setup() -> void:
	var enemy: Dictionary = _fixtures.enemy_track(Vector2(320.0, 0.0), Vector2.ZERO, false)
	var observation: Dictionary = _fixtures.planning_observation([enemy])
	observation.wave_state.seconds_remaining = 0.4
	var attack: Dictionary = _fixtures.weapon_attack_model()
	attack.timing.expected_attack_interval_seconds = 0.1
	observation.player_state.weapons = [{"slot": 0, "attack_model": attack}]
	var context := {
		"environmental_pressure_weights": _influence_weights(),
		"enemy_completion_value_ledger": _completion_value_ledger({1: 10.0}),
		"state_factors":
		{
			"health_inventory_value":
			{"maximum_consumable_recovery": 0.0, "replenishment_unit_value": 0.0},
			"information_value_per_viewport": 0.0,
			"environmental_exposure_value": 0.0,
			"continuation_horizon_seconds": 0.4,
		},
		"wave_completion_forecast": _fixtures.wave_completion_forecast({1: 1.0}),
	}
	var compute_policy: Reference = load(PLANNING_PATH + "planning_compute_budget_policy.gd").new()
	var result: Dictionary = load(PLANNING_PATH + "navigation_intent_planner.gd").new().plan(
		observation,
		context,
		{"has_deadline": false},
		{"navigation_baseline_direction_count": 4, "navigation_extra_evaluation_limit": 0},
		compute_policy
	)
	var right_sample: Dictionary = _nearest_trajectory_sample(
		result.trajectory_value_samples, Vector2.RIGHT
	)
	_expect(
		(
			result.trajectory_sample_count >= 2
			and result.movement_preference.dot(Vector2.RIGHT) > 0.99
			and right_sample.value_breakdown.target_access_opportunity > 0.0
		),
		(
			"a short wave deadline must preserve combat setup that creates attacks before "
			+ "cleanup instead of sampling only the zero-value terminal state"
		)
	)


func _check_pickup_deadline() -> void:
	var material := {
		"kind": "material",
		"relative_position": Vector2(100.0, 0.0),
		"visual_radius": 36.0,
		"existence_confidence": 1.0,
		"material_quantity": 1.0,
	}
	var observation: Dictionary = _fixtures.planning_observation([])
	observation.wave_state.seconds_remaining = 0.5
	observation.remembered_entities = [material]
	var context := {
		"state_factors": {"health_inventory_value": {}},
		"enemy_completion_value_ledger": _completion_value_ledger({}),
		"wave_completion_forecast": _fixtures.wave_completion_forecast({}),
	}
	var spatial: Reference = load(PLANNING_PATH + "spatial_opportunity_value_model.gd").new()
	var expired_progress: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(50.0, 0.0), 0.5
	)
	var deadline_collection: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(80.0, 0.0), 0.5
	)
	_expect(
		(
			abs(expired_progress.material_opportunity) < 0.0001
			and deadline_collection.material_opportunity > 0.0
		),
		(
			"wave cleanup must erase unfinished pickup progress while retaining collection "
			+ "that completes by the deadline"
		)
	)


func _check_autonomous_target_access_counterfactual() -> void:
	var follower: Dictionary = _fixtures.enemy_track(
		Vector2(900.0, 0.0), Vector2(-100.0, 0.0), true
	)
	var observation: Dictionary = _fixtures.planning_observation([follower])
	observation.player_state.weapons = [
		{"slot": 0, "attack_model": _fixtures.weapon_attack_model()}
	]
	var context := {
		"state_factors":
		{
			"health_inventory_value":
			{"maximum_consumable_recovery": 0.0, "replenishment_unit_value": 0.0},
			"continuation_horizon_seconds": 1.0,
		},
		"enemy_completion_value_ledger": _completion_value_ledger({1: 10.0}),
		"wave_completion_forecast": _fixtures.wave_completion_forecast({1: 1.0}),
	}
	var spatial: Reference = load(PLANNING_PATH + "spatial_opportunity_value_model.gd").new()
	var approach: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(100.0, 0.0), 1.0
	)
	var retreat: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(-100.0, 0.0), 1.0
	)
	var escape: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(-1000.0, 0.0), 1.0
	)
	var candidates: Array = spatial.candidate_directions(observation, context)
	_expect(
		(
			abs(approach.target_access_opportunity) < 0.0001
			and abs(retreat.target_access_opportunity) < 0.0001
			and escape.target_access_opportunity < 0.0
			and candidates.empty()
		),
		(
			"a target that autonomously enters weapon range before cleanup must already be "
			+ "accessible in the zero-input counterfactual; only losing that access has value"
		)
	)


func _check_target_specific_interval_capacity() -> void:
	var near_attack: Dictionary = _fixtures.weapon_attack_model()
	near_attack.delivery.maximum_targeting_distance = 200.0
	near_attack.impact.damage = 10.0
	var far_attack: Dictionary = _fixtures.weapon_attack_model()
	far_attack.delivery.minimum_targeting_distance = 300.0
	far_attack.delivery.maximum_targeting_distance = 800.0
	far_attack.impact.damage = 1.0
	var weapons := [
		{"slot": 0, "attack_model": near_attack},
		{"slot": 1, "attack_model": far_attack},
	]
	var interval_script_path := PLANNING_PATH + "weapons/weapon_targeting_interval_model.gd"
	var interval_model: Reference = load(interval_script_path).new()
	var health_intervals: Array = interval_model.normalized_intervals(
		weapons, {"weapon_response": {"hit_limit_progress_per_hit": 0.0}}
	)
	var hit_intervals: Array = interval_model.normalized_intervals(
		weapons, {"weapon_response": {"hit_limit_progress_per_hit": 1.0}}
	)
	_expect(
		(
			health_intervals.size() == 2
			and health_intervals[0].capacity_share > 0.9
			and is_equal_approx(hit_intervals[0].capacity_share, 0.5)
			and is_equal_approx(hit_intervals[1].capacity_share, 0.5)
		),
		(
			"targeting intervals must use damage capacity for health targets and hit "
			+ "capacity for hit-limited neutrals"
		)
	)


func _check_minimum_targeting_distance_access() -> void:
	var enemy: Dictionary = _fixtures.enemy_track(Vector2(100.0, 0.0), Vector2.ZERO, false)
	var observation: Dictionary = _fixtures.planning_observation([enemy])
	var attack: Dictionary = _fixtures.weapon_attack_model()
	attack.delivery.minimum_targeting_distance = 300.0
	attack.delivery.maximum_targeting_distance = 800.0
	observation.player_state.weapons = [{"slot": 0, "attack_model": attack}]
	var context := {
		"state_factors":
		{
			"health_inventory_value":
			{"maximum_consumable_recovery": 0.0, "replenishment_unit_value": 0.0},
			"continuation_horizon_seconds": 1.0,
		},
		"enemy_completion_value_ledger": _completion_value_ledger({1: 10.0}),
		"wave_completion_forecast": _fixtures.wave_completion_forecast({1: 1.0}),
	}
	var spatial: Reference = load(PLANNING_PATH + "spatial_opportunity_value_model.gd").new()
	var retreat: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(-250.0, 0.0), 0.5
	)
	var approach: Dictionary = spatial.point_value_delta(
		observation, context, Vector2(50.0, 0.0), 0.5
	)
	var candidates: Array = spatial.candidate_directions(observation, context)
	_expect(
		(
			retreat.target_access_opportunity > 0.0
			and approach.target_access_opportunity < 0.0
			and not candidates.empty()
			and candidates[0].direction.dot(Vector2.LEFT) > 0.99
		),
		(
			"a weapon dead zone must create an outward setup gradient and an outward search "
			+ "direction without a weapon-specific movement policy"
		)
	)


func _check_long_range_access_gradients() -> void:
	var spatial_script: Script = load(PLANNING_PATH + "spatial_opportunity_value_model.gd")
	var observation: Dictionary = _fixtures.planning_observation([])
	var material := {
		"kind": "material",
		"relative_position": Vector2(700.0, 0.0),
		"existence_confidence": 1.0,
		"material_quantity": 1.0,
	}
	observation.remembered_entities = [material]
	var context := {
		"state_factors":
		{
			"health_inventory_value":
			{"maximum_consumable_recovery": 0.0, "replenishment_unit_value": 0.0}
		},
		"enemy_completion_value_ledger": _completion_value_ledger({}),
		"wave_completion_forecast": _fixtures.wave_completion_forecast({}),
	}
	var material_toward: Dictionary = spatial_script.new().point_value_delta(
		observation, context, Vector2.RIGHT * 100.0, 1.0
	)
	var material_away: Dictionary = spatial_script.new().point_value_delta(
		observation, context, Vector2.LEFT * 100.0, 1.0
	)
	observation.physics_frame += 1
	material = material.duplicate(true)
	material.relative_position = Vector2(900.0, 0.0)
	observation.remembered_entities = [material]
	var farther_material: Dictionary = spatial_script.new().point_value_delta(
		observation, context, Vector2.RIGHT * 100.0, 1.0
	)
	_expect(
		(
			material_toward.material_opportunity > 0.0
			and material_away.material_opportunity < 0.0
			and farther_material.material_opportunity > 0.0
			and farther_material.material_opportunity < material_toward.material_opportunity
		),
		(
			"reachable remembered pickups must reward approach, penalize retreat, and expose "
			+ "less marginal value as distance grows beyond the local navigation horizon"
		)
	)
	observation.physics_frame += 1
	observation.wave_state.seconds_remaining = 2.0
	var unreachable_spatial: Reference = spatial_script.new()
	var unreachable_material: Dictionary = unreachable_spatial.point_value_delta(
		observation, context, Vector2.RIGHT * 100.0, 1.0
	)
	_expect(
		(
			abs(unreachable_material.material_opportunity) < 0.0001
			and unreachable_spatial.candidate_directions(observation, context).empty()
		),
		"a pickup that cannot be reached before cleanup must add neither value nor search work"
	)

	observation.physics_frame += 1
	observation.wave_state.seconds_remaining = 10.0
	observation.player_state.weapons = [
		{"slot": 0, "attack_model": _fixtures.weapon_attack_model()}
	]
	observation.remembered_entities = [
		{
			"memory_record_id": 1,
			"kind": "tree",
			"relative_position": Vector2(900.0, 0.0),
			"visual_radius": 10.0,
			"existence_confidence": 1.0,
			"destructible_profile": _fixtures.tree_destructible_profile(1.0, 10.0, 8.0),
		}
	]
	context.enemy_completion_value_ledger = _completion_value_ledger({})
	context.state_factors.continuation_horizon_seconds = 1.0
	context.wave_completion_forecast = _fixtures.wave_completion_forecast({}, {1: 1.0})
	var distant_tree: Dictionary = spatial_script.new().point_value_delta(
		observation, context, Vector2.RIGHT * 100.0, 1.0
	)
	var retreating_from_tree: Dictionary = spatial_script.new().point_value_delta(
		observation, context, Vector2.LEFT * 100.0, 1.0
	)
	_expect(
		(
			distant_tree.target_access_opportunity > 0.0
			and retreating_from_tree.target_access_opportunity < 0.0
		),
		(
			"a completable target beyond local weapon setup must reward approach and penalize "
			+ "retreat through the same deadline-limited access field"
		)
	)


func _nearest_trajectory_sample(samples: Array, direction: Vector2) -> Dictionary:
	var nearest := {}
	var nearest_alignment := -INF
	for sample in samples:
		var alignment: float = sample.direction.dot(direction)
		if alignment > nearest_alignment:
			nearest = sample
			nearest_alignment = alignment
	return nearest


func _completion_value_ledger(net_values: Dictionary) -> Dictionary:
	var entries := {}
	for track_id in net_values:
		entries[track_id] = {
			"reward_delta_value": net_values[track_id],
			"burden_relief_value": 0.0,
			"death_consequence_value": 0.0,
			"net_completion_value": net_values[track_id],
			"remaining_health": 10.0,
		}
	return {
		"entries_by_track_id": entries,
		"mean_net_completion_value": 0.0,
		"mean_absolute_net_completion_value": 0.0,
		"living_enemy_preservation_value": 0.0,
	}


func _influence_weights() -> Dictionary:
	return {
		"enemy_proximity": 1.0,
		"enemy_contact": 1.0,
		"projectile_contact": 1.0,
		"spawn_warning": 1.0,
		"maneuver_constraint": 1.0,
		"ranged_attack": 1.0,
		"allied_body_proximity": 1.0,
		"allied_pressure_relief": 1.0,
		"projectile_interception_relief": 1.0,
	}


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot wave-deadline contract failed: %s" % message)
