extends Reference

# Converts declarative player rules into action outcomes using only the
# public observation and candidate path geometry.

const EnemyMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_motion_predictor.gd"
)
const ProjectileMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/projectile_motion_predictor.gd"
)
const PlayerRuleProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_rule_projector.gd"
)
const StatOpportunityPricingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/stat_opportunity_pricing_model.gd"
)
const PickupCollectionGeometryModel := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/pickups/"
		+ "pickup_collection_geometry_model.gd"
	)
)
const DamageCompletionWorkModel := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "damage_completion_work_model.gd"
	)
)
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _projectile_motion_predictor: Reference = ProjectileMotionPredictor.new()
var _rule_projector: Reference = PlayerRuleProjector.new()
var _stat_opportunity_pricing_model: Reference = StatOpportunityPricingModel.new()
var _pickup_collection_geometry_model: Reference = PickupCollectionGeometryModel.new()
var _damage_completion_work_model: Reference = DamageCompletionWorkModel.new()


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_enemy_motion_predictor = predictor


func accumulate_outcome(
	observation: Dictionary, action: Dictionary, outcome: Dictionary, planning_context: Dictionary
) -> void:
	outcome.expected_recovery = _rule_projector.project_recovery(
		observation.player_state.effect_rules, "healing", outcome.expected_recovery
	)
	if outcome.expected_recovery <= 0.0:
		outcome.expected_recovery_events = 0.0
	var material_events := _pickup_events(
		observation.visible_world.materials, action.samples, observation.player_state.pickup
	)
	var consumable_events := _pickup_events(
		observation.visible_world.consumables, action.samples, observation.player_state.pickup
	)
	for event in material_events:
		var recovery_before: float = outcome.expected_recovery
		_apply_event_rules(observation, "material_pickup", event, outcome, planning_context)
		if outcome.expected_recovery > recovery_before:
			var healing_event: Dictionary = event.duplicate(true)
			healing_event.event_weight = min(1.0, outcome.expected_recovery - recovery_before)
			_apply_event_rules(observation, "healing", healing_event, outcome, planning_context)
	for event in consumable_events:
		_apply_consumable_event(observation, event, outcome, planning_context)
	if outcome.expected_recovery_events > 0.0:
		_apply_event_rules(
			observation,
			"healing",
			{
				"entity": {},
				"time": action.forecast_seconds,
				"player_displacement": action.samples.back().displacement,
				"event_weight": outcome.expected_recovery_events,
			},
			outcome,
			planning_context
		)
	if outcome.expected_critical_kill_weight > 0.0:
		var recovery_before_critical_kills: float = outcome.expected_recovery
		var critical_kill_event := {
			"entity": {},
			"time": action.forecast_seconds,
			"player_displacement": action.samples.back().displacement,
			"event_weight": outcome.expected_critical_kill_weight,
		}
		_apply_event_rules(
			observation, "critical_kill", critical_kill_event, outcome, planning_context
		)
		if outcome.expected_recovery > recovery_before_critical_kills:
			var healing_event: Dictionary = critical_kill_event.duplicate(true)
			healing_event.event_weight = (
				outcome.expected_recovery
				- recovery_before_critical_kills
			)
			_apply_event_rules(observation, "healing", healing_event, outcome, planning_context)
	var missing_health: float = max(
		0.0, observation.player_state.health.maximum - observation.player_state.health.current
	)
	outcome.expected_recovery = min(missing_health, outcome.expected_recovery)
	if _has_incoming_hit_rules(observation.player_state.effect_rules):
		var incoming_hit_event: Dictionary = _first_incoming_hit_event(observation, action.samples)
		if not incoming_hit_event.empty():
			incoming_hit_event.event_weight = incoming_hit_event.damage_probability
			_apply_event_rules(
				observation, "damage_taken", incoming_hit_event, outcome, planning_context
			)
			incoming_hit_event.event_weight = incoming_hit_event.dodge_probability
			_apply_event_rules(
				observation, "attack_dodged", incoming_hit_event, outcome, planning_context
			)


func _has_incoming_hit_rules(rules: Array) -> bool:
	for rule in rules:
		if rule.event == "damage_taken" or rule.event == "attack_dodged":
			return true
	return false


func _apply_consumable_event(
	observation: Dictionary, event: Dictionary, outcome: Dictionary, planning_context: Dictionary
) -> void:
	var profile: Dictionary = event.entity.get("pickup_profile", {})
	var recovery_before: float = outcome.expected_recovery
	outcome.expected_recovery += profile.get("base_recovery", 0.0)
	_apply_event_rules(observation, "consumable_pickup", event, outcome, planning_context)
	outcome.expected_recovery = _rule_projector.project_recovery(
		observation.player_state.effect_rules, "healing", outcome.expected_recovery
	)
	var uncapped_recovery_gain := max(0.0, outcome.expected_recovery - recovery_before)
	outcome.consumed_consumable_recovery_supply += uncapped_recovery_gain
	var missing_health: float = max(
		0.0, observation.player_state.health.maximum - observation.player_state.health.current
	)
	var remaining_recovery_capacity := max(0.0, missing_health - recovery_before)
	var effective_recovery_gain := min(remaining_recovery_capacity, uncapped_recovery_gain)
	outcome.wasted_consumable_recovery += max(0.0, uncapped_recovery_gain - effective_recovery_gain)
	outcome.expected_recovery = recovery_before + effective_recovery_gain
	var expected_recovery := max(0.0, outcome.expected_recovery - recovery_before)
	if expected_recovery > 0.0:
		var healing_event: Dictionary = event.duplicate(true)
		healing_event.event_weight = 1.0
		_apply_event_rules(observation, "healing", healing_event, outcome, planning_context)


func _apply_event_rules(
	observation: Dictionary,
	event_name: String,
	event: Dictionary,
	outcome: Dictionary,
	planning_context: Dictionary
) -> void:
	for rule in observation.player_state.effect_rules:
		if rule.event != event_name or not _condition_matches(rule.condition, event, observation):
			continue
		for consequence in rule.consequences:
			_apply_consequence(observation, consequence, event, outcome, planning_context)


func _apply_consequence(
	observation: Dictionary,
	consequence: Dictionary,
	event: Dictionary,
	outcome: Dictionary,
	planning_context: Dictionary
) -> void:
	var expected_occurrences: float = (
		clamp(consequence.get("probability", 1.0), 0.0, 1.0)
		* event.get("event_weight", 1.0)
	)
	if consequence.target == "health_recovery":
		match consequence.operation:
			"add":
				outcome.expected_recovery += consequence.get("value", 0.0) * expected_occurrences
			"multiply":
				outcome.expected_recovery *= lerp(
					1.0, consequence.get("value", 1.0), clamp(expected_occurrences, 0.0, 1.0)
				)
			"set":
				outcome.expected_recovery = lerp(
					outcome.expected_recovery,
					consequence.get("value", 0.0),
					clamp(expected_occurrences, 0.0, 1.0)
				)
		return
	if consequence.target == "materials" and consequence.operation == "add":
		outcome.expected_material_gain += consequence.get("value", 0.0) * expected_occurrences
		return
	if consequence.target == "enemy_health" and consequence.operation == "deal_damage":
		outcome.expected_rule_completion_value += (
			_delivered_enemy_completion_value(
				observation.enemy_tracks,
				consequence.delivery,
				event,
				_rule_damage_amount(consequence.amount),
				planning_context.enemy_completion_value_ledger
			)
			* expected_occurrences
		)
		return
	match consequence.operation:
		"add":
			outcome.expected_stat_opportunity_value += (
				_stat_opportunity_pricing_model.value(
					observation,
					[
						{
							"stat": consequence.target,
							"operation": "add",
							"value": consequence.get("value", 0.0),
						}
					]
				)
				* expected_occurrences
			)
			outcome.expected_stat_upgrade_equivalents += (
				consequence.get("upgrade_equivalent_value", 0.0)
				* expected_occurrences
			)
		"multiply":
			if consequence.target == "picked_material_value":
				outcome.material_acquisition_value += (
					max(0.0, consequence.get("value", 1.0) - 1.0)
					* expected_occurrences
				)


func _pickup_events(pickups: Array, samples: Array, pickup_state: Dictionary) -> Array:
	var result := []
	for pickup in pickups:
		var event: Dictionary = _pickup_collection_geometry_model.first_collection(
			pickup, samples, pickup_state.collection_radius
		)
		if not event.empty():
			result.push_back(event)
	return result


func _first_incoming_hit_event(observation: Dictionary, samples: Array) -> Dictionary:
	var dodge_failure: float = 1.0 - observation.player_state.runtime_stats.dodge_chance
	for sample in samples:
		for track in observation.enemy_tracks:
			if not track.visible:
				continue
			var enemy_position: Vector2 = _predict_enemy_position(
				track, sample.time, sample.displacement
			)
			var collision_radius: float = (
				observation.player_state.collision_radius
				+ track.behavior_profile.contact_radius
			)
			if (enemy_position - sample.displacement).length() <= collision_radius:
				return {
					"entity": track,
					"time": sample.time,
					"player_displacement": sample.displacement,
					"damage_probability": dodge_failure,
					"dodge_probability": 1.0 - dodge_failure,
				}
		for projectile in observation.visible_world.enemy_projectiles:
			var projectile_position: Vector2 = _projectile_motion_predictor.predict_position(
				projectile, sample.time
			)
			var collision_radius: float = (
				observation.player_state.collision_radius
				+ projectile.contact_radius
			)
			if (projectile_position - sample.displacement).length() <= collision_radius:
				return {
					"entity": projectile,
					"time": sample.time,
					"player_displacement": sample.displacement,
					"damage_probability": dodge_failure,
					"dodge_probability": 1.0 - dodge_failure,
				}
	return {}


func _delivered_enemy_completion_value(
	tracks: Array,
	delivery: Dictionary,
	event: Dictionary,
	damage: float,
	completion_value_ledger: Dictionary
) -> float:
	var center: Vector2 = event.player_displacement
	if delivery.anchor_on_event_entity:
		center = event.entity.get("relative_position", center)
	var radius: float = max(0.0, delivery.radius)
	var covered_mass := 0.0
	var weighted_completion_value := 0.0
	for track in tracks:
		if not track.visible:
			continue
		var enemy_position := _predict_enemy_position(track, event.time, event.player_displacement)
		if enemy_position.distance_to(center) > radius + track.last_measurement.visual_radius:
			continue
		var confidence: float = track.recency_confidence
		var ledger_entry: Dictionary = completion_value_ledger.entries_by_track_id[track.track_id]
		covered_mass += confidence
		weighted_completion_value += (
			confidence
			* ledger_entry.net_completion_value
			* _damage_completion_work_model.completion_fraction_per_hit(
				ledger_entry.remaining_health, damage
			)
		)
	if covered_mass <= 0.0:
		return 0.0
	var capacity_scale := min(1.0, max(0.0, delivery.capacity_per_event) / covered_mass)
	return weighted_completion_value * capacity_scale


func _rule_damage_amount(amount: Dictionary) -> float:
	return max(amount.minimum, amount.constant)


func _condition_matches(condition: Dictionary, event: Dictionary, observation: Dictionary) -> bool:
	if condition.get("health_is_full", false) and observation.player_state.health.ratio < 1.0:
		return false
	if condition.has("entity_has_trait"):
		var traits: Array = event.entity.get("pickup_profile", {}).get("traits", [])
		if not condition.entity_has_trait in traits:
			return false
	return true


func _predict_enemy_position(
	track: Dictionary, time: float, player_displacement := Vector2.ZERO
) -> Vector2:
	return _enemy_motion_predictor.predict_position(track, time, player_displacement)
