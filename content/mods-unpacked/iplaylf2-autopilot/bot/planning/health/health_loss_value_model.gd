extends Reference

# Prices projected or realized health depletion from any source against the same liquid-health
# inventory curve. This leaf model deliberately owns no source forecasting so
# collision, pickup, and navigation models can depend on it without forming a
# cycle through wave completion or opportunity pricing.


func value(
	expected_health_loss: float, inventory_value: Dictionary, continuation_horizon_ratio := 1.0
) -> float:
	var loss := max(0.0, expected_health_loss)
	if loss <= 0.0:
		return 0.0
	# Future replenishment cannot absorb a hit before it arrives. Pricing against
	# projected inventory would let a rolling planner borrow against the same supply
	# repeatedly, so every immediate source uses the liquid buffer.
	var immediate_buffer: float = max(1.0, inventory_value.immediate_survival_buffer)
	var value_scale: float = inventory_value.health_inventory_value_scale
	var survivable_loss := min(loss, max(0.0, immediate_buffer - 1.0))
	# Liquid health has no terminal value after vanilla resets next-wave health.
	# Preserve only the fraction needed beyond this forecast; exhausting the buffer
	# remains terminally expensive at every horizon.
	var result := (
		clamp(float(continuation_horizon_ratio), 0.0, 1.0)
		* (value_scale * log(immediate_buffer / max(1.0, immediate_buffer - survivable_loss)))
	)
	var terminal_loss := max(0.0, loss - survivable_loss)
	return result + terminal_loss * inventory_value.terminal_health_loss_unit_value
