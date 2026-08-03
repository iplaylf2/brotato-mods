extends Reference

# Removes visible hostile projectiles that cannot reach the player's planning
# region within the navigation horizon under the available motion bounds. Other
# observation domains pass through unchanged.

const MovementTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_timing_model.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)

var _movement_geometry: Reference = MovementGeometryModel.new()


func filter(observation: Dictionary) -> Dictionary:
	var timing: Dictionary = MovementTimingModel.derive(observation)
	var geometry: Dictionary = _movement_geometry.derive(observation)
	var horizon_seconds: float = timing.effective_navigation_horizon_seconds
	var included_projectiles := []
	var deferred_projectile_count := 0
	for projectile in observation.visible_world.enemy_projectiles:
		if _projectile_can_reach_planning_region(projectile, horizon_seconds, geometry):
			included_projectiles.push_back(projectile)
		else:
			deferred_projectile_count += 1

	var filtered_observation: Dictionary = observation.duplicate(false)
	filtered_observation.visible_world = observation.visible_world.duplicate(false)
	filtered_observation.visible_world.enemy_projectiles = included_projectiles
	return {
		"filtered_observation": filtered_observation,
		"included_projectile_count": included_projectiles.size(),
		"deferred_projectile_count": deferred_projectile_count,
		"mode": "conservative_reachable_distance",
		"horizon_seconds": horizon_seconds,
	}


func _projectile_can_reach_planning_region(
	projectile: Dictionary, horizon_seconds: float, geometry: Dictionary
) -> bool:
	var player_travel_bound: float = geometry.command_speed * horizon_seconds
	var projectile_travel_bound: float = projectile.velocity.length() * horizon_seconds
	projectile_travel_bound += (
		projectile.acceleration.length()
		* horizon_seconds
		* horizon_seconds
		* 0.5
	)
	var motion_model: Dictionary = projectile.get("motion_model", {"kind": "linear"})
	if motion_model.kind == "sinusoidal_velocity":
		var amplitude: Vector2 = motion_model.velocity_amplitude
		var angular_velocity: Vector2 = motion_model.angular_velocity
		projectile_travel_bound += _maximum_integrated_axis_excursion(
			amplitude.x, angular_velocity.x, horizon_seconds
		)
		projectile_travel_bound += _maximum_integrated_axis_excursion(
			amplitude.y, angular_velocity.y, horizon_seconds
		)
	var interaction_radius: float = (
		geometry.player_radius
		+ projectile.visual_radius
		+ geometry.projectile_pressure_distance
	)
	return (
		projectile.relative_position.length()
		<= player_travel_bound + projectile_travel_bound + interaction_radius
	)


func _maximum_integrated_axis_excursion(
	amplitude: float, angular_velocity: float, horizon_seconds: float
) -> float:
	if abs(angular_velocity) <= 0.0001:
		return abs(amplitude) * horizon_seconds
	return min(abs(amplitude) * horizon_seconds, 2.0 * abs(amplitude / angular_velocity))
