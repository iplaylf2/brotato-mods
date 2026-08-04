extends Reference

# Forecasts how much of each observed target can be completed before wave cleanup.
# This is a wave-scale capacity prior for navigation and replenishment, not a
# target priority or a substitute for action-conditioned automatic targeting.

const WeaponAttackCapacityModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapons/weapon_attack_capacity_model.gd"
)
const EngagementTargetProjector := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "engagement_target_projector.gd"
	)
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

var _weapon_attack_capacity_model: Reference = WeaponAttackCapacityModel.new()
var _engagement_target_projector: Reference = EngagementTargetProjector.new()
var _enemy_health_model: Reference = EnemyHealthModel.new()
var _neutral_completion_work_model: Reference = NeutralCompletionWorkModel.new()


func forecast(observation: Dictionary) -> Dictionary:
	var remaining_seconds: float = max(0.0, observation.wave_state.seconds_remaining)
	var primary_hit_rate: float = _weapon_attack_capacity_model.expected_primary_hit_rate(
		observation.player_state.weapons
	)
	var primary_damage_rate: float = _weapon_attack_capacity_model.expected_primary_damage_rate(
		observation.player_state.weapons
	)
	var primary_hit_capacity := primary_hit_rate * remaining_seconds
	var mean_damage_per_primary_hit := (
		primary_damage_rate / primary_hit_rate
		if primary_hit_rate > 0.0
		else 0.0
	)
	var entries: Array = _completion_demands(observation, mean_damage_per_primary_hit)
	for entry in entries:
		entry.independent_completion_fraction = (
			clamp(primary_hit_capacity / entry.demand_hits, 0.0, 1.0)
			* entry.confidence
		)
	var allocation: Dictionary = _allocate_competing_capacity(entries, primary_hit_capacity)
	return {
		"completion_fraction_by_target_id": allocation.completion_fraction_by_target_id,
		"primary_hit_capacity": primary_hit_capacity,
		"independent_demand_hits": allocation.independent_demand_hits,
		"allocated_hits": allocation.allocated_hits,
		"competition_scale": allocation.competition_scale,
		"mean_damage_per_primary_hit": mean_damage_per_primary_hit,
	}


func enemy_completion_fraction(forecast: Dictionary, track: Dictionary) -> float:
	return completion_fraction(forecast, _engagement_target_projector.enemy_target_id(track))


func tree_completion_fraction(forecast: Dictionary, tree: Dictionary) -> float:
	return completion_fraction(forecast, _engagement_target_projector.tree_target_id(tree))


func completion_fraction(forecast: Dictionary, target_id: String) -> float:
	return forecast.get("completion_fraction_by_target_id", {}).get(target_id, 0.0)


func _completion_demands(observation: Dictionary, mean_damage_per_primary_hit: float) -> Array:
	var result := []
	if mean_damage_per_primary_hit > 0.0:
		for track in observation.enemy_tracks:
			result.push_back(
				{
					"target_id": _engagement_target_projector.enemy_target_id(track),
					"demand_hits":
					_enemy_health_model.remaining_health(track) / mean_damage_per_primary_hit,
					"confidence": track.recency_confidence,
				}
			)
	for tree in observation.remembered_entities:
		if tree.kind != "tree":
			continue
		var demand_hits: float = _neutral_completion_work_model.expected_hits_to_complete(
			tree,
			mean_damage_per_primary_hit,
			observation.player_state.neutral_completion.instant_on_player_hit
		)
		if demand_hits <= 0.0:
			continue
		result.push_back(
			{
				"target_id": _engagement_target_projector.tree_target_id(tree),
				"demand_hits": demand_hits,
				"confidence": tree.existence_confidence,
			}
		)
	return result


func _allocate_competing_capacity(entries: Array, primary_hit_capacity: float) -> Dictionary:
	var independent_demand_hits := 0.0
	for entry in entries:
		independent_demand_hits += entry.demand_hits * entry.independent_completion_fraction
	var competition_scale := (
		min(1.0, primary_hit_capacity / independent_demand_hits)
		if independent_demand_hits > 0.0
		else 1.0
	)
	var fractions := {}
	var allocated_hits := 0.0
	for entry in entries:
		var completion_fraction: float = entry.independent_completion_fraction * competition_scale
		var target_allocated_hits: float = entry.demand_hits * completion_fraction
		fractions[entry.target_id] = completion_fraction
		allocated_hits += target_allocated_hits
	return {
		"completion_fraction_by_target_id": fractions,
		"independent_demand_hits": independent_demand_hits,
		"allocated_hits": allocated_hits,
		"competition_scale": competition_scale,
	}
