extends Reference

# Maps planning budget pressure and earliest physical influence into bounded
# search fidelity. This module allocates computation only: opportunity and
# survival value remain owned by the utility models.

const MovementTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_timing_model.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const ProjectileMotionPredictor := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/projectile_motion_predictor.gd"
)

const MINIMUM_DIRECTION_COUNT := 4
const MAXIMUM_NAVIGATION_DIRECTION_COUNT := 8
const MINIMUM_SEARCH_FIDELITY := 0.25
const INFLUENCE_CURVE_EXPONENT := 2.0
const IMMEDIATE_INFLUENCE_PRESSURE_SHARE := 0.5

var _movement_geometry: Reference = MovementGeometryModel.new()
var _projectile_motion_predictor: Reference = ProjectileMotionPredictor.new()


func allocate(observation: Dictionary, compute_budget: Dictionary) -> Dictionary:
	var timing: Dictionary = MovementTimingModel.derive(observation)
	var geometry: Dictionary = _movement_geometry.derive(observation)
	var budget_pressure: float = compute_budget.budget_pressure
	var reference_seconds: float = timing.near_term_horizon_seconds
	var earliest_influence_seconds := _earliest_physical_influence_seconds(
		observation, geometry, timing
	)
	var movement_search_fidelity := _retained_search_fidelity(
		budget_pressure, earliest_influence_seconds, reference_seconds
	)
	var navigation_search_fidelity := _retained_search_fidelity(
		budget_pressure, timing.effective_navigation_horizon_seconds, reference_seconds
	)
	return {
		"fidelity_model": "influence_weighted_decay",
		"budget_pressure": budget_pressure,
		"reference_seconds": reference_seconds,
		"earliest_physical_influence_seconds":
		null if earliest_influence_seconds == INF else earliest_influence_seconds,
		"minimum_search_fidelity": MINIMUM_SEARCH_FIDELITY,
		"influence_curve_exponent": INFLUENCE_CURVE_EXPONENT,
		"immediate_influence_pressure_share": IMMEDIATE_INFLUENCE_PRESSURE_SHARE,
		"movement_search_fidelity": movement_search_fidelity,
		"navigation_search_fidelity": navigation_search_fidelity,
		"movement_direction_count":
		_scaled_direction_count(
			MINIMUM_DIRECTION_COUNT, geometry.direction_count, movement_search_fidelity
		),
		"navigation_direction_count":
		_scaled_direction_count(
			MINIMUM_DIRECTION_COUNT, MAXIMUM_NAVIGATION_DIRECTION_COUNT, navigation_search_fidelity
		),
		"navigation_extra_evaluation_limit":
		_extra_work_limit(MAXIMUM_NAVIGATION_DIRECTION_COUNT, navigation_search_fidelity),
		"movement_refinement_limit":
		_extra_work_limit(geometry.direction_count, movement_search_fidelity),
	}


func _retained_search_fidelity(
	budget_pressure: float, influence_seconds: float, reference_seconds: float
) -> float:
	if budget_pressure <= 0.0:
		return 1.0
	var normalized_distance := min(influence_seconds / reference_seconds, 1.0)
	var influence_pressure_scale: float = lerp(
		IMMEDIATE_INFLUENCE_PRESSURE_SHARE, 1.0, pow(normalized_distance, INFLUENCE_CURVE_EXPONENT)
	)
	# Immediate work absorbs only part of budget pressure; the remaining pressure
	# grows quadratically with influence time. Near-field search fidelity therefore falls
	# more slowly, but cannot remain unbounded during sustained overload.
	return pow(MINIMUM_SEARCH_FIDELITY, budget_pressure * influence_pressure_scale)


func _scaled_direction_count(minimum_count: int, maximum_count: int, fidelity: float) -> int:
	var count := int(ceil(float(maximum_count) * fidelity))
	count = max(count, minimum_count)
	# Opposite direction pairs keep the uniform lattice unbiased.
	return count + count % 2


func _extra_work_limit(maximum_count: int, fidelity: float) -> int:
	var extra_fraction := (fidelity - MINIMUM_SEARCH_FIDELITY) / (1.0 - MINIMUM_SEARCH_FIDELITY)
	return int(round(float(maximum_count) * extra_fraction))


func _earliest_physical_influence_seconds(
	observation: Dictionary, geometry: Dictionary, timing: Dictionary
) -> float:
	var earliest := INF
	var player_speed: float = geometry.command_speed
	for track in observation.enemy_tracks:
		var clearance: float = max(
			0.0,
			(
				track.relative_position.length()
				- geometry.player_radius
				- track.last_measurement.visual_radius
				- track.uncertainty_radius
			)
		)
		var relative_reach_speed: float = player_speed + track.estimated_velocity.length()
		earliest = min(earliest, clearance / relative_reach_speed)
	for projectile in observation.visible_world.enemy_projectiles:
		var predicted_position: Vector2 = _projectile_motion_predictor.predict_position(
			projectile, timing.default_local_horizon_seconds
		)
		var projectile_speed: float = (
			(predicted_position - projectile.relative_position).length()
			/ max(0.01, timing.default_local_horizon_seconds)
		)
		var clearance: float = max(
			0.0,
			(
				projectile.relative_position.length()
				- geometry.player_radius
				- projectile.visual_radius
			)
		)
		earliest = min(earliest, clearance / (player_speed + projectile_speed))
	for warning in observation.visible_world.spawn_warnings:
		if warning.disposition != "hostile":
			continue
		var clearance: float = max(0.0, warning.relative_position.length() - geometry.player_radius)
		earliest = min(earliest, clearance / player_speed)
	return earliest
