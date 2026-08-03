extends Reference

# Converts geometric collision likelihood into the health resource consumed by
# one forecast. The calculation uses armor, dodge, hit protection, and stat
# changes projected for the candidate movement state; health valuation owns the
# nonlinear scarcity of the remaining health resource.

# Vanilla Player.get_iframes() never grants more than one new hit every 0.2
# seconds before endless-mode scaling. Using that stable lower bound converts
# sustained contact occupancy into repeated-hit opportunity without inventing a
# swarm-specific behavior rule.
const MINIMUM_INVINCIBILITY_SECONDS := 0.2

const PlayerMovementStateProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_movement_state_projector.gd"
)

var _movement_state_projector: Reference = PlayerMovementStateProjector.new()


func evaluate(
	observation: Dictionary,
	action: Dictionary,
	hostile_collision_risk: float,
	integrated_hostile_collision_risk: float,
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
	var maximum_hit_opportunities := max(
		1.0, action.forecast_seconds / MINIMUM_INVINCIBILITY_SECONDS
	)
	var expected_hit_count := clamp(
		max(
			clamp(hostile_collision_risk, 0.0, 1.0),
			integrated_hostile_collision_risk / MINIMUM_INVINCIBILITY_SECONDS
		),
		0.0,
		maximum_hit_opportunities
	)
	var expected_health_loss := (
		0.0
		if has_hit_protection
		else (expected_hit_count * maximum_hit_damage * dodge_failure_probability)
	)
	return {
		"maximum_armor_adjusted_hit_damage": maximum_hit_damage,
		"expected_collision_hit_count": expected_hit_count,
		"expected_health_loss": expected_health_loss,
		"terminal_collision_risk":
		(
			hostile_collision_risk
			if (
				not has_hit_protection
				and (
					positive_damage_is_terminal_rule
					or maximum_hit_damage >= current_health
					or expected_health_loss >= current_health
				)
			)
			else 0.0
		),
	}


func _armor_damage_multiplier(armor: float) -> float:
	if armor >= 0.0:
		return 1.0 / (1.0 + armor / 15.0)
	return 2.0 - 1.0 / (1.0 - armor / 15.0)
