extends Reference

# Conserves finite target capacities after weapon outcomes have been accumulated.
# The forecast model owns target geometry and hit attribution. This model ensures
# that one enemy hit completes at most one enemy, each visible enemy completes at
# most once, and every completion-derived value channel represents the same
# completion equivalents across weapons and path samples.

const DamageCompletionWorkModel := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "damage_completion_work_model.gd"
	)
)

var _damage_completion_work_model: Reference = DamageCompletionWorkModel.new()


func accumulate_enemy_completion(
	outcome: Dictionary,
	coverage: Dictionary,
	expected_enemy_hits: float,
	expected_enemy_damage: float,
	critical_chance: float
) -> void:
	var damage_per_hit := (
		max(0.0, expected_enemy_damage) / expected_enemy_hits
		if expected_enemy_hits > 0.0
		else 0.0
	)
	var completion_fraction_per_hit: float = _damage_completion_work_model.completion_fraction_per_hit(
		coverage.mean_enemy_remaining_health, damage_per_hit
	)
	var completion_equivalents: float = min(
		max(0.0, coverage.covered_enemy_mass),
		max(0.0, expected_enemy_hits) * completion_fraction_per_hit
	)
	outcome.expected_enemy_completion_equivalents += completion_equivalents
	outcome.expected_enemy_reward_delta_value += (
		completion_equivalents
		* coverage.mean_enemy_reward_delta_value
	)
	outcome.expected_enemy_burden_relief_value += (
		completion_equivalents
		* coverage.mean_enemy_burden_relief_value
	)
	outcome.expected_enemy_death_consequence_value += (
		completion_equivalents
		* coverage.mean_enemy_death_consequence_value
	)
	outcome.expected_kill_weight += completion_equivalents
	outcome.expected_critical_kill_weight += (
		completion_equivalents
		* clamp(critical_chance, 0.0, 1.0)
	)


func constrain(outcome: Dictionary, target_capacity: Dictionary) -> void:
	# Contributions from several weapons and path samples share one target
	# capacity. Scale every completion-derived channel together instead of
	# independently clamping values and changing their implied target mix.
	var unconstrained_completion_equivalents: float = max(
		0.0, outcome.expected_enemy_completion_equivalents
	)
	var completion_equivalent_limit: float = min(
		max(0.0, target_capacity.enemy_count), max(0.0, outcome.expected_enemy_hits)
	)
	var conservation_scale := (
		min(1.0, completion_equivalent_limit / unconstrained_completion_equivalents)
		if unconstrained_completion_equivalents > 0.0
		else 1.0
	)
	outcome.expected_enemy_completion_equivalents *= conservation_scale
	outcome.expected_enemy_reward_delta_value *= conservation_scale
	outcome.expected_enemy_burden_relief_value *= conservation_scale
	outcome.expected_enemy_death_consequence_value *= conservation_scale
	outcome.expected_kill_weight *= conservation_scale
	outcome.expected_critical_kill_weight *= conservation_scale

	# Damage and harvest value are separate finite capacities. These bounds protect
	# against repeated path samples without manufacturing completion value.
	outcome.expected_weapon_damage = min(
		max(0.0, outcome.expected_weapon_damage), max(0.0, target_capacity.enemy_health)
	)
	outcome.expected_tree_completion_value = clamp(
		outcome.expected_tree_completion_value, 0.0, target_capacity.tree_harvest_value
	)
