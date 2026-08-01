extends Reference

# Maps tracked-enemy and visible-projectile counts to a bounded search budget.
# This count-based policy can later be replaced by measured frame-time feedback.

const DEFAULT_DIRECTION_COUNT := 12
const REDUCED_DIRECTION_COUNT := 8
const BUSY_THREAT_COUNT := 140
const EXTREME_THREAT_COUNT := 320
const TURN_RATES := [-1.0, 0.0, 1.0]


func build(observation: Dictionary) -> Dictionary:
	var enemy_and_projectile_count: int = (
		observation.enemy_tracks.size()
		+ observation.visible_world.enemy_projectiles.size()
	)
	if enemy_and_projectile_count >= EXTREME_THREAT_COUNT:
		return {
			"load_class": "extreme",
			"enemy_and_projectile_count": enemy_and_projectile_count,
			"direction_count": REDUCED_DIRECTION_COUNT,
			"turn_rates": [0.0],
			"full_evaluation_limit": 4,
		}
	if enemy_and_projectile_count >= BUSY_THREAT_COUNT:
		return {
			"load_class": "busy",
			"enemy_and_projectile_count": enemy_and_projectile_count,
			"direction_count": REDUCED_DIRECTION_COUNT,
			"turn_rates": TURN_RATES,
			"full_evaluation_limit": 6,
		}
	return {
		"load_class": "normal",
		"enemy_and_projectile_count": enemy_and_projectile_count,
		"direction_count": DEFAULT_DIRECTION_COUNT,
		"turn_rates": TURN_RATES,
		"full_evaluation_limit": 10,
	}
