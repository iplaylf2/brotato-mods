extends Reference

# Estimates whether the player's target-independent attack capacity can complete
# a visible enemy or remembered destructible before wave cleanup. Reward pricing
# and replenishment forecasting consume this shared mechanical projection.

const WeaponAttackCapacityModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/weapons/weapon_attack_capacity_model.gd"
)

var _weapon_attack_capacity_model: Reference = WeaponAttackCapacityModel.new()


func enemy_kill_feasibility(observation: Dictionary, track: Dictionary) -> float:
	var maximum_health: float = max(1.0, float(track.behavior_profile.durability.maximum_health))
	var remaining_seconds: float = max(0.0, observation.wave_state.seconds_remaining)
	var primary_damage_rate: float = _weapon_attack_capacity_model.expected_primary_damage_rate(
		observation.player_state.weapons
	)
	return clamp(primary_damage_rate * remaining_seconds / maximum_health, 0.0, 1.0)


func tree_destruction_feasibility(observation: Dictionary, tree: Dictionary) -> float:
	var required_hits: float = max(
		1.0, tree.get("destructible_profile", {}).get("destruction", {}).get("required_hits", 1.0)
	)
	var remaining_seconds: float = max(0.0, observation.wave_state.seconds_remaining)
	return clamp(
		(
			_weapon_attack_capacity_model.expected_primary_hit_rate(
				observation.player_state.weapons
			)
			* remaining_seconds
			/ required_hits
		),
		0.0,
		1.0
	)
