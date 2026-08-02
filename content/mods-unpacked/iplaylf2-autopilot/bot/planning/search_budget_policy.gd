extends Reference

# Maps estimated pressure/weapon interaction work to a bounded search budget.
# This count-based policy can later be replaced by measured frame-time feedback.

const DEFAULT_DIRECTION_COUNT := 16
const BUSY_DIRECTION_COUNT := 12
const REDUCED_DIRECTION_COUNT := 8
const BUSY_THREAT_COUNT := 140
const EXTREME_THREAT_COUNT := 320


func build(observation: Dictionary) -> Dictionary:
	var enemy_count: int = observation.enemy_tracks.size()
	var projectile_count: int = observation.visible_world.enemy_projectiles.size()
	var influence_source_count: int = (
		observation.visible_world.get("structures", []).size()
		+ observation.visible_world.get("allied_agents", []).size()
		+ _estimate_remembered_structure_count(observation)
	)
	var interceptor_count := _count_projectile_interceptors(observation)
	var interaction_load := int(
		ceil((enemy_count * influence_source_count + projectile_count * interceptor_count) / 8.0)
	)
	var planning_load := enemy_count + projectile_count + interaction_load
	var diagnostics := {
		"enemy_and_projectile_count": enemy_count + projectile_count,
		"influence_source_count": influence_source_count,
		"interaction_load": interaction_load,
		"planning_load": planning_load,
	}
	if planning_load >= EXTREME_THREAT_COUNT:
		return _with_diagnostics(
			{
				"load_class": "extreme",
				"direction_count": REDUCED_DIRECTION_COUNT,
				"forecast_sample_count": 3,
				"graph_angular_resolution_scale": 0.5,
				"detailed_prediction_limit": 4,
			},
			diagnostics
		)
	if planning_load >= BUSY_THREAT_COUNT:
		return _with_diagnostics(
			{
				"load_class": "busy",
				"direction_count": BUSY_DIRECTION_COUNT,
				"forecast_sample_count": 4,
				"graph_angular_resolution_scale": 0.75,
				"detailed_prediction_limit": 6,
			},
			diagnostics
		)
	return _with_diagnostics(
		{
			"load_class": "normal",
			"direction_count": DEFAULT_DIRECTION_COUNT,
			"forecast_sample_count": 6,
			"graph_angular_resolution_scale": 1.0,
			"detailed_prediction_limit": 10,
		},
		diagnostics
	)


func _count_projectile_interceptors(observation: Dictionary) -> int:
	var result := 0
	for ally in observation.visible_world.get("allied_agents", []):
		if ally.influence.roles.projectile_interceptor:
			result += 1
	return result


func _estimate_remembered_structure_count(observation: Dictionary) -> int:
	var effective_count := 0.0
	for remembered_entity in observation.get("remembered_entities", []):
		if remembered_entity.kind == "structure" and not remembered_entity.visible:
			effective_count += remembered_entity.existence_confidence
	return int(ceil(effective_count))


func _with_diagnostics(budget: Dictionary, diagnostics: Dictionary) -> Dictionary:
	budget.merge(diagnostics)
	return budget
