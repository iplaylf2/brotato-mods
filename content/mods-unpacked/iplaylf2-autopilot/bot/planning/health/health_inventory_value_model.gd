extends Reference

# Prices health as a replenishable inventory. Immediate liquid health owns
# viability; time-feasible replenishment changes continuation value without
# pretending that future supply can absorb a hit before it arrives.

const HealthReplenishmentForecastModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/health/health_replenishment_forecast_model.gd"
)
const MovementTimingModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_timing_model.gd"
)
const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const EnemyReachEnvelopeModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_reach_envelope_model.gd"
)

# The sole material-equivalent risk-preference parameter. Timing and source
# availability belong to the replenishment forecast rather than this value scale.
const HEALTH_INVENTORY_VALUE_SCALE := 12.0

var _health_replenishment_forecast_model: Reference = HealthReplenishmentForecastModel.new()
var _movement_geometry_model: Reference = MovementGeometryModel.new()
var _enemy_reach_envelope_model: Reference = EnemyReachEnvelopeModel.new()


func estimate(
	observation: Dictionary, rule_projection: Dictionary, completion_ledger: Dictionary
) -> Dictionary:
	var current_health: float = observation.player_state.health.current
	var replenishment_forecast: Dictionary = _health_replenishment_forecast_model.forecast(
		observation, rule_projection, completion_ledger
	)
	var immediate_hit_reserve := _immediate_hit_reserve(observation)
	var immediate_survival_buffer := max(1.0, current_health - immediate_hit_reserve)
	var projected_health_inventory := max(
		1.0,
		(
			immediate_survival_buffer
			+ replenishment_forecast.total_replenishment
			- replenishment_forecast.expected_passive_health_drain
		)
	)
	var terminal_health_loss_unit_value := HEALTH_INVENTORY_VALUE_SCALE / immediate_survival_buffer
	var marginal_health_unit_value := HEALTH_INVENTORY_VALUE_SCALE / projected_health_inventory
	var result: Dictionary = replenishment_forecast.duplicate(false)
	result.merge(
		{
			"marginal_health_unit_value": marginal_health_unit_value,
			"terminal_health_loss_unit_value": terminal_health_loss_unit_value,
			"replenishment_unit_value": marginal_health_unit_value,
			"recovery_conversion_unit_value":
			max(0.0, terminal_health_loss_unit_value - marginal_health_unit_value),
			"immediate_hit_reserve": immediate_hit_reserve,
			"immediate_survival_buffer": immediate_survival_buffer,
			"projected_health_inventory": projected_health_inventory,
		},
		true
	)
	return result


func health_loss_value(expected_health_loss: float, inventory_value: Dictionary) -> float:
	var loss := max(0.0, expected_health_loss)
	if loss <= 0.0:
		return 0.0
	# The immediate buffer limits how much loss can be non-terminal. Replenishment
	# lowers the continuation cost of that survivable part, while any buffer overrun
	# retains the terminal price regardless of future supply.
	var immediate_buffer: float = max(1.0, inventory_value.immediate_survival_buffer)
	var projected_inventory: float = max(1.0, inventory_value.projected_health_inventory)
	var survivable_loss := min(loss, max(0.0, immediate_buffer - 1.0))
	var logarithmic_loss := min(survivable_loss, max(0.0, projected_inventory - 1.0))
	var value := (
		HEALTH_INVENTORY_VALUE_SCALE
		* (
			log(projected_inventory / max(1.0, projected_inventory - logarithmic_loss))
			+ survivable_loss
			- logarithmic_loss
		)
	)
	var terminal_loss := max(0.0, loss - survivable_loss)
	return value + terminal_loss * inventory_value.terminal_health_loss_unit_value


func _immediate_hit_reserve(observation: Dictionary) -> float:
	var maximum_raw_damage := 0.0
	var horizon: float = MovementTimingModel.clip_to_wave_remaining(
		observation, MovementTimingModel.control_interval_seconds()
	)
	var geometry: Dictionary = _movement_geometry_model.derive(observation)
	for projectile in observation.visible_world.enemy_projectiles:
		if _projectile_can_contact_player(observation, projectile, horizon, geometry):
			maximum_raw_damage = max(maximum_raw_damage, projectile.contact_damage)
	var knockback_reach: float = (
		observation.player_state.movement.knockback_velocity.length()
		* horizon
	)
	for track in observation.enemy_tracks:
		var contact_support_radius: float = _enemy_reach_envelope_model.contact_support_radius(
			track, horizon, knockback_reach, geometry.player_radius
		)
		if track.relative_position.length() <= contact_support_radius:
			maximum_raw_damage = max(maximum_raw_damage, track.behavior_profile.contact_damage)
	var armor: float = observation.player_state.runtime_stats.armor
	var armor_multiplier := (
		1.0 / (1.0 + armor / 15.0)
		if armor >= 0.0
		else 2.0 - 1.0 / (1.0 - armor / 15.0)
	)
	return round(maximum_raw_damage * armor_multiplier)


func _projectile_can_contact_player(
	observation: Dictionary, projectile: Dictionary, horizon: float, geometry: Dictionary
) -> bool:
	# Inventory value is built before an action is chosen. Bound the visible
	# projectile's path length so a curved path cannot disappear between endpoint
	# checks; candidate-specific swept geometry remains in the action predictor.
	var player_reach: float = (
		observation.player_state.movement.knockback_velocity.length()
		* horizon
	)
	var projectile_reach: float = (
		projectile.velocity.length() * horizon
		+ 0.5 * projectile.acceleration.length() * horizon * horizon
	)
	var motion_model: Dictionary = projectile.motion_model
	if motion_model.kind == "sinusoidal_velocity":
		projectile_reach += motion_model.velocity_amplitude.length() * horizon
	var contact_support: float = (
		geometry.player_radius
		+ projectile.contact_radius
		+ player_reach
		+ projectile_reach
	)
	return projectile.relative_position.length() <= contact_support
