extends Reference

# Estimates the observable run value erased by player death. Health loss and
# replenishment remain health-domain concerns; this cross-domain model only
# prices currently held materials, items, and weapons through public proxies.


func estimate(observation: Dictionary) -> Dictionary:
	var player_state: Dictionary = observation.player_state
	var liquid_material_value: float = max(
		0.0, float(player_state.get("resources", {}).get("materials", 0.0))
	)
	var replacement_unit_value := _replacement_unit_value(player_state)
	var item_count: int = max(0, int(player_state.get("inventory", {}).get("item_count", 0)))
	var weapon_count: int = player_state.get("weapons", []).size()
	var equipment_replacement_value: float = replacement_unit_value * (item_count + weapon_count)
	return {
		"valuation_model": "observable_run_capital_proxy",
		"liquid_material_value": liquid_material_value,
		"equipment_replacement_unit_value": replacement_unit_value,
		"equipment_count": item_count + weapon_count,
		"equipment_replacement_value": equipment_replacement_value,
		"total_value": liquid_material_value + equipment_replacement_value,
	}


func _replacement_unit_value(player_state: Dictionary) -> float:
	# Reuse the public tier means already exposed for item-box valuation. The
	# least positive mean is a conservative proxy when item and weapon identities
	# are intentionally absent from the planning snapshot.
	var profile: Dictionary = player_state.get("item_box_item_value_profile", {})
	var result := INF
	for value in profile.get("mean_shop_price_by_tier", []):
		var price: float = max(0.0, float(value))
		if price > 0.0:
			result = min(result, price)
	return 0.0 if result == INF else result
