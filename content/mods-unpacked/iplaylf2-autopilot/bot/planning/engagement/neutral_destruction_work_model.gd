extends Reference

# Interprets the latest visible neutral-destruction measurement as remaining
# completion work. Observation owns the mutable hit count; reward pricing and
# attack-capacity models consume this one planning-side interpretation.


func remaining_hits(neutral: Dictionary) -> float:
	var required_hits: float = max(
		1.0,
		neutral.get("destructible_profile", {}).get("destruction", {}).get("required_hits", 1.0)
	)
	var progress: Dictionary = neutral.get("destruction_progress", {})
	if progress.has("remaining_hits"):
		return clamp(float(progress.remaining_hits), 0.0, required_hits)
	if progress.has("completed_hits"):
		return clamp(required_hits - float(progress.completed_hits), 0.0, required_hits)
	return required_hits
