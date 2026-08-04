extends Reference

# Forecasts how much of each observed target can be completed before wave cleanup. This is
# a wave-scale capacity prior for navigation and replenishment, not a target
# priority and not a substitute for action-conditioned automatic targeting.

const WeaponAttackCapacityModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapons/weapon_attack_capacity_model.gd"
)
const EnemyHealthModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/enemy_health_model.gd"
)
const NeutralDestructionWorkModel := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "neutral_destruction_work_model.gd"
	)
)

var _weapon_attack_capacity_model: Reference = WeaponAttackCapacityModel.new()
var _enemy_health_model: Reference = EnemyHealthModel.new()
var _neutral_destruction_work_model: Reference = NeutralDestructionWorkModel.new()


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
	var entries := []
	if mean_damage_per_primary_hit > 0.0:
		for track in observation.enemy_tracks:
			var required_hits: float = (
				_enemy_health_model.remaining_health(track)
				/ mean_damage_per_primary_hit
			)
			entries.push_back(
				{
					"kind": "enemy",
					"id": track.track_id,
					"required_hits": required_hits,
					"independent_completion_fraction":
					(
						clamp(primary_hit_capacity / required_hits, 0.0, 1.0)
						* track.recency_confidence
					),
				}
			)
	for tree in observation.remembered_entities:
		if tree.kind != "tree":
			continue
		var remaining_hits: float = _neutral_destruction_work_model.remaining_hits(tree)
		if remaining_hits <= 0.0:
			continue
		entries.push_back(
			{
				"kind": "tree",
				"id": tree.memory_record_id,
				"required_hits": remaining_hits,
				"independent_completion_fraction":
				clamp(primary_hit_capacity / remaining_hits, 0.0, 1.0) * tree.existence_confidence,
			}
		)
	var allocation: Dictionary = _allocate_competing_capacity(entries, primary_hit_capacity)
	for track in observation.enemy_tracks:
		if not allocation.enemy_completion_fraction_by_track_id.has(track.track_id):
			allocation.enemy_completion_fraction_by_track_id[track.track_id] = 0.0
	for tree in observation.remembered_entities:
		if (
			tree.kind == "tree"
			and not allocation.tree_completion_fraction_by_memory_record_id.has(
				tree.memory_record_id
			)
		):
			allocation.tree_completion_fraction_by_memory_record_id[tree.memory_record_id] = 0.0
	return {
		"enemy_completion_fraction_by_track_id": allocation.enemy_completion_fraction_by_track_id,
		"tree_completion_fraction_by_memory_record_id":
		allocation.tree_completion_fraction_by_memory_record_id,
		"primary_hit_capacity": primary_hit_capacity,
		"independent_demand_hits": allocation.independent_demand_hits,
		"allocated_hits": allocation.allocated_hits,
		"enemy_allocated_hits": allocation.enemy_allocated_hits,
		"tree_allocated_hits": allocation.tree_allocated_hits,
		"competition_scale": allocation.competition_scale,
		"mean_damage_per_primary_hit": mean_damage_per_primary_hit,
	}


func enemy_completion_fraction(forecast: Dictionary, track: Dictionary) -> float:
	return forecast.enemy_completion_fraction_by_track_id[track.track_id]


func tree_completion_fraction(forecast: Dictionary, tree: Dictionary) -> float:
	return forecast.tree_completion_fraction_by_memory_record_id[tree.memory_record_id]


func _allocate_competing_capacity(entries: Array, primary_hit_capacity: float) -> Dictionary:
	var independent_demand_hits := 0.0
	for entry in entries:
		independent_demand_hits += entry.required_hits * entry.independent_completion_fraction
	var competition_scale := (
		min(1.0, primary_hit_capacity / independent_demand_hits)
		if independent_demand_hits > 0.0
		else 1.0
	)
	var enemy_fractions := {}
	var tree_fractions := {}
	var enemy_allocated_hits := 0.0
	var tree_allocated_hits := 0.0
	for entry in entries:
		var completion_fraction: float = entry.independent_completion_fraction * competition_scale
		var allocated_hits: float = entry.required_hits * completion_fraction
		if entry.kind == "enemy":
			enemy_fractions[entry.id] = completion_fraction
			enemy_allocated_hits += allocated_hits
		else:
			tree_fractions[entry.id] = completion_fraction
			tree_allocated_hits += allocated_hits
	return {
		"enemy_completion_fraction_by_track_id": enemy_fractions,
		"tree_completion_fraction_by_memory_record_id": tree_fractions,
		"independent_demand_hits": independent_demand_hits,
		"allocated_hits": enemy_allocated_hits + tree_allocated_hits,
		"enemy_allocated_hits": enemy_allocated_hits,
		"tree_allocated_hits": tree_allocated_hits,
		"competition_scale": competition_scale,
	}
