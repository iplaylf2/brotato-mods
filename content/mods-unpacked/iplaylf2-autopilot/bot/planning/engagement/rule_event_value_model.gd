extends Reference

# Prices the finite consequences realized by one declarative event. Direct
# damage and status transitions share spatial delivery and enemy-completion
# conservation; callers discover events but never reinterpret their mechanics.

const DamageCompletionWorkModel := preload("damage_completion_work_model.gd")
const WeaponAttackCapacityModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapons/weapon_attack_capacity_model.gd"
)

var _damage_completion_work_model: Reference = DamageCompletionWorkModel.new()
var _weapon_attack_capacity_model: Reference = WeaponAttackCapacityModel.new()
var _enemy_motion_predictor: Reference


func set_enemy_motion_predictor(predictor: Reference) -> void:
	_enemy_motion_predictor = predictor


func realized_value(
	observation: Dictionary,
	event_name: String,
	event: Dictionary,
	completion_value_ledger: Dictionary
) -> float:
	var result := 0.0
	for rule in observation.player_state.effect_rules:
		if rule.event != event_name or not _condition_matches(rule.condition, event, observation):
			continue
		for consequence in rule.consequences:
			result += consequence_value(observation, consequence, event, completion_value_ledger)
	return result * event.get("event_weight", 1.0)


func consequence_value(
	observation: Dictionary,
	consequence: Dictionary,
	event: Dictionary,
	completion_value_ledger: Dictionary
) -> float:
	var probability: float = clamp(consequence.get("probability", 1.0), 0.0, 1.0)
	if probability <= 0.0:
		return 0.0
	if consequence.target == "enemy_health" and consequence.operation == "deal_damage":
		return (
			probability
			* _delivered_completion_value(
				observation,
				consequence.delivery,
				event,
				_damage_amount(consequence.amount),
				completion_value_ledger
			)
		)
	if consequence.target == "enemy_status" and consequence.operation == "apply":
		return (
			probability
			* _status_transition_value(observation, consequence, event, completion_value_ledger)
		)
	return 0.0


func _status_transition_value(
	observation: Dictionary,
	consequence: Dictionary,
	event: Dictionary,
	completion_value_ledger: Dictionary
) -> float:
	var duration: float = min(
		max(0.0, consequence.get("duration_seconds", 0.0)),
		max(0.0, observation.wave_state.seconds_remaining - event.time)
	)
	var direct_damage: float = _damage_amount(
		consequence.get("damage_over_time", {"constant": 0.0, "minimum": 0.0})
	)
	var followup_multiplier := _followup_damage_multiplier(
		observation.player_state.effect_rules, consequence.status
	)
	var bonus_damage_budget: float = (
		_followup_damage_capacity(observation.player_state.weapons, duration, event.time)
		* max(0.0, followup_multiplier - 1.0)
	)
	return _delivered_completion_value(
		observation,
		consequence.delivery,
		event,
		direct_damage,
		completion_value_ledger,
		bonus_damage_budget
	)


func _followup_damage_capacity(weapons: Array, duration: float, event_time: float) -> float:
	var result := 0.0
	for observed_weapon in weapons:
		var attack_model: Dictionary = observed_weapon.attack_model
		result += (
			_weapon_attack_capacity_model.expected_damage_per_hit(attack_model)
			* _weapon_attack_capacity_model.expected_attack_count(
				attack_model, duration, event_time
			)
			* float(attack_model.delivery.paths.count)
			* float(attack_model.delivery.paths.primary_probability_floor)
		)
	return result


func _followup_damage_multiplier(rules: Array, status: String) -> float:
	var result := 1.0
	for rule in rules:
		if rule.event != "damage_dealt":
			continue
		if rule.condition.get("target_has_status", "") != status:
			continue
		if rule.condition.get("damage_kind_is_not", "") != "damage_over_time":
			continue
		for consequence in rule.consequences:
			if consequence.target == "dealt_damage" and consequence.operation == "multiply":
				result *= max(0.0, consequence.get("value", 1.0))
	return result


func _delivered_completion_value(
	observation: Dictionary,
	delivery: Dictionary,
	event: Dictionary,
	damage_per_target: float,
	completion_value_ledger: Dictionary,
	shared_bonus_damage := 0.0
) -> float:
	assert(_enemy_motion_predictor != null)
	var center: Vector2 = event.player_displacement
	if delivery.anchor_on_event_entity:
		center = event.entity.get("relative_position", center)
	var covered := []
	var covered_mass := 0.0
	for track in observation.enemy_tracks:
		if not track.visible:
			continue
		var enemy_position: Vector2 = _enemy_motion_predictor.predict_position(
			track, event.time, event.player_displacement
		)
		if (
			enemy_position.distance_to(center)
			> delivery.radius + track.last_measurement.visual_radius
		):
			continue
		var confidence: float = track.recency_confidence
		covered.push_back({"track": track, "confidence": confidence})
		covered_mass += confidence
	if covered_mass <= 0.0:
		return 0.0
	var capacity_scale: float = min(1.0, max(0.0, delivery.capacity_per_event) / covered_mass)
	var result := 0.0
	for entry in covered:
		var ledger_entry: Dictionary = completion_value_ledger.entries_by_track_id[entry.track.track_id]
		var allocated_damage: float = (
			damage_per_target
			+ shared_bonus_damage * entry.confidence / covered_mass
		)
		result += (
			entry.confidence
			* ledger_entry.net_completion_value
			* _damage_completion_work_model.completion_fraction_per_hit(
				ledger_entry.remaining_health, allocated_damage
			)
		)
	return result * capacity_scale


func _damage_amount(amount: Dictionary) -> float:
	return max(amount.get("minimum", 0.0), amount.get("constant", 0.0))


func _condition_matches(condition: Dictionary, event: Dictionary, observation: Dictionary) -> bool:
	if condition.get("health_is_full", false) and observation.player_state.health.ratio < 1.0:
		return false
	if condition.has("entity_has_trait"):
		var traits: Array = event.entity.get("pickup_profile", {}).get("traits", [])
		if not condition.entity_has_trait in traits:
			return false
	return true
