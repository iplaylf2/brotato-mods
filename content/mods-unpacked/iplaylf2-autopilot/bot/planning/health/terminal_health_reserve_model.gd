extends Reference

# Describes whether an action leaves the current immediate hit reserve intact
# after its forecast health loss. This is a state-space boundary, not a survival
# reward: utility can compare any outcomes that remain inside it, but cannot buy
# a transition out of it while an inside-domain action exists.


func evaluate(outcome: Dictionary, health_inventory_value: Dictionary) -> Dictionary:
	var forecast_health_loss: float = max(0.0, outcome.get("forecast_expected_health_loss", 0.0))
	# Outcome recovery has no within-window ordering contract. Counting a fruit or
	# lifesteal event that may occur after contact would let every rolling plan
	# borrow the same future recovery before it is observed. Realized recovery
	# enters the next observation as liquid health and expands the domain then.
	var reserve_margin: float = (
		health_inventory_value.immediate_survival_buffer
		- forecast_health_loss
	)
	return {
		"terminal_health_reserve_margin": reserve_margin,
		"retains_terminal_health_reserve": reserve_margin > 0.0,
	}
