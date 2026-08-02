extends Reference

# Converts declarative player rules into action outcomes using only the
# public observation and candidate path geometry.

const ObservedMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/observed_motion_predictor.gd"
)
const PlayerRuleProjection := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_rule_projection.gd"
)

var _motion_predictor: Reference = ObservedMotionPredictor.new()
var _rule_projection: Reference = PlayerRuleProjection.new()


func accumulate_outcome(observation: Dictionary, action: Dictionary, outcome: Dictionary) -> void:
	outcome.expected_recovery = _rule_projection.project_recovery(
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
	var missing_health: float = max(
		0.0, observation.player_state.health.maximum - observation.player_state.health.current
	)
	outcome.expected_recovery = min(missing_health, outcome.expected_recovery)
	var incoming_hit_event = _first_incoming_hit_event(observation, action.samples)
	if incoming_hit_event != null:
		incoming_hit_event.event_weight = incoming_hit_event.damage_probability
		_apply_event_rules(observation, "damage_taken", incoming_hit_event, outcome)
		incoming_hit_event.event_weight = incoming_hit_event.dodge_probability
		_apply_event_rules(observation, "attack_dodged", incoming_hit_event, outcome)


func _apply_consumable_event(
	observation: Dictionary, event: Dictionary, outcome: Dictionary
) -> void:
	var profile: Dictionary = event.entity.get("pickup_profile", {})
	var recovery_before: float = outcome.expected_recovery
	outcome.expected_recovery += profile.get("base_recovery", 0.0)
	_apply_event_rules(observation, "consumable_pickup", event, outcome)
	outcome.expected_recovery = _rule_projection.project_recovery(
		observation.player_state.effect_rules, "healing", outcome.expected_recovery
	)
	var missing_health: float = max(
		0.0, observation.player_state.health.maximum - observation.player_state.health.current
	)
	outcome.expected_recovery = min(missing_health, outcome.expected_recovery)
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
	var expected_occurrences := (
		clamp(consequence.get("chance_percent", 100.0) / 100.0, 0.0, 1.0)
		* event.get("event_weight", 1.0)
	)
	if consequence.target == "health_recovery":
		match consequence.operation:
			"add":
				outcome.expected_recovery += consequence.get("value", 0.0) * expected_occurrences
			"multiply":
				outcome.expected_recovery *= lerp(
					1.0, consequence.get("value", 1.0), expected_occurrences
				)
			"set":
				outcome.expected_recovery = lerp(
					outcome.expected_recovery, consequence.get("value", 0.0), expected_occurrences
				)
		return
	match consequence.operation:
		"deal_scaled_damage":
			if observation.enemy_tracks.empty():
				return
			var stat_value: float = observation.player_state.effective_stats.get(
				consequence.scaling_stat, 0.0
			)
			var base_damage := floor(max(1.0, consequence.scaling_percent / 100.0 * stat_value))
			var damage_multiplier := max(
				0.0, 1.0 + observation.player_state.effective_stats.percent_damage / 100.0
			)
			outcome.expected_effect_damage += (
				round(base_damage * damage_multiplier)
				* expected_occurrences
			)
		"deal_area_damage":
			var center: Vector2 = event.player_displacement
			if consequence.get("center", "player") == "pickup":
				center = event.entity.relative_position
			var covered_enemy_weight := _covered_enemy_weight(
				observation.enemy_tracks, center, event.time, consequence.radius
			)
			outcome.expected_effect_damage += (
				consequence.damage
				* expected_occurrences
				* covered_enemy_weight
			)
		"add_permanently", "add_temporarily":
			outcome.expected_stat_gain_value += (
				consequence.get("value", 0.0)
				* expected_occurrences
				* _stat_value_multiplier(consequence.target)
			)
		"add_percent":
			if consequence.target == "picked_material_value":
				outcome.material_pickup_value += consequence.get("value", 0.0) / 100.0
		"multiply":
			if consequence.target == "picked_material_value":
				outcome.material_pickup_value += (
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


func _first_incoming_hit_event(observation: Dictionary, samples: Array):
	var dodge_failure: float = 1.0 - observation.player_state.runtime_stats.dodge_chance
	for sample in samples:
		for track in observation.enemy_tracks:
			if not track.visible:
				continue
			var enemy_position := _predict_track_position(track, sample.time)
			var collision_radius := (
				observation.player_state.collision_radius
				+ track.last_measurement.visual_radius
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
			var projectile_position: Vector2 = (
				projectile.relative_position
				+ projectile.velocity * sample.time
			)
			var collision_radius := (
				observation.player_state.collision_radius
				+ projectile.visual_radius
			)
			if (projectile_position - sample.displacement).length() <= collision_radius:
				return {
					"entity": projectile,
					"time": sample.time,
					"player_displacement": sample.displacement,
					"damage_probability": dodge_failure,
					"dodge_probability": 1.0 - dodge_failure,
				}
	return null


func _covered_enemy_weight(tracks: Array, center: Vector2, time: float, radius: float) -> float:
	var result := 0.0
	for track in tracks:
		if not track.visible:
			continue
		var enemy_position := _predict_track_position(track, time)
		if enemy_position.distance_to(center) <= radius + track.last_measurement.visual_radius:
			result += track.recency_confidence
	return result


func _condition_matches(condition: Dictionary, event: Dictionary, observation: Dictionary) -> bool:
	if condition.get("health_is_full", false) and observation.player_state.health.ratio < 1.0:
		return false
	if condition.has("entity_has_trait"):
		var traits: Array = event.entity.get("pickup_profile", {}).get("traits", [])
		if not condition.entity_has_trait in traits:
			return false
	return true


func _stat_value_multiplier(stat_name: String) -> float:
	var multipliers := {
		"max_health": 1.5,
		"armor": 1.2,
		"dodge": 1.2,
		"speed": 0.8,
		"harvesting": 0.8,
		"curse": 0.7,
	}
	return multipliers.get(stat_name, 1.0)


func _predict_track_position(track: Dictionary, time: float) -> Vector2:
	return _motion_predictor.predict_position(
		track.relative_position,
		track.estimated_velocity,
		track.estimated_acceleration,
		track.motion_confidence,
		time
	)
