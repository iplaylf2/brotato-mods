extends Reference

# Conserves finite target capacities after weapon outcomes have been accumulated.
# Enemy attack work remains keyed by target until every weapon and path sample has
# contributed. Settlement then keeps hits, damage, completion, and value attached
# to the same target. Tree harvest value retains its separate aggregate bound.

const DamageCompletionWorkModel := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "damage_completion_work_model.gd"
	)
)

var _damage_completion_work_model: Reference = DamageCompletionWorkModel.new()


func accumulate_target_work(
	work_by_target_id: Dictionary,
	target: Dictionary,
	expected_hits: float,
	expected_damage: float,
	critical_chance: float
) -> void:
	var hits := max(0.0, expected_hits)
	var damage := max(0.0, expected_damage)
	if hits <= 0.0 or damage <= 0.0:
		return
	var target_id: String = target.target_id
	if not work_by_target_id.has(target_id):
		work_by_target_id[target_id] = {
			"target": target,
			"expected_hits": 0.0,
			"expected_damage": 0.0,
			"critical_hit_mass": 0.0,
		}
	var work: Dictionary = work_by_target_id[target_id]
	work.expected_hits += hits
	work.expected_damage += damage
	work.critical_hit_mass += hits * clamp(critical_chance, 0.0, 1.0)


func settle_enemy_work(outcome: Dictionary, work_by_target_id: Dictionary) -> void:
	var conserved_hits := 0.0
	var conserved_damage := 0.0
	for work in work_by_target_id.values():
		var target: Dictionary = work.target
		var expected_hits: float = max(0.0, work.expected_hits)
		var remaining_health: float = max(0.0, target.completion.health.remaining)
		var expected_damage: float = max(0.0, work.expected_damage)
		conserved_hits += expected_hits
		conserved_damage += min(expected_damage, remaining_health)
		if expected_hits <= 0.0 or expected_damage <= 0.0 or remaining_health <= 0.0:
			continue
		var damage_per_hit := expected_damage / expected_hits
		var required_hits: float = _damage_completion_work_model.hits_to_complete(
			remaining_health, damage_per_hit
		)
		var completion: float = _damage_completion_work_model.completion_probability(
			expected_hits, required_hits
		)
		if completion <= 0.0:
			continue
		var value: Dictionary = target.value
		outcome.expected_enemy_completion_equivalents += completion
		outcome.expected_enemy_reward_delta_value += completion * value.reward_delta_value
		outcome.expected_enemy_burden_relief_value += completion * value.burden_relief_value
		outcome.expected_enemy_death_consequence_value += (
			completion
			* value.death_consequence_value
		)
		outcome.expected_kill_weight += completion
		outcome.expected_critical_kill_weight += (
			completion
			* clamp(work.critical_hit_mass / expected_hits, 0.0, 1.0)
		)
	outcome.expected_enemy_hits = conserved_hits
	outcome.expected_weapon_damage = conserved_damage


func constrain_tree_value(outcome: Dictionary, maximum_tree_value: float) -> void:
	# Tree completion remains a separate value unit and cannot consume enemy work.
	outcome.expected_tree_completion_value = clamp(
		outcome.expected_tree_completion_value, 0.0, maximum_tree_value
	)
