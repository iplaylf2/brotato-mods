extends Reference

# Associates first-observed, mechanically guaranteed death products with
# previously seen enemies. A product can retire a track only when it falls in the
# mechanic support domain of exactly one tracked candidate; proximity alone does
# not identify a source.


func match_track_ids(candidates: Array, observations: Array) -> Array:
	var matches := []
	var unmatched_candidates: Array = candidates.duplicate(false)
	var unmatched_observations: Array = observations.duplicate(false)
	var matched_one := true
	while matched_one:
		matched_one = false
		for observation_index in unmatched_observations.size():
			var candidate_indices := _candidate_indices(
				unmatched_candidates, unmatched_observations[observation_index]
			)
			if candidate_indices.size() != 1:
				continue
			var candidate_index: int = candidate_indices[0]
			matches.push_back(unmatched_candidates[candidate_index].track_id)
			unmatched_candidates.remove(candidate_index)
			unmatched_observations.remove(observation_index)
			matched_one = true
			break
	return matches


func _candidate_indices(candidates: Array, observation: Dictionary) -> Array:
	var result := []
	for candidate_index in candidates.size():
		if _supports(candidates[candidate_index], observation):
			result.push_back(candidate_index)
	return result


func _supports(candidate: Dictionary, observation: Dictionary) -> bool:
	for product in candidate.products:
		if product.kind != observation.kind:
			continue
		var association_radius: float = (
			candidate.position_uncertainty_radius
			+ product.maximum_spawn_displacement
		)
		if (
			candidate.relative_position.distance_to(observation.relative_position)
			<= association_radius
		):
			return true
	return false
