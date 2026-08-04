extends Reference

# Resolves an enemy track's remaining health from the last visible measurement,
# falling back to the stable maximum-health prior when no measurement exists.
# Completion, pricing, and outcome models share this interpretation.


func remaining_health(track: Dictionary) -> float:
	var maximum_health: float = max(1.0, float(track.behavior_profile.durability.maximum_health))
	var observed_health: Dictionary = track.get("last_measurement", {}).get("health", {})
	return clamp(float(observed_health.get("current", maximum_health)), 1.0, maximum_health)
