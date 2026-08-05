extends Reference

# Adapts Brotato 1.1.15.4's unlocked item pools and tier distribution into a pure
# shop-price expectation profile. No random draw is consumed; planning uses the
# price as an item-value proxy before the future item is generated.

const ITEM_TIER_DATA := [
	{"minimum_wave": 0, "base_chance": 1.0, "wave_bonus": 0.0, "maximum_chance": 1.0},
	{"minimum_wave": 0, "base_chance": 0.0, "wave_bonus": 0.06, "maximum_chance": 0.6},
	{"minimum_wave": 2, "base_chance": 0.0, "wave_bonus": 0.02, "maximum_chance": 0.25},
	{"minimum_wave": 6, "base_chance": 0.0, "wave_bonus": 0.0023, "maximum_chance": 0.08},
]

var _mean_shop_price_cache := {}


func adapt(player_index: int, luck: float) -> Dictionary:
	var wave: int = max(1, RunData.current_wave)
	return {
		"tier_probabilities": tier_probabilities(wave, luck / 100.0),
		"mean_shop_price_by_tier": _mean_shop_prices(wave, player_index),
	}


func tier_probabilities(wave: int, luck: float) -> Array:
	var result := [0.0, 0.0, 0.0, 0.0]
	var claimed_roll_mass := 0.0
	for tier in range(ITEM_TIER_DATA.size() - 1, -1, -1):
		var data: Dictionary = ITEM_TIER_DATA[tier]
		var wave_base_chance: float = max(
			0.0, float((wave - 1) - data.minimum_wave) * data.wave_bonus
		)
		var adjusted_wave_chance := (
			wave_base_chance * (1.0 + luck)
			if luck >= 0.0
			else wave_base_chance / (1.0 + abs(luck))
		)
		var threshold: float = clamp(
			data.base_chance + adjusted_wave_chance, 0.0, data.maximum_chance
		)
		result[tier] = max(0.0, threshold - claimed_roll_mass)
		claimed_roll_mass = max(claimed_roll_mass, threshold)
	return result


func _mean_shop_prices(wave: int, player_index: int) -> Array:
	var cache_key := _mean_shop_price_cache_key(wave, player_index)
	if _mean_shop_price_cache.has(cache_key):
		return _mean_shop_price_cache[cache_key]
	var result := []
	for tier in ITEM_TIER_DATA.size():
		var pool: Array = ItemService.get_pool(tier, ItemService.TierData.ITEMS)
		var total := 0.0
		for item in pool:
			total += ItemService.get_value(
				wave, item.value, player_index, true, false, item.my_id_hash
			)
		result.push_back(total / pool.size() if not pool.empty() else 0.0)
	_mean_shop_price_cache[cache_key] = result
	return result


func _mean_shop_price_cache_key(wave: int, player_index: int) -> String:
	return (
		"%s|%s|%s|%s|%s"
		% [
			wave,
			player_index,
			RunData.get_player_effect(Keys.items_price_hash, player_index),
			RunData.get_player_effect(Keys.inflation_modifier_hash, 0),
			str(RunData.get_player_effect(Keys.specific_items_price_hash, player_index)),
		]
	)
