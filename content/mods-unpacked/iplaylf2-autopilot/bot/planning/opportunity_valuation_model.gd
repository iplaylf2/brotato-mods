extends Reference

# Converts stable reward payloads into material-equivalent marginal value using
# only the current public player state. Geometry and event realization remain in
# their owning predictors.

const CONSUMABLE_DROP_OPPORTUNITY_VALUE := 1.0
const CURSE_STAT_OPPORTUNITY_VALUE := 0.7
const BONUS_REWARD_BASELINE_MATERIALS := 1.0
const PlayerRuleProjector := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/player_rule_projector.gd"
)

var _rule_projector: Reference = PlayerRuleProjector.new()


func tree_reward_value(observation: Dictionary, tree: Dictionary) -> float:
	var rewards: Dictionary = tree.get("destructible_profile", {}).get("kill_rewards", {})
	var kill_value := _kill_reward_value(observation, rewards)
	return (
		max(0.0, kill_value - _living_tree_preservation_value(observation))
		* tree_harvest_feasibility(observation, tree)
	)


func tree_harvest_feasibility(observation: Dictionary, tree: Dictionary) -> float:
	var required_hits: float = max(
		1.0, tree.get("destructible_profile", {}).get("destruction", {}).get("required_hits", 1.0)
	)
	var remaining_seconds: float = max(0.0, observation.wave_state.seconds_remaining)
	return clamp(_weapon_hit_rate(observation) * remaining_seconds / required_hits, 0.0, 1.0)


func bonus_kill_reward_value(observation: Dictionary, track: Dictionary) -> float:
	var rewards: Dictionary = track.behavior_profile.get("kill_rewards", {})
	if not rewards.get("has_bonus_reward", false):
		return 0.0
	return max(0.0, _kill_reward_value(observation, rewards) - BONUS_REWARD_BASELINE_MATERIALS)


func enemy_kill_feasibility(observation: Dictionary, track: Dictionary) -> float:
	var maximum_health: float = max(1.0, float(track.behavior_profile.durability.maximum_health))
	var remaining_seconds: float = max(0.0, observation.wave_state.seconds_remaining)
	var damage_rate := _weapon_damage_rate(observation)
	return clamp(damage_rate * remaining_seconds / maximum_health, 0.0, 1.0)


func consumable_recovery_value(observation: Dictionary, consumable: Dictionary) -> float:
	var missing_health: float = max(
		0.0, observation.player_state.health.maximum - observation.player_state.health.current
	)
	if missing_health <= 0.0:
		return 0.0
	var recovery: float = consumable.get("pickup_profile", {}).get("base_recovery", 0.0)
	recovery = _rule_projector.project_recovery(
		observation.player_state.effect_rules, "consumable_pickup", recovery
	)
	recovery = _rule_projector.project_recovery(
		observation.player_state.effect_rules, "healing", recovery
	)
	return min(missing_health, max(0.0, recovery)) / max(1.0, missing_health)


func _kill_reward_value(observation: Dictionary, rewards: Dictionary) -> float:
	var value: float = max(0.0, rewards.get("base_materials", 0.0))
	var drop_chance: float = clamp(rewards.get("consumable_drop_chance", 0.0), 0.0, 1.0)
	if rewards.get("guaranteed_consumable", false):
		drop_chance = 1.0
	else:
		var luck: float = observation.player_state.effective_stats.luck
		drop_chance = clamp(drop_chance * max(0.0, 1.0 + luck / 100.0), 0.0, 1.0)
	value += drop_chance * CONSUMABLE_DROP_OPPORTUNITY_VALUE
	value += max(0.0, rewards.get("curse_gain", 0.0)) * CURSE_STAT_OPPORTUNITY_VALUE
	return value


func _living_tree_preservation_value(observation: Dictionary) -> float:
	var result := 0.0
	for rule in observation.player_state.effect_rules:
		if rule.event != "wave_end":
			continue
		for consequence in rule.consequences:
			if consequence.target == "materials_and_experience_per_living_tree":
				result += max(0.0, consequence.get("value", 0.0))
	return result


func _weapon_damage_rate(observation: Dictionary) -> float:
	var result := 0.0
	for weapon in observation.player_state.weapons:
		var attack: Dictionary = weapon.attack_model
		var cycle_seconds: float = max(0.05, attack.timing.cycle_seconds)
		var path_count: float = max(1.0, float(attack.delivery.paths.count))
		var hit_probability: float = clamp(
			attack.delivery.paths.primary_probability_floor, 0.05, 1.0
		)
		var critical_multiplier: float = (
			1.0
			+ (
				clamp(attack.impact.critical_chance, 0.0, 1.0)
				* max(0.0, attack.impact.critical_damage_multiplier - 1.0)
			)
		)
		result += (
			attack.impact.damage
			* path_count
			* hit_probability
			* critical_multiplier
			/ cycle_seconds
		)
	return result


func _weapon_hit_rate(observation: Dictionary) -> float:
	var result := 0.0
	for weapon in observation.player_state.weapons:
		var attack: Dictionary = weapon.attack_model
		var cycle_seconds: float = max(0.05, attack.timing.cycle_seconds)
		var path_count: float = max(1.0, float(attack.delivery.paths.count))
		var hit_probability: float = clamp(
			attack.delivery.paths.primary_probability_floor, 0.05, 1.0
		)
		result += path_count * hit_probability / cycle_seconds
	return result
