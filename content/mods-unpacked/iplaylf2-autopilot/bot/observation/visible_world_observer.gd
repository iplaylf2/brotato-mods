extends Reference

# Reads the camera- and fog-visible world plus health and survival exposed by
# vanilla's persistent enemy health bars. Scene objects in internal observations
# are private continuity tokens and never become public.

const DEFAULT_ENTITY_VISUAL_RADIUS := 32.0
const PROJECTILE_ORIGIN_INFERENCE_DISTANCE := 120.0
const BIRTH_TIMER_TICKS_PER_SECOND := 60.0
const ObservedMotionEstimator := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/observation/observed_motion_estimator.gd"
)
const EnemyMechanicCompiler := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/enemies/enemy_mechanic_compiler.gd"
)
const EnemyAttackTimingObserver := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/observation/enemy_attack_timing_observer.gd"
)
const StructureMechanicCompiler := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/structures/structure_mechanic_compiler.gd"
)
const AllyMechanicCompiler := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/allies/ally_mechanic_compiler.gd"
)
const ConsumableProfileAdapter := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/pickups/consumable_profile_adapter.gd"
)
const NeutralMechanicCompiler := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/neutrals/neutral_mechanic_compiler.gd"
)
const ProjectileMotionCompiler := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/projectiles/projectile_motion_compiler.gd"
)
const CollisionShapeRadiusAdapter := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/collision_shape_radius_adapter.gd"
)

var _main: Node
var _players: Array
var _motion_estimators := []
var _enemy_mechanic_compiler: Reference = EnemyMechanicCompiler.new()
var _enemy_attack_timing_observer: Reference = EnemyAttackTimingObserver.new()
var _structure_mechanic_compiler: Reference = StructureMechanicCompiler.new()
var _ally_mechanic_compiler: Reference = AllyMechanicCompiler.new()
var _consumable_profile_adapter: Reference = ConsumableProfileAdapter.new()
var _neutral_mechanic_compiler: Reference = NeutralMechanicCompiler.new()
var _projectile_motion_compiler: Reference = ProjectileMotionCompiler.new()
var _collision_shape_radius_adapter: Reference = CollisionShapeRadiusAdapter.new()


func _init(main: Node, players: Array) -> void:
	_main = main
	_players = players
	for _player in players:
		_motion_estimators.push_back(ObservedMotionEstimator.new())


func observe(player_index: int, player: Node2D, delta_seconds: float) -> Dictionary:
	var visible_rect := _get_visible_rect()
	var origin: Vector2 = player.global_position
	var enemies_by_disposition := _partition_enemy_nodes(
		_main._entity_spawner.get_all_enemies(true), _main._entity_spawner.get_all_enemies(false)
	)
	var enemy_batch := _observe_enemy_batch(player, visible_rect, enemies_by_disposition.hostile)
	var enemies: Array = enemy_batch.enemy_observations
	var enemy_projectiles := _observe_enemy_projectiles(origin, visible_rect, enemies)
	var trees := _observe_trees(origin, visible_rect)
	var materials := _observe_materials(origin, visible_rect)
	var consumables := _observe_consumables(origin, visible_rect)
	var structures := _observe_structures(origin, visible_rect)
	var allied_agents := _observe_allied_agents(
		player_index, origin, visible_rect, enemies_by_disposition.allied
	)
	var moving_observations := []
	moving_observations.append_array(enemies)
	moving_observations.append_array(enemy_projectiles)
	moving_observations.append_array(structures)
	moving_observations.append_array(allied_agents)
	_motion_estimators[player_index].update(moving_observations, delta_seconds)
	var projectile_emissions_by_source := _infer_projectile_emissions(enemies, enemy_projectiles)
	for enemy in enemies:
		var emitted_projectiles: Array = projectile_emissions_by_source.get(enemy._source, [])
		enemy.features.ranged_attack_inferred = not emitted_projectiles.empty()
		enemy.features.visible_removable_projectile_damage = 0.0
		var projectile_attack: Dictionary = enemy.features.stable_mechanic_profile.projectile_attack
		if projectile_attack.get("all_projectiles_removed_on_death", false):
			for projectile in emitted_projectiles:
				enemy.features.visible_removable_projectile_damage += projectile.contact_damage
	return {
		# Internal inputs for observed world memory; never expose them through the service.
		"enemy_observations": enemies,
		"non_hostile_enemy_sources": enemies_by_disposition.allied,
		"persistent_enemy_health_observations": enemy_batch.persistent_health_observations,
		"persistent_enemy_health_snapshot_complete": ProgressData.settings.hp_bar_on_bosses,
		"entity_memory_observations": trees + materials + consumables + structures,
		"visible_edges": _observe_visible_edges(origin, visible_rect),
		"visibility":
		{
			"viewport_size": visible_rect.size,
			"viewport_offset_from_player": visible_rect.position - origin,
			"fog_active": _main._is_fog_wave,
		},
		"visible_world":
		{
			"trees": _make_public_motion_observations(trees),
			"allied_agents": _make_public_motion_observations(allied_agents),
			"structures": _make_public_motion_observations(structures),
			"materials": _make_public_motion_observations(materials),
			"consumables": _make_public_motion_observations(consumables),
			"enemy_projectiles": _make_public_motion_observations(enemy_projectiles),
			"spawn_warnings": _observe_spawn_warnings(origin, visible_rect),
		},
	}


func _partition_enemy_nodes(all_enemies: Array, hostile_enemies: Array) -> Dictionary:
	var allied := []
	var hostile_instance_ids := {}
	for enemy in hostile_enemies:
		hostile_instance_ids[enemy.get_instance_id()] = true
	for enemy in all_enemies:
		if not hostile_instance_ids.has(enemy.get_instance_id()):
			allied.push_back(enemy)
	return {"hostile": hostile_enemies, "allied": allied}


func _observe_enemy_batch(
	player: Node2D, visible_rect: Rect2, hostile_enemies: Array
) -> Dictionary:
	var observations := []
	var persistent_health_observations := []
	# The spawner query merges bosses with ordinary enemies. The caller has already
	# restricted that complete set to vanilla's current automatic-weapon target domain.
	for enemy in hostile_enemies:
		if _has_persistent_health_observation(enemy):
			persistent_health_observations.push_back(
				{
					"_source": enemy,
					"alive": not enemy.dead,
					"health": _observe_health(enemy),
				}
			)
		if not _is_node_visible(enemy, visible_rect):
			continue
		var relative_position: Vector2 = enemy.global_position - player.global_position
		var enemy_velocity := _get_velocity(enemy)
		observations.push_back(
			{
				"_source": enemy,
				"_world_position": enemy.global_position,
				"_velocity_is_authoritative": _has_authoritative_velocity(enemy),
				"relative_position": relative_position,
				"velocity": enemy_velocity,
				"acceleration": Vector2.ZERO,
				"motion_confidence": 0.0,
				"features":
				{
					"visual_radius": _get_visual_radius(enemy),
					# This is mutable battle state, so it belongs to observation rather
					# than the stable mechanic compiler. Ordinary targets retain this last
					# visual value; a persistent health observation may refresh it off-screen.
					"health": _observe_health(enemy),
					"persistent_health_observation": _has_persistent_health_observation(enemy),
					"stable_mechanic_profile": _enemy_mechanic_compiler.compile(enemy),
					"next_volley_window":
					_enemy_attack_timing_observer.observe_projectile_volley_window(enemy),
					"next_charge_attack_window":
					_enemy_attack_timing_observer.observe_charge_attack_window(enemy),
					"ranged_attack_inferred": false,
				},
			}
		)
	return {
		"enemy_observations": observations,
		"persistent_health_observations": persistent_health_observations,
	}


func _has_persistent_health_observation(enemy: Node) -> bool:
	return ProgressData.settings.hp_bar_on_bosses and enemy is Boss


func _observe_health(enemy: Node) -> Dictionary:
	var maximum_health := 1.0
	var current_health := 1.0
	if "max_stats" in enemy and enemy.max_stats != null and "health" in enemy.max_stats:
		maximum_health = max(1.0, float(enemy.max_stats.health))
	if "current_stats" in enemy and enemy.current_stats != null and "health" in enemy.current_stats:
		current_health = clamp(float(enemy.current_stats.health), 0.0, maximum_health)
	return {
		"current": current_health,
		"maximum": maximum_health,
		"ratio": current_health / maximum_health,
	}


func _observe_enemy_projectiles(origin: Vector2, visible_rect: Rect2, enemies: Array) -> Array:
	var projectiles := []
	_append_visible_projectiles(projectiles, _main._enemy_projectiles, origin, visible_rect)
	# Some vanilla hazards (for example Corrupted Tree and Predator orbitals) are
	# enemy children rather than children of Main.EnemyProjectiles.
	for enemy in enemies:
		_append_visible_projectiles(projectiles, enemy._source, origin, visible_rect)
	return projectiles


func _append_visible_projectiles(
	observations: Array, parent: Node, origin: Vector2, visible_rect: Rect2
) -> void:
	for child in parent.get_children():
		if child is EnemyProjectile and _is_node_visible(child, visible_rect):
			var observation := _make_entity_observation(child, origin, "enemy_projectile")
			var collision: CollisionShape2D = child.get_node("Hitbox/Collision")
			observation._source = child
			observation.relative_position = collision.global_position - origin
			observation._world_position = collision.global_position
			observation.acceleration = Vector2.ZERO
			observation.motion_confidence = 0.0
			observation.motion_model = _projectile_motion_compiler.compile(child)
			observation.contact_damage = max(0.0, float(child.get_damage()))
			observation.contact_radius = (_collision_shape_radius_adapter.adapt_collision_centered_radius(
				collision
			))
			observations.push_back(observation)
		_append_visible_projectiles(observations, child, origin, visible_rect)


func _make_public_motion_observations(observations: Array) -> Array:
	var result := []
	for observation in observations:
		var public_observation: Dictionary = observation.duplicate(true)
		public_observation.erase("_source")
		public_observation.erase("_world_position")
		public_observation.erase("_velocity_is_authoritative")
		result.push_back(public_observation)
	return result


func _infer_projectile_emissions(enemies: Array, projectiles: Array) -> Dictionary:
	var projectiles_by_source := {}
	var max_distance_squared := (
		PROJECTILE_ORIGIN_INFERENCE_DISTANCE
		* PROJECTILE_ORIGIN_INFERENCE_DISTANCE
	)
	for projectile in projectiles:
		var best_enemy := {}
		var best_distance_squared := max_distance_squared
		for enemy in enemies:
			if enemy._source.is_a_parent_of(projectile._source):
				best_enemy = enemy
				break
			if projectile.velocity.length_squared() == 0.0:
				continue
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
		if not best_enemy.empty():
			_append_projectile_emission(projectiles_by_source, best_enemy._source, projectile)
	return projectiles_by_source


func _append_projectile_emission(
	projectiles_by_source: Dictionary, source: Object, projectile: Dictionary
) -> void:
	if not projectiles_by_source.has(source):
		projectiles_by_source[source] = []
	projectiles_by_source[source].push_back(projectile)


func _observe_allied_agents(
	player_index: int, origin: Vector2, visible_rect: Rect2, converted_enemies: Array
) -> Array:
	var observations := []
	for index in _players.size():
		if index == player_index:
			continue
		_append_allied_agent(
			observations, _players[index], origin, visible_rect, "player", index, "party_member"
		)

	for pet in _main._entity_spawner.pets:
		var owner_index: int = pet.player_index if "player_index" in pet else -1
		var relationship := "owned_companion" if owner_index == player_index else "party_companion"
		_append_allied_agent(
			observations, pet, origin, visible_rect, "pet", owner_index, relationship
		)
	for enemy in converted_enemies:
		var owner_index: int = enemy.get_charmed_by_player_index()
		var relationship := (
			"converted_companion"
			if owner_index == player_index
			else "party_converted_companion"
		)
		_append_allied_agent(
			observations, enemy, origin, visible_rect, "converted_enemy", owner_index, relationship
		)
	return observations


func _append_allied_agent(
	observations: Array,
	agent,
	origin: Vector2,
	visible_rect: Rect2,
	kind: String,
	owner_player_index: int,
	relationship: String
) -> void:
	if not _is_node_visible(agent, visible_rect):
		return
	var observation := _make_entity_observation(agent, origin, kind)
	observation._source = agent
	observation._world_position = agent.global_position
	observation.acceleration = Vector2.ZERO
	observation.motion_confidence = 0.0
	observation.owner_player_index = owner_player_index
	observation.relationship = relationship
	observation.influence = _ally_mechanic_compiler.compile(agent, kind)
	observation.collision_radius = (_collision_shape_radius_adapter.adapt_owner_centered_radius(
		agent, "Collision"
	))
	if kind == "player":
		observation.pickup = _get_player_pickup_geometry(agent)
		observation.move_speed = agent.get_move_speed()
	observations.push_back(observation)


func _get_player_pickup_geometry(player: Node) -> Dictionary:
	var attract_shape: Shape2D = player._item_attract_area.get_node("CollisionShape2D").shape
	var pickup_shape: Shape2D = player._item_pickup_area.get_node("CollisionShape2D").shape
	return {
		"attraction_radius": attract_shape.radius,
		"collection_radius": pickup_shape.radius,
	}


func _observe_structures(origin: Vector2, visible_rect: Rect2) -> Array:
	var observations := []
	for structure in _main._entity_spawner.structures:
		if not _is_node_visible(structure, visible_rect):
			continue
		var observation := _make_entity_observation(structure, origin, "structure")
		observation._source = structure
		observation._world_position = structure.global_position
		observation.acceleration = Vector2.ZERO
		observation.motion_confidence = 0.0
		observation.influence = _structure_mechanic_compiler.compile(structure)
		observations.push_back(observation)
	return observations


func _observe_nodes(nodes: Array, origin: Vector2, visible_rect: Rect2, kind: String) -> Array:
	var observations := []
	for node in nodes:
		_append_observation(observations, node, origin, visible_rect, kind)
	return observations


func _observe_trees(origin: Vector2, visible_rect: Rect2) -> Array:
	var observations := []
	for tree in _main._entity_spawner.neutrals:
		if not _is_node_visible(tree, visible_rect):
			continue
		var observation := _make_entity_observation(tree, origin, "tree")
		observation._source = tree
		observation._world_position = tree.global_position
		observation.destructible_profile = _neutral_mechanic_compiler.compile(tree)
		observation.destruction_state = _observe_destruction_state(
			tree, observation.destructible_profile
		)
		observations.push_back(observation)
	return observations


func _observe_destruction_state(tree: Node, destructible_profile: Dictionary) -> Dictionary:
	var hit_limit: float = destructible_profile.destruction.hit_limit
	var received_hits := 0.0
	if "current_number_of_hits" in tree:
		received_hits = clamp(float(tree.current_number_of_hits), 0.0, hit_limit)
	return {
		"received_hits": received_hits,
		"remaining_hits_to_limit": max(0.0, hit_limit - received_hits),
		"health": _observe_health(tree),
	}


func _observe_children(
	container: Node, origin: Vector2, visible_rect: Rect2, kind: String
) -> Array:
	return _observe_nodes(container.get_children(), origin, visible_rect, kind)


func _observe_consumables(origin: Vector2, visible_rect: Rect2) -> Array:
	var observations := []
	for consumable in _main._consumables_container.get_children():
		if not _is_node_visible(consumable, visible_rect):
			continue
		var observation := _make_entity_observation(consumable, origin, "consumable")
		observation._source = consumable
		observation._world_position = consumable.global_position
		observation.pickup_profile = _consumable_profile_adapter.adapt(consumable)
		observations.push_back(observation)
	return observations


func _observe_materials(origin: Vector2, visible_rect: Rect2) -> Array:
	var observations := []
	for material in _main._materials_container.get_children():
		if not _is_node_visible(material, visible_rect):
			continue
		var observation := _make_entity_observation(material, origin, "material")
		observation._source = material
		observation._world_position = material.global_position
		# Gold.value is the exact quantity consumed by vanilla pickup and wave-end
		# settlement. It is already determined when the visible material exists.
		observation.material_quantity = max(0.0, float(material.value))
		observations.push_back(observation)
	return observations


func _observe_spawn_warnings(origin: Vector2, visible_rect: Rect2) -> Array:
	var observations := []
	for birth in _main._births_container.get_children():
		if not _is_node_visible(birth, visible_rect):
			continue
		var disposition := _get_spawn_disposition(birth.type)
		# This countdown is the current phase that directly drives the visible,
		# accelerating flicker. Reading its authoritative value preserves the
		# presented state; it does not reveal the queued entity or a future draw.
		var resolution_window := _exact_tick_window(birth._current_time_before_spawn)
		observations.push_back(
			{
				"kind": "spawn_warning",
				"relative_position": birth.global_position - origin,
				# Warning color visibly distinguishes hostile, neutral, and allied births.
				"disposition": disposition,
				"interaction_radius":
				_collision_shape_radius_adapter.adapt_owner_centered_radius(
					birth, "%CollisionShape2D"
				),
				"resolution_window": resolution_window,
				# Vanilla relocates and restarts only hostile births when the player
				# occupies the visible overlap area at resolution.
				"player_overlap_defers_spawn": disposition == "hostile",
			}
		)
	return observations


func _exact_tick_window(remaining_ticks: float) -> Dictionary:
	var seconds := max(0.0, float(remaining_ticks)) / BIRTH_TIMER_TICKS_PER_SECOND
	return {
		"is_exact": true,
		"earliest_seconds": seconds,
		"latest_seconds": seconds,
	}


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
		var observation := _make_entity_observation(node, origin, kind)
		observation._source = node
		observation._world_position = node.global_position
		observations.push_back(observation)


func _make_entity_observation(node: Node2D, origin: Vector2, kind: String) -> Dictionary:
	return {
		"_velocity_is_authoritative": _has_authoritative_velocity(node),
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


func _has_authoritative_velocity(node: Node2D) -> bool:
	return "linear_velocity" in node or "velocity" in node


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
	var fog: Node = _main._fog_viewport
	if not is_instance_valid(fog):
		return false

	for player_index in _players.size():
		var player: Node2D = _players[player_index]
		if not is_instance_valid(player) or player.dead:
			continue
		var bonus := 1.0
		if player_index < fog._player_bonus.size():
			bonus += fog._player_bonus[player_index]
		if player_index >= fog.player_lights.size():
			continue
		var light: Node = fog.player_lights[player_index]
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
	var fog: Node = _main._fog_viewport
	return texture_radius * fog._base_fog_scale.x * fog._wave_fog_scale * visibility_multiplier


func _get_visible_rect() -> Rect2:
	var camera: Camera2D = _main._camera
	var size: Vector2 = Vector2(Utils.project_width, Utils.project_height) * camera.zoom
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
	var fog: Node = _main._fog_viewport
	var light_sources := []
	light_sources.append_array(fog.fire_lights.keys())
	light_sources.append_array(fog.structure_and_pet_lights.keys())
	light_sources.append_array(fog.explosion_lights.keys())
	return light_sources
