extends Reference

# Projects every automatically attackable observation into one planning
# contract. Consumers derive pursuit value from motion, completion state, rewards,
# burdens, and death consequences.

const OpportunityPricingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/opportunity_pricing_model.gd"
)
const EnemyHealthModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/enemy_health_model.gd"
)
const NeutralCompletionWorkModel := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "neutral_completion_work_model.gd"
	)
)

var _opportunity_pricing_model: Reference = OpportunityPricingModel.new()
var _enemy_health_model: Reference = EnemyHealthModel.new()
var _neutral_completion_work_model: Reference = NeutralCompletionWorkModel.new()


func project_navigation_targets(observation: Dictionary, context: Dictionary) -> Array:
	var result := []
	for track in observation.enemy_tracks:
		if track.recency_confidence <= 0.0:
			continue
		result.push_back(_project_enemy(track, context))
	for entity in observation.remembered_entities:
		if entity.kind == "tree" and entity.existence_confidence > 0.0:
			result.push_back(_project_tree(observation, entity, context))
	return result


func project_visible_targets(observation: Dictionary, context: Dictionary) -> Array:
	var result := []
	for track in observation.enemy_tracks:
		if track.visible:
			result.push_back(_project_enemy(track, context))
	var visible_trees: Array = observation.visible_world.trees
	for tree_index in visible_trees.size():
		var tree: Dictionary = visible_trees[tree_index].duplicate(false)
		tree.existence_confidence = 1.0
		if not tree.has("memory_record_id"):
			tree.memory_record_id = -1 - tree_index
		result.push_back(_project_tree(observation, tree, context))
	return result


func enemy_target_id(track: Dictionary) -> String:
	return "enemy:%s" % track.track_id


func tree_target_id(tree: Dictionary) -> String:
	return "tree:%s" % tree.memory_record_id


func _project_enemy(track: Dictionary, context: Dictionary) -> Dictionary:
	var value := _enemy_value(context, track)
	var maximum_health: float = max(1.0, float(track.behavior_profile.durability.maximum_health))
	var remaining_health: float = _enemy_health_model.remaining_health(track)
	return {
		"target_id": enemy_target_id(track),
		"motion_track": track,
		"relative_position": track.relative_position,
		"confidence": track.recency_confidence,
		"radius": track.last_measurement.visual_radius,
		"completion":
		{
			"completed": remaining_health <= 0.0,
			"health": {"maximum": maximum_health, "remaining": remaining_health},
			"hit_limit": {"maximum": 0.0, "remaining": 0.0},
		},
		"value": value,
		"weapon_response":
		{
			"health_damage_applies": true,
			"hit_limit_progress_per_hit": 0.0,
		},
	}


func _project_tree(observation: Dictionary, tree: Dictionary, context: Dictionary) -> Dictionary:
	var health_inventory_value: Dictionary = context.state_factors.health_inventory_value
	var reward_delta_value: float = _opportunity_pricing_model.tree_destruction_value(
		observation, tree, health_inventory_value
	)
	var target_id := tree_target_id(tree)
	var remaining_hits_to_limit: float = _neutral_completion_work_model.remaining_hits_to_limit(
		tree
	)
	var maximum_health: float = max(
		1.0, float(tree.destructible_profile.destruction.maximum_health)
	)
	var remaining_health: float = _neutral_completion_work_model.remaining_health(tree)
	var hit_limit: float = tree.destructible_profile.destruction.hit_limit
	return {
		"target_id": target_id,
		"motion_track": _stationary_motion_track(tree),
		"relative_position": tree.relative_position,
		"confidence": tree.existence_confidence,
		"radius": tree.visual_radius,
		"completion":
		{
			"completed": remaining_health <= 0.0 or remaining_hits_to_limit <= 0.0,
			"health": {"maximum": maximum_health, "remaining": remaining_health},
			"hit_limit": {"maximum": hit_limit, "remaining": remaining_hits_to_limit},
		},
		"value":
		{
			"reward_delta_value": reward_delta_value,
			"burden_relief_value": 0.0,
			"death_consequence_value": 0.0,
			"net_completion_value": reward_delta_value,
		},
		"weapon_response":
		{
			"health_damage_applies": true,
			"hit_limit_progress_per_hit":
			(
				remaining_hits_to_limit
				if observation.player_state.neutral_completion.instant_on_player_hit
				else 1.0
			),
		},
	}


func _enemy_value(context: Dictionary, track: Dictionary) -> Dictionary:
	return context.enemy_completion_value_ledger.entries_by_track_id[track.track_id].duplicate(
		false
	)


func _stationary_motion_track(tree: Dictionary) -> Dictionary:
	return {
		"track_id": -1,
		"relative_position": tree.relative_position,
		"estimated_velocity": Vector2.ZERO,
		"estimated_acceleration": Vector2.ZERO,
		"motion_confidence": 1.0,
		"behavior_profile":
		{
			"target_position_response":
			{
				"responds_to_target_position": false,
				"movement_speed": 0.0,
			},
			"charge_attack": {"active": false},
		},
	}
