extends Reference

# Adapts target-version stat mechanics to normalized opportunity curves.

const CURSE_CURVE_SCALE := 50.0
const CURSED_ENEMY_CHANCE_LIMIT := 0.5

var _profiles := {}


func adapt() -> Dictionary:
	if _profiles.empty():
		_profiles = {
			"curse":
			{
				"curve": "saturating_probability",
				"scale": CURSE_CURVE_SCALE,
				"chance_limits": [CURSED_ENEMY_CHANCE_LIMIT, _get_cursed_item_chance_limit()],
			}
		}
	return _profiles


func _get_cursed_item_chance_limit() -> float:
	for dlc_data in ProgressData.available_dlcs:
		if "max_curse_item_chance" in dlc_data:
			return max(0.0, float(dlc_data.max_curse_item_chance))
	return 0.0
