extends Reference

# Interprets the two vanilla neutral-completion limits: ordinary health damage
# and the eligible-hit limit. Either can complete the target first.

const DamageCompletionWorkModel := preload(
	(
		"res://mods-unpacked/iplaylf2-autopilot/bot/planning/engagement/"
		+ "damage_completion_work_model.gd"
	)
)

var _damage_completion_work_model: Reference = DamageCompletionWorkModel.new()


func remaining_hits_to_limit(neutral: Dictionary) -> float:
	var hit_limit: float = max(1.0, float(neutral.destructible_profile.destruction.hit_limit))
	var state: Dictionary = neutral.get("destruction_state", {})
	if state.has("remaining_hits_to_limit"):
		return clamp(float(state.remaining_hits_to_limit), 0.0, hit_limit)
	if state.has("received_hits"):
		return clamp(hit_limit - float(state.received_hits), 0.0, hit_limit)
	return hit_limit


func remaining_health(neutral: Dictionary) -> float:
	var maximum_health: float = max(
		1.0, float(neutral.destructible_profile.destruction.maximum_health)
	)
	var state: Dictionary = neutral.get("destruction_state", {})
	var health: Dictionary = state.get("health", {})
	return clamp(float(health.get("current", maximum_health)), 0.0, maximum_health)


func expected_hits_to_complete(
	neutral: Dictionary, expected_damage_per_hit: float, instant_on_player_hit: bool
) -> float:
	var remaining_hit_limit: float = remaining_hits_to_limit(neutral)
	var health_remaining: float = remaining_health(neutral)
	if remaining_hit_limit <= 0.0 or health_remaining <= 0.0:
		return 0.0
	if instant_on_player_hit:
		return 1.0
	if expected_damage_per_hit <= 0.0:
		return remaining_hit_limit
	return min(
		remaining_hit_limit,
		_damage_completion_work_model.hits_to_complete(health_remaining, expected_damage_per_hit)
	)
