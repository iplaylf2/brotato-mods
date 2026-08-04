extends Reference

# Derives conservative distance envelopes from observed enemy motion and stable
# target-response mechanics. It owns spatial reach bounds, not trajectory shape,
# threat semantics, or target eligibility.


func maximum_displacement(track: Dictionary, horizon_seconds: float) -> float:
	var target_response: Dictionary = track.behavior_profile.get("target_position_response", {})
	var charge_attack: Dictionary = track.behavior_profile.get("charge_attack", {})
	var maximum_speed: float = max(
		track.estimated_velocity.length(), target_response.get("movement_speed", 0.0)
	)
	maximum_speed = max(maximum_speed, charge_attack.get("maximum_charge_speed", 0.0))
	var horizon := max(0.0, horizon_seconds)
	return maximum_speed * horizon + 0.5 * track.estimated_acceleration.length() * horizon * horizon


func contact_support_radius(
	track: Dictionary, horizon_seconds: float, player_reach: float, player_radius: float
) -> float:
	return (
		player_radius
		+ track.behavior_profile.contact_radius
		+ track.uncertainty_radius
		+ player_reach
		+ maximum_displacement(track, horizon_seconds)
	)
