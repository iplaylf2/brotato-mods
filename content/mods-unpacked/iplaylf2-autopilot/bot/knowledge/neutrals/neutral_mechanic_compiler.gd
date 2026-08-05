extends Reference

# Compiles a visible neutral's stable completion mechanics and reward inputs.
# Planning owns the state-dependent valuation of these raw mechanics.

const DeathRewardProfileAdapter := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/rewards/death_reward_profile_adapter.gd"
)

var _death_reward_profile_adapter: Reference = DeathRewardProfileAdapter.new()


func compile(neutral: Node) -> Dictionary:
	var result := {
		"destruction":
		{
			"hit_limit": 1.0,
			"maximum_health": max(1.0, float(neutral.max_stats.health)),
		},
		"death_rewards": _death_reward_profile_adapter.adapt_neutral(neutral),
	}
	if "number_of_hits_before_dying" in neutral:
		result.destruction.hit_limit = max(1.0, float(neutral.number_of_hits_before_dying))
	return result
