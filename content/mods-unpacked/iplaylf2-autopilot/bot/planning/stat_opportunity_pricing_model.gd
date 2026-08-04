extends Reference

# Converts player-stat changes into material-equivalent changes in future event
# opportunities.

const REFERENCE_MATERIAL_VALUES := {"curse": 0.7}


func value(observation: Dictionary, stat_changes: Array) -> float:
	var result := 0.0
	for change in stat_changes:
		if change.get("operation", "") != "add":
			continue
		result += _change_value(observation, change)
	return result


func _change_value(observation: Dictionary, change: Dictionary) -> float:
	var stat_name: String = change.get("stat", "")
	var reference_material_value: float = REFERENCE_MATERIAL_VALUES.get(stat_name, 0.0)
	if reference_material_value == 0.0:
		return 0.0
	var profile: Dictionary = observation.player_state.get("stat_opportunity_profiles", {}).get(
		stat_name, {}
	)
	if profile.empty():
		return 0.0
	var delta: float = change.get("value", 0.0)
	if delta == 0.0:
		return 0.0
	var reference_gain: float = (
		_opportunity_chance(profile, 1.0)
		- _opportunity_chance(profile, 0.0)
	)
	if reference_gain <= 0.0:
		return 0.0
	var current_value: float = observation.player_state.effective_stats.get(stat_name, 0.0)
	var next_opportunity_chance: float = _opportunity_chance(
		profile, max(0.0, current_value + delta)
	)
	var current_opportunity_chance: float = _opportunity_chance(profile, max(0.0, current_value))
	var marginal_gain := next_opportunity_chance - current_opportunity_chance
	return (
		reference_material_value
		* marginal_gain
		/ reference_gain
		* _remaining_run_opportunity_fraction(observation)
	)


func _opportunity_chance(profile: Dictionary, stat_value: float) -> float:
	if profile.get("curve", "") != "saturating_probability":
		return 0.0
	var scale: float = profile.get("scale", 0.0)
	if stat_value <= 0.0 or scale <= 0.0:
		return 0.0
	var value := 0.0
	for chance_limit in profile.get("chance_limits", []):
		value += max(0.0, float(chance_limit)) * (1.0 - 1.0 / (1.0 + stat_value / scale))
	return value


func _remaining_run_opportunity_fraction(observation: Dictionary) -> float:
	if observation.wave_state.get("endless", false):
		return 1.0
	var final_wave: float = max(1.0, observation.wave_state.get("final_number", 1.0))
	var current_wave: float = clamp(observation.wave_state.number, 1.0, final_wave)
	var duration: float = max(0.01, observation.wave_state.duration_seconds)
	var current_wave_fraction: float = clamp(
		observation.wave_state.seconds_remaining / duration, 0.0, 1.0
	)
	return clamp((final_wave - current_wave + current_wave_fraction) / final_wave, 0.0, 1.0)
