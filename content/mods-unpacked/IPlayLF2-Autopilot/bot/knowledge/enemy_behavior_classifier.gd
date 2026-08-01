extends Reference

# Fixed, hand-authored prior experience. It adds semantic hypotheses to exact
# observable measurements; it never replaces those measurements with buckets and never
# depends on content IDs or per-run learning.

const STATIONARY_SPEED := 5.0
const FAST_CLOSING_SPEED := 90.0


func accumulate_evidence(previous: Dictionary, measurement: Dictionary) -> Dictionary:
	if previous.empty():
		return {
			"peak_observed_speed": measurement.observed_speed,
			"peak_closing_speed": measurement.closing_speed,
			"ranged_attack_inferred": measurement.ranged_attack_inferred,
		}
	return {
		"peak_observed_speed": max(previous.peak_observed_speed, measurement.observed_speed),
		"peak_closing_speed": max(previous.peak_closing_speed, measurement.closing_speed),
		"ranged_attack_inferred":
		previous.ranged_attack_inferred or measurement.ranged_attack_inferred,
	}


func classify(evidence: Dictionary) -> Dictionary:
	return {
		"attack_behavior":
		{
			"kind":
			"ranged_projectile_inferred" if evidence.ranged_attack_inferred else "unconfirmed",
			"confidence": 0.9 if evidence.ranged_attack_inferred else 0.5,
		},
		"movement_behavior": _classify_movement(evidence),
	}


func _classify_movement(evidence: Dictionary) -> Dictionary:
	if evidence.peak_observed_speed < STATIONARY_SPEED:
		return {"kind": "stationary_observed", "confidence": 0.9}
	if evidence.peak_closing_speed >= FAST_CLOSING_SPEED:
		return {"kind": "fast_closing_observed", "confidence": 0.75}
	return {"kind": "mobile_observed", "confidence": 0.55}
