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
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _projectile_motion_predictor: Reference = ProjectileMotionPredictor.new()
var _rule_projector: Reference = PlayerRuleProjector.new()
var _stat_opportunity_pricing_model: Reference = StatOpportunityPricingModel.new()


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_enemy_motion_predictor = predictor


func accumulate_outcome(observation: Dictionary, action: Dictionary, outcome: Dictionary) -> void:
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
		_apply_event_rules(observation, "material_pickup", event, outcome)
		if outcome.expected_recovery > recovery_before:
			var healing_event: Dictionary = event.duplicate(true)
			healing_event.event_weight = min(1.0, outcome.expected_recovery - recovery_before)
			_apply_event_rules(observation, "healing", healing_event, outcome)
	for event in consumable_events:
		_apply_consumable_event(observation, event, outcome)
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
			outcome
		)
	if outcome.expected_critical_kill_weight > 0.0:
		var recovery_before_critical_kills: float = outcome.expected_recovery
		var critical_kill_event := {
			"entity": {},
			"time": action.forecast_seconds,
			"player_displacement": action.samples.back().displacement,
			"event_weight": outcome.expected_critical_kill_weight,
		}
		_apply_event_rules(observation, "critical_kill", critical_kill_event, outcome)
		if outcome.expected_recovery > recovery_before_critical_kills:
			var healing_event: Dictionary = critical_kill_event.duplicate(true)
			healing_event.event_weight = (
				outcome.expected_recovery
				- recovery_before_critical_kills
			)
			_apply_event_rules(observation, "healing", healing_event, outcome)
	var missing_health: float = max(
		0.0, observation.player_state.health.maximum - observation.player_state.health.current
	)
	outcome.expected_recovery = min(missing_health, outcome.expected_recovery)
	if _has_incoming_hit_rules(observation.player_state.effect_rules):
		var incoming_hit_event: Dictionary = _first_incoming_hit_event(observation, action.samples)
		if not incoming_hit_event.empty():
			incoming_hit_event.event_weight = incoming_hit_event.damage_probability
			_apply_event_rules(observation, "damage_taken", incoming_hit_event, outcome)
			incoming_hit_event.event_weight = incoming_hit_event.dodge_probability
			_apply_event_rules(observation, "attack_dodged", incoming_hit_event, outcome)


func _has_incoming_hit_rules(rules: Array) -> bool:
	for rule in rules:
		if rule.event == "damage_taken" or rule.event == "attack_dodged":
			return true
	return false


func _apply_consumable_event(
	observation: Dictionary, event: Dictionary, outcome: Dictionary
) -> void:
	var profile: Dictionary = event.entity.get("pickup_profile", {})
	var recovery_before: float = outcome.expected_recovery
	outcome.expected_recovery += profile.get("base_recovery", 0.0)
	_apply_event_rules(observation, "consumable_pickup", event, outcome)
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
		_apply_event_rules(observation, "healing", healing_event, outcome)


func _apply_event_rules(
	observation: Dictionary, event_name: String, event: Dictionary, outcome: Dictionary
) -> void:
	for rule in observation.player_state.effect_rules:
		if rule.event != event_name or not _condition_matches(rule.condition, event, observation):
			continue
		for consequence in rule.consequences:
			_apply_consequence(observation, consequence, event, outcome)


func _apply_consequence(
	observation: Dictionary, consequence: Dictionary, event: Dictionary, outcome: Dictionary
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
		var applications := _delivered_enemy_weight(
			observation.enemy_tracks, consequence.delivery, event
		)
		outcome.expected_rule_damage += (
			_rule_damage_amount(consequence.amount)
			* expected_occurrences
			* applications
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


func _pickup_events(entities: Array, samples: Array, pickup: Dictionary) -> Array:
	var result := []
	for entity in entities:
		for sample in samples:
			if (
				(entity.relative_position - sample.displacement).length()
				<= pickup.collection_radius
			):
				result.push_back(
					{
						"entity": entity,
						"time": sample.time,
						"player_displacement": sample.displacement,
					}
				)
				break
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


func _delivered_enemy_weight(tracks: Array, delivery: Dictionary, event: Dictionary) -> float:
	var center: Vector2 = event.player_displacement
	if delivery.anchor_on_event_entity:
		center = event.entity.get("relative_position", center)
	var radius: float = max(0.0, delivery.radius)
	var result := 0.0
	for track in tracks:
		if not track.visible:
			continue
		var enemy_position := _predict_enemy_position(track, event.time, event.player_displacement)
		if enemy_position.distance_to(center) <= radius + track.last_measurement.visual_radius:
			result += track.recency_confidence
	return min(result, max(0.0, delivery.capacity_per_event))


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
