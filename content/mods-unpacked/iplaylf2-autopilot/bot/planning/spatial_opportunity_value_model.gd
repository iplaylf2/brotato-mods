extends Reference

# Samples the material-equivalent opportunity field at one future player state.
# Moving candidates and the zero-input counterfactual use the same time, so this
# model values only access changes caused by player movement.

const OpportunityPricingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_pricing_model.gd"
)
const EngagementTargetProjector := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "engagement_target_projector.gd"
	)
)
const RuleEventValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/" + "rule_event_value_model.gd"
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
var _rule_event_value_model: Reference = RuleEventValueModel.new()
var _pickup_collection_geometry_model: Reference = PickupCollectionGeometryModel.new()
var _movement_geometry: Reference = MovementGeometryModel.new()
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _prepared_physics_frame := -1
var _prepared_geometry := {}
var _prepared_pickups := []
var _prepared_spawn_warnings := []
var _prepared_candidate_entries := []
var _prepared_target_access_entries := []


func _init() -> void:
	_rule_event_value_model.set_enemy_motion_predictor(_enemy_motion_predictor)


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_enemy_motion_predictor = predictor
	_rule_event_value_model.set_enemy_motion_predictor(predictor)


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
		"future_event_opportunity": 0.0,
		"rule_event_opportunity": 0.0,
		"target_access_opportunity": 0.0,
		"total": 0.0,
	}
	var seconds_until_wave_end: float = max(
		0.0, observation.wave_state.seconds_remaining - forecast_seconds
	)
	var deadline_reach_distance: float = _prepared_geometry.command_speed * seconds_until_wave_end
	for entry in _prepared_pickups:
		var pickup: Dictionary = entry.pickup
		var stationary_collection: Dictionary = _pickup_collection_at(
			observation, pickup, Vector2.ZERO, forecast_seconds
		)
		var candidate_collection: Dictionary = _pickup_collection_at(
			observation, pickup, player_displacement, forecast_seconds
		)
		var stationary_gap: float = _pickup_collection_geometry_model.collection_gap_at(
			pickup, Vector2.ZERO, forecast_seconds, _pickup_collection_radius(observation)
		)
		var candidate_gap: float = _pickup_collection_geometry_model.collection_gap_at(
			pickup, player_displacement, forecast_seconds, _pickup_collection_radius(observation)
		)
		var stationary_accessibility := _deadline_accessibility(
			stationary_gap, deadline_reach_distance, _prepared_geometry.opportunity_reach_distance
		)
		var candidate_accessibility := _deadline_accessibility(
			candidate_gap, deadline_reach_distance, _prepared_geometry.opportunity_reach_distance
		)
		if not stationary_collection.empty():
			stationary_accessibility = 1.0
		if not candidate_collection.empty():
			candidate_accessibility = 1.0
		var contribution: float = entry.value * (candidate_accessibility - stationary_accessibility)
		var event_name := _pickup_event_name(pickup)
		if not event_name.empty():
			var stationary_rule_value := (
				_pickup_rule_collection_value(
					observation, context, event_name, stationary_collection
				)
				if not stationary_collection.empty()
				else _pickup_rule_event_value(
					observation, context, pickup, Vector2.ZERO, forecast_seconds
				)
			)
			var candidate_rule_value := (
				_pickup_rule_collection_value(
					observation, context, event_name, candidate_collection
				)
				if not candidate_collection.empty()
				else _pickup_rule_event_value(
					observation, context, pickup, player_displacement, forecast_seconds
				)
			)
			result.rule_event_opportunity += (
				candidate_rule_value * candidate_accessibility
				- stationary_rule_value * stationary_accessibility
			)
		match pickup.kind:
			"material":
				result.material_opportunity += contribution
			"consumable":
				result.recovery_opportunity += contribution
	for entry in _prepared_spawn_warnings:
		var warning: Dictionary = entry.warning
		var stationary_gap: float = _spawn_warning_gap(warning, Vector2.ZERO)
		var candidate_gap: float = _spawn_warning_gap(warning, player_displacement)
		var seconds_until_deadline := _spawn_warning_seconds_until_deadline(
			observation, warning, forecast_seconds
		)
		var warning_reach_distance: float = (
			_prepared_geometry.command_speed
			* seconds_until_deadline
		)
		result.future_event_opportunity += (
			entry.value
			* _deadline_accessibility_delta(
				stationary_gap,
				candidate_gap,
				warning_reach_distance,
				_prepared_geometry.opportunity_reach_distance
			)
		)
	result.target_access_opportunity = _target_access_delta(
		player_displacement, forecast_seconds, seconds_until_wave_end
	)
	result.total = (
		result.material_opportunity
		+ result.recovery_opportunity
		+ result.future_event_opportunity
		+ result.rule_event_opportunity
		+ result.target_access_opportunity
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
		"future_event_opportunity": candidate.future_event_opportunity,
		"rule_event_opportunity": candidate.rule_event_opportunity,
		"target_access_opportunity": candidate.target_access_opportunity,
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
	_prepared_spawn_warnings = []
	_prepared_candidate_entries = []
	_prepared_target_access_entries = []
	var deadline_reach_distance: float = (
		_prepared_geometry.command_speed
		* max(0.0, float(observation.wave_state.seconds_remaining))
	)
	var characteristic_reach_distance: float = _prepared_geometry.opportunity_reach_distance
	var health_inventory_value: Dictionary = context.state_factors.health_inventory_value
	for pickup in observation.get("remembered_entities", []):
		if pickup.kind == "tree":
			continue
		if pickup.existence_confidence <= 0.0:
			continue
		var gap: float = _pickup_initial_collection_gap(observation, pickup)
		if gap <= 0.0:
			continue
		var base_value: float = (
			_pickup_value(observation, context, pickup, health_inventory_value)
			* pickup.existence_confidence
		)
		var candidate_value := base_value
		if not _pickup_event_name(pickup).empty():
			candidate_value += _pickup_rule_event_value(
				observation, context, pickup, Vector2.ZERO, 0.0
			)
		if is_zero_approx(candidate_value):
			continue
		var pickup_entry := {
			"pickup": pickup,
			"value": base_value,
		}
		_prepared_pickups.push_back(pickup_entry)
		if candidate_value > 0.0:
			_append_prepared_candidate(
				pickup.relative_position,
				(
					candidate_value
					* _deadline_accessibility(
						gap, deadline_reach_distance, characteristic_reach_distance
					)
				)
			)
	for warning in observation.visible_world.spawn_warnings:
		var value: float = _spawn_warning_value(observation, context, warning)
		if value == 0.0:
			continue
		var gap := _spawn_warning_gap(warning, Vector2.ZERO)
		var seconds_until_deadline := _spawn_warning_seconds_until_deadline(
			observation, warning, 0.0
		)
		var warning_reach_distance: float = (
			_prepared_geometry.command_speed
			* seconds_until_deadline
		)
		var access_potential: float = _deadline_accessibility(
			gap, warning_reach_distance, characteristic_reach_distance
		)
		if access_potential <= 0.0:
			continue
		_prepared_spawn_warnings.push_back({"warning": warning, "value": value})
		if value > 0.0:
			_append_prepared_candidate(warning.relative_position, value * access_potential)
	var maximum_targeting_distance := _maximum_weapon_targeting_distance(observation)
	if maximum_targeting_distance <= 0.0:
		return
	for target in _engagement_target_projector.project_navigation_targets(observation, context):
		var value: float = (
			target.value.net_completion_value
			* target.confidence
			* context.wave_completion_forecast.get("completion_fraction_by_target_id", {}).get(
				target.target_id, 0.0
			)
		)
		if value <= 0.0:
			continue
		var gap: float = max(0.0, target.relative_position.length() - maximum_targeting_distance)
		var access_potential: float = _deadline_accessibility(
			gap, deadline_reach_distance, characteristic_reach_distance
		)
		var enters_without_player_movement := _enters_targeting_range_without_player_movement(
			target, maximum_targeting_distance, observation.wave_state.seconds_remaining
		)
		if not enters_without_player_movement:
			_append_prepared_candidate(target.relative_position, value * access_potential)
		if gap > 0.0 and (access_potential > 0.0 or enters_without_player_movement):
			_prepared_target_access_entries.push_back(
				{
					"target": target,
					"value": value,
					"targeting_distance": maximum_targeting_distance,
				}
			)


func _target_access_delta(
	player_displacement: Vector2, forecast_seconds: float, seconds_until_deadline: float
) -> float:
	var result := 0.0
	var deadline_reach_distance: float = _prepared_geometry.command_speed * seconds_until_deadline
	for entry in _prepared_target_access_entries:
		var target: Dictionary = entry.target
		var stationary_position: Vector2 = _enemy_motion_predictor.predict_position(
			target.motion_track, forecast_seconds, Vector2.ZERO
		)
		var candidate_position: Vector2 = _enemy_motion_predictor.predict_position(
			target.motion_track, forecast_seconds, player_displacement
		)
		var stationary_gap: float = _autonomous_targeting_gap(
			target, stationary_position, seconds_until_deadline, entry.targeting_distance
		)
		var candidate_gap: float = _autonomous_targeting_gap(
			target,
			candidate_position - player_displacement,
			seconds_until_deadline,
			entry.targeting_distance
		)
		result += (
			entry.value
			* _deadline_accessibility_delta(
				stationary_gap,
				candidate_gap,
				deadline_reach_distance,
				_prepared_geometry.opportunity_reach_distance
			)
		)
	return result


func _enters_targeting_range_without_player_movement(
	target: Dictionary, targeting_distance: float, deadline_seconds: float
) -> bool:
	if target.relative_position.length() <= targeting_distance:
		return true
	return (
		_autonomous_targeting_gap(
			target, target.relative_position, deadline_seconds, targeting_distance
		)
		<= 0.0
	)


func _autonomous_targeting_gap(
	target: Dictionary, relative_position: Vector2, seconds: float, targeting_distance: float
) -> float:
	var current_gap: float = max(0.0, relative_position.length() - targeting_distance)
	if current_gap <= 0.0 or seconds <= 0.0:
		return current_gap
	var motion_track: Dictionary = target.motion_track
	var response: Dictionary = motion_track.behavior_profile.get("target_position_response", {})
	if not response.get("responds_to_target_position", false):
		return current_gap
	var preferred_distance: float = max(0.0, response.get("preferred_distance", 0.0))
	if relative_position.length() <= preferred_distance:
		return current_gap
	var response_confidence: float = clamp(response.get("confidence", 0.0), 0.0, 1.0)
	var closing_speed: float = (
		max(
			max(0.0, response.get("movement_speed", 0.0)),
			motion_track.get("estimated_velocity", Vector2.ZERO).length()
		)
		* response_confidence
	)
	var terminal_gap_floor: float = max(0.0, preferred_distance - targeting_distance)
	return max(terminal_gap_floor, current_gap - closing_speed * seconds)


func _maximum_weapon_targeting_distance(observation: Dictionary) -> float:
	var result := 0.0
	for weapon in observation.player_state.weapons:
		result = max(result, float(weapon.attack_model.delivery.maximum_targeting_distance))
	return result


func _pickup_value(
	observation: Dictionary,
	context: Dictionary,
	pickup: Dictionary,
	health_inventory_value: Dictionary
) -> float:
	match pickup.kind:
		"material":
			return _opportunity_pricing_model.material_collection_value(observation, pickup)
		"consumable":
			return _opportunity_pricing_model.consumable_pickup_value(
				observation,
				pickup,
				health_inventory_value,
				context.state_factors.get("run_continuation_value", {})
			)
	return 0.0


func _pickup_rule_event_value(
	observation: Dictionary,
	context: Dictionary,
	pickup: Dictionary,
	player_displacement: Vector2,
	forecast_seconds: float
) -> float:
	var event_pickup: Dictionary = pickup.duplicate(false)
	event_pickup.relative_position = (
		pickup.relative_position
		+ (
			pickup.get("velocity", Vector2.ZERO)
			* clamp(pickup.get("motion_confidence", 1.0), 0.0, 1.0)
			* forecast_seconds
		)
	)
	return _rule_event_value_model.realized_value(
		observation,
		_pickup_event_name(pickup),
		{
			"entity": event_pickup,
			"time": forecast_seconds,
			"player_displacement": player_displacement,
			"event_weight": pickup.existence_confidence,
		},
		context.enemy_completion_value_ledger
	)


func _pickup_collection_at(
	observation: Dictionary,
	pickup: Dictionary,
	player_displacement: Vector2,
	forecast_seconds: float
) -> Dictionary:
	var event: Dictionary = _pickup_collection_geometry_model.first_collection(
		pickup,
		[{"time": forecast_seconds, "displacement": player_displacement}],
		_pickup_collection_radius(observation)
	)
	if not event.empty():
		event.event_weight = clamp(float(pickup.get("existence_confidence", 0.0)), 0.0, 1.0)
	return event


func _pickup_rule_collection_value(
	observation: Dictionary, context: Dictionary, event_name: String, event: Dictionary
) -> float:
	return _rule_event_value_model.realized_value(
		observation, event_name, event, context.enemy_completion_value_ledger
	)


func _pickup_event_name(pickup: Dictionary) -> String:
	match pickup.kind:
		"material":
			return "material_pickup"
		"consumable":
			return "consumable_pickup"
	return ""


func _pickup_initial_collection_gap(observation: Dictionary, pickup: Dictionary) -> float:
	return _pickup_collection_geometry_model.initial_collection_gap(
		pickup, _pickup_collection_radius(observation)
	)


func _pickup_collection_radius(observation: Dictionary) -> float:
	# Entering the attraction area starts motion but does not realize a pickup.
	# Navigation keeps the opportunity until the observed center can reach the
	# same collection circle used by the local outcome and memory contracts.
	return observation.player_state.pickup.collection_radius


func _spawn_warning_value(
	observation: Dictionary, context: Dictionary, warning: Dictionary
) -> float:
	# A visible warning exposes a future event but not the hidden sampled entity.
	# Value hostile deferral from the signed mean burden of observed enemies; value
	# a neutral warning as access to a newly revealed attackable event.
	if warning.disposition == "neutral":
		return context.state_factors.information_value_per_viewport
	if not warning.player_overlap_defers_spawn:
		return 0.0
	var latest_resolution_seconds: float = warning.resolution_window.latest_seconds
	var burden_horizon: float = max(1.0, sqrt(max(0.0, observation.wave_state.seconds_remaining)))
	var deferral_value: float = (
		context.enemy_completion_value_ledger.mean_burden_relief_value
		* latest_resolution_seconds
		/ burden_horizon
	)
	return deferral_value


func _spawn_warning_gap(warning: Dictionary, player_displacement: Vector2) -> float:
	return max(
		0.0,
		(
			(warning.relative_position - player_displacement).length()
			- warning.interaction_radius
			- _prepared_geometry.player_radius
		)
	)


func _spawn_warning_seconds_until_deadline(
	observation: Dictionary, warning: Dictionary, forecast_seconds: float
) -> float:
	var available_seconds: float = max(0.0, observation.wave_state.seconds_remaining)
	if warning.player_overlap_defers_spawn:
		available_seconds = min(available_seconds, warning.resolution_window.latest_seconds)
	return max(0.0, available_seconds - forecast_seconds)


func _append_prepared_candidate(position: Vector2, value: float) -> void:
	if value <= 0.0:
		return
	_prepared_candidate_entries.push_back({"position": position, "value": value})


func _deadline_accessibility_delta(
	stationary_gap: float,
	candidate_gap: float,
	deadline_reach_distance: float,
	characteristic_reach_distance: float
) -> float:
	return (
		_deadline_accessibility(
			candidate_gap, deadline_reach_distance, characteristic_reach_distance
		)
		- _deadline_accessibility(
			stationary_gap, deadline_reach_distance, characteristic_reach_distance
		)
	)


func _deadline_accessibility(
	gap: float, deadline_reach_distance: float, characteristic_reach_distance: float
) -> float:
	if gap <= 0.0:
		return 1.0
	if deadline_reach_distance <= 0.0 or gap >= deadline_reach_distance:
		return 0.0
	var scale := max(1.0, characteristic_reach_distance)
	var deadline_floor := exp(-deadline_reach_distance / scale)
	return (exp(-gap / scale) - deadline_floor) / max(0.0001, 1.0 - deadline_floor)


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
