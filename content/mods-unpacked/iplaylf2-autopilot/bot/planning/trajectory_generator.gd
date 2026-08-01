extends Reference

# Generates a bounded family of curved trajectories. The search space is kept
# deliberately small enough for exhaustive coarse evaluation every replan.

const HORIZON_SECONDS := 0.8
const HORIZON_STEPS := 6


func generate(observation: Dictionary, search_budget: Dictionary) -> Array:
	var speed: float = max(0.0, observation.player_state.runtime_stats.move_speed)
	var trajectories := [_make_trajectory("hold", Vector2.ZERO, 0.0, speed)]
	for direction_index in search_budget.direction_count:
		var heading := TAU * float(direction_index) / float(search_budget.direction_count)
		for turn_rate in search_budget.turn_rates:
			var trajectory_id := "move_%s_%s" % [direction_index, turn_rate]
			trajectories.push_back(
				_make_trajectory(trajectory_id, Vector2.RIGHT.rotated(heading), turn_rate, speed)
			)
	return trajectories


func _make_trajectory(
	trajectory_id: String, initial_movement: Vector2, turn_rate: float, speed: float
) -> Dictionary:
	var samples := []
	var displacement := Vector2.ZERO
	var step_seconds := HORIZON_SECONDS / float(HORIZON_STEPS)
	for step in range(1, HORIZON_STEPS + 1):
		var time := step_seconds * float(step)
		var movement := initial_movement.rotated(turn_rate * time)
		displacement += movement * speed * step_seconds
		samples.push_back(
			{
				"time": time,
				"displacement": displacement,
				"movement": movement,
			}
		)
	return {
		"trajectory_id": trajectory_id,
		"movement": initial_movement,
		"turn_rate": turn_rate,
		"horizon_seconds": HORIZON_SECONDS,
		"samples": samples,
	}
