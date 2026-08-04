extends Reference

# Adapts target-version player effects to one normalized observation contract.

const MovementRuleAdapter := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/player_effects/movement_rule_adapter.gd"
)
const PickupRuleAdapter := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/player_effects/pickup_rule_adapter.gd"
)
const WaveRuleAdapter := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/player_effects/wave_rule_adapter.gd"
)
const SurvivalRuleAdapter := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/player_effects/survival_rule_adapter.gd"
)
const CombatRuleAdapter := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/player_effects/combat_rule_adapter.gd"
)
const StatMetadata := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/stats/stat_metadata.gd"
)

var _movement_rule_adapter: Reference = MovementRuleAdapter.new()
var _pickup_rule_adapter: Reference = PickupRuleAdapter.new()
var _wave_rule_adapter: Reference = WaveRuleAdapter.new()
var _survival_rule_adapter: Reference = SurvivalRuleAdapter.new()
var _combat_rule_adapter: Reference = CombatRuleAdapter.new()
var _stat_metadata: Reference = StatMetadata.new()


func adapt(player_index: int, player: Node) -> Dictionary:
	var effects: Dictionary = RunData.get_player_effects(player_index)
	var rules := []
	rules.append_array(_movement_rule_adapter.adapt(effects, player))
	rules.append_array(_pickup_rule_adapter.adapt(effects, player_index))
	rules.append_array(_wave_rule_adapter.adapt(effects))
	rules.append_array(_survival_rule_adapter.adapt(effects, player_index))
	rules.append_array(_combat_rule_adapter.adapt(effects))
	_attach_stat_upgrade_values(rules)
	return {
		"effect_rules": rules,
		"automatic_attacks_allowed_while_moving": bool(effects[Keys.can_attack_while_moving_hash]),
		"instant_neutral_completion_on_player_hit": bool(effects[Keys.one_shot_trees_hash]),
	}


func _attach_stat_upgrade_values(rules: Array) -> void:
	for rule in rules:
		for consequence in rule.consequences:
			if consequence.operation != "add":
				continue
			var equivalent_value: float = _stat_metadata.upgrade_equivalent_value(
				consequence.target, consequence.get("value", 0.0)
			)
			if equivalent_value != 0.0:
				consequence.upgrade_equivalent_value = equivalent_value
