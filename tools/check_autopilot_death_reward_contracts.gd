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
const ENEMY_MECHANIC_COMPILER_PATH := (
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/enemies/"
	+ "enemy_mechanic_compiler.gd"
)
const COMBAT_RULE_ADAPTER_PATH := (
	"res://mods-unpacked/iplaylf2-autopilot/bot/knowledge/player_effects/"
	+ "combat_rule_adapter.gd"
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


class DistanceScalingEffect:
	extends Resource
	var value := 100
	var min_value := -100
	var max_range := 200
	var buffer := 0
	var invert_scaling := false


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


class EnemyMechanicStats:
	extends Resource
	var speed := 0.0
	var health := 10.0


class EnemyHitboxState:
	extends Reference
	var damage := 1.0


class EnemyMechanicUnit:
	extends Node2D
	var enemy_id := ""
	var stats: Reference = EnemyMechanicStats.new()
	var max_stats: Reference = EnemyMechanicStats.new()
	var can_drop_loot := false
	var heal := 0.0
	var heal_increase_each_wave := 0.0
	var player_heal := 0.0
	var player_heal_increase_each_wave := 0.0
	var _hitbox: Reference = EnemyHitboxState.new()

	func _init(archetype: String, healing_radius := 0.0) -> void:
		enemy_id = archetype
		var hitbox := Node2D.new()
		hitbox.name = "Hitbox"
		var hitbox_collision := CollisionShape2D.new()
		hitbox_collision.name = "Collision"
		var hitbox_shape := CircleShape2D.new()
		hitbox_shape.radius = 10.0
		hitbox_collision.shape = hitbox_shape
		hitbox.add_child(hitbox_collision)
		add_child(hitbox)
		if healing_radius <= 0.0:
			return
		var boost_zone := Area2D.new()
		boost_zone.name = "BoostZone"
		var boost_collision := CollisionShape2D.new()
		boost_collision.name = "BoostCollision"
		var boost_shape := CircleShape2D.new()
		boost_shape.radius = healing_radius
		boost_collision.shape = boost_shape
		boost_zone.add_child(boost_collision)
		add_child(boost_zone)


func run() -> bool:
	_check_enemy_mechanic_profiles()
	_check_death_reward_profile()
	_check_action_conditioned_enemy_material_reward()
	_check_material_drop_probability()
	return not _failed


func _check_enemy_mechanic_profiles() -> void:
	var compiler: Reference = load(ENEMY_MECHANIC_COMPILER_PATH).new()
	var sea_pig := EnemyMechanicUnit.new("sea_pig")
	var sea_pig_profile: Dictionary = compiler.compile(sea_pig)
	var stat_changes: Array = sea_pig_profile.death_rewards.stat_changes
	_expect(
		(
			stat_changes.size() == 1
			and stat_changes[0].stat == "curse"
			and stat_changes[0].operation == "add"
			and is_equal_approx(stat_changes[0].value, 1.0)
		),
		"enemy mechanics must expose deterministic death stat changes"
	)
	var healer := EnemyMechanicUnit.new("healer", 200.0)
	healer.heal = 100.0
	var healer_profile: Dictionary = compiler.compile(healer)
	_expect(
		is_equal_approx(healer_profile.battlefield_effects.enemy_healing_radius, 200.0),
		"enemy mechanics must expose the named healing trigger geometry"
	)
	sea_pig.queue_free()
	healer.queue_free()


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
		"wave_state":
		{
			"number": 1,
			"final_number": 20,
			"duration_seconds": 20.0,
			"seconds_remaining": 20.0,
			"endless": true,
			"is_horde": false,
		},
		"player_state":
		{
			"effective_stats": {"luck": 0.0, "curse": 0.0},
			"stat_opportunity_profiles":
			{
				"curse":
				{
					"curve": "saturating_probability",
					"scale": 50.0,
					"chance_limits": [0.5, 0.15],
				}
			},
		},
	}
	var pricing: Reference = load(PRICING_MODEL_PATH).new()
	_expect(
		is_equal_approx(pricing.death_reward_value(observation, profile), 150.0),
		"priced kill rewards must preserve the adapted material value"
	)
	profile.stat_changes = [{"stat": "curse", "operation": "add", "value": 1.0}]
	var reward_without_stat: Dictionary = profile.duplicate(true)
	reward_without_stat.stat_changes = []
	var endless_stat_value: float = (
		pricing.death_reward_value(observation, profile)
		- pricing.death_reward_value(observation, reward_without_stat)
	)
	observation.wave_state.endless = false
	var scheduled_stat_value: float = (
		pricing.death_reward_value(observation, profile)
		- pricing.death_reward_value(observation, reward_without_stat)
	)
	_expect(
		is_equal_approx(endless_stat_value - scheduled_stat_value, 0.7),
		"endless pricing must add one bounded tail without replacing scheduled waves"
	)
	observation.wave_state.endless = true
	observation.wave_state.number = 21
	var post_campaign_without_stat: Dictionary = profile.duplicate(true)
	post_campaign_without_stat.stat_changes = []
	var post_campaign_stat_value: float = (
		pricing.death_reward_value(observation, profile)
		- pricing.death_reward_value(observation, post_campaign_without_stat)
	)
	_expect(
		is_equal_approx(post_campaign_stat_value, 0.7),
		"the post-campaign endless tail must remain a bounded one-wave opportunity"
	)
	observation.wave_state.endless = false
	observation.wave_state.number = 5
	observation.wave_state.duration_seconds = 40.0
	observation.wave_state.seconds_remaining = 20.0
	var recurring_stat_value: float = (
		pricing.death_reward_value(observation, profile)
		- pricing.death_reward_value(observation, reward_without_stat)
	)
	_expect(
		is_equal_approx(recurring_stat_value, 10.85),
		(
			"a durable stat reward must retain one opportunity contribution for every "
			+ "remaining wave equivalent"
		)
	)
	unit.stats.always_drop_consumables = true
	profile = adapter.adapt_enemy(unit)
	_expect(
		profile.material_drop_guaranteed and not profile.consumable_drop_guaranteed,
		"material guarantees must not invent unsupported consumables"
	)
	unit.queue_free()


func _check_action_conditioned_enemy_material_reward() -> void:
	var effects := {
		Keys.scale_materials_with_distance_hash: [DistanceScalingEffect.new()],
		Keys.bonus_non_elemental_damage_against_burning_targets_hash: 0.0,
		Keys.gold_on_crit_kill_hash: [],
		Keys.heal_on_crit_kill_hash: 0.0,
	}
	var adapter: Reference = load(COMBAT_RULE_ADAPTER_PATH).new()
	var rules: Array = adapter.adapt(effects)
	_expect(
		(
			rules.size() == 1
			and rules[0].event == "enemy_death"
			and rules[0].consequences[0].target == "enemy_material_reward"
		),
		"distance-scaled enemy materials must cross the knowledge boundary as a generic rule"
	)
	var observation := {
		"wave_state": {"number": 1, "seconds_remaining": 20.0, "duration_seconds": 20.0},
		"player_state":
		{
			"effective_stats": {"luck": 0.0, "curse": 0.0},
			"stat_opportunity_profiles": {},
			"effect_rules": rules,
		},
	}
	var death_rewards := {
		"material_quantity": 10.0,
		"material_drop_guaranteed": true,
		"base_consumable_drop_chance": 0.0,
		"item_box_conditional_chance": 0.0,
		"stat_changes": [],
	}
	var pricing: Reference = load(PRICING_MODEL_PATH).new()
	var profile: Dictionary = pricing.enemy_death_reward_profile(observation, death_rewards)
	_expect(
		(
			is_equal_approx(pricing.enemy_death_reward_value_at_distance(profile, 0.0), 0.0)
			and is_equal_approx(pricing.enemy_death_reward_value_at_distance(profile, 100.0), 10.0)
			and is_equal_approx(pricing.enemy_death_reward_value_at_distance(profile, 200.0), 20.0)
		),
		(
			"enemy material value must follow the observed clamped distance curve without "
			+ "changing non-material death rewards"
		)
	)


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
