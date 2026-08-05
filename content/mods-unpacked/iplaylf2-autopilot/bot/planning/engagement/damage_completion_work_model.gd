extends Reference

# Converts one discrete damage event into target-completion work. Damage beyond
# the target's remaining health has no additional completion value; damage below
# it advances exactly one of the integer hits still required at that hit size.


func hits_to_complete(remaining_health: float, damage_per_hit: float) -> float:
	if remaining_health <= 0.0:
		return 0.0
	if damage_per_hit <= 0.0:
		return INF
	return ceil(remaining_health / damage_per_hit)


func completion_fraction_per_hit(remaining_health: float, damage_per_hit: float) -> float:
	var required_hits := hits_to_complete(remaining_health, damage_per_hit)
	if is_inf(required_hits) or required_hits <= 0.0:
		return 0.0
	return 1.0 / required_hits
