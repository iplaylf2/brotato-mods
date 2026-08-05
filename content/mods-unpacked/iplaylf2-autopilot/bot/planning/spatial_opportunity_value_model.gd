extends Reference

# Samples the material-equivalent opportunity field at one future player state.
# Moving candidates and the zero-input counterfactual use the same time, so only
# player-caused access and target-selection changes receive value.

const OpportunityPricingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_pricing_model.gd"
)
const EngagementTargetProjector := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "engagement_target_projector.gd"
	)
)
const NavigationWeaponCompletionValueModel := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "navigation_weapon_completion_value_model.gd"
	)
)
const PickupCollectionGeometryModel := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/pickups/"
		+ "pickup_collection_geometry_model.gd"
	)
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)
var _opportunity_pricing_model: Reference = OpportunityPricingModel.new()
var _engagement_target_projector: Reference = EngagementTargetProjector.new()
var _navigation_weapon_completion_value_model := NavigationWeaponCompletionValueModel.new()
var _pickup_collection_geometry_model: Reference = PickupCollectionGeometryModel.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _prepared_physics_frame := -1
var _prepared_geometry := {}
var _prepared_pickups := []
var _prepared_candidate_entries := []
var _stationary_weapon_value_by_time := {}


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_enemy_motion_predictor = predictor
	_navigation_weapon_completion_value_model.set_enemy_motion_predictor(predictor)


func _evaluate_point(
	observation: Dictionary,
	context: Dictionary,
	player_displacement: Vector2,
	forecast_seconds: float
) -> Dictionary:
	_prepare_inputs(observation, context)
	_enemy_motion_predictor.begin_physics_frame(observation.get("physics_frame", -1))
	var result := {
		"material_opportunity": 0.0,
		"recovery_opportunity": 0.0,
		"weapon_completion_opportunity": 0.0,
		"total": 0.0,
	}
	var reach_distance: float = _prepared_geometry.opportunity_reach_distance
	for entry in _prepared_pickups:
		var pickup: Dictionary = entry.pickup
		var stationary_gap: float = _pickup_collection_geometry_model.collection_gap_at(
			pickup, Vector2.ZERO, forecast_seconds, _pickup_collection_radius(observation)
		)
		var candidate_gap: float = _pickup_collection_geometry_model.collection_gap_at(
			pickup, player_displacement, forecast_seconds, _pickup_collection_radius(observation)
		)
		var contribution: float = (
			entry.value
			* _accessibility_delta(stationary_gap, candidate_gap, reach_distance)
		)
		match pickup.kind:
			"material":
				result.material_opportunity += contribution
			"consumable":
				result.recovery_opportunity += contribution
	result.weapon_completion_opportunity = (
		_navigation_weapon_completion_value_model.value_at(
			observation, context, player_displacement, forecast_seconds
		)
		- _stationary_weapon_value(observation, context, forecast_seconds)
	)
	result.total = (
		result.material_opportunity
		+ result.recovery_opportunity
		+ result.weapon_completion_opportunity
	)
	return result


func point_value_delta(
	observation: Dictionary,
	context: Dictionary,
	player_displacement: Vector2,
	forecast_seconds: float
) -> Dictionary:
	var candidate: Dictionary = _evaluate_point(
		observation, context, player_displacement, forecast_seconds
	)
	return {
		"material_opportunity": candidate.material_opportunity,
		"recovery_opportunity": candidate.recovery_opportunity,
		"weapon_completion_opportunity": candidate.weapon_completion_opportunity,
		"total": candidate.total,
	}


func candidate_directions(observation: Dictionary, context: Dictionary) -> Array:
	_prepare_inputs(observation, context)
	var candidates := []
	var bins := {}
	var bin_count: int = max(1, int(_prepared_geometry.direction_count))
	for entry in _prepared_candidate_entries:
		var direction: Vector2 = entry.position.normalized()
		var bin_index := int(round(fposmod(direction.angle(), TAU) / TAU * bin_count)) % bin_count
		if not bins.has(bin_index):
			bins[bin_index] = {"weighted_direction": Vector2.ZERO, "value": 0.0}
		bins[bin_index].weighted_direction += direction * entry.value
		bins[bin_index].value += entry.value
	for bin in bins.values():
		_append_candidate(candidates, bin.weighted_direction, bin.value)
	candidates.sort_custom(self, "_higher_candidate_value")
	return candidates


func _prepare_inputs(observation: Dictionary, context: Dictionary) -> void:
	var physics_frame: int = observation.get("physics_frame", -1)
	if physics_frame >= 0 and physics_frame == _prepared_physics_frame:
		return
	_prepared_physics_frame = physics_frame
	_prepared_geometry = _movement_geometry.derive(observation)
	_prepared_pickups = []
	_prepared_candidate_entries = []
	_stationary_weapon_value_by_time = {}
	var health_inventory_value: Dictionary = context.state_factors.health_inventory_value
	for pickup in observation.get("remembered_entities", []):
		if pickup.kind == "tree":
			continue
		if pickup.existence_confidence <= 0.0:
			continue
		var gap: float = _pickup_initial_collection_gap(observation, pickup)
		if gap <= 0.0:
			continue
		var value: float = (
			_pickup_value(observation, pickup, health_inventory_value)
			* pickup.existence_confidence
		)
		if value <= 0.0:
			continue
		var pickup_entry := {
			"pickup": pickup,
			"value": value,
		}
		_prepared_pickups.push_back(pickup_entry)
		_prepared_candidate_entries.push_back(
			{
				"position": pickup.relative_position,
				"value": value * _accessibility(gap, _prepared_geometry.opportunity_reach_distance),
			}
		)
	for target in _engagement_target_projector.project_navigation_targets(observation, context):
		var value: float = target.value.net_completion_value * target.confidence
		if value <= 0.0:
			continue
		var gap: float = target.relative_position.length()
		_prepared_candidate_entries.push_back(
			{
				"position": target.relative_position,
				"value": value * _accessibility(gap, _prepared_geometry.opportunity_reach_distance),
			}
		)


func _stationary_weapon_value(
	observation: Dictionary, context: Dictionary, forecast_seconds: float
) -> float:
	if not _stationary_weapon_value_by_time.has(forecast_seconds):
		var stationary_value: float = _navigation_weapon_completion_value_model.value_at(
			observation, context, Vector2.ZERO, forecast_seconds
		)
		_stationary_weapon_value_by_time[forecast_seconds] = stationary_value
	return _stationary_weapon_value_by_time[forecast_seconds]


func _pickup_value(
	observation: Dictionary, pickup: Dictionary, health_inventory_value: Dictionary
) -> float:
	match pickup.kind:
		"material":
			return _opportunity_pricing_model.material_collection_value(observation, pickup)
		"consumable":
			return _opportunity_pricing_model.consumable_pickup_value(
				observation, pickup, health_inventory_value
			)
	return 0.0


func _pickup_initial_collection_gap(observation: Dictionary, pickup: Dictionary) -> float:
	return _pickup_collection_geometry_model.initial_collection_gap(
		pickup, _pickup_collection_radius(observation)
	)


func _pickup_collection_radius(observation: Dictionary) -> float:
	# Entering the attraction area starts motion but does not realize a pickup.
	# Navigation keeps the opportunity until the observed center can reach the
	# same collection circle used by the local outcome and memory contracts.
	return observation.player_state.pickup.collection_radius


func _accessibility(gap: float, reach_distance: float) -> float:
	return exp(-gap / reach_distance)


func _accessibility_delta(
	stationary_gap: float, candidate_gap: float, reach_distance: float
) -> float:
	if stationary_gap <= 0.0:
		return 0.0 if candidate_gap <= 0.0 else -1.0
	var stationary_accessibility: float = _accessibility(stationary_gap, reach_distance)
	var candidate_accessibility: float = _accessibility(candidate_gap, reach_distance)
	return clamp(
		(candidate_accessibility - stationary_accessibility) / (1.0 - stationary_accessibility),
		-1.0,
		1.0
	)


func _append_candidate(candidates: Array, displacement: Vector2, value: float) -> void:
	if value <= 0.0 or displacement.length_squared() <= 0.0:
		return
	candidates.push_back(
		{
			"direction": displacement.normalized(),
			"distance": displacement.length(),
			"upper_bound_value": value,
		}
	)


func _higher_candidate_value(left: Dictionary, right: Dictionary) -> bool:
	return left.upper_bound_value > right.upper_bound_value
