extends Reference

# Estimates whether a remembered world entity still exists from legal pickup or
# visibility evidence. It owns teammate reachability memory; it does not store
# entities or inspect hidden scene state.

const NEARBY_PICKUP_HAZARD_PER_SECOND := 1.5
const OBSERVED_MOTION_SECONDS := 1.0
const PICKUP_INFLUENCE_DISTANCE := 300.0
const VisibilityCoverageModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/observation/visibility_coverage_model.gd"
)

var _elapsed_seconds := 0.0
var _odometry_position := Vector2.ZERO
var _teammate_observations := {}
var _visibility_coverage_model: Reference = VisibilityCoverageModel.new()


func update(delta_seconds: float, position_delta: Vector2, visible_allies: Array) -> void:
	_elapsed_seconds += delta_seconds
	_odometry_position += position_delta
	for ally in visible_allies:
		if ally.kind != "player":
			continue
		_teammate_observations[ally.owner_player_index] = {
			"observed_at_seconds": _elapsed_seconds,
			"odometry_position": _odometry_position + ally.relative_position,
			"velocity": ally.velocity,
			"move_speed": ally.move_speed,
			"pickup": ally.pickup.duplicate(true),
		}


func estimate(
	memory_record: Dictionary,
	party_state: Dictionary,
	player_pickup: Dictionary,
	visibility: Dictionary
) -> Dictionary:
	var kind: String = memory_record.observation.kind
	if kind == "tree":
		return (
			_confirmed_absence()
			if _tree_last_position_is_covered(memory_record, visibility)
			else _unchanged_estimate()
		)
	if kind != "material" and kind != "consumable":
		return _unchanged_estimate()
	var entity_position: Vector2 = memory_record.odometry_position - _odometry_position
	var own_distance := entity_position.length()
	if own_distance <= player_pickup.collection_radius:
		return _confirmed_absence()
	var hazard_rate := 0.0
	if own_distance <= player_pickup.attraction_radius:
		hazard_rate += NEARBY_PICKUP_HAZARD_PER_SECOND
	for player_index in party_state.living_teammate_player_indices:
		if not _teammate_observations.has(player_index):
			continue
		var teammate: Dictionary = _teammate_observations[player_index]
		var seconds_since_observed: float = _elapsed_seconds - teammate.observed_at_seconds
		var teammate_position: Vector2 = teammate.odometry_position - _odometry_position
		var travel: Vector2 = teammate.velocity * OBSERVED_MOTION_SECONDS
		var closest_fraction := 0.0
		if travel.length_squared() > 0.0:
			closest_fraction = clamp(
				(entity_position - teammate_position).dot(travel) / travel.length_squared(),
				0.0,
				1.0
			)
		var closest_position: Vector2 = teammate_position + travel * closest_fraction
		var pickup: Dictionary = teammate.pickup
		var distance: float = closest_position.distance_to(entity_position)
		if seconds_since_observed == 0.0 and distance <= pickup.collection_radius:
			return _confirmed_absence()
		var uncertainty_radius: float = teammate.move_speed * seconds_since_observed
		var attraction_radius: float = pickup.attraction_radius
		var gap := max(0.0, distance - attraction_radius - uncertainty_radius)
		var location_likelihood := pow(
			attraction_radius / max(1.0, max(attraction_radius, uncertainty_radius)), 2.0
		)
		hazard_rate += (
			NEARBY_PICKUP_HAZARD_PER_SECOND
			* exp(-gap / PICKUP_INFLUENCE_DISTANCE)
			* location_likelihood
		)
	return {
		"absence_confirmed": false,
		"disappearance_hazard_per_second": hazard_rate,
	}


func _tree_last_position_is_covered(memory_record: Dictionary, visibility: Dictionary) -> bool:
	var entity_position: Vector2 = memory_record.odometry_position - _odometry_position
	var visual_radius: float = max(0.0, memory_record.observation.get("visual_radius", 0.0))
	return _visibility_coverage_model.covers_reachable_circle(
		entity_position, visual_radius, 0.0, visibility
	)


func _unchanged_estimate() -> Dictionary:
	return {"absence_confirmed": false, "disappearance_hazard_per_second": 0.0}


func _confirmed_absence() -> Dictionary:
	return {"absence_confirmed": true, "disappearance_hazard_per_second": 0.0}
