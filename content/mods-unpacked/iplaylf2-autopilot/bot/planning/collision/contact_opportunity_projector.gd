extends Reference

# Maps a detected geometric contact and its source into the stable opportunity
# contract consumed by health-state propagation. An opportunity is predicted
# evidence, not an observed hit event.


func project_enemy_contact(
	time_seconds: float, track: Dictionary, realization_probability: float
) -> Dictionary:
	return {
		"time_seconds": time_seconds,
		"source_id": "enemy:%s" % track.track_id,
		"realization_probability": realization_probability,
		"raw_damage": track.behavior_profile.contact_damage,
		"source_consumed_on_contact": false,
	}


func project_projectile_contact(
	time_seconds: float,
	projectile_index: int,
	projectile: Dictionary,
	realization_probability: float
) -> Dictionary:
	return {
		"time_seconds": time_seconds,
		"source_id": "projectile:%s" % projectile_index,
		"realization_probability": realization_probability,
		"raw_damage": projectile.contact_damage,
		"source_consumed_on_contact": true,
	}
