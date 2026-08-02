extends Reference

# Builds a player-centred, adaptive state-cost graph and solves a layered
# Bellman shortest-path recurrence. Environmental exposure is a non-negative
# traversal cost. Resources and strategic opportunities are terminal rewards;
# exact velocity-space collision checks remain outside this global value model.

const BattlefieldExposureModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/battlefield_exposure_model.gd"
)
const WeaponEngagementModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapon_engagement_model.gd"
)
const MovementPlanningTiming := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_planning_timing.gd"
)
const PlayerKinematicsModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_kinematics_model.gd"
)
const MovementScaleModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_scale_model.gd"
)

const MIN_RING_DIRECTION_COUNT := 8
const REFERENCE_LOCAL_RING_DIRECTION_COUNT := 32
const ENGAGEMENT_RADIAL_SAMPLES := 6.0
const FAR_RING_GROWTH := 1.65

var _exposure_model: Reference = BattlefieldExposureModel.new()
var _engagement_model: Reference = WeaponEngagementModel.new()
var _player_kinematics: Reference = PlayerKinematicsModel.new()
var _movement_scale: Reference = MovementScaleModel.new()


func build(observation: Dictionary, context: Dictionary, search_budget: Dictionary) -> Dictionary:
	var map_extent := _map_extent(observation)
	var spatial_scale := _spatial_scale(observation)
	var radii := _adaptive_radii(
		map_extent.radius, spatial_scale.near_node_spacing, spatial_scale.local_detail_radius
	)
	var nodes := [
		_sample_node(
			observation,
			context,
			Vector2.ZERO,
			0.0,
			0,
			spatial_scale.near_node_spacing,
			spatial_scale.local_prediction_radius
		)
	]
	for ring_offset in radii.size():
		var radius: float = radii[ring_offset]
		var direction_count := _ring_direction_count(
			radius, spatial_scale.local_detail_radius, search_budget.graph_angular_resolution_scale
		)
		var spatial_resolution: float = TAU * radius / float(direction_count)
		for direction_index in direction_count:
			var position := (
				Vector2.RIGHT.rotated(TAU * float(direction_index) / float(direction_count))
				* radius
			)
			if not _inside_domain(position, map_extent):
				continue
			nodes.push_back(
				_sample_node(
					observation,
					context,
					position,
					radius,
					ring_offset + 1,
					spatial_resolution,
					spatial_scale.local_prediction_radius
				)
			)

	_solve_route_values(nodes, context, map_extent.radius, spatial_scale.near_node_spacing)
	var navigation_guidance := _navigation_guidance(nodes)
	var preferred_directions := []
	if navigation_guidance != Vector2.ZERO:
		preferred_directions.push_back(navigation_guidance.normalized())
	return {
		"nodes": nodes,
		"preferred_directions": preferred_directions,
		"navigation_guidance": navigation_guidance,
		"domain": map_extent,
		"near_node_spacing": spatial_scale.near_node_spacing,
		"local_detail_radius": spatial_scale.local_detail_radius,
		"local_prediction_radius": spatial_scale.local_prediction_radius,
		"control_distance": spatial_scale.control_distance,
		"engagement_capacity": spatial_scale.engagement_capacity,
		"current_engagement_estimate": spatial_scale.current_engagement_estimate,
		"node_count": nodes.size(),
		"source_scope": "visible_and_remembered",
	}


func _sample_node(
	observation: Dictionary,
	context: Dictionary,
	position: Vector2,
	radius: float,
	ring_index: int,
	spatial_resolution: float,
	local_prediction_radius: float
) -> Dictionary:
	var speed: float = max(1.0, _player_kinematics.predict_command_speed(observation, true))
	var forecast_seconds := clamp(
		radius / speed,
		MovementPlanningTiming.CONTROL_INTERVAL_SECONDS,
		MovementPlanningTiming.NAVIGATION_FORECAST_MAX_SECONDS
	)
	var current: Dictionary = _exposure_model.sample_point(
		observation, position, 0.0, context.exposure_policy
	)
	var forecast: Dictionary = _exposure_model.sample_point(
		observation, position, forecast_seconds, context.exposure_policy
	)
	var eulerian_pressure_derivative: float = (
		(forecast.environmental_pressure - current.environmental_pressure)
		/ forecast_seconds
	)
	var strategic_value := _strategic_value(
		observation, context, position, forecast_seconds, local_prediction_radius
	)
	var healing_value: float = forecast.healing_support * context.navigation_policy.healing_support
	var engagement_estimate: Dictionary = _engagement_model.estimate_at_position(
		observation,
		position,
		forecast_seconds,
		MovementPlanningTiming.NAVIGATION_FORECAST_MAX_SECONDS
	)
	var engagement_utility: float = (
		engagement_estimate.expected_damage
		* context.objective_weights.combat.expected_weapon_damage
	)
	var traversal_cost: float = (
		0.4 * current.environmental_pressure
		+ 0.6 * forecast.environmental_pressure
		+ max(0.0, eulerian_pressure_derivative) * context.navigation_policy.rising_pressure
	)
	# Local outcomes own the current forecast interval. The graph contributes only
	# residual terminal value beyond it.
	var terminal_horizon_weight := clamp(
		(radius - local_prediction_radius) / max(1.0, spatial_resolution), 0.0, 1.0
	)
	var terminal_reward: float = (
		(strategic_value + healing_value + engagement_utility)
		* terminal_horizon_weight
	)
	return {
		"position": position,
		"ring_index": ring_index,
		"spatial_resolution": spatial_resolution,
		"forecast_seconds": forecast_seconds,
		"current_environmental_pressure": current.environmental_pressure,
		"forecast_environmental_pressure": forecast.environmental_pressure,
		"eulerian_pressure_derivative": eulerian_pressure_derivative,
		"strategic_value": strategic_value,
		"healing_value": healing_value,
		"engagement_estimate": engagement_estimate,
		"engagement_utility": engagement_utility,
		"traversal_cost": traversal_cost,
		"terminal_reward": terminal_reward,
		"terminal_horizon_weight": terminal_horizon_weight,
		"path_cost": INF,
		"route_value": -INF,
		"parent_index": -1,
	}


func _strategic_value(
	observation: Dictionary,
	context: Dictionary,
	position: Vector2,
	time: float,
	local_prediction_radius: float
) -> float:
	var value := 0.0
	for remembered_entity in observation.get("remembered_entities", []):
		# Static goals reachable by the local predictor belong to that predictor.
		# The graph cannot assume they survive collection or destruction.
		if remembered_entity.relative_position.length() <= local_prediction_radius:
			continue
		var confidence: float = remembered_entity.existence_confidence
		var distance: float = (remembered_entity.relative_position - position).length()
		match remembered_entity.kind:
			"material":
				value += (
					_radial_pull(distance, 420.0)
					* confidence
					* context.navigation_policy.material
				)
			"consumable":
				value += (
					_radial_pull(distance, 360.0)
					* confidence
					* (
						context.navigation_policy.recovery_pickup
						+ context.navigation_policy.consumable_event_value
					)
				)
			"tree":
				value += (
					_radial_pull(distance, 500.0)
					* confidence
					* context.navigation_policy.tree
				)

	for track in observation.enemy_tracks:
		var predicted_position: Vector2 = track.relative_position + track.estimated_velocity * time
		var distance: float = (predicted_position - position).length()
		var roles: Dictionary = track.behavior_profile.strategic_roles
		if roles.enemy_producer:
			value += (
				_radial_pull(distance, 600.0)
				* track.recency_confidence
				* context.navigation_policy.enemy_producer
			)
		if roles.loot_reward_target:
			value += (
				_radial_pull(distance, 600.0)
				* track.recency_confidence
				* context.navigation_policy.loot_target
			)
		if roles.ranged_pressure_source:
			value += (
				_radial_pull(distance, 700.0)
				* track.recency_confidence
				* context.navigation_policy.ranged_source
			)
		if context.navigation_policy.contact_combat > 0.0:
			value += (
				_radial_pull(distance, 420.0)
				* track.recency_confidence
				* context.navigation_policy.contact_combat
			)
	return sign(value) * (1.0 - exp(-abs(value)))


func _navigation_guidance(nodes: Array) -> Vector2:
	var best_index := 0
	for node_index in range(1, nodes.size()):
		if nodes[node_index].route_value > nodes[best_index].route_value:
			best_index = node_index
	if best_index == 0 or nodes[best_index].route_value <= 0.0:
		return Vector2.ZERO
	var first_step_index := best_index
	while nodes[first_step_index].parent_index > 0:
		first_step_index = nodes[first_step_index].parent_index
	var magnitude: float = clamp(nodes[best_index].route_value, 0.0, 1.0)
	return nodes[first_step_index].position.normalized() * magnitude


func _solve_route_values(
	nodes: Array, context: Dictionary, map_radius: float, near_node_spacing: float
) -> void:
	nodes[0].path_cost = 0.0
	nodes[0].route_value = nodes[0].terminal_reward
	var maximum_ring := 0
	for node in nodes:
		maximum_ring = max(maximum_ring, node.ring_index)
	for ring_index in range(1, maximum_ring + 1):
		var parent_ring := _previous_populated_ring(nodes, ring_index)
		if parent_ring < 0:
			continue
		for node_index in nodes.size():
			var node: Dictionary = nodes[node_index]
			if node.ring_index != ring_index:
				continue
			var best_parent := -1
			var best_cost := INF
			for parent_index in nodes.size():
				var parent: Dictionary = nodes[parent_index]
				if parent.ring_index != parent_ring:
					continue
				var edge_distance: float = parent.position.distance_to(node.position)
				var edge_cost := (
					(
						0.5
						* (parent.traversal_cost + node.traversal_cost)
						* edge_distance
						/ near_node_spacing
					)
					+ context.navigation_policy.travel_cost * edge_distance / max(1.0, map_radius)
				)
				var candidate_cost: float = parent.path_cost + edge_cost
				if candidate_cost < best_cost:
					best_cost = candidate_cost
					best_parent = parent_index
			node.path_cost = best_cost
			node.parent_index = best_parent
			var safety_gain := max(0.0, nodes[0].traversal_cost - node.traversal_cost)
			node.route_value = node.terminal_reward + safety_gain - best_cost


func _previous_populated_ring(nodes: Array, ring_index: int) -> int:
	for candidate_ring in range(ring_index - 1, -1, -1):
		for node in nodes:
			if node.ring_index == candidate_ring:
				return candidate_ring
	return -1


func _adaptive_radii(
	maximum_radius: float, near_node_spacing: float, local_detail_radius: float
) -> Array:
	var result := []
	var radius := near_node_spacing
	while radius < maximum_radius:
		result.push_back(radius)
		if radius < local_detail_radius:
			radius += near_node_spacing
		else:
			radius *= FAR_RING_GROWTH
	if maximum_radius > 0.0 and (result.empty() or result.back() < maximum_radius * 0.85):
		result.push_back(maximum_radius)
	return result


func _spatial_scale(observation: Dictionary) -> Dictionary:
	var player_state: Dictionary = observation.player_state
	var movement_scale: Dictionary = _movement_scale.derive(observation)
	var player_radius: float = movement_scale.player_radius
	var speed: float = movement_scale.command_speed
	var control_distance: float = movement_scale.control_distance
	var engagement_capacity: Dictionary = _engagement_model.estimate_capacity(
		observation, MovementPlanningTiming.NAVIGATION_FORECAST_MAX_SECONDS
	)
	var current_engagement: Dictionary = _engagement_model.estimate_at_position(
		observation, Vector2.ZERO, 0.0, MovementPlanningTiming.NAVIGATION_FORECAST_MAX_SECONDS
	)
	var effective_range: float = engagement_capacity.damage_weighted_range
	var engagement_sample_count := (
		4.0
		+ sqrt(
			(
				max(
					current_engagement.engaged_attack_count,
					engagement_capacity.scheduled_attack_count
				)
				+ max(current_engagement.expected_hits, engagement_capacity.hit_capacity)
			)
		)
	)
	var engagement_resolution := INF
	if effective_range > 0.0:
		var effective_engagement_span: float = max(
			player_radius, engagement_capacity.damage_weighted_engagement_span
		)
		engagement_resolution = (
			min(effective_range, effective_engagement_span)
			/ max(ENGAGEMENT_RADIAL_SAMPLES, engagement_sample_count)
		)
	var near_node_spacing: float = clamp(
		min(max(player_radius, control_distance), engagement_resolution),
		player_radius,
		player_radius * 4.0
	)
	var reachable_radius := speed * MovementPlanningTiming.NAVIGATION_FORECAST_MAX_SECONDS
	var local_prediction_radius := speed * MovementPlanningTiming.LOCAL_FORECAST_MAX_SECONDS
	var pickup_radius: float = player_state.pickup.attraction_radius
	var bounded_engagement_radius := min(effective_range, reachable_radius * 2.0)
	var local_detail_radius: float = max(
		near_node_spacing * 3.0,
		max(reachable_radius, max(pickup_radius, bounded_engagement_radius))
	)
	return {
		"near_node_spacing": near_node_spacing,
		"local_detail_radius": local_detail_radius,
		"local_prediction_radius": local_prediction_radius,
		"control_distance": control_distance,
		"engagement_capacity": engagement_capacity,
		"current_engagement_estimate": current_engagement,
	}


func _ring_direction_count(
	radius: float, local_detail_radius: float, graph_angular_resolution_scale: float
) -> int:
	var local_detail := clamp(local_detail_radius / max(1.0, radius), 0.0, 1.0)
	var unscaled_count := lerp(
		float(MIN_RING_DIRECTION_COUNT), float(REFERENCE_LOCAL_RING_DIRECTION_COUNT), local_detail
	)
	return max(
		MIN_RING_DIRECTION_COUNT, int(round(unscaled_count * graph_angular_resolution_scale))
	)


func _map_extent(observation: Dictionary) -> Dictionary:
	var bounds: Dictionary = observation.localization.map_bounds
	var viewport_size: Vector2 = observation.visibility.viewport_size
	var viewport_offset: Vector2 = observation.visibility.viewport_offset_from_player
	var left: float = (
		-bounds.distance_to_left
		if bounds.distance_to_left != null
		else viewport_offset.x
	)
	var right: float = (
		bounds.distance_to_right
		if bounds.distance_to_right != null
		else viewport_offset.x + viewport_size.x
	)
	var top: float = (
		-bounds.distance_to_top
		if bounds.distance_to_top != null
		else viewport_offset.y
	)
	var bottom: float = (
		bounds.distance_to_bottom
		if bounds.distance_to_bottom != null
		else viewport_offset.y + viewport_size.y
	)
	for remembered_entity in observation.get("remembered_entities", []):
		var observed_position: Vector2 = remembered_entity.last_observed_relative_position
		left = min(left, observed_position.x)
		right = max(right, observed_position.x)
		top = min(top, observed_position.y)
		bottom = max(bottom, observed_position.y)
	var radius := 0.0
	var corners := [
		Vector2(left, top), Vector2(right, top), Vector2(left, bottom), Vector2(right, bottom)
	]
	for corner in corners:
		radius = max(radius, corner.length())
	return {
		"left": left,
		"right": right,
		"top": top,
		"bottom": bottom,
		"radius": radius,
		"all_edges_known":
		bounds.seen_left and bounds.seen_right and bounds.seen_top and bounds.seen_bottom,
	}


func _inside_domain(position: Vector2, domain: Dictionary) -> bool:
	return (
		position.x >= domain.left
		and position.x <= domain.right
		and position.y >= domain.top
		and position.y <= domain.bottom
	)


func _radial_pull(distance: float, radius: float) -> float:
	var proximity := clamp((radius - distance) / radius, 0.0, 1.0)
	return proximity * proximity
