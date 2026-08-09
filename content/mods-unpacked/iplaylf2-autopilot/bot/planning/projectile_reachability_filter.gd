extends Reference

# Removes visible hostile projectiles that cannot reach the player's planning
# region within the navigation horizon under the available motion bounds. Other
# observation domains pass through unchanged.

const PlanningTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/planning_timing_model.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const ProjectileMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/projectile_motion_predictor.gd"
)

var _movement_geometry: Reference = MovementGeometryModel.new()
var _projectile_motion_predictor: Reference = ProjectileMotionPredictor.new()


func filter(observation: Dictionary) -> Dictionary:
	var timing: Dictionary = PlanningTimingModel.derive(observation)
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
	var projectile_travel_bound: float = _projectile_motion_predictor.maximum_displacement(
		projectile, horizon_seconds
	)
	var interaction_radius: float = (
		geometry.player_radius
		+ projectile.contact_radius
		+ geometry.projectile_pressure_distance
	)
	return (
		projectile.relative_position.length()
		<= player_travel_bound + projectile_travel_bound + interaction_radius
	)
