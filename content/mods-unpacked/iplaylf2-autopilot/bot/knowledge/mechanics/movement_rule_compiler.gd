extends Reference

const StatVocabulary := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/stat_vocabulary.gd"
)

var _stat_vocabulary: Reference = StatVocabulary.new()


func compile(effects: Dictionary, player: Node) -> Array:
	var rules := []
	_append_conditional_stats(
		rules,
		effects[Keys.temp_stats_while_not_moving_hash],
		false,
		player.not_moving_bonuses_applied
	)
	_append_conditional_stats(
		rules, effects[Keys.temp_stats_while_moving_hash], true, player.moving_bonuses_applied
	)

	if not bool(effects[Keys.can_attack_while_moving_hash]):
		rules.push_back(
			{
				"event": "movement_state",
				"condition": {"is_moving": true},
				"consequences":
				[
					{
						"target": "automatic_weapon_attack",
						"operation": "disable",
					}
				],
				"active": player._current_movement != Vector2.ZERO,
			}
		)
	return rules


func _append_conditional_stats(
	rules: Array, conditional_stats: Array, moving: bool, active: bool
) -> void:
	for entry in conditional_stats:
		if entry.size() < 2:
			continue
		var consequence := {}
		var cadence_seconds = null
		if entry[0] == Keys.percent_materials_hash:
			consequence = {
				"target": "materials",
				"operation": "add_percent_of_current",
				"percent": entry[1],
				"minimum_absolute_change": 1,
				"maximum_absolute_change": entry[2] if entry.size() >= 3 else null,
			}
			cadence_seconds = 1.0
		else:
			var stat_name := _stat_vocabulary.get_name(entry[0])
			if stat_name.empty():
				continue
			consequence = {
				"target": stat_name,
				"operation": "add",
				"value": entry[1],
			}

		rules.push_back(
			{
				"event": "movement_state",
				"condition": {"is_moving": moving},
				"consequences": [consequence],
				"cadence_seconds": cadence_seconds,
				"active": active,
			}
		)
