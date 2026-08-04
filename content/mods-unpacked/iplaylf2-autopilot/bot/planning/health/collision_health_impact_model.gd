extends Reference

# Converts collision evidence into the health resource consumed by one
# forecast. Geometric models own contact detection; this model alone owns the
# interpretation of invincibility frames, armor, dodge, and hit protection.

const PlayerMovementStateProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_movement_state_projector.gd"
)

var _movement_state_projector: Reference = PlayerMovementStateProjector.new()


func evaluate(
	observation: Dictionary,
	action: Dictionary,
	evidence: Dictionary,
	positive_damage_is_terminal_rule: bool
) -> Dictionary:
	var runtime_stats: Dictionary = _movement_state_projector.project_runtime_stats(
		observation, action.movement != Vector2.ZERO
	)
	var invincibility_seconds: float = runtime_stats.minimum_invincibility_seconds
	var path_contact_opportunity_count_estimate: float = max(
		clamp(evidence.path_collision_risk, 0.0, 1.0),
		evidence.path_contact_evidence_seconds / invincibility_seconds
	)
	# Swept position and analytic velocity evidence can describe the same
	# contact, so retain the stronger account instead of adding them twice.
	var contact_opportunity_count_estimate: float = max(
		path_contact_opportunity_count_estimate, evidence.velocity_contact_evidence_sum
	)
	var path_raw_damage_evidence_sum: float = max(
		clamp(evidence.path_collision_risk, 0.0, 1.0) * evidence.maximum_path_raw_damage,
		evidence.path_raw_damage_evidence_seconds / invincibility_seconds
	)
	var raw_damage_evidence_sum: float = max(
		path_raw_damage_evidence_sum, evidence.velocity_raw_damage_evidence_sum
	)
	var maximum_hit_count := max(1.0, action.forecast_seconds / invincibility_seconds)
	var expected_hit_count := clamp(contact_opportunity_count_estimate, 0.0, maximum_hit_count)
	var unprotected_hit_count := max(0.0, expected_hit_count - float(runtime_stats.hit_protection))
	var mean_raw_damage_per_hit := (
		raw_damage_evidence_sum / contact_opportunity_count_estimate
		if contact_opportunity_count_estimate > 0.0
		else 0.0
	)
	var armor_multiplier := _armor_damage_multiplier(runtime_stats.armor)
	var mean_hit_damage := _armor_adjusted_damage(mean_raw_damage_per_hit, armor_multiplier)
	var maximum_raw_hit_damage: float = max(
		evidence.maximum_path_raw_damage, evidence.maximum_velocity_raw_damage
	)
	var maximum_hit_damage := _armor_adjusted_damage(maximum_raw_hit_damage, armor_multiplier)
	var dodge_failure_probability: float = clamp(1.0 - runtime_stats.dodge_chance, 0.0, 1.0)
	var expected_health_loss := unprotected_hit_count * mean_hit_damage * dodge_failure_probability
	var current_health: float = observation.player_state.health.current
	var collision_risk: float = max(
		clamp(evidence.path_collision_risk, 0.0, 1.0),
		clamp(evidence.velocity_collision_risk, 0.0, 1.0)
	)
	var has_terminal_hit_evidence := (
		unprotected_hit_count > 0.0
		and (positive_damage_is_terminal_rule or maximum_hit_damage >= current_health)
	)
	return {
		"maximum_armor_adjusted_hit_damage": maximum_hit_damage,
		"expected_collision_hit_count": expected_hit_count,
		"expected_health_loss": expected_health_loss,
		"terminal_collision_risk":
		collision_risk * dodge_failure_probability if has_terminal_hit_evidence else 0.0,
	}


func _armor_adjusted_damage(raw_damage: float, armor_multiplier: float) -> float:
	if raw_damage <= 0.0:
		return 0.0
	return max(1.0, round(raw_damage * armor_multiplier))


func _armor_damage_multiplier(armor: float) -> float:
	if armor >= 0.0:
		return 1.0 / (1.0 + armor / 15.0)
	return 2.0 - 1.0 / (1.0 - armor / 15.0)
