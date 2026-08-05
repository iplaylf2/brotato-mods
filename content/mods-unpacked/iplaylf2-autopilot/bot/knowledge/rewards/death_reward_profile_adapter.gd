extends Reference

# Adapts visible enemies and neutrals into one detached death-reward contract.
# Confirmed reward state and effect-behavior modifiers are sampled on the main
# thread, then detached from the scene tree before planning.


func adapt_enemy(enemy: Node) -> Dictionary:
	return _adapt(enemy, true)


func adapt_neutral(neutral: Node) -> Dictionary:
	return _adapt(neutral, false)


func _adapt(unit: Node, uses_enemy_material_drop_rules: bool) -> Dictionary:
	var profile := {
		"material_quantity": 0.0,
		"material_drop_guaranteed": not uses_enemy_material_drop_rules,
		"base_consumable_drop_chance": 0.0,
		"item_box_conditional_chance": 0.0,
		"consumable_drop_guaranteed": false,
		"guaranteed_death_products": [],
	}
	if not "stats" in unit or unit.stats == null or not unit.can_drop_loot:
		return profile

	var stats: Resource = unit.stats
	# The target-version implementations return the current deterministic base
	# quantity consumed by vanilla material settlement.
	var base_material_quantity := max(0.0, float(unit.get_stats_value()))
	var unit_material_multiplier := _unit_material_multiplier(unit)
	profile.material_quantity = max(0.0, base_material_quantity * unit_material_multiplier)
	profile.material_drop_guaranteed = (
		not uses_enemy_material_drop_rules
		or bool(stats.always_drop_consumables)
	)

	var can_drop_consumables := bool(stats.can_drop_consumables)
	if not can_drop_consumables:
		return profile
	profile.base_consumable_drop_chance = clamp(float(stats.base_drop_chance), 0.0, 1.0)
	profile.item_box_conditional_chance = clamp(float(stats.item_drop_chance), 0.0, 1.0)
	profile.consumable_drop_guaranteed = bool(stats.always_drop_consumables)
	if (
		profile.consumable_drop_guaranteed
		and profile.item_box_conditional_chance >= 1.0
		and RunData.current_wave <= RunData.nb_of_waves
	):
		# Vanilla selects the box destination inside a radius of
		# `100 + gold_spread` from the unit's death position.
		profile.guaranteed_death_products.push_back(
			{
				"kind": "item_box",
				"maximum_spawn_displacement": max(50.0, 100.0 + float(stats.gold_spread)),
			}
		)
	return profile


func _unit_material_multiplier(unit: Node) -> float:
	var modifier := 0.0
	for behavior in unit.effect_behaviors.get_children():
		modifier += float(behavior.get_gold_value_modifier())
	return 1.0 + modifier
