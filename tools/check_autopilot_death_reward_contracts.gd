extends Reference

const DEATH_REWARD_ADAPTER_PATH := (
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/rewards/"
	+ "death_reward_profile_adapter.gd"
)
const DEATH_REWARD_PROBABILITY_MODEL_PATH := (
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/"
	+ "death_reward_probability_model.gd"
)
const PRICING_MODEL_PATH := (
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/"
	+ "opportunity_pricing_model.gd"
)
var _failed := false


class DeathRewardStats:
	extends Resource
	var value := 6.0
	var base_drop_chance := 0.0
	var item_drop_chance := 0.0
	var always_drop_consumables := false
	var can_drop_consumables := false
	var gold_spread := 0.0


class MaterialQuantityEffect:
	extends Node
	var modifier := 0.0

	func _init(value: float) -> void:
		modifier = value

	func get_gold_value_modifier() -> float:
		return modifier


class DeathRewardUnit:
	extends Node
	var stats: Reference = DeathRewardStats.new()
	var can_drop_loot := true
	var effect_behaviors: Node = Node.new()
	var canonical_base_material_quantity := 100.0

	func _init() -> void:
		add_child(effect_behaviors)

	func get_stats_value() -> int:
		return int(canonical_base_material_quantity)


func run() -> bool:
	_check_death_reward_profile()
	_check_material_drop_probability()
	return not _failed


func _check_death_reward_profile() -> void:
	var adapter: Reference = load(DEATH_REWARD_ADAPTER_PATH).new()
	var unit := DeathRewardUnit.new()
	unit.effect_behaviors.add_child(MaterialQuantityEffect.new(0.5))
	var profile: Dictionary = adapter.adapt_enemy(unit)
	_expect(
		is_equal_approx(profile.material_quantity, 150.0),
		"canonical settlement quantity must compose with current material modifiers"
	)
	var observation := {
		"wave_state": {"number": 1, "is_horde": false},
		"player_state": {"effective_stats": {"luck": 0.0}},
	}
	var pricing: Reference = load(PRICING_MODEL_PATH).new()
	_expect(
		is_equal_approx(pricing.death_reward_value(observation, profile), 150.0),
		"priced kill rewards must preserve the adapted material value"
	)
	unit.stats.always_drop_consumables = true
	profile = adapter.adapt_enemy(unit)
	_expect(
		profile.material_drop_guaranteed and not profile.consumable_drop_guaranteed,
		"material guarantees must not invent unsupported consumables"
	)
	unit.queue_free()


func _check_material_drop_probability() -> void:
	var model: Reference = load(DEATH_REWARD_PROBABILITY_MODEL_PATH).new()
	var observation := {
		"wave_state": {"number": 20, "is_horde": false},
		"player_state": {"effective_stats": {"luck": 0.0}},
	}
	var profile := {"material_drop_guaranteed": false}
	var ordinary_probability: float = model.material_drop_probability(observation, profile)
	observation.wave_state.is_horde = true
	var horde_probability: float = model.material_drop_probability(observation, profile)
	profile.material_drop_guaranteed = true
	_expect(
		(
			is_equal_approx(ordinary_probability, 0.7)
			and is_equal_approx(horde_probability, 0.455)
			and is_equal_approx(model.material_drop_probability(observation, profile), 1.0)
		),
		"wave, horde, and guaranteed material-drop rules must compose"
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failed = true
	printerr("Autopilot death-reward contract failed: %s" % message)
