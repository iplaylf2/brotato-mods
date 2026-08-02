extends Reference

# Converts geometric collision likelihood into the health resource consumed by
# one forecast. The worst threat predicted to intersect this action defines its
# survival reserve. The calculation uses armor, dodge, hit protection, and stat
# changes projected for the candidate movement state.

const PlayerMovementStateProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_movement_state_projector.gd"
)

var _movement_state_projector: Reference = PlayerMovementStateProjector.new()


func evaluate(
	observation: Dictionary,
	action: Dictionary,
	hostile_collision_risk: float,
	maximum_raw_hit_damage: float,
	positive_damage_is_terminal_rule: bool
) -> Dictionary:
	var runtime_stats: Dictionary = _movement_state_projector.project_runtime_stats(
		observation, action.movement != Vector2.ZERO
	)
	var maximum_hit_damage := max(
		1.0, round(maximum_raw_hit_damage * _armor_damage_multiplier(runtime_stats.armor))
	)
	var current_health: float = observation.player_state.health.current
	var has_hit_protection: bool = runtime_stats.hit_protection > 0
	var dodge_failure_probability: float = clamp(1.0 - runtime_stats.dodge_chance, 0.0, 1.0)
	var expected_health_loss := (
		0.0
		if has_hit_protection
		else (
			clamp(hostile_collision_risk, 0.0, 1.0)
			* maximum_hit_damage
			* dodge_failure_probability
		)
	)
	var survival_reserve := 0.0 if has_hit_protection else maximum_hit_damage
	var expendable_health := max(0.0, current_health - survival_reserve)
	return {
		"maximum_armor_adjusted_hit_damage": maximum_hit_damage,
		"survival_reserve": survival_reserve,
		"expendable_health": expendable_health,
		"expected_health_loss": expected_health_loss,
		"expendable_health_consumption_ratio": expected_health_loss / max(1.0, expendable_health),
		"terminal_collision_risk":
		(
			hostile_collision_risk
			if (
				not has_hit_protection
				and (positive_damage_is_terminal_rule or maximum_hit_damage >= current_health)
			)
			else 0.0
		),
	}


func _armor_damage_multiplier(armor: float) -> float:
	if armor >= 0.0:
		return 1.0 / (1.0 + armor / 15.0)
	return 2.0 - 1.0 / (1.0 - armor / 15.0)
