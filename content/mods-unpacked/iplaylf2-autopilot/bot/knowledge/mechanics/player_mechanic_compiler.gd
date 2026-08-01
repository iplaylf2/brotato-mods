extends Reference

# Combines independently changing mechanic families into the player's rule set.

const MovementRuleCompiler := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/mechanics/movement_rule_compiler.gd"
)
const PickupRuleCompiler := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/mechanics/pickup_rule_compiler.gd"
)
const WaveRewardRuleCompiler := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/mechanics/wave_reward_rule_compiler.gd"
)

var _movement_rules: Reference = MovementRuleCompiler.new()
var _pickup_rules: Reference = PickupRuleCompiler.new()
var _wave_reward_rules: Reference = WaveRewardRuleCompiler.new()


func compile(player_index: int, player: Node) -> Dictionary:
	var effects: Dictionary = RunData.get_player_effects(player_index)
	var rules := []
	rules.append_array(_movement_rules.compile(effects, player))
	rules.append_array(_pickup_rules.compile(effects))
	rules.append_array(_wave_reward_rules.compile(effects))
	return {
		"rules": rules,
		"automatic_attacks_allowed_while_moving": bool(effects[Keys.can_attack_while_moving_hash]),
	}
