extends Reference

# Allocates target-independent primary-hit capacity across enemies and trees
# that compete for automatic attacks before wave cleanup. Reward pricing and
# replenishment forecasting consume the same completion ledger.

const WeaponAttackCapacityModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapons/weapon_attack_capacity_model.gd"
)

var _weapon_attack_capacity_model: Reference = WeaponAttackCapacityModel.new()


func allocate(observation: Dictionary) -> Dictionary:
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
	var entries := []
	if mean_damage_per_primary_hit > 0.0:
		for track in observation.enemy_tracks:
			var health: float = track.behavior_profile.durability.maximum_health
			var required_hits := health / mean_damage_per_primary_hit
			entries.push_back(
				{
					"kind": "enemy",
					"id": track.track_id,
					"required_hits": required_hits,
					"independent_likelihood":
					(
						clamp(primary_hit_capacity / required_hits, 0.0, 1.0)
						* track.recency_confidence
					),
				}
			)
	for tree in observation.remembered_entities:
		if tree.kind != "tree":
			continue
		var required_hits: float = tree.destructible_profile.destruction.required_hits
		entries.push_back(
			{
				"kind": "tree",
				"id": tree.memory_record_id,
				"required_hits": required_hits,
				"independent_likelihood":
				clamp(primary_hit_capacity / required_hits, 0.0, 1.0) * tree.existence_confidence,
			}
		)
	var allocation: Dictionary = _allocate_competing_completion(entries, primary_hit_capacity)
	for track in observation.enemy_tracks:
		if not allocation.enemy_completion_likelihood_by_track_id.has(track.track_id):
			allocation.enemy_completion_likelihood_by_track_id[track.track_id] = 0.0
	return {
		"enemy_completion_likelihood_by_track_id":
		allocation.enemy_completion_likelihood_by_track_id,
		"tree_completion_likelihood_by_memory_record_id":
		allocation.tree_completion_likelihood_by_memory_record_id,
		"primary_hit_capacity": primary_hit_capacity,
		"independent_demand_hits": allocation.independent_demand_hits,
		"allocated_hits": allocation.allocated_hits,
		"enemy_allocated_hits": allocation.enemy_allocated_hits,
		"tree_allocated_hits": allocation.tree_allocated_hits,
		"competition_scale": allocation.competition_scale,
		"mean_damage_per_primary_hit": mean_damage_per_primary_hit,
	}


func enemy_completion_likelihood(completion_ledger: Dictionary, track: Dictionary) -> float:
	return completion_ledger.enemy_completion_likelihood_by_track_id[track.track_id]


func tree_completion_likelihood(completion_ledger: Dictionary, tree: Dictionary) -> float:
	return completion_ledger.tree_completion_likelihood_by_memory_record_id[tree.memory_record_id]


func _allocate_competing_completion(entries: Array, primary_hit_capacity: float) -> Dictionary:
	var independent_demand_hits := 0.0
	for entry in entries:
		independent_demand_hits += entry.required_hits * entry.independent_likelihood
	var competition_scale := (
		min(1.0, primary_hit_capacity / independent_demand_hits)
		if independent_demand_hits > 0.0
		else 1.0
	)
	var enemy_completion_likelihood_by_track_id := {}
	var tree_completion_likelihood_by_memory_record_id := {}
	var enemy_allocated_hits := 0.0
	var tree_allocated_hits := 0.0
	for entry in entries:
		var likelihood: float = entry.independent_likelihood * competition_scale
		var allocated_hits: float = entry.required_hits * likelihood
		if entry.kind == "enemy":
			enemy_completion_likelihood_by_track_id[entry.id] = likelihood
			enemy_allocated_hits += allocated_hits
		else:
			tree_completion_likelihood_by_memory_record_id[entry.id] = likelihood
			tree_allocated_hits += allocated_hits
	return {
		"enemy_completion_likelihood_by_track_id": enemy_completion_likelihood_by_track_id,
		"tree_completion_likelihood_by_memory_record_id":
		tree_completion_likelihood_by_memory_record_id,
		"independent_demand_hits": independent_demand_hits,
		"allocated_hits": enemy_allocated_hits + tree_allocated_hits,
		"enemy_allocated_hits": enemy_allocated_hits,
		"tree_allocated_hits": tree_allocated_hits,
		"competition_scale": competition_scale,
	}
