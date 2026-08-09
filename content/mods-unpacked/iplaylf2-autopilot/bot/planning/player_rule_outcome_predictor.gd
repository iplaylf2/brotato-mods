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
const RuleEventValueModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/" + "rule_event_value_model.gd"
)
var _enemy_motion_predictor: Reference = EnemyMotionPredictor.new()
var _projectile_motion_predictor: Reference = ProjectileMotionPredictor.new()
var _rule_projector: Reference = PlayerRuleProjector.new()
var _stat_opportunity_pricing_model: Reference = StatOpportunityPricingModel.new()
var _rule_event_value_model: Reference = RuleEventValueModel.new()


func _init() -> void:
	_rule_event_value_model.set_enemy_motion_predictor(_enemy_motion_predictor)


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_enemy_motion_predictor = predictor
	_rule_event_value_model.set_enemy_motion_predictor(predictor)


func accumulate_outcome(
	observation: Dictionary, action: Dictionary, outcome: Dictionary, planning_context: Dictionary
) -> void:
	outcome.expected_recovery = _rule_projector.project_recovery(
		observation.player_state.effect_rules, "healing", outcome.expected_recovery
	)
	if outcome.expected_recovery <= 0.0:
		outcome.expected_recovery_events = 0.0
	var pickup_events: Dictionary = outcome.pickup_events
	var material_events: Array = pickup_events.material
	var consumable_events: Array = pickup_events.consumable
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
	_apply_consumable_health_damage(observation, event, profile, outcome, planning_context)
	var recovery_before: float = outcome.expected_recovery
	if profile.get("base_health_damage", 0.0) <= 0.0:
		outcome.expected_recovery += (
			_rule_projector.project_consumable_health_effect(
				observation.player_state.effect_rules, profile.get("base_recovery", 0.0)
			)
			* event.get("event_weight", 1.0)
		)
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
		healing_event.event_weight = event.get("event_weight", 1.0)
		_apply_event_rules(observation, "healing", healing_event, outcome, planning_context)


func _apply_consumable_health_damage(
	observation: Dictionary,
	event: Dictionary,
	profile: Dictionary,
	outcome: Dictionary,
	planning_context: Dictionary
) -> void:
	var base_damage: float = profile.get("base_health_damage", 0.0)
	if base_damage <= 0.0:
		return
	# Vanilla's non-dodgeable damage effect is suppressed only while an already
	# active invincibility timer lasts; taking it does not start new iframes.
	if event.time < observation.player_state.runtime_stats.invincibility_seconds_remaining:
		return
	var event_weight: float = clamp(event.get("event_weight", 1.0), 0.0, 1.0)
	var full_damage: float = _rule_projector.project_consumable_health_effect(
		observation.player_state.effect_rules, base_damage
	)
	var damage: float = full_damage * event_weight
	outcome.forecast_consumable_health_loss += damage
	outcome.forecast_expected_health_loss += damage
	if full_damage >= observation.player_state.health.current:
		outcome.forecast_terminal_consumable_risk = max(
			outcome.forecast_terminal_consumable_risk, event_weight
		)
	elif (
		is_equal_approx(event_weight, 1.0)
		and outcome.forecast_consumable_health_loss >= observation.player_state.health.current
	):
		outcome.forecast_terminal_consumable_risk = 1.0
	var forecast_health_risk: float = outcome.forecast_terminal_health_risk
	var forecast_consumable_risk: float = outcome.forecast_terminal_consumable_risk
	outcome.forecast_terminal_health_time_seconds = _stronger_terminal_time(
		forecast_health_risk,
		outcome.get("forecast_terminal_health_time_seconds", null),
		forecast_consumable_risk,
		event.time
	)
	outcome.forecast_terminal_health_risk = max(forecast_health_risk, forecast_consumable_risk)
	var tactical_control_interval: float = planning_context.get(
		"tactical_control_interval_seconds", 0.0
	)
	if event.time > tactical_control_interval:
		return
	outcome.committed_consumable_health_loss += damage
	outcome.committed_expected_health_loss += damage
	if full_damage >= observation.player_state.health.current:
		outcome.committed_terminal_consumable_risk = max(
			outcome.committed_terminal_consumable_risk, event_weight
		)
	elif (
		is_equal_approx(event_weight, 1.0)
		and outcome.committed_consumable_health_loss >= observation.player_state.health.current
	):
		outcome.committed_terminal_consumable_risk = 1.0
	var committed_health_risk: float = outcome.committed_terminal_health_risk
	var committed_consumable_risk: float = outcome.committed_terminal_consumable_risk
	outcome.committed_terminal_health_time_seconds = _stronger_terminal_time(
		committed_health_risk,
		outcome.get("committed_terminal_health_time_seconds", null),
		committed_consumable_risk,
		event.time
	)
	outcome.committed_terminal_health_risk = max(committed_health_risk, committed_consumable_risk)


func _stronger_terminal_time(
	current_risk: float, current_time, candidate_risk: float, candidate_time
):
	if current_risk > candidate_risk:
		return current_time
	if candidate_risk > current_risk:
		return candidate_time
	if current_risk <= 0.0:
		return null
	if current_time == null or candidate_time == null:
		return null
	return min(float(current_time), float(candidate_time))


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
	# This modifier was already applied to the pickup's mutually exclusive healing
	# or damage effect. It is mechanism input, not an additional outcome.
	if consequence.target == "consumable_health_effect":
		return
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
	if (
		(consequence.target == "enemy_health" and consequence.operation == "deal_damage")
		or (consequence.target == "enemy_status" and consequence.operation == "apply")
	):
		outcome.expected_rule_completion_value += (
			_rule_event_value_model.consequence_value(
				observation, consequence, event, planning_context.enemy_completion_value_ledger
			)
			* event.get("event_weight", 1.0)
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
				var material_quantity: float = max(
					0.0, event.get("entity", {}).get("material_quantity", 0.0)
				)
				outcome.material_acquisition_value += (
					material_quantity
					* max(0.0, consequence.get("value", 1.0) - 1.0)
					* expected_occurrences
				)


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
