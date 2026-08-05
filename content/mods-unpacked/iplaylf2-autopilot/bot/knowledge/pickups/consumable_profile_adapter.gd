extends Reference

# Adapts target-version consumable data to a stable visible profile without
# exposing its content ID or scene node to planning.


func adapt(consumable: Node) -> Dictionary:
	var result := {
		"base_recovery": 0.0,
		"traits": [],
	}
	if not "consumable_data" in consumable or consumable.consumable_data == null:
		return result
	var data: Resource = consumable.consumable_data
	for effect in data.effects:
		if effect is ConsumableHealingEffect:
			result.base_recovery += effect.value
	if data.my_id_hash in [Keys.consumable_fruit_hash, Keys.consumable_poisoned_fruit_hash]:
		result.traits.push_back("fruit")
	if data.my_id_hash in [Keys.consumable_item_box_hash, Keys.consumable_legendary_item_box_hash]:
		result.traits.push_back("item_box")
	return result
