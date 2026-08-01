extends Reference

# Reads only the camera- and fog-visible world. Scene objects in internal enemy
# and projectile observations are private continuity tokens and never become public.

const DEFAULT_ENTITY_VISUAL_RADIUS := 32.0
const PROJECTILE_ORIGIN_INFERENCE_DISTANCE := 120.0
const ObservedMotionEstimator := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/observation/observed_motion_estimator.gd"
)

var _main: Node
var _players: Array
var _motion_estimators := []


func _init(main: Node, players: Array) -> void:
	_main = main
	_players = players
	for _player in players:
		_motion_estimators.push_back(ObservedMotionEstimator.new())


func observe(player_index: int, player: Node2D, delta_seconds: float) -> Dictionary:
	var visible_rect := _get_visible_rect()
	var origin: Vector2 = player.global_position
	var enemies := _observe_enemies(player, visible_rect)
	var enemy_projectiles := _observe_enemy_projectiles(origin, visible_rect)
	var moving_observations := []
	moving_observations.append_array(enemies)
	moving_observations.append_array(enemy_projectiles)
	_motion_estimators[player_index].update(moving_observations, delta_seconds)
	_update_enemy_motion_features(enemies, _get_velocity(player))
	var ranged_attack_sources := _infer_ranged_attacks(enemies, enemy_projectiles)
	for enemy in enemies:
		enemy.features.ranged_attack_inferred = ranged_attack_sources.has(enemy._source)

	return {
		# Internal inputs for observed world memory; never expose them through the service.
		"enemy_observations": enemies,
		"visible_edges": _observe_visible_edges(origin, visible_rect),
		"visibility":
		{
			"viewport_size": visible_rect.size,
			"viewport_offset_from_player": visible_rect.position - origin,
			"fog_active": _main._is_fog_wave,
		},
		"visible_world":
		{
			"trees": _observe_nodes(_main._entity_spawner.neutrals, origin, visible_rect, "tree"),
			"allies": _observe_allies(player_index, origin, visible_rect),
			"materials":
			_observe_children(_main._materials_container, origin, visible_rect, "material"),
			"consumables":
			_observe_children(_main._consumables_container, origin, visible_rect, "consumable"),
			"enemy_projectiles": _make_public_motion_observations(enemy_projectiles),
			"spawn_warnings": _observe_spawn_warnings(origin, visible_rect),
		},
	}


func _observe_enemies(player: Node2D, visible_rect: Rect2) -> Array:
	var observations := []
	for enemy in _main._entity_spawner.enemies:
		if not _is_node_visible(enemy, visible_rect):
			continue
		var relative_position: Vector2 = enemy.global_position - player.global_position
		var enemy_velocity := _get_velocity(enemy)
		observations.push_back(
			{
				"_source": enemy,
				"_world_position": enemy.global_position,
				"relative_position": relative_position,
				"velocity": enemy_velocity,
				"acceleration": Vector2.ZERO,
				"motion_confidence": 0.0,
				"features":
				{
					"visual_radius": _get_visual_radius(enemy),
					"observed_speed": enemy_velocity.length(),
					"closing_speed": 0.0,
					"ranged_attack_inferred": false,
					"loot_reward_known": enemy.is_loot,
					"enemy_production_known": _can_spawn_enemies(enemy),
				},
			}
		)
	return observations


func _update_enemy_motion_features(enemies: Array, player_velocity: Vector2) -> void:
	for enemy in enemies:
		var relative_velocity: Vector2 = enemy.velocity - player_velocity
		var closing_speed := 0.0
		if enemy.relative_position.length_squared() > 0.0:
			closing_speed = -enemy.relative_position.normalized().dot(relative_velocity)
		enemy.features.observed_speed = enemy.velocity.length()
		enemy.features.closing_speed = closing_speed


func _can_spawn_enemies(enemy: Node) -> bool:
	if "enemy_to_spawn" in enemy:
		return true
	if "_all_attack_behaviors" in enemy:
		for behavior in enemy._all_attack_behaviors:
			if behavior is SpawningAttackBehavior:
				return true
	return false


func _observe_enemy_projectiles(origin: Vector2, visible_rect: Rect2) -> Array:
	var projectiles := []
	_append_visible_projectiles(projectiles, _main._enemy_projectiles, origin, visible_rect)
	return projectiles


func _append_visible_projectiles(
	observations: Array, parent: Node, origin: Vector2, visible_rect: Rect2
) -> void:
	for child in parent.get_children():
		if child is EnemyProjectile and _is_node_visible(child, visible_rect):
			var observation := _make_entity_observation(child, origin, "enemy_projectile")
			observation._source = child
			observation._world_position = child.global_position
			observation.acceleration = Vector2.ZERO
			observation.motion_confidence = 0.0
			observations.push_back(observation)
		_append_visible_projectiles(observations, child, origin, visible_rect)


func _make_public_motion_observations(observations: Array) -> Array:
	var result := []
	for observation in observations:
		var public_observation: Dictionary = observation.duplicate(true)
		public_observation.erase("_source")
		public_observation.erase("_world_position")
		result.push_back(public_observation)
	return result


func _infer_ranged_attacks(enemies: Array, projectiles: Array) -> Dictionary:
	var likely_sources := {}
	var max_distance_squared := (
		PROJECTILE_ORIGIN_INFERENCE_DISTANCE
		* PROJECTILE_ORIGIN_INFERENCE_DISTANCE
	)
	for projectile in projectiles:
		if projectile.velocity.length_squared() == 0.0:
			continue
		var best_enemy = null
		var best_distance_squared := max_distance_squared
		for enemy in enemies:
			var enemy_to_projectile: Vector2 = (
				projectile.relative_position
				- enemy.relative_position
			)
			var distance_squared := enemy_to_projectile.length_squared()
			if distance_squared >= best_distance_squared or distance_squared == 0.0:
				continue
			var moving_away := (
				enemy_to_projectile.normalized().dot(projectile.velocity.normalized())
				> 0.3
			)
			if moving_away:
				best_distance_squared = distance_squared
				best_enemy = enemy
		if best_enemy != null:
			likely_sources[best_enemy._source] = true
	return likely_sources


func _observe_allies(player_index: int, origin: Vector2, visible_rect: Rect2) -> Array:
	var observations := []
	for index in _players.size():
		if index == player_index:
			continue
		_append_observation(observations, _players[index], origin, visible_rect, "player")

	for structure in _main._entity_spawner.structures:
		_append_observation(observations, structure, origin, visible_rect, "structure")
	for pet in _main._entity_spawner.pets:
		_append_observation(observations, pet, origin, visible_rect, "pet")
	return observations


func _observe_nodes(nodes: Array, origin: Vector2, visible_rect: Rect2, kind: String) -> Array:
	var observations := []
	for node in nodes:
		_append_observation(observations, node, origin, visible_rect, kind)
	return observations


func _observe_children(
	container: Node, origin: Vector2, visible_rect: Rect2, kind: String
) -> Array:
	return _observe_nodes(container.get_children(), origin, visible_rect, kind)


func _observe_spawn_warnings(origin: Vector2, visible_rect: Rect2) -> Array:
	var observations := []
	for birth in _main._births_container.get_children():
		if not _is_node_visible(birth, visible_rect):
			continue
		observations.push_back(
			{
				"kind": "spawn_warning",
				"relative_position": birth.global_position - origin,
				# Warning color visibly distinguishes hostile, neutral, and allied births.
				"disposition": _get_spawn_disposition(birth.type),
			}
		)
	return observations


func _get_spawn_disposition(entity_type: int) -> String:
	if entity_type == EntityType.ENEMY:
		return "hostile"
	if entity_type == EntityType.NEUTRAL:
		return "neutral"
	return "allied"


func _append_observation(
	observations: Array, node, origin: Vector2, visible_rect: Rect2, kind: String
) -> void:
	if _is_node_visible(node, visible_rect):
		observations.push_back(_make_entity_observation(node, origin, kind))


func _make_entity_observation(node: Node2D, origin: Vector2, kind: String) -> Dictionary:
	return {
		"kind": kind,
		"relative_position": node.global_position - origin,
		"velocity": _get_velocity(node),
		"visual_radius": _get_visual_radius(node),
	}


func _get_velocity(node: Node2D) -> Vector2:
	if "linear_velocity" in node:
		return node.linear_velocity
	if "velocity" in node:
		return node.velocity
	return Vector2.ZERO


func _get_visual_radius(node: Node2D) -> float:
	if not "sprite" in node or not is_instance_valid(node.sprite) or node.sprite.texture == null:
		return DEFAULT_ENTITY_VISUAL_RADIUS
	var texture_size: Vector2 = node.sprite.texture.get_size()
	var visual_scale: Vector2 = node.scale * node.sprite.scale
	return max(abs(texture_size.x * visual_scale.x), abs(texture_size.y * visual_scale.y)) / 2.0


func _is_node_visible(node, visible_rect: Rect2) -> bool:
	if not is_instance_valid(node) or not node is Node2D:
		return false
	if "dead" in node and node.dead:
		return false
	if node is CanvasItem and not node.is_visible_in_tree():
		return false
	if not visible_rect.grow(_get_visual_radius(node)).has_point(node.global_position):
		return false
	return not _main._is_fog_wave or _is_in_fog_light(node.global_position)


func _is_in_fog_light(world_position: Vector2) -> bool:
	var fog = _main._fog_viewport
	if not is_instance_valid(fog):
		return false

	for player_index in _players.size():
		var player = _players[player_index]
		if not is_instance_valid(player) or player.dead:
			continue
		var bonus := 1.0
		if player_index < fog._player_bonus.size():
			bonus += fog._player_bonus[player_index]
		if player_index >= fog.player_lights.size():
			continue
		var light = fog.player_lights[player_index]
		if not is_instance_valid(light):
			continue
		var radius := _get_fog_light_radius(light, bonus)
		if player.global_position.distance_squared_to(world_position) <= radius * radius:
			return true

	for lights in [fog.fire_lights, fog.structure_and_pet_lights, fog.explosion_lights]:
		for light_source in lights:
			if not is_instance_valid(light_source):
				continue
			var radius := _get_fog_light_radius(lights[light_source], 1.0)
			if light_source.global_position.distance_squared_to(world_position) <= radius * radius:
				return true
	return false


func _get_fog_light_radius(light: Node, visibility_multiplier: float) -> float:
	var sprite: Sprite = light.get_node("player_light_in_shadow")
	var texture_size: Vector2 = sprite.texture.get_size()
	var visual_scale: Vector2 = sprite.scale
	var texture_radius := (
		max(abs(texture_size.x * visual_scale.x), abs(texture_size.y * visual_scale.y))
		/ 2.0
	)
	var fog = _main._fog_viewport
	return texture_radius * fog._base_fog_scale.x * fog._wave_fog_scale * visibility_multiplier


func _get_visible_rect() -> Rect2:
	var camera = _main._camera
	var size := Vector2(Utils.project_width, Utils.project_height) * camera.zoom
	return Rect2(camera.global_position - size / 2.0, size)


func _observe_visible_edges(origin: Vector2, visible_rect: Rect2) -> Dictionary:
	var observations := {}
	var zone_rect: Rect2 = ZoneService.get_current_zone_rect()
	for edge in ["left", "right", "top", "bottom"]:
		if not _is_edge_visible(edge, zone_rect, visible_rect):
			continue
		if edge == "left" or edge == "right":
			observations[edge] = zone_rect.position.x - origin.x
			if edge == "right":
				observations[edge] = zone_rect.end.x - origin.x
		else:
			observations[edge] = zone_rect.position.y - origin.y
			if edge == "bottom":
				observations[edge] = zone_rect.end.y - origin.y
	return observations


func _is_edge_visible(edge: String, zone_rect: Rect2, visible_rect: Rect2) -> bool:
	var closest_point := _get_closest_point_on_edge(edge, _main._camera.global_position, zone_rect)
	if not visible_rect.has_point(closest_point):
		return false
	if not _main._is_fog_wave:
		return true

	var light_sources := _players.duplicate()
	light_sources.append_array(_get_other_fog_light_sources())
	for light_source in light_sources:
		if not is_instance_valid(light_source):
			continue
		closest_point = _get_closest_point_on_edge(edge, light_source.global_position, zone_rect)
		if visible_rect.has_point(closest_point) and _is_in_fog_light(closest_point):
			return true
	return false


func _get_closest_point_on_edge(edge: String, position: Vector2, zone_rect: Rect2) -> Vector2:
	match edge:
		"left":
			return Vector2(
				zone_rect.position.x, clamp(position.y, zone_rect.position.y, zone_rect.end.y)
			)
		"right":
			return Vector2(
				zone_rect.end.x, clamp(position.y, zone_rect.position.y, zone_rect.end.y)
			)
		"top":
			return Vector2(
				clamp(position.x, zone_rect.position.x, zone_rect.end.x), zone_rect.position.y
			)
		"bottom":
			return Vector2(
				clamp(position.x, zone_rect.position.x, zone_rect.end.x), zone_rect.end.y
			)
	return Vector2.ZERO


func _get_other_fog_light_sources() -> Array:
	var fog = _main._fog_viewport
	var light_sources := []
	light_sources.append_array(fog.fire_lights.keys())
	light_sources.append_array(fog.structure_and_pet_lights.keys())
	light_sources.append_array(fog.explosion_lights.keys())
	return light_sources
